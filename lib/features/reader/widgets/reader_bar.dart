import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../models/chapter_content.dart';

/// Shared chrome around the polymorphic chapter views: app bar with the
/// chapter title, a bottom progress bar with prev/next navigation, and a
/// reading-settings entry point. Plan §5.4 + §14.4.
class ReaderBar extends StatelessWidget {
  const ReaderBar({
    super.key,
    required this.chapter,
    required this.child,
    this.chromeVisible = true,
    this.onPrev,
    this.onNext,
    this.onOpenSettings,
    this.onOpenChapterList,
    this.onToggleTts,
  });

  final ChapterContent chapter;
  final Widget child;
  final bool chromeVisible;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onOpenChapterList;
  final VoidCallback? onToggleTts;

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
      appBar: chromeVisible
          ? AppBar(
              toolbarHeight: 44,
              centerTitle: false,
              titleSpacing: 4,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => _onBack(context),
              ),
              title: Text(
                chapter.title.isEmpty
                    ? '${chapter.chapterNumber}'
                    : '${chapter.chapterNumber}: ${chapter.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              actions: [
                if (chapter is TextChapterContent && onToggleTts != null)
                  IconButton(
                    icon: const Icon(Icons.headphones),
                    tooltip: 'Nghe audio',
                    onPressed: onToggleTts,
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
            )
          : null,
      body: chromeVisible
          ? child
          : Padding(
              padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
              child: child,
            ),
    );
  }
}
