/// Markdown → TTS-friendly plain text chunker.
///
/// Per `docs/plan-flutter-app.md` §9.4 — pure-Dart, no `flutter_tts`
/// dependency. The same input drives both:
///   1. The on-device TTS engine (Phase 2, behind `flutter_tts`).
///   2. The "estimated reading time" + reader "jump-to-chunk" index
///      features that ship in the MVP reader chrome.
class TtsMarkdownPreprocessor {
  TtsMarkdownPreprocessor._();

  /// Convert [markdown] into a list of plain-text chunks roughly <= 500
  /// characters each, broken on paragraph boundaries.
  static List<String> process(String markdown) {
    var text = markdown;

    // 1. Remove fenced code blocks entirely.
    text = text.replaceAll(RegExp(r'```[\s\S]*?```'), '');
    text = text.replaceAll(RegExp(r'~~~[\s\S]*?~~~'), '');

    // 2. Inline code: keep the inner text.
    text = text.replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => m.group(1)!);

    // 3. Strip heading markers, add a pause.
    text = text.replaceAllMapped(
      RegExp(r'^#{1,6}\s+(.+)$', multiLine: true),
      (m) => '${m.group(1)}.\n\n',
    );

    // 4. Strip bold / italic markers.
    text = text.replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'), (m) => m.group(1)!);
    text = text.replaceAllMapped(RegExp(r'__([^_]+)__'), (m) => m.group(1)!);
    text = text.replaceAllMapped(RegExp(r'\*([^*]+)\*'), (m) => m.group(1)!);
    text = text.replaceAllMapped(RegExp(r'_([^_]+)_'), (m) => m.group(1)!);

    // 5. Strikethrough.
    text = text.replaceAllMapped(RegExp(r'~~([^~]+)~~'), (m) => m.group(1)!);

    // 6. Links: keep the label, drop the URL.
    text = text.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\([^)]+\)'),
      (m) => m.group(1)!,
    );

    // 7. Images: drop entirely.
    text = text.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]+\)'), '');

    // 8. Blockquote markers.
    text = text.replaceAll(RegExp(r'^>\s*', multiLine: true), '');

    // 9. List markers.
    text = text.replaceAll(RegExp(r'^[\-\*\+]\s+', multiLine: true), '');
    text = text.replaceAll(RegExp(r'^\d+\.\s+', multiLine: true), '');

    // 10. Horizontal rule → pause.
    text = text.replaceAll(RegExp(r'^[\-\*_]{3,}$', multiLine: true), '\n\n');

    // 11. Hard breaks.
    text = text.replaceAll(RegExp(r'  \n'), '\n\n');
    text = text.replaceAll(RegExp(r'\\\n'), '\n\n');

    // 12. Collapse 3+ newlines, then trim.
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();

    // 13. Split into chunks at paragraph boundaries, max ~500 chars each.
    //     Long paragraphs with no blank-line breaks fall back to sentence
    //     boundaries (. ! ?) so we still get multiple TTS-sized chunks.
    final paragraphs = text.split(RegExp(r'\n\n+'));
    final chunks = <String>[];
    var current = StringBuffer();

    void pushCurrent() {
      final s = current.toString().trim();
      if (s.isNotEmpty) chunks.add(s);
      current.clear();
    }

    for (final para in paragraphs) {
      final trimmed = para.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.length > 500) {
        // Flush whatever we've accumulated first so sentence-bisected
        // chunks don't blend into a previous paragraph.
        pushCurrent();
        for (final piece in _splitSentences(trimmed, 500)) {
          chunks.add(piece);
        }
        continue;
      }
      if (current.length + trimmed.length > 500 && current.isNotEmpty) {
        pushCurrent();
      }
      current
        ..writeln(trimmed)
        ..writeln();
    }
    pushCurrent();
    return chunks;
  }

  /// Split a long paragraph into <= [maxLen]-char pieces on sentence
  /// boundaries (`. `, `! `, `? `). Falls back to hard slicing if a single
  /// sentence exceeds [maxLen].
  static List<String> _splitSentences(String text, int maxLen) {
    final result = <String>[];
    final sentenceEnd = RegExp(r'(?<=[.!?])\s+');
    final sentences = text.split(sentenceEnd);
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
