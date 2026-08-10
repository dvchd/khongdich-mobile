import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/comment.dart';
import '../../repositories/story_repository.dart';

/// Bottom sheet composer for a paragraph-level (segment) comment —
/// anchored to the quoted paragraph the reader long-pressed.
///
/// The app can't compute the server's FNV-1a paragraph key (it renders
/// markdown itself), so `para_key` is sent empty; the backend resolves
/// the anchor from the exact normalized paragraph text.
class SegmentComposerSheet extends ConsumerStatefulWidget {
  const SegmentComposerSheet({
    super.key,
    required this.chapterId,
    required this.quoteText,
  });

  final String chapterId;

  /// Full plain text of the long-pressed paragraph (normalized).
  final String quoteText;

  @override
  ConsumerState<SegmentComposerSheet> createState() =>
      _SegmentComposerSheetState();
}

class _SegmentComposerSheetState extends ConsumerState<SegmentComposerSheet> {
  final TextEditingController _controller = TextEditingController();
  bool _posting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _posting) return;
    setState(() => _posting = true);
    try {
      final result = await ref.read(storyRepositoryProvider).postSegmentComment(
        chapterId: widget.chapterId,
        quoteText: widget.quoteText,
        content: text,
      );
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _posting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gửi thất bại: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.format_quote, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                const Text(
                  'Bình luận đoạn',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border(
                  left: BorderSide(color: theme.colorScheme.primary, width: 3),
                ),
              ),
              child: Text(
                widget.quoteText,
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText: 'Viết bình luận cho đoạn này…',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _posting ? null : _submit,
              icon: _posting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.send),
              label: const Text('Gửi bình luận'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows the sheet; pops with a [CommentPostResult] when posted.
Future<CommentPostResult?> showSegmentComposer(
  BuildContext context, {
  required String chapterId,
  required String quoteText,
}) {
  return showModalBottomSheet<CommentPostResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => SegmentComposerSheet(
      chapterId: chapterId,
      quoteText: quoteText,
    ),
  );
}