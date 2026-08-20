import 'ast.dart';
import 'parser.dart';

/// Markdown → TTS-friendly plain text chunker.
///
/// Per `docs/plan-flutter-app.md` §9.4 — pure-Dart, no `flutter_tts`
/// dependency. The same input drives both:
///   1. The on-device TTS engine (Phase 2, behind `flutter_tts`).
///   2. The "estimated reading time" + reader "jump-to-chunk" index
///      features that ship in the MVP reader chrome.
///
/// Since the reader highlight feature, chunks are produced BLOCK-ALIGNED
/// via [processWithBlocks]: every chunk knows which rendered markdown
/// block(s) it covers. The reader uses that exact mapping (instead of
/// fuzzy text matching) to highlight the paragraph being read — the
/// previous char-fingerprint matching drifted off-paragraph whenever a
/// chunk started mid-block or covered several short paragraphs.
class TtsMarkdownPreprocessor {
  TtsMarkdownPreprocessor._();

  /// Convert [markdown] into a list of plain-text chunks roughly <= 500
  /// characters each, broken on paragraph boundaries.
  static List<String> process(String markdown) {
    return [
      for (final chunk in processWithBlocks(markdown)) chunk.text,
    ];
  }

  /// Block-aligned chunker. Each returned [TtsChunk] carries the exact
  /// [Block] indices (into the `MarkdownParser` block list) whose text it
  /// contains, so the reader can highlight the paragraph currently being
  /// spoken without any fuzzy matching.
  ///
  /// Rules (mirroring the regex preprocessor semantics):
  ///   - Fenced code blocks are skipped entirely.
  ///   - Blocks with no visible text (horizontal rules, images with no
  ///     alt/caption) are skipped.
  ///   - Blocks are accumulated into a chunk until adding the next block
  ///     would exceed ~500 chars — a chunk therefore spans one or more
  ///     WHOLE blocks (paragraph boundaries are never crossed mid-block).
  ///   - A single block longer than 500 chars is sentence-split into
  ///     multiple chunks; every piece maps back to the same block.
  static List<TtsChunk> processWithBlocks(String markdown) {
    final blocks = MarkdownParser().parse(markdown);
    final chunks = <TtsChunk>[];

    void pushCurrent(List<TtsChunkBlock> parts) {
      if (parts.isEmpty) return;
      final text = parts.map((p) => p.text).join('\n\n').trim();
      if (text.isEmpty) return;
      chunks.add(TtsChunk(text: text, blocks: parts));
    }

    var current = <TtsChunkBlock>[];
    var currentLen = 0;

    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      if (block is CodeBlock) continue;
      var raw = block.plainText.trim();
      if (raw.isEmpty) continue;
      if (block is Heading) {
        // Heading markers are gone — add the trailing pause the regex
        // preprocessor used to append (".\n\n").
        if (!raw.endsWith('.')) raw = '$raw.';
      }
      if (raw.length > 500) {
        pushCurrent(current);
        current = [];
        currentLen = 0;
        for (final piece in _splitSentences(raw, 500)) {
          chunks.add(TtsChunk(text: piece, blocks: [
            TtsChunkBlock(blockIndex: i, text: piece),
          ]));
        }
        continue;
      }
      if (currentLen + raw.length > 500 && current.isNotEmpty) {
        pushCurrent(current);
        current = [];
        currentLen = 0;
      }
      current.add(TtsChunkBlock(blockIndex: i, text: raw));
      currentLen += raw.length;
    }
    pushCurrent(current);
    return chunks;
  }

  /// Split a long paragraph into <= [maxLen]-char pieces on sentence
  /// boundaries (`. `, `! `, `? `). Falls back to hard slicing if a single
  /// sentence exceeds [maxLen].
  static final RegExp _sentenceEndRegExp = RegExp(r'(?<=[.!?])\s+');

  static List<String> _splitSentences(String text, int maxLen) {
    final result = <String>[];
    final sentences = text.split(_sentenceEndRegExp);
    var buf = StringBuffer();
    for (final s in sentences) {
      if (s.isEmpty) continue;
      if (buf.length + s.length + 1 > maxLen && buf.isNotEmpty) {
        result.add(buf.toString().trim());
        buf.clear();
      }
      if (s.length > maxLen) {
        // Hard-split overlong single sentence.
        var start = 0;
        while (start < s.length) {
          final end = (start + maxLen).clamp(0, s.length);
          result.add(s.substring(start, end).trim());
          start = end;
        }
      } else {
        buf..write(s)..write(' ');
      }
    }
    final tail = buf.toString().trim();
    if (tail.isNotEmpty) result.add(tail);
    return result;
  }
}

/// One speakable piece of text + the rendered blocks it covers.
class TtsChunk {
  const TtsChunk({required this.text, required this.blocks});

  /// Plain text fed to the TTS engine.
  final String text;

  /// The markdown blocks (in reading order) whose text this chunk
  /// contains. Empty for chunks that map to no rendered block (shouldn't
  /// happen in practice).
  final List<TtsChunkBlock> blocks;
}

/// A block range element inside a [TtsChunk].
class TtsChunkBlock {
  const TtsChunkBlock({required this.blockIndex, required this.text});

  /// Index into the `MarkdownParser` block list.
  final int blockIndex;

  /// This block's contribution to the chunk text.
  final String text;
}
