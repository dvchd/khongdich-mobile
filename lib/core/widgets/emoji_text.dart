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
/// Sizing + layout rules (same as the web CSS):
///   - whole comment = only emojis  → 72px, mỗi icon một dòng riêng
///   - emoji leading the text       → 56px, cách dòng (đứng đầu)
///   - emoji trailing the text      → 56px, cách dòng (đứng cuối)
///   - emoji inline mid-sentence    → 20px, inline
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

    // 1. Tách content_html thành segment (text / emoji kèm class) — cùng
    //    thứ tự như web render: token → <img>, còn lại là text.
    final segments = <_Seg>[];
    var last = 0;
    var first = true;
    for (final m in _imgRe.allMatches(html)) {
      final textPart = _unescape(html.substring(last, m.start));
      if (!first || textPart.isNotEmpty) {
        segments.add(_Seg(text: textPart));
      }
      first = false;
      segments.add(
        _Seg(
          emoji: true,
          cls: m.group(1) ?? 'custom-emoji',
          url: m.group(2) ?? '',
          name: m.group(3) ?? '',
        ),
      );
      last = m.end;
    }
    final tail = _unescape(html.substring(last));
    if (tail.isNotEmpty) segments.add(_Seg(text: tail));

    // Bỏ khoảng trắng thuần nằm GIỮA hai emoji — web dùng `display:block`
    // cho emoji only/lead/trail nên khoảng trắng đó bị collapse (không
    // đáng kể); giữ lại sẽ chèn TextSpan rỗng giữa các dòng emoji.
    final cleaned = <_Seg>[];
    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      final isWsOnly = !seg.emoji && seg.text!.trim().isEmpty;
      final prevIsEmoji = i > 0 && segments[i - 1].emoji;
      final nextIsEmoji = i < segments.length - 1 && segments[i + 1].emoji;
      if (isWsOnly && prevIsEmoji && nextIsEmoji) continue;
      cleaned.add(seg);
    }

    // 2. Ghép thành spans. Emoji block (only/lead/trail) phải "cách dòng"
    //    như web (`display:block`) → chèn '\n' quanh nó:
    //      - only/trail: xuống dòng TRƯỚC (có nội dung phía trước)
    //      - only/lead:  xuống dòng SAU (có nội dung phía sau)
    final spans = <InlineSpan>[];
    for (var i = 0; i < cleaned.length; i++) {
      final seg = cleaned[i];
      if (!seg.emoji) {
        if (seg.text!.isNotEmpty) spans.add(TextSpan(text: seg.text));
        continue;
      }
      final cls = seg.cls!;
      final isOnly = cls.contains('custom-emoji-only');
      final isLead = cls.contains('custom-emoji-lead');
      final isTrail = cls.contains('custom-emoji-trail');
      final hasContentBefore = spans.isNotEmpty;
      final hasContentAfter = cleaned.skip(i + 1).any(
        (s) => !s.emoji ? s.text!.trim().isNotEmpty : true,
      );

      if ((isOnly || isTrail) && hasContentBefore) {
        spans.add(const TextSpan(text: '\n'));
      }
      spans.add(_emojiSpan(cls, seg.url!, seg.name!, effective));
      // only/lead KHÔNG thêm newline sau: khoảng cách giữa các emoji
      // only được tạo bởi newline TRƯỚC của emoji kế (tránh dòng trống).
      if (isLead && hasContentAfter) {
        spans.add(const TextSpan(text: '\n'));
      }
    }

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

/// Một segment trong content_html: text thường hoặc một emoji `<img>`.
class _Seg {
  const _Seg({this.text, this.emoji = false, this.cls, this.url, this.name});

  /// Text thường (null khi là emoji).
  final String? text;
  final bool emoji;
  final String? cls;
  final String? url;
  final String? name;
}
