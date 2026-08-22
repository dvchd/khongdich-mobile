import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../models/chapter_content.dart';

/// Shared chrome around the polymorphic chapter views: app bar with the
/// chapter title, a bottom progress bar with prev/next navigation, and a
/// reading-settings entry point. Plan §5.4 + §14.4.
///
/// The chrome (AppBar) is always visible — tap-center opens the settings
/// sheet instead of toggling the AppBar. The previous `chromeVisible`
/// parameter was always `true` in practice, so it has been removed to
/// avoid dead code.
class ReaderBar extends StatelessWidget {
  const ReaderBar({
    super.key,
    required this.chapter,
    required this.child,
    this.onPrev,
    this.onNext,
    this.onOpenSettings,
    this.onOpenChapterList,
    this.onToggleTts,
    this.onOpenComments,
  });

  final ChapterContent chapter;
  final Widget child;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onOpenChapterList;
  final VoidCallback? onToggleTts;
  final VoidCallback? onOpenComments;

  void _onBack(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
        centerTitle: false,
        titleSpacing: 4,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => _onBack(context),
        ),
        title: Text(
          // Toolbar giống web mobile: back = tên truyện (chương hiện đã
          // có header riêng "Ch. N: Title" ngay đầu nội dung).
          chapter.storyTitle.isEmpty
              ? '${chapter.chapterNumber}'
              : chapter.storyTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        actions: [
          if ((chapter is TextChapterContent ||
                  chapter is VisualChapterContent) &&
              onToggleTts != null)
            IconButton(
              icon: const Icon(Icons.headphones),
              tooltip: 'Nghe audio',
              onPressed: onToggleTts,
            ),
          if (onOpenComments != null)
            IconButton(
              tooltip: 'Bình luận',
              onPressed: onOpenComments,
              icon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(chapter.commentCount != null
                      ? Icons.chat_bubble
                      : Icons.chat_bubble_outline),
                  if (chapter.commentCount != null) ...[
                    const SizedBox(width: 3),
                    Text(
                      '${chapter.commentCount}',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ],
              ),
            ),
          IconButton(
            icon: const Icon(Icons.list),
            tooltip: 'Danh sách chương',
            onPressed: onOpenChapterList,
          ),
          IconButton(
            icon: const Icon(Icons.text_fields),
            onPressed: onOpenSettings,
          ),
        ],
      ),
      body: child,
    );
  }
}
