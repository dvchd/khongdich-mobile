import 'package:flutter/material.dart';

import '../../../models/chapter_content.dart';

/// Shared chrome around the polymorphic chapter views: app bar with the
/// chapter title, a bottom progress bar with prev/next navigation, and a
/// reading-settings entry point. Plan §5.4 + §14.4.
class ReaderChrome extends StatelessWidget {
  const ReaderChrome({
    super.key,
    required this.chapter,
    required this.child,
    this.onPrev,
    this.onNext,
    this.onOpenSettings,
  });

  final ChapterContent chapter;
  final Widget child;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(chapter.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.bookmark_border),
            onPressed: () => _toast(context, 'Bookmark — nhấn giữ để thêm vào tủ'),
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

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
    );
  }
}
