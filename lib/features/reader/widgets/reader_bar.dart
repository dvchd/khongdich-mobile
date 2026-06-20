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
    this.onPrev,
    this.onNext,
    this.onOpenSettings,
    this.onOpenChapterList,
  });

  final ChapterContent chapter;
  final Widget child;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onOpenChapterList;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/home');
            }
          },
        ),
        title: Text(chapter.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
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
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onPrev,
                  icon: const Icon(Icons.chevron_left),
                  label: const Text('Trước'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: onNext,
                  icon: const Icon(Icons.chevron_right),
                  label: const Text('Sau'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
