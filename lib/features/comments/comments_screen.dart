import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_client.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/emoji_picker_sheet.dart';
import '../../core/widgets/emoji_text.dart';
import '../../models/comment.dart';
import '../../repositories/story_repository.dart';

/// Chapter comments screen (bình luận chương).
///
/// Renders the merged feed from `GET /api/v1/mobile/chapters/{id}/comments`
/// (regular + segment comments, threads grouped under roots like the web),
/// with: like, reply, delete-own, pagination, and login-gated posting.
/// Replies to a segment comment go through the segment endpoint so they
/// inherit the paragraph anchor server-side.
class CommentsScreen extends ConsumerStatefulWidget {
  const CommentsScreen({
    super.key,
    required this.chapterId,
    required this.chapterTitle,
  });

  final String chapterId;
  final String chapterTitle;

  @override
  ConsumerState<CommentsScreen> createState() => _CommentsScreenState();
}

class _CommentsScreenState extends ConsumerState<CommentsScreen> {
  PaginatedComments? _feed;
  String? _error;
  bool _loading = true;
  bool _loadingMore = false;
  bool _posting = false;
  bool _newest = true;
  // Generation counter: bump mỗi lần _load (refresh) bắt đầu — mọi
  // mutation đang bay (_loadMore, _toggleLike) phải bỏ qua kết quả nếu
  // epoch đã đổi, nếu không dữ liệu cũ sẽ ghi đè feed mới.
  int _feedEpoch = 0;
  final TextEditingController _composer = TextEditingController();
  CommentItem? _replyingTo;

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
      final feed = await _repo.fetchChapterComments(
        widget.chapterId,
        page: 1,
        sort: _newest ? 'newest' : 'oldest',
      );
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
      final next = await _repo.fetchChapterComments(
        widget.chapterId,
        page: feed.page + 1,
        sort: _newest ? 'newest' : 'oldest',
      );
      if (!mounted || epoch != _feedEpoch) return;
      setState(() {
        final current = _feed;
        if (current == null) return;
        // Append + dedupe: với sort=newest, comment mới đăng giữa 2 lần
        // fetch làm item cuối page trượt xuống page sau → trùng item.
        final known = {for (final c in current.comments) c.id};
        final merged = [
          ...current.comments,
          ...next.comments.where((c) => !known.contains(c.id)),
        ];
        _feed = PaginatedComments(
          comments: merged,
          total: next.total,
          page: next.page,
          perPage: next.perPage,
          totalPages: next.totalPages,
        );
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted && epoch == _feedEpoch) {
        setState(() => _loadingMore = false);
      }
    }
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _posting) return;
    final api = ref.read(apiClientProvider).valueOrNull;
    if (api == null || !await api.isAuthenticated()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đăng nhập để bình luận.')),
        );
        context.push('/auth');
      }
      return;
    }
    setState(() => _posting = true);
    final parent = _replyingTo;
    try {
      final result = parent != null && parent.isSegment
          ? await _repo.postSegmentComment(
              chapterId: widget.chapterId,
              parentId: parent.id,
              quoteText: '',
              content: text,
            )
          : await _repo.postChapterComment(
              widget.chapterId,
              content: text,
              parentId: parent?.id,
            );
      // Check mounted TRƯỚC khi chạm vào controller/state — trước đây
      // _composer.clear() + setState chạy trước check mounted → nếu user
      // rời màn hình trong lúc POST đang bay → setState after dispose +
      // assert crash.
      if (!mounted) return;
      _composer.clear();
      setState(() {
        _replyingTo = null;
        _posting = false;
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              result.wasHidden
                  ? 'Đã gửi — bình luận đang chờ kiểm duyệt.'
                  : 'Đã gửi bình luận.',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      // Refresh so the new comment (and any replies) appear in place.
      _newest = true;
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _posting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gửi thất bại: $e')),
      );
    }
  }

  Future<void> _toggleLike(CommentItem c) async {
    try {
      final (liked, count) = c.isSegment
          ? await _repo.toggleSegmentCommentLike(c.id)
          : await _repo.toggleCommentLike(c.id);
      if (!mounted) return;
      setState(() {
        final feed = _feed;
        if (feed == null) return;
        _feed = _mapComment(feed, c.id, (copy) {
          return CommentItem(
            id: copy.id,
            userId: copy.userId,
            username: copy.username,
            displayName: copy.displayName,
            avatarUrl: copy.avatarUrl,
            content: copy.content,
            contentHtml: copy.contentHtml,
            likeCount: count,
            createdAt: copy.createdAt,
            edited: copy.edited,
            hidden: copy.hidden,
            isMine: copy.isMine,
            likedByMe: liked,
            parentId: copy.parentId,
            replyToName: copy.replyToName,
            replyToId: copy.replyToId,
            isSegment: copy.isSegment,
            quoteText: copy.quoteText,
            paraKey: copy.paraKey,
            segChapterId: copy.segChapterId,
            replies: copy.replies,
          );
        });
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Không thích được — thử lại sau.')),
        );
      }
    }
  }

  Future<void> _delete(CommentItem c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Xoá bình luận?'),
        content: const Text('Bình luận này sẽ bị xoá vĩnh viễn.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Xoá'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      if (c.isSegment) {
        await _repo.deleteSegmentComment(c.id);
      } else {
        await _repo.deleteComment(c.id);
      }
      if (!mounted) return;
      setState(() {
        // Drop the comment (and its replies — the backend cascades
        // soft-deletes the whole thread).
        var feed = _feed;
        if (feed != null) {
          feed = _mapComment(feed, c.id, null);
          _feed = feed == null
              ? null
              : PaginatedComments(
                  comments: feed.comments,
                  total: feed.total - 1,
                  page: feed.page,
                  perPage: feed.perPage,
                  totalPages: feed.totalPages,
                );
        }
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Xoá thất bại — thử lại sau.')),
        );
      }
    }
  }

  /// Rebuild the feed with [id] replaced by [replace]'s result
  /// (recursively — replies live inside their root's `replies` list).
  /// Pass [replace] = null to remove the comment entirely.
  PaginatedComments? _mapComment(
    PaginatedComments feed,
    String id,
    CommentItem? Function(CommentItem)? replace,
  ) {
    final comments = <CommentItem>[];
    for (final c in feed.comments) {
      final mapped = _mapRecursively(c, id, replace);
      if (mapped != null) comments.add(mapped);
    }
    return PaginatedComments(
      comments: comments,
      total: feed.total,
      page: feed.page,
      perPage: feed.perPage,
      totalPages: feed.totalPages,
    );
  }

  CommentItem? _mapRecursively(
    CommentItem c,
    String id,
    CommentItem? Function(CommentItem)? replace,
  ) {
    if (c.id == id) {
      return replace?.call(c);
    }
    final replyIndex = c.replies.indexWhere((r) => r.id == id);
    if (replyIndex < 0) return c;
    final replies = <CommentItem>[];
    for (final r in c.replies) {
      final mapped = _mapRecursively(r, id, replace);
      if (mapped != null) replies.add(mapped);
    }
    return _copyComment(c, replies: replies);
  }

  CommentItem _copyComment(CommentItem c, {List<CommentItem>? replies}) {
    return CommentItem(
      id: c.id,
      userId: c.userId,
      username: c.username,
      displayName: c.displayName,
      avatarUrl: c.avatarUrl,
      content: c.content,
      contentHtml: c.contentHtml,
      likeCount: c.likeCount,
      createdAt: c.createdAt,
      edited: c.edited,
      hidden: c.hidden,
      isMine: c.isMine,
      likedByMe: c.likedByMe,
      parentId: c.parentId,
      replyToName: c.replyToName,
      replyToId: c.replyToId,
      isSegment: c.isSegment,
      quoteText: c.quoteText,
      paraKey: c.paraKey,
      segChapterId: c.segChapterId,
      replies: replies ?? c.replies,
    );
  }

  void _startReply(CommentItem c) {
    setState(() => _replyingTo = c);
    _composer.text = '';
    FocusScope.of(context).requestFocus(FocusNode());
  }

  void _cancelReply() {
    setState(() => _replyingTo = null);
  }

  /// Insert a `:name:` shortcode at the cursor (emoji picker).
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
          widget.chapterTitle.isEmpty ? 'Bình luận' : 'Bình luận chương',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: Icon(_newest ? Icons.arrow_downward : Icons.arrow_upward),
            tooltip: _newest ? 'Mới nhất' : 'Cũ nhất',
            onPressed: () {
              setState(() => _newest = !_newest);
              _load();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(child: _buildFeed()),
          _ComposerBar(
            controller: _composer,
            posting: _posting,
            replyingTo: _replyingTo,
            onSend: _send,
            onCancelReply: _cancelReply,
            onEmoji: _insertEmoji,
          ),
        ],
      ),
    );
  }

  Widget _buildFeed() {
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
              const Text('Không tải được bình luận'),
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
    if (feed.comments.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 120),
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          const Center(child: Text('Chưa có bình luận nào. Hãy là người đầu tiên!')),
        ],
      );
    }
    final hasMore = feed.page < feed.totalPages;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: feed.comments.length + (hasMore ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= feed.comments.length) {
          return Padding(
            padding: const EdgeInsets.all(8),
            child: Center(
              child: _loadingMore
                  ? const CircularProgressIndicator(strokeWidth: 2)
                  : TextButton.icon(
                      onPressed: _loadMore,
                      icon: const Icon(Icons.expand_more),
                      label: const Text('Xem thêm bình luận'),
                    ),
            ),
          );
        }
        final c = feed.comments[i];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CommentTile(
              item: c,
              onLike: () => _toggleLike(c),
              onReply: () => _startReply(c),
              onDelete: c.isMine ? () => _delete(c) : null,
            ),
            for (final r in c.replies)
              Padding(
                padding: const EdgeInsets.only(left: 24),
                child: _CommentTile(
                  item: r,
                  onLike: () => _toggleLike(r),
                  onReply: () => _startReply(r),
                  onDelete: r.isMine ? () => _delete(r) : null,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Renders a single comment (root or reply) with quote block for segment
/// comments and like/reply/delete actions.
class _CommentTile extends StatelessWidget {
  const _CommentTile({
    required this.item,
    required this.onLike,
    required this.onReply,
    this.onDelete,
  });

  final CommentItem item;
  final VoidCallback onLike;
  final VoidCallback onReply;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = item.hidden
        ? Text(
            'Bình luận này đã bị ẩn.',
            style: theme.textTheme.bodySmall?.copyWith(
              fontStyle: FontStyle.italic,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (item.isSegment && (item.quoteText?.isNotEmpty ?? false))
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                    border: Border(
                      left: BorderSide(
                        color: theme.colorScheme.primary,
                        width: 3,
                      ),
                    ),
                  ),
                  child: Text(
                    item.quoteText!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              EmojiText(
                text: item.content,
                contentHtml: item.contentHtml,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
              ),
            ],
          );

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
                    if (item.isSegment) ...[
                      const SizedBox(width: 6),
                      Icon(
                        Icons.format_quote,
                        size: 12,
                        color: theme.colorScheme.primary,
                      ),
                    ],
                    if (item.edited) ...[
                      const SizedBox(width: 6),
                      Text(
                        'đã sửa',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.4,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                body,
                const SizedBox(height: 4),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: onLike,
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                      icon: Icon(
                        item.likedByMe
                            ? Icons.favorite
                            : Icons.favorite_border,
                        size: 16,
                        color: item.likedByMe
                            ? Colors.redAccent
                            : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                      label: Text(
                        '${item.likeCount}',
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                    if (!item.hidden)
                      TextButton(
                        onPressed: onReply,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        child: Text(
                          'Trả lời',
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                    if (onDelete != null)
                      TextButton.icon(
                        onPressed: onDelete,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                        ),
                        icon: Icon(
                          Icons.delete_outline,
                          size: 16,
                          color: Colors.redAccent.withValues(alpha: 0.8),
                        ),
                        label: Text(
                          'Xoá',
                          style: theme.textTheme.labelSmall
                              ?.copyWith(color: Colors.redAccent),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom composer bar: reply context chip + text field + send.
class _ComposerBar extends StatelessWidget {
  const _ComposerBar({
    required this.controller,
    required this.posting,
    required this.replyingTo,
    required this.onSend,
    required this.onCancelReply,
    required this.onEmoji,
  });

  final TextEditingController controller;
  final bool posting;
  final CommentItem? replyingTo;
  final VoidCallback onSend;
  final VoidCallback onCancelReply;
  final VoidCallback onEmoji;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (replyingTo != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Đang trả lời @${replyingTo!.displayAuthor}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      visualDensity: VisualDensity.compact,
                      onPressed: onCancelReply,
                    ),
                  ],
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Icons.emoji_emotions_outlined),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Chèn emoji',
                  onPressed: posting ? null : onEmoji,
                ),
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                    decoration: InputDecoration(
                      hintText: replyingTo == null
                          ? 'Viết bình luận…'
                          : 'Viết trả lời…',
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  icon: posting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send),
                  onPressed: posting ? null : onSend,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}