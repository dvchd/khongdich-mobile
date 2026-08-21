import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../network/app_image_cache.dart';
import 'ast.dart';

/// Reader typography + palette. Plan §14.1 design system; runtime
/// configurable via the reading settings sheet (font size, family, line
/// height, theme).
class ReaderTheme {
  ReaderTheme({
    required this.bodyStyle,
    required this.headingStyles,
    required this.accentColor,
    required this.paragraphSpacing,
    required this.codeStyle,
    required this.quoteColor,
    required this.blockBackground,
  });

  final TextStyle bodyStyle;
  final Map<int, TextStyle> headingStyles;
  final Color accentColor;
  final double paragraphSpacing;
  final TextStyle codeStyle;
  final Color quoteColor;
  final Color? blockBackground;

  factory ReaderTheme.defaults(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final onSurface = isDark
        ? const Color(0xFFF1F5F9)
        : const Color(0xFF0F172A);
    final bodyColor = onSurface;
    // Use GoogleFonts to ensure the font is actually loaded — using
    // fontFamily: 'NotoSerif' as a plain string doesn't work because
    // GoogleFonts registers fonts under hashed names.
    final body = GoogleFonts.notoSerif(
      fontSize: 18,
      height: 1.6,
      color: bodyColor,
    );
    final headingBase = GoogleFonts.notoSans(
      fontWeight: FontWeight.w700,
      color: onSurface,
    );
    return ReaderTheme(
      bodyStyle: body,
      headingStyles: {
        1: headingBase.copyWith(fontSize: 28, height: 1.3),
        2: headingBase.copyWith(fontSize: 24, height: 1.3),
        3: headingBase.copyWith(fontSize: 20, height: 1.3),
        4: headingBase.copyWith(fontSize: 18, height: 1.4),
        5: headingBase.copyWith(fontSize: 16, height: 1.4),
        6: headingBase.copyWith(fontSize: 14, height: 1.4),
      },
      accentColor: const Color(0xFF3B82F6),
      paragraphSpacing: 12,
      codeStyle: TextStyle(
        fontFamily: 'monospace',
        fontSize: 15,
        color: bodyColor,
        backgroundColor: isDark
            ? const Color(0xFF0F172A)
            : const Color(0xFFF1F5F9),
      ),
      quoteColor: const Color(0xFFE11D48),
      blockBackground: isDark
          ? const Color(0xFF1E293B)
          : const Color(0xFFF8FAFC),
    );
  }

  TextStyle headingStyle(int level) =>
      headingStyles[level.clamp(1, 6)] ?? headingStyles[6]!;
}

/// Turn a [List<Block>] AST (from [MarkdownParser]) into a column of native
/// Flutter widgets. Per `docs/plan-flutter-app.md` §4.4.
///
/// Hiệu năng: highlight TTS dùng [ValueListenable] — khi block đang đọc
/// đổi, chỉ block cũ + block mới rebuild (qua `child` của
/// `ValueListenableBuilder`), KHÔNG rebuild cả chương như kiểu truyền
/// `int? activeBlockIndex` trước đây (mỗi chunk TTS rebuild hàng trăm
/// RichText). Recognizer của link được dispose trong state; plain-text
/// của paragraph được cache theo AST node (tính 1 lần, không lặp lại
/// mỗi rebuild khi có long-press handler).
class MarkdownRenderer extends StatefulWidget {
  const MarkdownRenderer({
    super.key,
    required this.blocks,
    required this.theme,
    this.onLinkTap,
    this.activeBlock,
    this.baseBlockIndex = 0,
    this.onParagraphLongPress,
  });

  final List<Block> blocks;
  final ReaderTheme theme;
  final void Function(Uri url)? onLinkTap;

  /// Index of the block currently being read by TTS (GLOBAL index into
  /// the chapter's block list — subtract [baseBlockIndex] to map into
  /// [blocks]). The renderer wraps that block in a yellow-tinted
  /// background so the user can see where the audio is up to. Null when
  /// TTS is idle or the active chunk doesn't map to any block (e.g.
  /// horizontal rule). Listenable cho phép highlight đổi mà không rebuild
  /// cả cây widget.
  final ValueListenable<int?>? activeBlock;

  /// Global block index of [blocks].first — dùng khi render một page con
  /// của chương (page mode chia blocks thành nhiều trang).
  final int baseBlockIndex;

  /// Fired when a paragraph block is long-pressed. Receives the block's
  /// normalized plain text (used as the paragraph quote for bình luận
  /// đoạn — the server resolves the anchor from it).
  final void Function(String plainText)? onParagraphLongPress;

  @override
  State<MarkdownRenderer> createState() => _MarkdownRendererState();
}

class _MarkdownRendererState extends State<MarkdownRenderer> {
  /// TapGestureRecognizer tạo ra trong build — dispose khi build tiếp
  /// theo thay thế chúng hoặc khi widget unmount. Trước đây (stateless)
  /// recognizer mới được tạo mỗi rebuild và không bao giờ dispose.
  final List<TapGestureRecognizer> _recognizers = [];

  /// Cache plain-text per AST node identity — [normalizeParagraphPlain]
  /// chạy regex + join cho MỌI paragraph trong MỌI rebuild (khi có
  /// long-press handler); node identity ổn định giữa các rebuild.
  final Map<Object, String> _plainCache = {};

  @override
  void didUpdateWidget(covariant MarkdownRenderer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.blocks, widget.blocks)) {
      _plainCache.clear();
    }
  }

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Dispose recognizers của build trước — chúng không còn được
    // RenderParagraph mới tham chiếu sau khi build này hoàn tất.
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < widget.blocks.length; i++)
          _maybeHighlight(
            i,
            _renderBlock(widget.blocks[i], widget.theme, context),
          ),
      ],
    );
  }

  /// Wrap the block in a yellow-tinted background if its index matches
  /// the active TTS block. The tint is semi-transparent so the underlying
  /// text colour is still readable on both light and dark themes.
  ///
  /// Chỉ block có trạng thái highlight THAY ĐỔI mới rebuild — các block
  /// khác trả về đúng instance `child` cũ (Flutter bỏ qua khi so sánh).
  Widget _maybeHighlight(int index, Widget child) {
    final activeBlock = widget.activeBlock;
    if (activeBlock == null) return child;
    final globalIndex = widget.baseBlockIndex + index;
    return ValueListenableBuilder<int?>(
      valueListenable: activeBlock,
      builder: (context, active, child) {
        if (active == globalIndex) {
          return Container(
            decoration: BoxDecoration(
              color: const Color(0x44FFD54F), // ~27% amber-yellow tint
              borderRadius: BorderRadius.circular(4),
            ),
            child: child,
          );
        }
        return child!;
      },
      child: child,
    );
  }

  Widget _renderBlock(Block block, ReaderTheme t, BuildContext context) {
    return switch (block) {
      Paragraph(:final children) => _renderParagraph(children, t, context),
      Heading(:final level, :final children) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 8),
        child: RichText(
          text: TextSpan(
            style: t.headingStyle(level),
            children: [for (final i in children) _renderInline(i, t, context)],
          ),
        ),
      ),
      BlockQuote(:final children) => Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.only(left: 16, top: 4, bottom: 4),
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: t.quoteColor, width: 4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final b in children) _renderBlock(b, t, context),
          ],
        ),
      ),
      CodeBlock(:final code, :final language) => Container(
        margin: const EdgeInsets.symmetric(vertical: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: t.blockBackground,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (language != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  language,
                  style: t.bodyStyle.copyWith(
                    fontSize: 12,
                    color: t.bodyStyle.color?.withValues(alpha: 0.5),
                  ),
                ),
              ),
            SelectableText(code, style: t.codeStyle),
          ],
        ),
      ),
      HorizontalRule() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text('* * *', style: t.bodyStyle.copyWith(letterSpacing: 8)),
        ),
      ),
      BulletList(:final items) => _renderList(
        items,
        t,
        context,
        ordered: false,
        start: 1,
      ),
      OrderedList(:final start, :final items) => _renderList(
        items,
        t,
        context,
        ordered: true,
        start: start,
      ),
      ImageBlock(:final url, :final alt, :final caption) => _renderImage(
        url,
        alt,
        caption,
        t,
        context,
      ),
    };
  }

  /// Renders a paragraph block. When [onParagraphLongPress] is set and the
  /// paragraph has visible text, wraps it in a long-press detector that
  /// reports the normalized plain text (bình luận đoạn quote).
  Widget _renderParagraph(List<Inline> children, ReaderTheme t, BuildContext context) {
    final text = Padding(
      padding: EdgeInsets.symmetric(vertical: t.paragraphSpacing / 2),
      child: RichText(
        text: TextSpan(
          style: t.bodyStyle,
          children: [for (final i in children) _renderInline(i, t, context)],
        ),
      ),
    );
    final callback = widget.onParagraphLongPress;
    if (callback == null) return text;
    // Cache theo identity của AST node — node ổn định giữa các rebuild
    // (parse 1 lần/chương), không tính lại regex+join cho mọi paragraph.
    final plain = _plainCache.putIfAbsent(
      children,
      () => normalizeParagraphPlain(children),
    );
    if (plain.isEmpty) return text;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPress: () => callback(plain),
      child: text,
    );
  }

  Widget _renderList(
    List<List<Block>> items,
    ReaderTheme t,
    BuildContext context, {
    required bool ordered,
    required int start,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 24,
                    child: Text(
                      ordered ? '${start + i}.' : '•',
                      style: t.bodyStyle,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final b in items[i])
                          _renderBlock(b, t, context),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _renderImage(
    String url,
    String? alt,
    String? caption,
    ReaderTheme t,
    BuildContext context,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CachedNetworkImage(
              imageUrl: url,
              cacheManager: AppImageCache.instance,
              fit: BoxFit.fitWidth,
              memCacheWidth: 1200,
              maxWidthDiskCache: 1200,
              errorWidget: (_, __, ___) => Container(
                height: 120,
                color: t.blockBackground,
                alignment: Alignment.center,
                child: Text(alt ?? '[image]', style: t.bodyStyle),
              ),
            ),
          ),
          if (caption != null || alt != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                caption ?? alt!,
                textAlign: TextAlign.center,
                style: t.bodyStyle.copyWith(
                  fontSize: 13,
                  fontStyle: FontStyle.italic,
                  color: t.bodyStyle.color?.withValues(alpha: 0.7),
                ),
              ),
            ),
        ],
      ),
    );
  }

  InlineSpan _renderInline(Inline inline, ReaderTheme t, BuildContext context) {
    return switch (inline) {
      TextRun(:final text) => TextSpan(text: text),
      EmphasisRun(:final children) => TextSpan(
        style: const TextStyle(fontStyle: FontStyle.italic),
        children: [for (final i in children) _renderInline(i, t, context)],
      ),
      StrongRun(:final children) => TextSpan(
        style: const TextStyle(fontWeight: FontWeight.bold),
        children: [for (final i in children) _renderInline(i, t, context)],
      ),
      StrikethroughRun(:final children) => TextSpan(
        style: const TextStyle(decoration: TextDecoration.lineThrough),
        children: [for (final i in children) _renderInline(i, t, context)],
      ),
      LinkRun(:final url, :final children) => TextSpan(
        style: TextStyle(
          color: t.accentColor,
          decoration: TextDecoration.underline,
        ),
        recognizer: _createLinkRecognizer(url),
        children: [for (final i in children) _renderInline(i, t, context)],
      ),
      CodeRun(:final code) => WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: t.codeStyle.backgroundColor,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(code, style: t.codeStyle),
        ),
      ),
      LineBreak(:final hard) => TextSpan(text: hard ? '\n' : ' '),
    };
  }

  /// Tạo recognizer cho một link và theo dõi để dispose ở build sau /
  /// unmount (xem [_recognizers]).
  TapGestureRecognizer _createLinkRecognizer(String url) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () {
        final uri = Uri.tryParse(url);
        if (uri != null) {
          final cb = widget.onLinkTap;
          if (cb != null) cb(uri);
        }
      };
    _recognizers.add(recognizer);
    return recognizer;
  }
}
