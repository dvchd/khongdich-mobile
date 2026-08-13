import 'package:flutter/material.dart';

/// Renders comment / chat text with custom emoji, mirroring the web
/// renderer (`utils.rs::render_comment_emojis` + `style.css`).
///
/// The backend enriches `content_html` with
/// `<img class="custom-emoji…" src="…" alt=":name:">` tags, so parsing it
/// reproduces the server's token classification exactly — no per-token
/// resolve requests. Falls back to plain [text] when `content_html` is
/// missing (offline rows / legacy payloads).
///
/// Sizing rules (same as the web CSS):
///   - whole comment = only emojis        → 72px, own line
///   - emoji leading/trailing the text    → 56px, own line
///   - emoji inline mid-sentence          → 20px, inline
class EmojiText extends StatelessWidget {
  const EmojiText({
    super.key,
    required this.text,
    this.contentHtml,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
  });

  final String text;
  final String? contentHtml;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  static final RegExp _imgRe = RegExp(
    r'<img class="(custom-emoji[^"]*)" src="([^"]+)" alt=":([a-z0-9_]{1,32}):"[^>]*>',
  );

  /// Whether [html] contains any emoji `<img>` tag.
  static bool hasEmojiImages(String html) => _imgRe.hasMatch(html);

  @override
  Widget build(BuildContext context) {
    final html = contentHtml ?? '';
    if (html.isEmpty || !hasEmojiImages(html)) {
      return Text(
        text,
        style: style,
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: overflow,
      );
    }

    final effective = style ?? DefaultTextStyle.of(context).style;
    final spans = <InlineSpan>[];
    var last = 0;
    var first = true;
    for (final m in _imgRe.allMatches(html)) {
      final textPart = _unescape(html.substring(last, m.start));
      if (!first || textPart.isNotEmpty) {
        spans.add(TextSpan(text: textPart));
      }
      first = false;
      final cls = m.group(1) ?? 'custom-emoji';
      final url = m.group(2) ?? '';
      final name = m.group(3) ?? '';
      spans.add(_emojiSpan(cls, url, name, effective));
      last = m.end;
    }
    final tail = _unescape(html.substring(last));
    if (tail.isNotEmpty) spans.add(TextSpan(text: tail));
    if (spans.isEmpty) {
      return Text(
        text,
        style: style,
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: overflow,
      );
    }
    return Text.rich(
      TextSpan(style: effective, children: spans),
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
    );
  }

  WidgetSpan _emojiSpan(String cls, String url, String name, TextStyle base) {
    final double size;
    if (cls.contains('custom-emoji-only')) {
      size = 72;
    } else if (cls.contains('custom-emoji-lead') ||
        cls.contains('custom-emoji-trail')) {
      size = 56;
    } else {
      size = 20;
    }
    final img = url.isEmpty
        ? null
        : Image.network(
            url,
            width: size,
            height: size,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => Text(
              ':$name:',
              style: base.copyWith(fontWeight: FontWeight.w600),
            ),
          );
    final child = img ??
        Text(':$name:', style: base.copyWith(fontWeight: FontWeight.w600));
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: size >= 40 ? 2 : 1.5),
        child: child,
      ),
    );
  }

  /// Minimal HTML entity unescape for the set the backend's `html_escape`
  /// produces: `&amp; &lt; &gt; &quot; &#39;`. Single-pass so text like
  /// `&amp;lt;` (a literal `&lt;`) is unescaped exactly one level.
  static String _unescape(String s) => s.replaceAllMapped(
    RegExp(r'&(amp|lt|gt|quot|#39);'),
    (m) => switch (m.group(1)) {
      'amp' => '&',
      'lt' => '<',
      'gt' => '>',
      'quot' => '"',
      _ => "'",
    },
  );
}
