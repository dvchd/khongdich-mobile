import 'package:cached_network_image/cached_network_image.dart';
import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/database/app_database.dart';
import '../../core/markdown/markdown.dart';
import '../../core/network/app_image_cache.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/format.dart';
import '../../core/widgets/app_bottom_nav.dart';
import '../../core/widgets/app_retry_view.dart';
import '../../core/widgets/app_snack_bar.dart';
import '../../core/widgets/follow_button.dart';
import '../../core/widgets/report_sheet.dart';
import '../../core/widgets/share_story_sheet.dart';
import '../../models/story.dart' show ChapterSummary, StorySummary;
import '../../repositories/story_repository.dart';
import '../../services/download_manager.dart';
import '../bookshelf/bookshelf_screen.dart' show bookshelfProvider;
import '../profile/profile_screen.dart' show currentUserProvider;
import '../tts/tts_now_playing_bar.dart';

/// Stream of download queue rows for a specific story — auto-updates
/// via Drift's `watch()`.
final downloadQueueForStoryProvider =
    StreamProvider.autoDispose.family<List<DownloadQueueData>, String>(
        (ref, storyId) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.downloadQueue)
        ..where((t) => t.storyId.equals(storyId))
        ..orderBy([(t) => OrderingTerm.desc(t.queuedAt)]))
      .watch();
});

/// Stream of downloaded chapters for a specific story — auto-updates
/// via Drift's `watch()`.
///
/// **Filter**: chỉ hiện `manual_download` (user chủ động bấm download).
/// `auto_cache` (prefetch ngầm) bị ẩn — story detail chỉ count chương
/// user thực sự bấm download, không count auto-cache.
final downloadedChaptersForStoryProvider =
    StreamProvider.autoDispose.family<List<DownloadedChapter>, String>(
        (ref, storyId) {
  final db = ref.watch(appDatabaseProvider);
  return (db.select(db.downloadedChapters)
        ..where((t) => t.storyId.equals(storyId))
        ..where((t) => t.source.equals('manual_download'))
        ..orderBy([(t) => OrderingTerm.asc(t.chapterNumber)]))
      .watch();
});

/// VIP status for a story — fetched once when the story detail loads.
/// Provides `is_vip` flag, locked chapter IDs, and whether the user
/// can download offline (only story-wide VIP grants allow offline).
final vipStatusProvider =
    FutureProvider.autoDispose.family<VipStatus, String>((ref, storyId) async {
  final repo = ref.watch(storyRepositoryProvider);
  return repo.fetchVipStatus(storyId);
});

/// Bookmark listType của MỘT story, phản ứng theo [bookshelfProvider] —
/// sau toggle bookmark icon cập nhật ngay mà KHÔNG cần invalidate
/// detail provider (invalidate trước đây refetch cả màn → loading flash
/// + mất scroll position của danh sách chương).
final storyBookmarkTypeProvider =
    Provider.autoDispose.family<String?, String>((ref, storyId) {
  final state = ref.watch(bookshelfProvider);
  final list = state.value;
  if (list == null) return null;
  for (final b in list) {
    if (b.storyId == storyId) return b.listType;
  }
  return null;
});

/// Story detail screen. Plan §5.3.
///
/// Hits:
///   - `GET /api/v1/mobile/stories/{slug}` → StoryDetailPayload
///   - `GET /api/v1/mobile/stories/{id}/chapters` → paginated chapter list
class StoryDetailScreen extends ConsumerWidget {
  const StoryDetailScreen({super.key, required this.storySlug});

  final String storySlug;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(_storyDetailProvider(storySlug));
    return Scaffold(
      body: detailAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => AppRetryView(
          message: 'Không tải được truyện.',
          detail: '$e',
          onRetry: () => ref.invalidate(_storyDetailProvider(storySlug)),
        ),
        data: (result) => _StoryDetailBody(detail: result.detail, localBookmark: result.localBookmark),
      ),
      // Bottom nav so the user can jump between Home / Search /
      // Bookshelf / Profile directly from the story detail page
      // (this screen lives outside MainShell). TTS now-playing bar nằm
      // TRONG slot này (trên menu) — vị trí thực, Scaffold tự thu hẹp
      // body nên không đè nội dung như overlay nổi.
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const TtsNowPlayingBar(),
          const AppBottomNav(currentIndex: -1),
        ],
      ),
    );
  }
}

class _StoryDetailBody extends ConsumerWidget {
  const _StoryDetailBody({required this.detail, this.localBookmark});
  final StoryDetailPayload detail;
  final String? localBookmark;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final story = detail.story;
    // Reactive bookmark — cập nhật ngay sau toggle, không invalidate
    // detail provider (giữ scroll + không refetch toàn màn).
    final reactiveBookmark =
        ref.watch(storyBookmarkTypeProvider(story.id));
    final effectiveBookmark = reactiveBookmark ?? localBookmark;
    final currentUser = ref.watch(currentUserProvider).value;
    final chaptersAsync = ref.watch(chapterListProvider(story.id));
    final downloadedAsync = ref.watch(downloadedChaptersForStoryProvider(story.id));
    final queueAsync = ref.watch(downloadQueueForStoryProvider(story.id));
    final vipAsync = ref.watch(vipStatusProvider(story.id));
    final vip = vipAsync.value ?? const VipStatus(isVip: false, lockedChapterIds: [], unlockedChapterIds: [], canDownloadOffline: true);
    final queueItems = queueAsync.value ?? [];
    final downloadedIds = downloadedAsync.value?.map((d) => d.chapterId).toSet() ?? {};
    final downloadedCount = downloadedAsync.value?.length ?? 0;
    final totalChapters = story.chapterCount ?? 0;
    final activeDownloads = queueItems.where((q) =>
        q.status == 'pending' || q.status == 'downloading' || q.status == 'retry').length;
    final queueStatus = {for (final q in queueItems) q.chapterId: q.status};
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          pinned: true,
          title: Text(
            story.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.share_outlined),
              tooltip: 'Chia sẻ truyện',
              onPressed: () => showStoryShareSheet(
                context,
                storySlug: story.slug,
                storyTitle: story.title,
              ),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              tooltip: 'Thêm',
              onSelected: (value) {
                if (value == 'report') {
                  showReportSheet(
                    context,
                    targetType: 'story',
                    targetId: story.id,
                    targetLabel: 'truyện',
                  );
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'report',
                  child: Row(
                    children: [
                      Icon(Icons.flag_outlined, size: 18),
                      SizedBox(width: 10),
                      Text('Báo cáo vi phạm'),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
        // Cover + info — căn giữa, bìa to 3:4 (giống web mobile-first:
        // `.cover-lg` centered, up to 300px; desktop mới chuyển sang 2 cột
        // cover trái + info phải).
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Bìa to căn giữa — 3:4 như web.
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 280),
                    child: AspectRatio(
                      aspectRatio: 3 / 4,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: story.coverUrl == null ||
                                story.coverUrl!.isEmpty
                            ? Container(
                                color: AppTheme.primary.withValues(
                                  alpha: 0.2,
                                ),
                                child: const Icon(Icons.book, size: 48),
                              )
                            : CachedNetworkImage(
                                imageUrl: story.coverUrl!,
                                cacheManager: AppImageCache.instance,
                                fit: BoxFit.cover,
                                // Bìa hiển thị ~200-280px logical → decode
                                // 720px cho nét trên màn 3x (trước đây 360px
                                // bị upscale → bìa mờ).
                                memCacheWidth: 720,
                                errorWidget: (_, _, _) => Container(
                                  color: AppTheme.primary.withValues(
                                    alpha: 0.2,
                                  ),
                                  child: const Icon(Icons.book, size: 48),
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  story.title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 4),
                // Tên tác giả + nút Theo dõi trên CÙNG một dòng — Wrap
                // căn giữa, chỉ tràn màn hình mới xuống dòng (trước đây
                // nút luôn nằm riêng một dòng dưới tên tác giả). Tên tác
                // giả chạm để mở trang tác giả; không có username (dữ
                // liệu cũ) → không bấm được.
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 10,
                  runSpacing: 4,
                  children: [
                    Builder(
                      builder: (context) {
                        final username = detail.authorUsername;
                        final authorText = Text(
                          story.author,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: username.isNotEmpty
                                ? AppTheme.primary
                                : null,
                            decoration: username.isNotEmpty
                                ? TextDecoration.underline
                                : TextDecoration.none,
                            decorationColor: AppTheme.primary.withValues(
                              alpha: 0.5,
                            ),
                          ),
                        );
                        if (username.isEmpty) {
                          return authorText;
                        }
                        return InkWell(
                          onTap: () => context.push('/author/$username'),
                          borderRadius: BorderRadius.circular(4),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: authorText,
                          ),
                        );
                      },
                    ),
                    if (detail.authorId.isNotEmpty &&
                        currentUser?.id != detail.authorId)
                      FollowButton(
                        authorId: detail.authorId,
                        initialFollowing: detail.isFollowing,
                        initialFollowerCount: 0,
                        compact: true,
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (detail.danh != null && detail.danh!.imageUrl.isNotEmpty)
                  // Danh hiệu truyện — ảnh tĩnh/động do hệ thống tạo,
                  // hiển thị dưới tên tác giả, trên badge thể loại (cùng
                  // vị trí web). Chiều cao ~1.7cm (64 logical px).
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Tooltip(
                      message: detail.danh!.name,
                      child: CachedNetworkImage(
                        imageUrl: detail.danh!.imageUrl,
                        width: double.infinity,
                        height: 64,
                        fit: BoxFit.contain,
                        placeholder: (_, __) => const SizedBox(
                          height: 64,
                          child: Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        ),
                        errorWidget: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (story.contentTypes.isNotEmpty)
                      _ContentTypeBadge(contentType: story.contentTypes.first),
                    if (story.status != null)
                      _StatusChip(status: story.status!),
                    if (vip.isVip)
                      // Cùng dáng pill + cỡ chữ 12 như _ContentTypeBadge /
                      // _StatusChip — trước đây dùng Material Chip (label
                      // ~14px, bo góc vuông hơn) trông lạc quẻ cạnh các
                      // badge còn lại.
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEF3C7),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.workspace_premium,
                                size: 12, color: Color(0xFFD97706)),
                            SizedBox(width: 4),
                            Text('VIP',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFFD97706),
                                    height: 1.2)),
                          ],
                        ),
                      ),
                    if (effectiveBookmark != null)
                      _BookmarkChip(listType: effectiveBookmark),
                    if (downloadedCount > 0)
                      // Cùng dáng pill như các badge còn lại — trước đây
                      // dùng Material Chip (cao hơn, bo góc khác) trông
                      // lạc quẻ trong hàng badge.
                      _InfoPill(
                        icon: Icons.download_done,
                        iconColor: const Color(0xFF16A34A),
                        background: const Color(0xFF16A34A).withValues(alpha: 0.12),
                        label: '$downloadedCount${totalChapters > 0 ? '/$totalChapters' : ''} đã tải',
                      ),
                    if (activeDownloads > 0)
                      _InfoPill(
                        spinner: true,
                        iconColor: const Color(0xFF2563EB),
                        background: const Color(0xFF2563EB).withValues(alpha: 0.12),
                        label: 'Đang tải $activeDownloads…',
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (story.categories.isNotEmpty || story.tags.isNotEmpty) ...[
                  // Một hàng badge liền mạch như web (.badges): thể loại nền
                  // trung tính, tag nền accent nhạt — thay ActionChip nặng
                  // (viền + ripple) bằng pill nhẹ dễ quét mắt.
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (var i = 0; i < story.categories.length; i++)
                        _GenreBadge(
                          label: story.categories[i],
                          onTap: () {
                            final slug = i < story.categorySlugs.length
                                ? story.categorySlugs[i]
                                : story.categories[i];
                            context.push(
                              '/category/$slug',
                              extra: story.categories[i],
                            );
                          },
                        ),
                      for (var i = 0; i < story.tags.length; i++)
                        _GenreBadge(
                          label: story.tags[i],
                          isTag: true,
                          onTap: () {
                            final slug = i < story.tagSlugs.length
                                ? story.tagSlugs[i]
                                : story.tags[i];
                            context.push(
                              '/tag/$slug',
                              extra: story.tags[i],
                            );
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                // Hàng thống kê — mirror web .stats (⭐ / 👁 / 📖 / ✏️).
                _StoryStats(
                  rating: story.rating,
                  viewCount: story.viewCount,
                  chapterCount: story.chapterCount,
                  wordCount: story.wordCount,
                ),
                const SizedBox(height: 12),
                // Giới thiệu — render markdown giống web (web dùng
                // render_vietnamese_text cho synopsis_html). Trước đây hiện
                // plain text nên **đậm**, danh sách, link... hiện nguyên
                // cú pháp thô.
                _StorySynopsis(text: story.synopsis),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Builder(
                        builder: (context) {
                          // "Tiếp tục đọc" như web: có last_read_chapter →
                          // vào thẳng chương đó; không → "Bắt đầu đọc".
                          final resume = detail.lastReadChapter;
                          final target = (resume != null &&
                                  resume != detail.firstChapter)
                              ? resume
                              : detail.firstChapter;
                          return FilledButton.icon(
                            onPressed: target == null
                                ? null
                                : () => context.push(
                                    '/chapter/${story.id}:$target'),
                            icon: const Icon(Icons.menu_book),
                            label: Text(
                              resume != null
                                  ? 'Tiếp tục chương $resume'
                                  : 'Bắt đầu đọc',
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.outlined(
                      icon: Icon(effectiveBookmark == null
                          ? Icons.bookmark_border
                          : Icons.bookmark),
                      tooltip: 'Thêm vào tủ truyện — giữ để chọn danh sách',
                      onPressed: () async {
                        final added = await ref
                            .read(bookshelfProvider.notifier)
                            .toggle(
                              story.id,
                              title: story.title,
                              slug: story.slug,
                              coverUrl: story.coverUrl,
                              author: story.author,
                              contentType: story.contentTypes.isNotEmpty
                                  ? story.contentTypes.first
                                  : 'text',
                            );
                        // Bookmark icon giờ phản ứng qua
                        // storyBookmarkTypeProvider — không invalidate
                        // detail provider nữa (giữ scroll + hết loading
                        // flash cả màn mỗi lần bấm bookmark).
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(added
                                  ? 'Đã thêm vào tủ truyện'
                                  : 'Đã xoá khỏi tủ truyện'),
                              duration: const Duration(seconds: 1),
                            ),
                          );
                        }
                      },
                      onLongPress: () => _pickBookmarkType(
                        context,
                        ref,
                        story,
                        effectiveBookmark,
                      ),
                    ),
                    IconButton.outlined(
                      tooltip: activeDownloads > 0
                          ? 'Đang tải $activeDownloads chương — xem tiến trình'
                          : 'Tải xuống để đọc offline',
                      icon: activeDownloads > 0
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : (downloadedCount > 0
                              ? const Icon(Icons.download_done, color: Colors.green)
                              : const Icon(Icons.download_outlined)),
                      // Download luôn enable — download manager sẽ check
                      // per-chapter access (fetchChapterAccess) và mark
                      // failed cho chapter user không có quyền. Trước đây
                      // disable nút khi vip.isVip && !canDownloadOffline
                      // (chỉ story-wide grant mới cho download) — quá
                      // strict, user có per-chapter grant vẫn không tải
                      // được dù có quyền đọc chapter đó.
                      //
                      // Khi đang có download chạy → bấm nút mở màn Tải
                      // xuống xem tiến trình (trước đây nút bị disable
                      // im lặng, user không biết queue đang kẹt hay chạy).
                      onPressed: activeDownloads > 0
                          ? () => context.push('/downloads')
                          : () async {
                        List<ChapterSummary> chapters;
                        try {
                          final repo = ref.read(storyRepositoryProvider);
                          chapters = await repo.fetchAllChapters(story.id);
                        } catch (e) {
                          // Offline / 5xx — trước đây unhandled async
                          // error, không có phản hồi gì cho user.
                          if (context.mounted) {
                            showAppSnackBar(
                              context,
                              'Không tải được danh sách chương: $e',
                            );
                          }
                          return;
                        }
                        if (chapters.isEmpty) {
                          if (context.mounted) {
                            showAppSnackBar(context, 'Chưa có chương để tải.');
                          }
                          return;
                        }
                        // Download tất cả chapters — download manager
                        // sẽ check access per-chapter. Chapter nào user
                        // không có quyền → mark failed với message rõ
                        // ràng, các chapter khác vẫn tải bình thường.
                        final total = chapters.length;
                        final already = downloadedIds.length;
                        final enqueued = await ref.read(downloadManagerProvider).enqueueAllChapters(
                          storyId: story.id,
                          storySlug: story.slug,
                          chapters: chapters,
                          storyTitle: story.title,
                          coverUrl: story.coverUrl,
                          storyAuthor: story.author,
                          storySynopsis: story.synopsis,
                        );
                        ref.invalidate(downloadedChaptersForStoryProvider(story.id));
                        if (context.mounted) {
                          final msg = enqueued == 0
                              ? 'Đã tải xong $already/$total chương.'
                              : 'Đang tải $enqueued chương (đã có $already/$total).';
                          showAppSnackBar(context, msg);
                        }
                      },
                    ),
                  ],
                ),
                // Khoảng nghỉ giữa hàng "Bắt đầu đọc + bookmark + tải" và
                // khối bình luận/tuỷ sách bên dưới — trước đây dính sát
                // nhau (padding 16 của container là chưa đủ).
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: _StorySocialSection(
            storyId: story.id,
            storySlug: story.slug,
            storyTitle: story.title,
            initialRating: story.rating,
            initialReviewCount: story.reviewCount,
            initialCommentCount: detail.commentCount,
          ),
        ),
        const SliverToBoxAdapter(child: Divider(height: 1)),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          sliver: SliverToBoxAdapter(
            child: Row(
              children: [
                Text(
                  'Danh sách chương',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                chaptersAsync.maybeWhen(
                  data: (chapters) => Text(
                    '${chapters.length} chương',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  orElse: () => const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
        chaptersAsync.when(
          loading: () => const SliverFillRemaining(
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => SliverFillRemaining(
            hasScrollBody: false,
            child: AppRetryView(
              message: 'Không tải được danh sách chương.',
              detail: '$e',
              onRetry: () =>
                  ref.invalidate(chapterListProvider(story.id)),
            ),
          ),
          data: (chapters) => chapters.isEmpty
              ? const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text('Chưa có chương nào.'),
                    ),
                  ),
                )
              : SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final c = chapters[i];
                      // Only pending / downloading / retry count as
                      // "active in queue" — a `completed` queue row
                      // means the chapter is on disk and should render
                      // the green checkmark, not a spinner.
                      final queueState = queueStatus[c.id];
                      final isActiveInQueue = queueState == 'pending' ||
                          queueState == 'downloading' ||
                          queueState == 'retry';
                      final isDownloaded = downloadedIds.contains(c.id);
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor:
                              AppTheme.primary.withValues(alpha: 0.12),
                          child: Text(
                            '${c.chapterNumber}',
                            style: const TextStyle(color: AppTheme.primary),
                          ),
                        ),
                        title: Text(
                          c.title.isEmpty
                              ? 'Chương ${c.chapterNumber}'
                              : c.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(_chapterSubtitle(story, c)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (vip.isChapterLocked(c.id))
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Icon(
                                  vip.isChapterUnlocked(c.id)
                                      ? Icons.lock_open
                                      : Icons.lock,
                                  size: 16,
                                  color: vip.isChapterUnlocked(c.id)
                                      ? const Color(0xFF10B981) // xanh — đã mở khóa
                                      : const Color(0xFFD97706), // vàng — chưa mở khóa
                                ),
                              ),
                            if (queueState == 'pending')
                              const Padding(
                                padding: EdgeInsets.only(right: 4),
                                child: Icon(Icons.hourglass_top, size: 16, color: Colors.grey),
                              ),
                            if (queueState == 'downloading')
                              const Padding(
                                padding: EdgeInsets.only(right: 4),
                                child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                            if (isDownloaded && !isActiveInQueue)
                              const Padding(
                                padding: EdgeInsets.only(right: 4),
                                child: Icon(Icons.download_done, size: 16, color: Colors.green),
                              ),
                            // Nút tải TỪNG chương — trước đây chỉ có nút
                            // "tải toàn bộ" ở header, user muốn tải 1
                            // chương phải tải cả truyện (216 chương).
                            if (!isDownloaded && !isActiveInQueue)
                              IconButton(
                                icon: const Icon(Icons.download_outlined, size: 20),
                                tooltip: 'Tải chương ${c.chapterNumber} để đọc offline',
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _downloadChapter(
                                    context, ref, story, c),
                              ),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                        onTap: () =>
                            context.push('/chapter/${story.id}:${c.chapterNumber}'),
                      );
                    },
                    childCount: chapters.length,
                  ),
                ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  /// Subtitle mỗi dòng chương: số từ (+ lượt đọc nếu có). Loại truyện
  /// ("Truyện chữ") đã hiện ở badge trên đầu trang — lặp lại ở từng
  /// chương là thừa. Backend trả sẵn `word_count` / `view_count` trong
  /// ChapterMeta — không cần đẩy gì thêm, UI chỉ hiển thị.
  String _chapterSubtitle(StorySummary story, ChapterSummary c) {
    final parts = <String>[];
    if (c.wordCount > 0) parts.add('${formatCount(c.wordCount)} từ');
    if (c.viewCount > 0) {
      parts.add('${formatCount(c.viewCount)} đọc');
    }
    return parts.join(' · ');
  }

  /// Tải một chương đơn lẻ (nút ⬇ ở mỗi dòng danh sách chương).
  Future<void> _downloadChapter(
    BuildContext context,
    WidgetRef ref,
    StorySummary story,
    ChapterSummary c,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final enqueued = await ref.read(downloadManagerProvider).enqueueChapter(
        storyId: story.id,
        storySlug: story.slug,
        chapterId: c.id,
        chapterNumber: c.chapterNumber,
        storyTitle: story.title,
        coverUrl: story.coverUrl,
        storyAuthor: story.author,
        storySynopsis: story.synopsis,
      );
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(enqueued < 0
                ? 'Chương ${c.chapterNumber} đã có trong bộ nhớ.'
                : 'Đang tải chương ${c.chapterNumber}…'),
            duration: const Duration(seconds: 2),
          ),
        );
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Không tải được chương: $e'),
          ),
        );
    }
  }

  /// Chọn danh sách tủ truyện cho bookmark (giữ nút 📚) — tương tự các
  /// tab tủ trên web: Đang đọc / Đã đọc xong / Sẽ đọc / Yêu thích.
  /// Chọn đúng loại hiện tại = bỏ bookmark; chọn loại khác = chuyển loại.
  Future<void> _pickBookmarkType(
    BuildContext context,
    WidgetRef ref,
    StorySummary story,
    String? currentListType,
  ) async {
    const options = [
      (Icons.auto_stories_outlined, 'reading', 'Đang đọc'),
      (Icons.check_circle_outline, 'completed', 'Đã đọc xong'),
      (Icons.schedule_outlined, 'plan_to_read', 'Sẽ đọc'),
      (Icons.favorite_outline, 'favorite', 'Yêu thích'),
    ];
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                'Thêm vào tủ truyện',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              subtitle: const Text('Chạm để chọn danh sách'),
            ),
            for (final (icon, type, label) in options)
              ListTile(
                leading: Icon(icon),
                title: Text(label),
                trailing: currentListType == type
                    ? const Icon(Icons.check, color: AppTheme.primary)
                    : null,
                onTap: () =>
                    Navigator.of(sheetContext).pop(type),
              ),
            if (currentListType != null)
              ListTile(
                leading: const Icon(Icons.bookmark_remove_outlined),
                title: const Text('Xoá khỏi tủ truyện'),
                textColor: Theme.of(context).colorScheme.error,
                onTap: () =>
                    Navigator.of(sheetContext).pop('__remove__'),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !context.mounted) return;
    final notifier = ref.read(bookshelfProvider.notifier);
    if (chosen == '__remove__') {
      await notifier.toggle(
        story.id,
        listType: currentListType!,
        title: story.title,
        slug: story.slug,
        coverUrl: story.coverUrl,
        author: story.author,
        contentType: story.contentTypes.isNotEmpty
            ? story.contentTypes.first
            : 'text',
      );
      if (context.mounted) {
        showAppSnackBar(
          context,
          'Đã xoá khỏi tủ truyện',
          duration: const Duration(seconds: 1),
        );
      }
      return;
    }
    final label = options.firstWhere((o) => o.$2 == chosen).$3;
    await notifier.toggle(
      story.id,
      listType: chosen,
      title: story.title,
      slug: story.slug,
      coverUrl: story.coverUrl,
      author: story.author,
      contentType: story.contentTypes.isNotEmpty
          ? story.contentTypes.first
          : 'text',
    );
    if (context.mounted) {
      showAppSnackBar(
        context,
        currentListType == chosen
            ? 'Đã xoá khỏi tủ truyện'
            : 'Đã thêm vào "$label"',
        duration: const Duration(seconds: 1),
      );
    }
  }
}

class _StorySynopsis extends StatelessWidget {
  const _StorySynopsis({required this.text});

  final String? text;

  @override
  Widget build(BuildContext context) {
    final raw = text?.trim() ?? '';
    if (raw.isEmpty) {
      return Text(
        '(Chưa có giới thiệu)',
        style: Theme.of(context).textTheme.bodyMedium,
      );
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final onSurface = scheme.onSurface;
    final body = theme.textTheme.bodyMedium?.copyWith(height: 1.6) ??
        const TextStyle(fontSize: 14, height: 1.6, color: Colors.black);
    final headingBase = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
      color: onSurface,
    ) ??
        const TextStyle(fontWeight: FontWeight.w700);
    final readerTheme = ReaderTheme(
      bodyStyle: body,
      headingStyles: {
        1: headingBase.copyWith(fontSize: 20, height: 1.3),
        2: headingBase.copyWith(fontSize: 18, height: 1.3),
        3: headingBase.copyWith(fontSize: 16, height: 1.3),
        4: headingBase.copyWith(fontSize: 15, height: 1.4),
        5: headingBase.copyWith(fontSize: 14, height: 1.4),
        6: headingBase.copyWith(fontSize: 13, height: 1.4),
      },
      accentColor: scheme.primary,
      paragraphSpacing: 6,
      codeStyle: TextStyle(
        fontFamily: 'monospace',
        fontSize: 13,
        color: onSurface,
        backgroundColor: scheme.surfaceContainerHighest,
      ),
      quoteColor: scheme.error,
      blockBackground: scheme.surfaceContainerHighest,
    );
    final blocks = MarkdownParser().parse(raw);
    return MarkdownRenderer(
      blocks: blocks,
      theme: readerTheme,
      onLinkTap: (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
    );
  }
}

/// Badge thể loại/tag dạng pill nhẹ như web (style.css `.badge` /
/// `.badge-cat` / `.badge-tag`): nền đặc không viền, bo tròn hoàn toàn.
/// THỂ LOẠI nổi bật hơn tag (accent + đậm chữ) — thể loại là trục điều
/// hướng chính (trang /the-loai, BXH theo loại), còn tag là nhãn mô tả
/// phụ thường xuất hiện nhiều hơn nên để trầm giúp hàng badge đỡ rối.
class _GenreBadge extends StatelessWidget {
  const _GenreBadge({
    required this.label,
    required this.onTap,
    this.isTag = false,
  });
  final String label;
  final VoidCallback onTap;
  final bool isTag;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: isTag
          ? scheme.surfaceContainerHigh
          : scheme.primary.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isTag ? FontWeight.w500 : FontWeight.w600,
              color: isTag ? scheme.onSurfaceVariant : scheme.primary,
              height: 1.2,
            ),
          ),
        ),
      ),
    );
  }
}

/// Badge loại truyện (chữ/tranh/bách khoa/video/chat) — mirror web
/// `.ct-badge-inline`: nền màu đặc theo loại + chữ trắng. Màu lấy từ
/// web nhưng làm tối nhẹ ở các màu tương phản thấp với nền trắng
/// (amber/orange/green của web ~3.0:1 → dùng shade 700 đạt ≥4.5:1).
class _ContentTypeBadge extends StatelessWidget {
  const _ContentTypeBadge({required this.contentType});
  final String contentType;

  static const _map = <String, (String, Color)>{
    'text': ('📖 Truyện chữ', Color(0xFF2563EB)),
    'visual': ('📚 Bách khoa', Color(0xFFB45309)),
    'manga': ('🖼️ Truyện tranh', Color(0xFF9333EA)),
    'video': ('🎬 Truyện video', Color(0xFFC2410C)),
    'chat': ('💬 Truyện chat', Color(0xFF15803D)),
  };

  @override
  Widget build(BuildContext context) {
    final entry = _map[contentType];
    if (entry == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: entry.$2,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        entry.$1,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Colors.white,
          height: 1.2,
        ),
      ),
    );
  }
}

/// Hàng thống kê truyện — mirror web `.stats`: ⭐ điểm / 👁 lượt đọc /
/// 📖 chương / ✏️ từ. Chỉ hiện giá trị có dữ liệu, màu trầm đủ tương
/// phản trên nền trắng (không dùng text quá nhạt).
class _StoryStats extends StatelessWidget {
  const _StoryStats({
    required this.rating,
    required this.viewCount,
    required this.chapterCount,
    required this.wordCount,
  });
  final double? rating;
  final int? viewCount;
  final int? chapterCount;
  final int? wordCount;

  /// Format điểm giống web `avg_rating_display()`: bỏ số 0 thừa ở
  /// phần thập phân (4.50 → 4.5, 5.00 → 5).
  static String _fmtRating(double r) {
    final s = r.toStringAsFixed(2);
    final parts = s.split('.');
    final frac = parts[1].replaceFirst(RegExp(r'0+$'), '');
    return frac.isEmpty ? parts[0] : '${parts[0]}.$frac';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant.withValues(alpha: 0.75);
    final iconColor = scheme.primary.withValues(alpha: 0.7);

    final items = <(IconData, String)>[
      if (rating != null && rating! > 0)
        (Icons.star_rounded, '${_fmtRating(rating!)}'),
      if (viewCount != null && viewCount! > 0)
        (Icons.visibility_outlined, '${formatCount(viewCount!)} đọc'),
      if (chapterCount != null && chapterCount! > 0)
        (Icons.menu_book_outlined, '${formatCount(chapterCount!)} chương'),
      if (wordCount != null && wordCount! > 0)
        (Icons.edit_outlined, '${formatCount(wordCount!)} từ'),
    ];
    if (items.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 14,
      runSpacing: 4,
      children: [
        for (final (icon, label) in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: iconColor),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: muted,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;
  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      'ongoing' => ('Đang ra', const Color(0xFF16A34A)),
      'completed' => ('Hoàn thành', const Color(0xFF2563EB)),
      'hiatus' => ('Tạm dừng', const Color(0xFFD97706)),
      _ => (status, Colors.grey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        // Pill tròn đầy đủ như _ContentTypeBadge (trước đây bo góc 6px
        // nên đứng cạnh badge khác trông lệch).
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            height: 1.2),
      ),
    );
  }
}

/// Pill thông tin (đã tải / đang tải) — cùng dáng với các badge khác
/// trong hàng badge story detail (cao đều, bo tròn 999, chữ 12) thay
/// Material Chip nặng (viền, chiều cao lệch).
class _InfoPill extends StatelessWidget {
  const _InfoPill({
    required this.label,
    required this.iconColor,
    required this.background,
    this.icon,
    this.spinner = false,
  });

  final String label;
  final IconData? icon;
  final Color iconColor;
  final Color background;
  final bool spinner;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (spinner)
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: iconColor,
              ),
            )
          else if (icon != null)
            Icon(icon, size: 12, color: iconColor),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: iconColor,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _BookmarkChip extends StatelessWidget {
  const _BookmarkChip({required this.listType});
  final String listType;

  @override
  Widget build(BuildContext context) {
    final label = switch (listType) {
      'reading' => 'Đang đọc',
      'completed' => 'Đã đọc xong',
      'plan_to_read' => 'Sẽ đọc',
      'favorite' => 'Yêu thích',
      _ => listType,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(
            color: AppTheme.primary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            height: 1.2),
      ),
    );
  }
}


/// Merged detail payload with local bookmark state.
/// Falls back to local Drift bookmarks when the server returns null
/// (e.g. anonymous users).
class _DetailWithBookmark {
  const _DetailWithBookmark({
    required this.detail,
    this.localBookmark,
  });
  final StoryDetailPayload detail;
  final String? localBookmark; // listType if bookmarked locally
}

final _storyDetailProvider = FutureProvider.autoDispose
    .family<_DetailWithBookmark, String>((ref, slug) async {
  final repo = ref.watch(storyRepositoryProvider);
  final db = ref.read(appDatabaseProvider);
  final detail = await repo.fetchStoryDetail(slug);
  // Merge local bookmark state for anonymous / offline users.
  String? localBookmark;
  try {
    final local = await db.getBookmarkForStory(detail.story.id);
    if (local != null) localBookmark = local.listType;
  } catch (_) {}
  return _DetailWithBookmark(
    detail: detail,
    localBookmark: detail.bookmark ?? localBookmark,
  );
});

// chapterListProvider is now defined in repositories/story_repository.dart
// and shared between this screen and the chapter reader's chapter-list
// bottom sheet.

/// Đánh giá + Bình luận entry block on the story detail header (mirrors
/// the web detail page's review/comment sections).
///
/// Initial counts come from the detail payload so the detail screen makes
/// no extra network calls on open. After returning from either child
/// screen the counts are silently refreshed (no full-screen reload / scroll
/// reset — the parent detail provider is NOT invalidated, per the repo's
/// scroll-preservation rule).
class _StorySocialSection extends ConsumerStatefulWidget {
  const _StorySocialSection({
    required this.storyId,
    required this.storySlug,
    required this.storyTitle,
    this.initialRating,
    this.initialReviewCount = 0,
    this.initialCommentCount = 0,
  });

  final String storyId;
  final String storySlug;
  final String storyTitle;
  final double? initialRating;
  final int initialReviewCount;
  final int initialCommentCount;

  @override
  ConsumerState<_StorySocialSection> createState() =>
      _StorySocialSectionState();
}

class _StorySocialSectionState extends ConsumerState<_StorySocialSection> {
  late double? _rating = widget.initialRating;
  late int _reviewCount = widget.initialReviewCount;
  late int _commentCount = widget.initialCommentCount;

  StoryRepository get _repo => ref.read(storyRepositoryProvider);

  /// Silent background refresh after returning from a child screen: pull
  /// fresh aggregates so the detail header matches what the user just
  /// posted/edited. Best-effort — failures keep the previous values.
  Future<void> _refresh() async {
    try {
      final reviews = await _repo.fetchStoryReviews(widget.storyId);
      final comments = await _repo.fetchStoryComments(widget.storyId);
      if (!mounted) return;
      setState(() {
        _rating = reviews.avgRating;
        _reviewCount = reviews.reviewCount;
        // total_comments đếm phẳng gồm cả reply (khớp commentCount từ detail
        // payload); `total` chỉ đếm entry gốc dùng cho phân trang.
        _commentCount = comments.totalComments ?? comments.total;
      });
    } catch (_) {
      // Keep previous values; the next visit refetches everything anyway.
    }
  }

  Future<void> _openReviews() async {
    await context.push(
      '/story-reviews/${widget.storyId}',
      extra: widget.storyTitle,
    );
    if (!mounted) return;
    await _refresh();
  }

  Future<void> _openComments() async {
    await context.push(
      '/story-comments/${widget.storyId}',
      extra: widget.storyTitle,
    );
    if (!mounted) return;
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Average rounded to the nearest half for the star row (like the web).
    final rounded = (_rating ?? 0) * 2;
    final filledStars = (rounded + 0.5).floor().clamp(0, 10) ~/ 2;
    return Column(
      children: [
        Divider(
          height: 1,
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
        ListTile(
          leading: Icon(
            Icons.star,
            color: theme.colorScheme.primary,
            size: 24,
          ),
          title: Row(
            children: [
              Text(
                _rating != null && _rating! > 0
                    ? _rating!.toStringAsFixed(2)
                    : '—',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              for (var i = 1; i <= 5; i++)
                Icon(
                  i <= filledStars ? Icons.star : Icons.star_border,
                  size: 16,
                  color: const Color(0xFFF59E0B),
                ),
            ],
          ),
          subtitle: Text('$_reviewCount đánh giá'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _openReviews,
        ),
        Divider(
          height: 1,
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
        ListTile(
          leading: Icon(
            Icons.forum_outlined,
            color: theme.colorScheme.primary,
            size: 24,
          ),
          title: const Text('Bình luận truyện'),
          subtitle: Text('$_commentCount bình luận'),
          trailing: const Icon(Icons.chevron_right),
          onTap: _openComments,
        ),
        Divider(
          height: 1,
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ],
    );
  }
}
