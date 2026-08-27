import 'ast.dart';

/// Custom CommonMark-subset parser for Không Dịch.
///
/// Implements the rendering spec in `docs/plan-flutter-app.md` §13.1
/// (CommonMark core) + §13.2 strikethrough extension. Tables, task lists
/// and footnotes are explicitly out of MVP scope per the plan.
///
/// The parser produces a `List<Block>` AST that the [MarkdownRenderer] turns
/// into Flutter widgets, and that the shared fixture test suite
/// (`test/fixtures/markdown-fixtures.json`, plan §13.5) compares against
/// the Rust backend renderer.
class MarkdownParser {
  MarkdownParser();

  /// Maximum nesting depth for blockquote / list recursion. Deeply
  /// nested structures (`> > > > ...` × 1000) would overflow Dart's
  /// ~1MB stack and crash the app with StackOverflowError. Since
  /// chapter content comes from the server, a malicious or buggy
  /// chapter could crash every client that opens it. 50 levels is
  /// far beyond any legitimate chapter structure.
  static const int _maxDepth = 50;

  /// Maximum inline nesting depth (Strong/Emphasis/Link label
  /// recursion). Each level needs at least ~4 chars of marker, so a
  /// long pathological string (`**a **b **c ...** b** a**`) could
  /// recurse tens of thousands of levels deep and overflow the stack.
  static const int _maxInlineDepth = 100;

  /// Parse [source] markdown into a list of top-level [Block]s.
  List<Block> parse(String source) => _parseWithDepth(source, 0);

  List<Block> _parseWithDepth(String source, int depth) {
    if (depth > _maxDepth) {
      // Fallback: treat the entire source as a single paragraph of
      // plain text. This prevents StackOverflowError on pathological
      // nesting while still showing the user the raw content.
      return [
        Paragraph([TextRun(source)]),
      ];
    }
    final lines = source.replaceAll('\r\n', '\n').split('\n');
    final ctx = _ParseContext(lines);
    return _parseBlocks(ctx, depth);
  }

  // ---- Block parsing ----

  List<Block> _parseBlocks(_ParseContext ctx, int depth) {
    final blocks = <Block>[];
    while (!ctx.isAtEnd) {
      // Skip blank lines between blocks.
      if (ctx.currentIsBlank) {
        ctx.advance();
        continue;
      }

      // ATX heading.
      final heading = _tryParseHeading(ctx);
      if (heading != null) {
        blocks.add(heading);
        continue;
      }

      // Horizontal rule.
      if (_isHorizontalRule(ctx.current)) {
        blocks.add(const HorizontalRule());
        ctx.advance();
        continue;
      }

      // Fenced code block.
      final fence = _tryParseFencedCode(ctx);
      if (fence != null) {
        blocks.add(fence);
        continue;
      }

      // Blockquote.
      if (ctx.current.trimLeft().startsWith('>')) {
        blocks.add(_parseBlockquote(ctx, depth));
        continue;
      }

      // Lists.
      if (_isBulletListItem(ctx.current) || _isOrderedListItem(ctx.current)) {
        blocks.add(_parseList(ctx, depth));
        continue;
      }

      // Indented code block (4+ leading spaces or 1+ tab).
      if (_isIndentedCode(ctx.current)) {
        blocks.add(_parseIndentedCode(ctx));
        continue;
      }

      // Default: paragraph (có thể tách thành các ImageBlock nếu cả đoạn
      /// là ảnh đứng riêng dòng — xem [_parseParagraph]).
      blocks.addAll(_parseParagraph(ctx));
    }
    return blocks;
  }

  Heading? _tryParseHeading(_ParseContext ctx) {
    final line = ctx.current;
    final m = _headingRegExp.firstMatch(line);
    if (m == null) return null;
    final level = m.group(1)!.length;
    var text = m.group(2)!.trim();
    // Strip trailing # sequence ("## foo ##").
    text = text.replaceFirst(_trailingHeadingRegExp, '');
    ctx.advance();
    return Heading(level, _parseInline(text));
  }

  Block _parseBlockquote(_ParseContext ctx, int depth) {
    final inner = <String>[];
    while (!ctx.isAtEnd && !ctx.currentIsBlank) {
      final line = ctx.current;
      final stripped = line.replaceFirst(_blockquoteStripRegExp, '');
      if (stripped == line && !line.trimLeft().startsWith('>')) {
        // Line no longer belongs to the blockquote.
        break;
      }
      inner.add(stripped);
      ctx.advance();
    }
    // NOTE: recursion must carry the SAME depth counter through
    // `_parseWithDepth` — a previous version created a fresh
    // `MarkdownParser()` instance here, resetting the depth guard to 0
    // on every level, so deeply-nested content could stack-overflow
    // the app.
    final childBlocks = _parseWithDepth(inner.join('\n'), depth + 1);
    return BlockQuote(childBlocks);
  }

  Block _parseList(_ParseContext ctx, int depth) {
    final isBullet = _isBulletListItem(ctx.current);
    var start = 1;
    if (!isBullet) {
      final m = _orderedListStartRegExp.firstMatch(ctx.current.trimLeft())!;
      start = int.parse(m.group(1)!);
    }
    final items = <List<Block>>[];
    while (!ctx.isAtEnd && !ctx.currentIsBlank) {
      final line = ctx.current;
      if (isBullet ? !_isBulletListItem(line) : !_isOrderedListItem(line)) {
        break;
      }
      // Collect this item: first line + continuation lines (indented or blank+indented).
      final itemLines = <String>[];
      final first = _stripListMarker(line);
      itemLines.add(first);
      ctx.advance();
      final indentBase = line.length - line.trimLeft().length;
      while (!ctx.isAtEnd) {
        final next = ctx.current;
        if (next.trim().isEmpty) {
          // Peek: if next-next is still indented → part of this item, else break.
          if (ctx.peekNextIndented(indentBase)) {
            itemLines.add('');
            ctx.advance();
            continue;
          } else {
            break;
          }
        }
        final nextIndent = next.length - next.trimLeft().length;
        if (nextIndent >= indentBase + 2) {
          itemLines.add(next.substring(indentBase + 2));
          ctx.advance();
        } else {
          break;
        }
      }
      items.add(_parseWithDepth(itemLines.join('\n'), depth + 1));
    }
    return isBullet ? BulletList(items) : OrderedList(start, items);
  }

  CodeBlock? _tryParseFencedCode(_ParseContext ctx) {
    final line = ctx.current;
    final m = _fenceRegExp.firstMatch(line);
    if (m == null) return null;
    // Only backtick fences (```) are supported — tilde fences (`~~~`) are
    // intentionally NOT recognised so that `~~~` typed by authors as a
    // decorative separator stays as literal text. `fenceChar` is always '`'.
    const fenceChar = '`';
    final lang = m.group(1)?.trim();
    // Count leading fence characters to know the minimum close fence length.
    // The opening match guarantees fenceChar repeats at least 3 times at the
    // start (after up to 3 leading whitespace chars).
    final stripped = line.trimLeft();
    var fenceLen = 0;
    for (final c in stripped.codeUnits) {
      if (String.fromCharCode(c) == fenceChar) {
        fenceLen++;
      } else {
        break;
      }
    }
    ctx.advance();
    final code = StringBuffer();
    final close = _fenceCloseRegExp(fenceLen);
    while (!ctx.isAtEnd) {
      final l = ctx.current;
      if (close.hasMatch(l)) {
        ctx.advance();
        break;
      }
      code.writeln(l);
      ctx.advance();
    }
    final text = code.toString();
    // Strip trailing newline introduced by writeln().
    final trimmed = text.endsWith('\n')
        ? text.substring(0, text.length - 1)
        : text;
    return CodeBlock((lang == null || lang.isEmpty) ? null : lang, trimmed);
  }

  Block _parseIndentedCode(_ParseContext ctx) {
    final code = StringBuffer();
    while (!ctx.isAtEnd) {
      final line = ctx.current;
      if (line.trim().isEmpty) {
        // Blank line: peek — if next line is also indented, keep; else break.
        if (ctx.peekNextIndented(4)) {
          code.writeln('');
          ctx.advance();
          continue;
        }
        break;
      }
      if (!_isIndentedCode(line)) break;
      // Strip first 4 spaces (or tab).
      final stripped = line.startsWith('\t')
          ? line.substring(1)
          : line.substring(4);
      code.writeln(stripped);
      ctx.advance();
    }
    final text = code.toString();
    final trimmed = text.endsWith('\n')
        ? text.substring(0, text.length - 1)
        : text;
    return CodeBlock(null, trimmed);
  }

  /// Parse a run of non-blank lines into blocks.
  ///
  /// WYSIWYG theo web (quyết định 2026-08): 1 Enter = line break trong
  /// CÙNG paragraph, 2 Enter = tách paragraph — KHÔNG chẻ hard break
  /// thành nhiều Paragraph. Đơn vị anchor bình luận đoạn / highlight /
  /// phân trang = đúng "đoạn" tác giả soạn.
  ///
  /// Ngoại lệ duy nhất: **ảnh đứng riêng dòng** `![alt](url)` emit
  /// [ImageBlock] để renderer vẽ ảnh thật — trước đây ảnh bị thay bằng
  /// text `[alt]` nên chương chữ không bao giờ hiển thị được ảnh. Ảnh
  /// trộn lẫn text trên cùng dòng vẫn fallback text `[alt]`.
  List<Block> _parseParagraph(_ParseContext ctx) {
    final buf = StringBuffer();
    while (!ctx.isAtEnd && !ctx.currentIsBlank) {
      final line = ctx.current;
      // Stop the paragraph if we hit a structural block starter.
      if (_headingRegExp.hasMatch(line) ||
          _isHorizontalRule(line) ||
          _fenceRegExp.hasMatch(line) ||
          line.trimLeft().startsWith('>') ||
          _isBulletListItem(line) ||
          _isOrderedListItem(line)) {
        break;
      }
      if (buf.isNotEmpty) buf.write('\n');
      buf.write(line);
      ctx.advance();
    }
    return _paragraphTextToBlocks(buf.toString());
  }

  /// Chuyển text paragraph thô thành block: cả đoạn chỉ gồm ảnh đứng
  /// riêng dòng → các [ImageBlock]; ngược lại [Paragraph] như cũ.
  List<Block> _paragraphTextToBlocks(String text) {
    if (text.isEmpty) return const [];
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const [];
    final lines = trimmed
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final images = <ImageBlock>[];
    for (final line in lines) {
      final img = _parseStandaloneImage(line);
      if (img == null) return [Paragraph(_parseInline(trimmed))];
      images.add(img);
    }
    return images;
  }

  /// Match TOÀN BỘ dòng là một ảnh markdown → ImageBlock. URL không
  /// an toàn (không http/https/mailto//) → null (fallback text `[alt]`
  /// như behavior cũ, không bao giờ fetch scheme lạ).
  ImageBlock? _parseStandaloneImage(String line) {
    final m = _imageRegExp.matchAsPrefix(line, 0);
    if (m == null || m.end != line.length) return null;
    final url = m.group(2) ?? '';
    if (!_isSafeUrl(url)) return null;
    final alt = (m.group(1) ?? '').trim();
    final title = m.group(3)?.trim();
    return ImageBlock(
      url,
      alt: alt.isEmpty ? null : alt,
      caption: (title != null && title.isEmpty) ? null : title,
    );
  }

  // ---- Inline parsing ----

  List<Inline> _parseInline(String text) => _parseInlineWithDepth(text, 0);

  List<Inline> _parseInlineWithDepth(String text, int depth) {
    if (depth > _maxInlineDepth) {
      return [TextRun(text)];
    }
    final spans = <Inline>[];
    final buf = StringBuffer();
    var i = 0;
    void flushText() {
      if (buf.isNotEmpty) {
        spans.add(TextRun(buf.toString()));
        buf.clear();
      }
    }

    while (i < text.length) {
      final c = text[i];

      // Hard break: two trailing spaces + newline OR backslash + newline.
      if (c == '\n') {
        final preceding = buf.toString();
        if (preceding.endsWith('  ')) {
          // Strip the two trailing spaces.
          buf
            ..clear()
            ..write(preceding.substring(0, preceding.length - 2));
          flushText();
          spans.add(const LineBreak(true));
          i++;
          continue;
        }
        if (preceding.endsWith('\\')) {
          buf
            ..clear()
            ..write(preceding.substring(0, preceding.length - 1));
          flushText();
          spans.add(const LineBreak(true));
          i++;
          continue;
        }
        // Soft break — flush text, emit soft LineBreak so the renderer can
        // decide whether to render it as a space or as a soft wrap. Plan
        // §13.1: "Soft break \n in paragraph → space (web) or soft wrap
        // (mobile)".
        flushText();
        spans.add(const LineBreak(false));
        i++;
        continue;
      }

      // Escape sequence.
      if (c == r'\' && i + 1 < text.length) {
        final next = text[i + 1];
        if (_escapableChars.contains(next)) {
          buf.write(next);
          i += 2;
          continue;
        }
      }

      // Inline code span.
      if (c == '`') {
        final match = _codeSpanRegExp.matchAsPrefix(text, i);
        if (match != null) {
          flushText();
          final raw = match.group(1)!;
          spans.add(CodeRun(raw.trim()));
          i = match.end;
          continue;
        }
      }

      // Image: ![alt](url)
      if (c == '!' && i + 1 < text.length && text[i + 1] == '[') {
        final match = _imageRegExp.matchAsPrefix(text, i);
        if (match != null) {
          flushText();
          final alt = (match.group(1) ?? '').trim();
          final url = match.group(2) ?? '';
          // Emit InlineImage (không phải TextRun('[$alt]') như trước):
          // renderer vẫn hiện fallback `[alt]`, nhưng TTS/plainText bỏ qua
          // hoàn toàn nên không bao giờ đọc link ảnh.
          spans.add(InlineImage(alt: alt, url: url));
          i = match.end;
          continue;
        }
      }

      // Link: [text](url)
      if (c == '[') {
        final match = _linkRegExp.matchAsPrefix(text, i);
        if (match != null) {
          final label = match.group(1) ?? '';
          final url = match.group(2) ?? '';
          if (_isSafeUrl(url)) {
            flushText();
            spans.add(
              LinkRun(url, _parseInlineWithDepth(label, depth + 1)),
            );
            i = match.end;
            continue;
          }
        }
      }

      // Strong **text** or __text__
      if ((c == '*' || c == '_') && i + 1 < text.length && text[i + 1] == c) {
        final marker = c + c;
        final close = text.indexOf(marker, i + 2);
        if (close > i + 2) {
          flushText();
          spans.add(
            StrongRun(
              _parseInlineWithDepth(text.substring(i + 2, close), depth + 1),
            ),
          );
          i = close + 2;
          continue;
        }
      }

      // Emphasis *text* or _text_
      if (c == '*' || c == '_') {
        final close = text.indexOf(c, i + 1);
        if (close > i + 1 &&
            !_isWordCharBefore(text, i) &&
            !_isWordCharAfter(text, close)) {
          flushText();
          spans.add(
            EmphasisRun(
              _parseInlineWithDepth(text.substring(i + 1, close), depth + 1),
            ),
          );
          i = close + 1;
          continue;
        }
      }

      // Note: ~~strikethrough~~ is intentionally NOT parsed. Vietnamese
      // authors sometimes type `~~~` as a decorative separator (similar to
      // `---` for scene break), and parsing `~~` as strikethrough produced
      // malformed output. Both `~~` and `~~~` fall through to literal text.

      buf.write(c);
      i++;
    }
    flushText();
    return spans;
  }

  bool _isWordCharBefore(String text, int idx) {
    if (idx == 0) return false;
    final prev = text[idx - 1];
    return _isWordChar(prev);
  }

  bool _isWordCharAfter(String text, int idx) {
    if (idx + 1 >= text.length) return false;
    final next = text[idx + 1];
    return _isWordChar(next);
  }

  bool _isWordChar(String c) {
    final rune = c.codeUnitAt(0);
    return (rune >= 0x30 && rune <= 0x39) || // 0-9
        (rune >= 0x41 && rune <= 0x5A) || // A-Z
        (rune >= 0x61 && rune <= 0x7A) || // a-z
        c == '_';
  }

  bool _isSafeUrl(String url) {
    final lower = url.toLowerCase();
    return lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('mailto:') ||
        lower.startsWith('/');
  }

  // ---- Static helpers / regexes ----

  static const String _escapableChars = r'\`*_{}[]()#+-.!|~>';

  static final RegExp _headingRegExp = RegExp(r'^\s{0,3}(#{1,6})\s+(.*)$');
  static final RegExp _trailingHeadingRegExp = RegExp(r'\s+#+\s*$');
  static final RegExp _blockquoteStripRegExp = RegExp(r'^\s{0,3}>\s?');
  // Fence regex: only backtick fences (```), NOT `~~~` (tilde fences).
  // Vietnamese authors sometimes type `~~~` as a decorative separator
  // (similar to `---`), so we deliberately don't recognise it as a code
  // fence to keep it as literal text.
  static final RegExp _fenceRegExp = RegExp(
    r'^\s{0,3}`{3,}\s*([\w\-+#.]*)\s*$',
  );

  /// Close-fence matchers, compiled once per distinct fence length.
  static final Map<int, RegExp> _fenceCloseCache = {};

  static RegExp _fenceCloseRegExp(int fenceLen) {
    return _fenceCloseCache.putIfAbsent(fenceLen, () {
      return RegExp('^\\s{0,3}`{$fenceLen,}\\s*\$');
    });
  }
  static final RegExp _orderedListStartRegExp = RegExp(r'^(\d{1,9})[.)]\s+');

  static final RegExp _codeSpanRegExp = RegExp(r'`+((?:[^`]|(?<=\\)`)*?)`+');
  static final RegExp _linkRegExp = RegExp(
    r'\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)',
  );
  // `\s*` giữa `]` và `(`: chịu được cách viết `![alt] (url)` mà tác giả
  // hay dùng — trước đây không khớp → nguyên cú pháp kể cả link ảnh bị
  // coi là text thô và TTS đọc to.
  static final RegExp _imageRegExp = RegExp(
    r'!\[([^\]]*)\]\s*\(([^)\s]+)(?:\s+"([^"]*)")?\)',
  );
  static final RegExp _bulletItemRegExp = RegExp(r'^\s{0,3}([-*+])\s+');

  bool _isHorizontalRule(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return false;
    if (trimmed.length < 3) return false;
    final first = trimmed[0];
    if (first != '-' && first != '*' && first != '_') return false;
    var count = 0;
    for (final code in trimmed.codeUnits) {
      if (code == 0x20) continue; // ' '
      if (code != first.codeUnitAt(0)) return false;
      count++;
    }
    return count >= 3;
  }

  bool _isBulletListItem(String line) {
    final m = _bulletItemRegExp.firstMatch(line);
    return m != null;
  }

  bool _isOrderedListItem(String line) {
    return _orderedListStartRegExp.hasMatch(line.trimLeft());
  }

  bool _isIndentedCode(String line) {
    return line.startsWith('    ') || line.startsWith('\t');
  }

  String _stripListMarker(String line) {
    final bullet = _bulletItemRegExp.firstMatch(line);
    if (bullet != null) return line.substring(bullet.end);
    final ordered = _orderedListStartRegExp.firstMatch(line.trimLeft())!;
    final leading = line.length - line.trimLeft().length;
    return line.substring(leading + ordered.end);
  }
}

/// Mutable cursor over the source lines.
class _ParseContext {
  _ParseContext(this._lines);

  final List<String> _lines;
  int _i = 0;

  bool get isAtEnd => _i >= _lines.length;
  String get current => _lines[_i];
  bool get currentIsBlank => current.trim().isEmpty;

  void advance() => _i++;

  /// Peek the next non-blank line. Return true if it is indented at least
  /// [minIndent] columns. Used to decide whether blank lines belong to the
  /// current list item / indented code block.
  bool peekNextIndented(int minIndent) {
    var j = _i + 1;
    while (j < _lines.length && _lines[j].trim().isEmpty) {
      j++;
    }
    if (j >= _lines.length) return false;
    final line = _lines[j];
    final indent = line.length - line.trimLeft().length;
    return indent >= minIndent;
  }
}
