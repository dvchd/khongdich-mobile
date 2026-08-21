/// Chuyển nội dung chương ở định dạng **plain text** sang markdown tương
/// đương để dùng chung pipeline render markdown của mobile.
///
/// Mirror chính xác `render_vietnamese_text` bên web (src/utils.rs):
///
/// | Web (plain)                    | Markdown tương đương          |
/// |--------------------------------|-------------------------------|
/// | 1 Enter `\n` → `<br>`          | 2 spaces cuối dòng (hard br)  |
/// | Dòng trống → `<p>` mới         | Dòng trống → paragraph mới    |
/// | `***`/`---`/`___` (3+) đứng 1 mình → `<hr class="scene-break">` | `---` → HorizontalRule |
/// | `#`–`######` đầu dòng → `<h1-h6>` | giữ nguyên heading         |
/// | `**bold**`, `*italic*`, `[link](url)`, `![img](url)` | giữ nguyên (markdown inline) |
/// | Mọi thứ khác literal           | literal (markdown cũng literal) |
///
/// Khác biệt có chủ đích: web escape list marker đầu dòng (`- `, `* `, ...)
/// thành literal; mobile làm tương tự để tránh parse nhầm thành list —
/// tác giả truyện Việt dùng `- ` cho lời thoại, không phải list.
String plainTextToMarkdown(String plain) {
  final normalized = plain.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final paragraphs = normalized
      .split('\n')
      .fold<List<List<String>>>([], (acc, line) {
        if (line.trim().isEmpty) {
          acc.add([]);
        } else if (acc.isEmpty) {
          acc.add([line]);
        } else {
          acc.last.add(line);
        }
        return acc;
      })
      .where((p) => p.isNotEmpty)
      .toList();

  final out = <String>[];
  for (final para in paragraphs) {
    final trimmedFirst = para.first.trim();
    if (isSceneBreakLine(trimmedFirst) && para.length == 1) {
      out.add('---');
      continue;
    }
    if (para.length == 1 && _isHeadingLine(trimmedFirst)) {
      out.add(_escapeListMarker(trimmedFirst));
      continue;
    }
    // Mỗi dòng trong paragraph → 1 dòng markdown với 2 spaces cuối (hard
    // break) → web render `<br>` tương đương.
    out.add(para.map(_escapeListMarker).map((l) => '$l  ').join('\n'));
  }
  return out.join('\n\n');
}

/// `***`, `---`, `___`, `* * *`, ... — đứng 1 mình, không có text khác.
/// Giống `is_scene_break_line` bên web.
bool isSceneBreakLine(String line) {
  if (line.isEmpty) return false;
  final first = line[0];
  if (first != '*' && first != '-' && first != '_') return false;
  var count = 0;
  for (final c in line.runes) {
    final ch = String.fromCharCode(c);
    if (ch == first) {
      count++;
    } else if (ch != ' ' && ch != '\t') {
      return false;
    }
  }
  return count >= 3;
}

bool _isHeadingLine(String line) =>
    RegExp(r'^\s{0,3}#{1,6}\s+').hasMatch(line);

/// Escape list marker đầu dòng — web làm thế (`- ` → `\- `) để hiển thị
/// literal thay vì parse thành list.
String _escapeListMarker(String line) {
  final trimmed = line.trimLeft();
  if (trimmed.startsWith('- ') ||
      trimmed.startsWith('* ') ||
      trimmed.startsWith('+ ')) {
    return line.replaceFirst(trimmed, '\\$trimmed');
  }
  final ordered = RegExp(r'^(\d+)\. ').firstMatch(trimmed);
  if (ordered != null) {
    final num = ordered.group(1)!;
    return line.replaceFirst(
        trimmed, '$num\\. ${trimmed.substring(trimmed.indexOf('. ') + 2)}');
  }
  return line;
}