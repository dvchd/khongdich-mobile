import 'package:flutter_test/flutter_test.dart';
import 'package:khongdich_mobile/core/markdown/markdown.dart';

/// Rule plain text mirror đúng web `render_vietnamese_text` (src/utils.rs):
/// 1 Enter = ngắt dòng, dòng trống = đoạn mới, scene-break = hr,
/// heading = h1-h6, list marker đầu dòng = literal.
void main() {
  group('plainTextToMarkdown', () {
    test('1 Enter duy nhất → hard break (web render <br>)', () {
      final out = plainTextToMarkdown('Dòng A\nDòng B\nDòng C');
      expect(out, 'Dòng A  \nDòng B  \nDòng C  ');
    });

    test('dòng trống → paragraph mới', () {
      final out = plainTextToMarkdown('Đoạn 1\n\nĐoạn 2');
      expect(out, 'Đoạn 1  \n\nĐoạn 2  ');
    });

    test('scene-break *** / --- / ___ → HorizontalRule', () {
      expect(plainTextToMarkdown('***'), '---');
      expect(plainTextToMarkdown('---'), '---');
      expect(plainTextToMarkdown('___'), '---');
      expect(plainTextToMarkdown('* * *'), '---');
      // Không phải scene break khi có text khác.
      expect(plainTextToMarkdown('---text'), '---text  ');
    });

    test('heading # → giữ nguyên heading', () {
      expect(plainTextToMarkdown('# Chương 1'), '# Chương 1');
      expect(plainTextToMarkdown('## Mục'), '## Mục');
    });

    test('list marker đầu dòng → escape literal (web escape)', () {
      expect(plainTextToMarkdown('- Lời thoại'), r'\- Lời thoại  ');
      expect(plainTextToMarkdown('* Lời thoại'), r'\* Lời thoại  ');
      expect(plainTextToMarkdown('1. Một'), r'1\. Một  ');
      // Không phải list marker khi không có space sau dấu.
      expect(plainTextToMarkdown('-không space'), '-không space  ');
    });

    test('inline **bold** *italic* giữ nguyên', () {
      expect(plainTextToMarkdown('**mạnh** và *nghiêng*'),
          '**mạnh** và *nghiêng*  ');
    });

    test('CRLF chuẩn hoá như CRLF', () {
      expect(plainTextToMarkdown('A\r\nB'), 'A  \nB  ');
    });

    test('paragraph nhiều dòng + scene break + heading lẫn nhau', () {
      final src = 'Đoạn 1 dòng 1\nĐoạn 1 dòng 2\n\n***\n\n# Tiêu đề\n\nCuối';
      final out = plainTextToMarkdown(src);
      expect(out, 'Đoạn 1 dòng 1  \nĐoạn 1 dòng 2  \n\n---\n\n# Tiêu đề\n\nCuối  ');
    });

    test('render qua parser: hard break xuống dòng, paragraph tách', () {
      final md = plainTextToMarkdown('Dòng A\nDòng B\n\nĐoạn 2');
      final blocks = MarkdownParser().parse(md);
      expect(blocks.length, 2); // 2 paragraphs
    });
  });
}