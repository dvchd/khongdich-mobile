import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/markdown/markdown.dart';

/// Provides a singleton [MarkdownParser]. Cheap to share; no per-call state.
final markdownParserProvider = Provider<MarkdownParser>((ref) => MarkdownParser());
