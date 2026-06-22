/// Block AST for the custom Không Dịch markdown renderer.
///
/// Per `docs/plan-flutter-app.md` §4.3 — sealed Block hierarchy.
/// Each block represents one top-level markdown structure (paragraph,
/// heading, list, blockquote, etc.). Inline spans live under [Inline].
library;

/// Marker interface for top-level markdown blocks.
sealed class Block {
  const Block();

  /// Render this block to a JSON-serialisable map. Used by the shared
  /// fixture test suite (plan §13.5) to compare Dart output against the
  /// Rust renderer.
  Map<String, dynamic> toJson();
}

class Paragraph extends Block {
  final List<Inline> children;
  const Paragraph(this.children);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'paragraph',
        'children': [for (final c in children) c.toJson()],
      };
}

class Heading extends Block {
  final int level; // 1..6
  final List<Inline> children;
  const Heading(this.level, this.children);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'heading',
        'level': level,
        'children': [for (final c in children) c.toJson()],
      };
}

class BlockQuote extends Block {
  final List<Block> children;
  const BlockQuote(this.children);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'blockquote',
        'children': [for (final c in children) c.toJson()],
      };
}

class CodeBlock extends Block {
  final String? language;
  final String code;
  const CodeBlock(this.language, this.code);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'code_block',
        if (language != null) 'language': language,
        'code': code,
      };
}

class HorizontalRule extends Block {
  const HorizontalRule();

  @override
  Map<String, dynamic> toJson() => {'type': 'horizontal_rule'};
}

class BulletList extends Block {
  final List<List<Block>> items;
  const BulletList(this.items);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'bullet_list',
        'items': [
          for (final item in items)
            [for (final b in item) b.toJson()],
        ],
      };
}

class OrderedList extends Block {
  final int start;
  final List<List<Block>> items;
  const OrderedList(this.start, this.items);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'ordered_list',
        'start': start,
        'items': [
          for (final item in items)
            [for (final b in item) b.toJson()],
        ],
      };
}

class ImageBlock extends Block {
  final String url;
  final String? alt;
  final String? caption;
  const ImageBlock(this.url, {this.alt, this.caption});

  @override
  Map<String, dynamic> toJson() => {
        'type': 'image',
        'url': url,
        if (alt != null) 'alt': alt,
        if (caption != null) 'caption': caption,
      };
}

// ---------- Inline spans ----------

/// Marker interface for inline markdown spans (RichText children).
sealed class Inline {
  const Inline();

  Map<String, dynamic> toJson();
}

class TextRun extends Inline {
  final String text;
  const TextRun(this.text);

  @override
  Map<String, dynamic> toJson() => {'type': 'text', 'text': text};
}

class EmphasisRun extends Inline {
  final List<Inline> children;
  const EmphasisRun(this.children);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'emphasis',
        'children': [for (final c in children) c.toJson()],
      };
}

class StrongRun extends Inline {
  final List<Inline> children;
  const StrongRun(this.children);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'strong',
        'children': [for (final c in children) c.toJson()],
      };
}

class StrikethroughRun extends Inline {
  final List<Inline> children;
  const StrikethroughRun(this.children);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'strikethrough',
        'children': [for (final c in children) c.toJson()],
      };
}

class LinkRun extends Inline {
  final String url;
  final List<Inline> children;
  const LinkRun(this.url, this.children);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'link',
        'url': url,
        'children': [for (final c in children) c.toJson()],
      };
}

class CodeRun extends Inline {
  final String code;
  const CodeRun(this.code);

  @override
  Map<String, dynamic> toJson() => {'type': 'code', 'code': code};
}

class LineBreak extends Inline {
  final bool hard; // true = <br>, false = soft break (rendered as space)
  const LineBreak(this.hard);

  @override
  Map<String, dynamic> toJson() => {'type': 'line_break', 'hard': hard};
}
