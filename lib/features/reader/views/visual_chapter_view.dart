import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../core/markdown/markdown.dart';
import '../../../core/network/app_image_cache.dart';
import 'text_chapter_view.dart';

/// `content_type=visual` (Bách khoa trực quan) chapter view.
///
/// The backend serves visual chapters exactly like text chapters (same
/// markdown pipeline) plus an optional story banner (`thumbnail_url`).
/// We render the banner (when present) above the shared text reader so
/// TTS, page-flip, scrolling and highlight behaviour are identical to
/// regular chapters.
class VisualChapterView extends StatelessWidget {
  const VisualChapterView({
    super.key,
    required this.markdown,
    required this.theme,
    required this.chapterId,
    this.thumbnailUrl,
    this.scrollController,
    this.pageController,
    this.isPageMode = false,
    this.onParagraphLongPress,
    this.footer,
  });

  final String markdown;
  final ReaderTheme theme;
  final String chapterId;
  final String? thumbnailUrl;
  final ScrollController? scrollController;
  final PageController? pageController;
  final bool isPageMode;
  final void Function(String plainText)? onParagraphLongPress;

  /// Block cuối nội dung (chỉ dùng cho chế độ cuộn dọc) — truyền thẳng
  /// xuống TextChapterView bên trong.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (thumbnailUrl != null && thumbnailUrl!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: CachedNetworkImage(
                  imageUrl: thumbnailUrl!,
                  cacheManager: AppImageCache.instance,
                  fit: BoxFit.cover,
                  memCacheWidth: 1200,
                  errorWidget: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        Expanded(
          child: TextChapterView(
            markdown: markdown,
            theme: theme,
            chapterId: chapterId,
            scrollController: scrollController,
            pageController: pageController,
            isPageMode: isPageMode,
            onParagraphLongPress: onParagraphLongPress,
            footer: footer,
          ),
        ),
      ],
    );
  }
}