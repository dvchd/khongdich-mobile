import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:khongdich_mobile/core/markdown/markdown.dart';

/// Shared fixture test — plan §13.5.
///
/// Loads `test/fixtures/markdown-fixtures.json`, runs every entry through
/// the Dart [MarkdownParser], and asserts that the resulting AST JSON
/// matches the `expected` block. The same fixtures are mirrored on the
/// Rust backend (`docs/markdown-fixtures.json`) so CI on both sides can
/// catch divergences.
void main() {
  final file = File('test/fixtures/markdown-fixtures.json');
  final raw = file.readAsStringSync();
  final List<dynamic> fixtures = jsonDecode(raw) as List<dynamic>;

  for (final entry in fixtures) {
    final fx = entry as Map<String, dynamic>;
    final name = fx['name'] as String;
    final input = fx['input'] as String;
    final expected = fx['expected'] as List<dynamic>;

    test('fixture: $name', () {
      final blocks = MarkdownParser().parse(input);
      final actual = [for (final b in blocks) b.toJson()];
      // Use a deep-equal JSON comparison so map key ordering doesn't matter.
      expect(jsonDecode(jsonEncode(actual)), equals(expected),
          reason: 'Fixture "$name" did not match.');
    });
  }
}
