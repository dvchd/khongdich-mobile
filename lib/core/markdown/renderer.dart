import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'ast.dart';

/// Reader typography + palette. Plan §14.1 design system; runtime
/// configurable via the reading settings sheet (font size, family, line
/// height, theme).
class ReaderTheme {
  ReaderTheme({
    required this.bodyStyle,
    required this.headingStyles,
    required this.accentColor,
    required this.paragraphSpacing,
    required this.codeStyle,
    required this.quoteColor,
    required this.blockBackground,
  });

  final TextStyle bodyStyle;
  final Map<int, TextStyle> headingStyles;
  final Color accentColor;
  final double paragraphSpacing;
  final TextStyle codeStyle;
  final Color quoteColor;
  final Color? blockBackground;

  factory ReaderTheme.defaults(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final onSurface =
        isDark ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A);
    final bodyColor = onSurface;
    final body = TextStyle(
      fontFamily: 'NotoSerif',
      fontSize: 18,
      height: 1.6,
      color: bodyColor,
    );
    final headingBase = TextStyle(
      fontFamily: 'NotoSans',
      fontWeight: FontWeight.w700,
      color: onSurface,
    );
    return ReaderTheme(
      bodyStyle: body,
      headingStyles: {
        1: headingBase.copyWith(fontSize: 28, height: 1.3),
        2: headingBase.copyWith(fontSize: 24, height: 1.3),
        3: headingBase.copyWith(fontSize: 20, height: 1.3),
        4: headingBase.copyWith(fontSize: 18, height: 1.4),
        5: headingBase.copyWith(fontSize: 16, height: 1.4),
        6: headingBase.copyWith(fontSize: 14, height: 1.4),
      },
      accentColor: const Color(0xFF3B82F6),
      paragraphSpacing: 12,
      codeStyle: TextStyle(
        fontFamily: 'monospace',
        fontSize: 15,
        color: bodyColor,
        backgroundColor:
            isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
      ),
      quoteColor: const Color(0xFFE11D48),
      blockBackground:
          isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC),
    );
  }

  TextStyle headingStyle(int level) =>
      headingStyles[level.clamp(1, 6)] ?? headingStyles[6]!;
}

/// Turn a [List<Block>] AST (from [MarkdownParser]) into a column of native
/// Flutter widgets. Per `docs/plan-flutter-app.md` §4.4.
class MarkdownRenderer extends StatelessWidget {
  const MarkdownRenderer({
    super.key,
    required this.blocks,
    required this.theme,
    this.onLinkTap,
  });

  final List<Block> blocks;
  final ReaderTheme theme;
  final void Function(Uri url)? onLinkTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final b in blocks) _renderBlock(b, theme, context),
      ],
    );
  }

  Widget _renderBlock(Block block, ReaderTheme t, BuildContext context) {
    return switch (block) {
      Paragraph(:final children) => Padding(
          padding: EdgeInsets.symmetric(vertical: t.paragraphSpacing / 2),
          child: RichText(
            text: TextSpan(
              style: t.bodyStyle,
              children: [
                for (final i in children) _renderInline(i, t, context),
              ],
            ),
          ),
        ),
      Heading(:final level, :final children) => Padding(
          padding: const EdgeInsets.only(top: 24, bottom: 12),
          child: RichText(
            text: TextSpan(
              style: t.headingStyle(level),
              children: [
                for (final i in children) _renderInline(i, t, context),
              ],
            ),
          ),
        ),
      BlockQuote(:final children) => Container(
          margin: const EdgeInsets.symmetric(vertical: 12),
          padding: const EdgeInsets.only(left: 16, top: 4, bottom: 4),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: t.quoteColor, width: 4),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final b in children) _renderBlock(b, t, context),
            ],
          ),
        ),
      CodeBlock(:final code, :final language) => Container(
          margin: const EdgeInsets.symmetric(vertical: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: t.blockBackground,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (language != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    language,
                    style: t.bodyStyle.copyWith(
                      fontSize: 12,
                      color: t.bodyStyle.color?.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              SelectableText(
                code,
                style: t.codeStyle,
              ),
            ],
          ),
        ),
      HorizontalRule() => Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: Text(
              '* * *',
              style: t.bodyStyle.copyWith(letterSpacing: 8),
            ),
          ),
        ),
      BulletList(:final items) => _renderList(items, t, context, ordered: false, start: 1),
      OrderedList(:final start, :final items) => _renderList(items, t, context, ordered: true, start: start),
      ImageBlock(:final url, :final alt, :final caption) => _renderImage(url, alt, caption, t, context),
    };
  }

  Widget _renderList(
    List<List<Block>> items,
    ReaderTheme t,
    BuildContext context, {
    required bool ordered,
    required int start,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 24,
                    child: Text(
                      ordered ? '${start + i}.' : '•',
                      style: t.bodyStyle,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final b in items[i])
                          _renderBlock(b, t, context),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _renderImage(
    String url,
    String? alt,
    String? caption,
    ReaderTheme t,
    BuildContext context,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              url,
              fit: BoxFit.fitWidth,
              errorBuilder: (_, __, ___) => Container(
                height: 120,
                color: t.blockBackground,
                alignment: Alignment.center,
                child: Text(
                  alt ?? '[image]',
                  style: t.bodyStyle,
                ),
              ),
            ),
          ),
          if (caption != null || alt != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                caption ?? alt!,
                textAlign: TextAlign.center,
                style: t.bodyStyle.copyWith(
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                  color: t.bodyStyle.color?.withValues(alpha: 0.7),
                ),
              ),
            ),
        ],
      ),
    );
  }

  InlineSpan _renderInline(Inline inline, ReaderTheme t, BuildContext context) {
    return switch (inline) {
      TextRun(:final text) => TextSpan(text: text),
      EmphasisRun(:final children) => TextSpan(
          style: const TextStyle(fontStyle: FontStyle.italic),
          children: [for (final i in children) _renderInline(i, t, context)],
        ),
      StrongRun(:final children) => TextSpan(
          style: const TextStyle(fontWeight: FontWeight.bold),
          children: [for (final i in children) _renderInline(i, t, context)],
        ),
      StrikethroughRun(:final children) => TextSpan(
          style: const TextStyle(decoration: TextDecoration.lineThrough),
          children: [for (final i in children) _renderInline(i, t, context)],
        ),
      LinkRun(:final url, :final children) => TextSpan(
          style: TextStyle(
            color: t.accentColor,
            decoration: TextDecoration.underline,
          ),
          recognizer: TapGestureRecognizer()
            ..onTap = () {
              final uri = Uri.tryParse(url);
              if (uri != null) {
                if (onLinkTap != null) {
                  onLinkTap!(uri);
                }
              }
            },
          children: [for (final i in children) _renderInline(i, t, context)],
        ),
      CodeRun(:final code) => WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: t.codeStyle.backgroundColor,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(code, style: t.codeStyle),
          ),
        ),
      LineBreak(:final hard) => TextSpan(text: hard ? '\n' : ' '),
    };
  }
}
