import 'package:flutter/material.dart';

import '../../../core/markdown/markdown.dart';

/// Plain-text chapter view: markdown → Block AST → native widget tree.
///
/// Plan §5.4 + §4.4 — `MarkdownRenderer` builds a column of `RichText`
/// widgets, which is far cheaper than `flutter_widget_from_html` for the
/// same payload.
class TextChapterView extends StatelessWidget {
  const TextChapterView({
    super.key,
    required this.markdown,
    required this.theme,
  });

  final String markdown;
  final ReaderTheme theme;

  @override
  Widget build(BuildContext context) {
    final blocks = MarkdownParser().parse(markdown);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: MarkdownRenderer(blocks: blocks, theme: theme),
    );
  }
}
