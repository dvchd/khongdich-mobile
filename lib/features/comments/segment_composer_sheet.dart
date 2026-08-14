import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_client.dart';
import '../../models/comment.dart';
import '../../repositories/story_repository.dart';

/// Bottom sheet composer for a paragraph-level action — either a
/// **segment comment** (bình luận đoạn) or a **reader suggestion**
/// (góp ý sửa đoạn), anchored to the paragraph the reader long-pressed.
///
/// The app can't compute the server's FNV-1a paragraph key (it renders
/// markdown itself), so `para_key` is sent empty; the backend resolves
/// the anchor from the exact normalized paragraph text.
class SegmentComposerSheet extends ConsumerStatefulWidget {
  const SegmentComposerSheet({
    super.key,
    required this.chapterId,
    required this.quoteText,
    this.initialMode = SegmentComposerMode.comment,
  });

  final String chapterId;

  /// Full plain text of the long-pressed paragraph (normalized).
  final String quoteText;

  final SegmentComposerMode initialMode;

  @override
  ConsumerState<SegmentComposerSheet> createState() =>
      _SegmentComposerSheetState();
}

enum SegmentComposerMode { comment, suggestion }

class _SegmentComposerSheetState extends ConsumerState<SegmentComposerSheet> {
  final TextEditingController _controller = TextEditingController();
  late SegmentComposerMode _mode = widget.initialMode;
  bool _posting = false;

  @override
  void initState() {
    super.initState();
    // Góp ý mode pre-fills the editor with the whole paragraph so the
    // reader edits in place (same as the web reader's suggestion box).
    if (_mode == SegmentComposerMode.suggestion) {
      _controller.text = widget.quoteText;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _posting) return;
    final api = ref.read(apiClientProvider).valueOrNull;
    if (api == null || !await api.isAuthenticated()) {
      if (!mounted) return;
      // Capture router trước khi pop — dùng context của sheet sau khi
      // pop là fragile (element sắp bị deactivate).
      final router = GoRouter.of(context);
      final messenger = ScaffoldMessenger.of(context);
      Navigator.of(context).pop();
      messenger.showSnackBar(
        const SnackBar(content: Text('Đăng nhập để bình luận đoạn và góp ý.')),
      );
      router.push('/auth');
      return;
    }
    setState(() => _posting = true);
    try {
      if (_mode == SegmentComposerMode.suggestion) {
        await ref.read(storyRepositoryProvider).postSuggestion(
          chapterId: widget.chapterId,
          quoteText: widget.quoteText,
          suggestedText: text,
        );
        if (!mounted) return;
        Navigator.of(
          context,
        ).pop(SuggestionPostResult(wasHidden: false));
      } else {
        final result = await ref
            .read(storyRepositoryProvider)
            .postSegmentComment(
              chapterId: widget.chapterId,
              quoteText: widget.quoteText,
              content: text,
            );
        if (!mounted) return;
        Navigator.of(context).pop(result);
      }
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
    final isSuggestion = _mode == SegmentComposerMode.suggestion;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  isSuggestion ? Icons.edit_note : Icons.format_quote,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  isSuggestion ? 'Góp ý sửa đoạn' : 'Bình luận đoạn',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Mode switch: bình luận đoạn ⇄ góp ý sửa đoạn.
            SegmentedButton<SegmentComposerMode>(
              segments: const [
                ButtonSegment(
                  value: SegmentComposerMode.comment,
                  icon: Icon(Icons.format_quote, size: 16),
                  label: Text('Bình luận'),
                ),
                ButtonSegment(
                  value: SegmentComposerMode.suggestion,
                  icon: Icon(Icons.edit_note, size: 16),
                  label: Text('Góp ý'),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: _posting
                  ? null
                  : (selection) {
                      setState(() {
                        _mode = selection.first;
                        if (_mode == SegmentComposerMode.suggestion &&
                            _controller.text.trim().isEmpty) {
                          _controller.text = widget.quoteText;
                        }
                      });
                    },
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(height: 10),
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
              maxLines: isSuggestion ? 6 : 5,
              decoration: InputDecoration(
                hintText: isSuggestion
                    ? 'Sửa đoạn trên rồi gửi cho tác giả…'
                    : 'Viết bình luận cho đoạn này…',
                helperText: isSuggestion
                    ? 'Góp ý gửi cho tác giả duyệt — không hiển thị công khai.'
                    : null,
                border: const OutlineInputBorder(),
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
                  : Icon(isSuggestion ? Icons.send : Icons.send),
              label: Text(
                isSuggestion ? 'Gửi góp ý' : 'Gửi bình luận',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Result of a posted suggestion — separate from [CommentPostResult]
/// because suggestions don't surface in the public feed.
class SuggestionPostResult {
  const SuggestionPostResult({this.wasHidden = false});
  final bool wasHidden;
}

/// Shows the sheet; pops with a [CommentPostResult] (bình luận đoạn) or
/// [SuggestionPostResult] (góp ý) when posted, null when cancelled.
Future<Object?> showSegmentComposer(
  BuildContext context, {
  required String chapterId,
  required String quoteText,
  SegmentComposerMode initialMode = SegmentComposerMode.comment,
}) {
  return showModalBottomSheet<Object>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => SegmentComposerSheet(
      chapterId: chapterId,
      quoteText: quoteText,
      initialMode: initialMode,
    ),
  );
}
