import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/markdown/markdown.dart';
import '../../tts/tts_audio_handler.dart';

/// Plain-text chapter view: markdown → Block AST → native widget tree.
/// When TTS is active, highlights the currently-spoken chunk.
class TextChapterView extends ConsumerStatefulWidget {
  const TextChapterView({
    super.key,
    required this.markdown,
    required this.theme,
    this.scrollController,
  });

  final String markdown;
  final ReaderTheme theme;
  final ScrollController? scrollController;

  @override
  ConsumerState<TextChapterView> createState() => _TextChapterViewState();
}

class _TextChapterViewState extends ConsumerState<TextChapterView> {
  int _highlightedChunk = -1;
  List<String>? _ttsChunks;

  @override
  void initState() {
    super.initState();
    // Pre-compute the same chunks TtsAudioHandler uses, so we can
    // map chunk index → text position for highlighting.
    _ttsChunks = TtsMarkdownPreprocessor.process(widget.markdown);
    // Listen to TTS progress
    _listenToTts();
  }

  void _listenToTts() {
    // Use a post-frame callback to avoid calling provider during build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final handlerAsync = ref.read(ttsHandlerProvider);
      handlerAsync.whenData((handler) {
        handler.chunkProgress.listen((p) {
          if (mounted && p.chunkIndex != _highlightedChunk) {
            setState(() => _highlightedChunk = p.chunkIndex);
          }
        });
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final blocks = MarkdownParser().parse(widget.markdown);
    return SingleChildScrollView(
      controller: widget.scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: _HighlightedMarkdown(
        blocks: blocks,
        theme: widget.theme,
        highlightedChunk: _highlightedChunk,
        ttsChunks: _ttsChunks ?? const [],
      ),
    );
  }
}

/// Renders markdown blocks, highlighting the TTS chunk that's
/// currently being spoken. The highlight is a subtle background tint
/// on the paragraph that contains the current chunk's text.
class _HighlightedMarkdown extends StatelessWidget {
  const _HighlightedMarkdown({
    required this.blocks,
    required this.theme,
    required this.highlightedChunk,
    required this.ttsChunks,
  });

  final List<Block> blocks;
  final ReaderTheme theme;
  final int highlightedChunk;
  final List<String> ttsChunks;

  @override
  Widget build(BuildContext context) {
    // If TTS is not active (highlightedChunk == -1), render normally.
    if (highlightedChunk < 0 || highlightedChunk >= ttsChunks.length) {
      return MarkdownRenderer(blocks: blocks, theme: theme);
    }

    // Get the text of the current chunk → find which paragraph
    // contains it → highlight that paragraph.
    final currentChunkText = ttsChunks[highlightedChunk];
    final highlightColor = theme.accentColor.withValues(alpha: 0.15);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final block in blocks)
          _renderBlockWithHighlight(block, theme, currentChunkText, highlightColor),
      ],
    );
  }

  Widget _renderBlockWithHighlight(
    Block block,
    ReaderTheme t,
    String chunkText,
    Color highlightColor,
  ) {
    // Check if this block's text contains the current chunk
    final blockText = _extractText(block);
    final shouldHighlight = blockText.isNotEmpty &&
        chunkText.isNotEmpty &&
        _textOverlap(blockText, chunkText);

    if (shouldHighlight && block is Paragraph) {
      return Container(
        decoration: BoxDecoration(
          color: highlightColor,
          borderRadius: BorderRadius.circular(4),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: RichText(
          text: TextSpan(
            style: t.bodyStyle,
            children: [
              for (final i in block.children)
                _renderInline(i, t, null),
            ],
          ),
        ),
      );
    }

    // Fall back to normal rendering
    return MarkdownRenderer(blocks: [block], theme: t);
  }

  String _extractText(Block block) {
    return switch (block) {
      Paragraph(:final children) => children
          .map((i) => switch (i) {
                TextRun(:final text) => text,
                _ => '',
              })
          .join(),
      Heading(:final children) => children
          .map((i) => switch (i) {
                TextRun(:final text) => text,
                _ => '',
              })
          .join(),
      _ => '',
    };
  }

  bool _textOverlap(String a, String b) {
    // Check if any 20-char substring of b appears in a
    if (b.length < 10) return a.contains(b);
    final snippet = b.substring(0, b.length > 40 ? 40 : b.length);
    return a.contains(snippet);
  }

  InlineSpan _renderInline(Inline inline, ReaderTheme t, VoidCallback? onTap) {
    return switch (inline) {
      TextRun(:final text) => TextSpan(text: text),
      EmphasisRun(:final children) => TextSpan(
          style: const TextStyle(fontStyle: FontStyle.italic),
          children: [for (final i in children) _renderInline(i, t, onTap)],
        ),
      StrongRun(:final children) => TextSpan(
          style: const TextStyle(fontWeight: FontWeight.bold),
          children: [for (final i in children) _renderInline(i, t, onTap)],
        ),
      StrikethroughRun(:final children) => TextSpan(
          style: const TextStyle(decoration: TextDecoration.lineThrough),
          children: [for (final i in children) _renderInline(i, t, onTap)],
        ),
      LinkRun(:final children) => TextSpan(
          style: TextStyle(color: t.accentColor, decoration: TextDecoration.underline),
          children: [for (final i in children) _renderInline(i, t, onTap)],
        ),
      CodeRun(:final code) => TextSpan(text: code, style: t.codeStyle),
      LineBreak(:final hard) => TextSpan(text: hard ? '\n' : ' '),
    };
  }
}
