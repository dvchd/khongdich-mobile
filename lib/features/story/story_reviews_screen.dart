import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_client.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/emoji_picker_sheet.dart';
import '../../core/widgets/emoji_text.dart';
import '../../models/review.dart';
import '../../repositories/story_repository.dart';
import '../profile/profile_screen.dart' show currentUserProvider;

/// Story reviews screen (đánh giá truyện) — mirrors the web story detail
/// review section: star summary, upsert form (one review per user per
/// story — submitting again updates it), paginated review list.
///
/// Hits:
///   - `GET /api/v1/mobile/stories/{id}/reviews`
///   - `POST /api/v1/mobile/stories/{id}/reviews` (login required)
class StoryReviewsScreen extends ConsumerStatefulWidget {
  const StoryReviewsScreen({
    super.key,
    required this.storyId,
    this.storyTitle = '',
  });

  final String storyId;
  final String storyTitle;

  @override
  ConsumerState<StoryReviewsScreen> createState() => _StoryReviewsScreenState();
}

class _StoryReviewsScreenState extends ConsumerState<StoryReviewsScreen> {
  ReviewsFeed? _feed;
  String? _error;
  bool _loading = true;
  bool _loadingMore = false;
  bool _posting = false;
  // Generation counter — mutations in flight must drop stale results.
  int _feedEpoch = 0;

  int _rating = 5;
  final TextEditingController _composer = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _composer.dispose();
    super.dispose();
  }

  StoryRepository get _repo => ref.read(storyRepositoryProvider);

  Future<void> _load() async {
    final epoch = ++_feedEpoch;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final feed = await _repo.fetchStoryReviews(widget.storyId);
      if (!mounted || epoch != _feedEpoch) return;
      setState(() {
        _feed = feed;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || epoch != _feedEpoch) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    final feed = _feed;
    if (feed == null || _loadingMore) return;
    if (feed.page >= feed.totalPages) return;
    final epoch = _feedEpoch;
    setState(() => _loadingMore = true);
    try {
      final next = await _repo.fetchStoryReviews(widget.storyId, page: feed.page + 1);
      if (!mounted || epoch != _feedEpoch) return;
      setState(() {
        final current = _feed;
        if (current == null) return;
        _feed = ReviewsFeed(
          reviews: [...current.reviews, ...next.reviews],
          total: next.total,
          page: next.page,
          perPage: next.perPage,
          totalPages: next.totalPages,
          avgRating: next.avgRating,
          reviewCount: next.reviewCount,
          myRating: next.myRating,
        );
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted && epoch == _feedEpoch) {
        setState(() => _loadingMore = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Không tải thêm được đánh giá — thử lại sau.'),
          ),
        );
      }
    }
  }

  Future<void> _submit() async {
    final content = _composer.text.trim();
    if (content.isEmpty || _posting) return;
    final api = ref.read(apiClientProvider).valueOrNull;
    if (api == null || !await api.isAuthenticated()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đăng nhập để đánh giá truyện.')),
        );
        context.push('/auth');
      }
      return;
    }
    setState(() => _posting = true);
    try {
      await _repo.upsertReview(
        storyId: widget.storyId,
        rating: _rating,
        content: content,
      );
      if (!mounted) return;
      _composer.clear();
      setState(() => _posting = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('Đã gửi đánh giá!'),
            duration: Duration(seconds: 2),
          ),
        );
      // Refresh so the caller's own review appears at the top of the list
      // (server sorts newest first) and the aggregates update in place.
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _posting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gửi đánh giá thất bại: $e')),
      );
    }
  }

  Future<void> _insertEmoji() async {
    final shortcode = await showEmojiPickerSheet(context);
    if (shortcode == null || !mounted) return;
    final value = _composer.text;
    final selection = _composer.selection;
    final start = selection.isValid ? selection.start : value.length;
    final end = selection.isValid ? selection.end : value.length;
    final next = value.replaceRange(start, end, shortcode);
    _composer.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + shortcode.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.storyTitle.isEmpty ? 'Đánh giá truyện' : 'Đánh giá truyện',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, size: 48),
              const SizedBox(height: 12),
              const Text('Không tải được đánh giá'),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Thử lại')),
            ],
          ),
        ),
      );
    }
    final feed = _feed!;
    final hasMore = feed.page < feed.totalPages;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        _SummaryCard(feed: feed),
        _ReviewForm(
          myRating: feed.myRating,
          rating: _rating,
          posting: _posting,
          controller: _composer,
          onRatingChanged: (r) => setState(() => _rating = r),
          onSubmit: _submit,
          onEmoji: _insertEmoji,
        ),
        const Divider(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Tất cả đánh giá (${feed.total})',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        const SizedBox(height: 4),
        if (feed.reviews.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(
                'Chưa có đánh giá nào.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
          )
        else
          for (final r in feed.reviews) _ReviewTile(item: r),
        if (hasMore)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Center(
              child: _loadingMore
                  ? const CircularProgressIndicator(strokeWidth: 2)
                  : TextButton.icon(
                      onPressed: _loadMore,
                      icon: const Icon(Icons.expand_more),
                      label: const Text('Xem thêm đánh giá'),
                    ),
            ),
          ),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// Summary card: average rating + stars + count.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.feed});
  final ReviewsFeed feed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          Text(
            '${feed.avgRating.toStringAsFixed(2)}',
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    for (var i = 1; i <= 5; i++)
                      Icon(
                        i <= (feed.avgRating + 0.5).floor()
                            ? Icons.star
                            : Icons.star_border,
                        size: 18,
                        color: const Color(0xFFF59E0B),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${feed.reviewCount} đánh giá',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Upsert form: star picker + content (pre-filled nothing; submitting
/// again updates the caller's existing review).
class _ReviewForm extends StatelessWidget {
  const _ReviewForm({
    required this.myRating,
    required this.rating,
    required this.posting,
    required this.controller,
    required this.onRatingChanged,
    required this.onSubmit,
    required this.onEmoji,
  });

  final int? myRating;
  final int rating;
  final bool posting;
  final TextEditingController controller;
  final ValueChanged<int> onRatingChanged;
  final VoidCallback onSubmit;
  final VoidCallback onEmoji;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Consumer(
      builder: (context, ref, _) {
        // Đăng nhập mới hiện form (apiClient luôn non-null — phải check
        // qua currentUserProvider, trước đây form hiện cả khi chưa login).
        final loggedIn = ref.watch(currentUserProvider).valueOrNull != null;
        final label = myRating == null ? 'Gửi đánh giá' : 'Cập nhật đánh giá';
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                myRating == null ? 'Viết đánh giá' : 'Đánh giá của bạn',
                style: theme.textTheme.titleSmall,
              ),
              if (myRating != null)
                Text(
                  'Bạn đã đánh giá $myRating★ — gửi lại để cập nhật.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              const SizedBox(height: 8),
              if (loggedIn) ...[
                Row(
                  children: [
                    for (var i = 1; i <= 5; i++)
                      IconButton(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          i <= rating ? Icons.star : Icons.star_border,
                          size: 30,
                          color: i <= rating
                              ? const Color(0xFFF59E0B)
                              : theme.colorScheme.onSurface.withValues(
                                  alpha: 0.3,
                                ),
                        ),
                        onPressed: posting ? null : () => onRatingChanged(i),
                      ),
                    Text('$rating/5', style: theme.textTheme.bodySmall),
                  ],
                ),
                TextField(
                  controller: controller,
                  minLines: 2,
                  maxLines: 5,
                  maxLength: 5000,
                  decoration: InputDecoration(
                    hintText: 'Suy nghĩ của bạn về truyện…',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                ),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.emoji_emotions_outlined),
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Chèn emoji',
                      onPressed: posting ? null : onEmoji,
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: posting || controller.text.trim().isEmpty
                          ? null
                          : onSubmit,
                      icon: posting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.send, size: 16),
                      label: Text(label),
                    ),
                  ],
                ),
              ] else
                Text(
                  'Đăng nhập để viết đánh giá.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// A single review tile: avatar, name, stars, content, time.
class _ReviewTile extends StatelessWidget {
  const _ReviewTile({required this.item});
  final ReviewItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: AppTheme.primary.withValues(alpha: 0.12),
            child: item.avatarUrl == null
                ? Text(
                    item.displayAuthor.isEmpty
                        ? '?'
                        : item.displayAuthor.characters.first,
                    style: const TextStyle(fontSize: 13),
                  )
                : ClipOval(
                    child: Image.network(
                      item.avatarUrl!,
                      width: 32,
                      height: 32,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Text(
                        item.displayAuthor.characters.first,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.displayAuthor,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    for (var i = 1; i <= 5; i++)
                      Icon(
                        i <= item.rating ? Icons.star : Icons.star_border,
                        size: 14,
                        color: i <= item.rating
                            ? const Color(0xFFF59E0B)
                            : theme.colorScheme.onSurface.withValues(
                                alpha: 0.2,
                              ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                EmojiText(
                  text: item.content,
                  contentHtml: item.contentHtml,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                ),
                const SizedBox(height: 4),
                Text(
                  _formatTime(item.createdAt),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime t) {
    final local = t.toLocal();
    return '${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}