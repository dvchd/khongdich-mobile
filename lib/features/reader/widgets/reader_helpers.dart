import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../core/markdown/markdown.dart';
import '../../../models/chapter_content.dart';
import '../reader_settings_provider.dart';
import '../views/chat_chapter_view.dart';
import '../views/manga_chapter_view.dart';
import '../views/text_chapter_view.dart';
import '../views/video_chapter_view.dart';

// ─── Theme resolution ──────────────────────────────────────────────

/// Resolve a [ReaderTheme] from user settings + the current [brightness].
///
/// Shared between the online reader (`ChapterReaderScreen`) and the
/// offline reader (`OfflineChapterReader`) so both render text, code
/// blocks, and headings identically. The only inputs are the user's
/// reader settings and the screen brightness — no other state.
ReaderTheme resolveReaderTheme(ReaderSettings s, Brightness brightness) {
  final isSepia = s.theme == ReaderThemeMode.sepia;
  final isLight = brightness == Brightness.light && !isSepia;
  final textColor = isSepia
      ? const Color(0xFF3A2E1F)
      : (isLight ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9));
  final blockBg = isSepia
      ? const Color(0xFFEDE0C8)
      : (isLight ? const Color(0xFFF1F5F9) : const Color(0xFF1E293B));
  final baseFont = switch (s.fontFamily) {
    'NotoSans' => GoogleFonts.notoSans(),
    'monospace' => GoogleFonts.robotoMono(),
    _ => GoogleFonts.notoSerif(),
  };
  return ReaderTheme(
    bodyStyle: baseFont.copyWith(
      fontSize: s.fontSize,
      height: s.lineHeight,
      color: textColor,
    ),
    headingStyles: {
      for (final entry in [1, 2, 3, 4, 5, 6])
        entry: GoogleFonts.notoSans(
          fontWeight: FontWeight.w700,
          fontSize: switch (entry) {
            1 => 28.0,
            2 => 24.0,
            3 => 20.0,
            4 => 18.0,
            5 => 16.0,
            _ => 14.0,
          } * (s.fontSize / 18),
          height: 1.3,
          color: textColor,
        ),
    },
    accentColor: const Color(0xFF3B82F6),
    paragraphSpacing: 6,
    codeStyle: GoogleFonts.robotoMono(
      fontSize: 15,
      color: textColor,
      backgroundColor: blockBg,
    ),
    quoteColor: const Color(0xFFE11D48),
    blockBackground: blockBg,
  );
}

/// Resolve the reader background colour from the theme mode + brightness.
///
/// Used by both online and offline readers so the empty space behind
/// the chapter content matches the chosen theme (light / dark / sepia).
Color readerBgColor(ReaderThemeMode theme, Brightness brightness) {
  final isSepia = theme == ReaderThemeMode.sepia;
  final isLight = brightness == Brightness.light && !isSepia;
  if (isSepia) return const Color(0xFFF5E6C8);
  if (isLight) return const Color(0xFFFAFAFA);
  return const Color(0xFF0F172A);
}

/// Resolve the current [Brightness] from reader settings + platform.
Brightness readerBrightness(ReaderSettings settings, BuildContext context) {
  return switch (settings.theme) {
    ReaderThemeMode.light => Brightness.light,
    ReaderThemeMode.sepia => Brightness.light,
    ReaderThemeMode.dark => Brightness.dark,
    ReaderThemeMode.system => MediaQuery.of(context).platformBrightness,
  };
}

// ─── Content rendering ─────────────────────────────────────────────

/// Build the right chapter-content widget for a [ChapterContent].
///
/// Switches on the chapter's runtime type and dispatches to the
/// matching view (`TextChapterView` / `MangaChapterView` /
/// `ChatChapterView` / `VideoChapterView`). Used by both the online
/// and offline readers so the rendering pipeline is identical — the
/// only thing that differs between online/offline is where the
/// `ChapterContent` came from (API vs local Drift DB).
///
/// For manga chapters, [mangaLocalImagePaths] lets the offline reader
/// pass the `imageUrl → localFilePath` mapping so the view can render
/// images from disk instead of hitting the network.
Widget buildChapterContent(
  ChapterContent chapter,
  ReaderTheme theme,
  bool isPageMode, {
  ScrollController? scrollController,
  PageController? pageController,
  VoidCallback? onNext,
  VoidCallback? onPrev,
  Map<String, String> mangaLocalImagePaths = const {},
}) {
  return switch (chapter) {
    TextChapterContent(:final contentMarkdown) => TextChapterView(
        markdown: contentMarkdown,
        theme: theme,
        scrollController: scrollController,
        pageController: isPageMode ? pageController : null,
        isPageMode: isPageMode,
      ),
    MangaChapterContent(:final images) => MangaChapterView(
        images: [for (final p in images) p.url],
        scrollController: scrollController,
        localImagePaths: mangaLocalImagePaths,
      ),
    ChatChapterContent(:final participants, :final messages) =>
      ChatChapterView(
        participants: participants,
        messages: messages,
        scrollController: scrollController,
        onNext: onNext,
        onPrev: onPrev,
      ),
    VideoChapterContent(:final video, :final captionMarkdown) =>
      VideoChapterView(
        videoId: video.videoId,
        captionMarkdown: captionMarkdown,
        readerTheme: theme,
        scrollController: scrollController,
      ),
  };
}

// ─── Navigation wrappers ───────────────────────────────────────────

/// Wraps content with horizontal swipe detection for the vertical
/// scroll reader mode.
///
/// Swipe right → previous chapter, swipe left → next chapter. Vertical
/// scrolling passes through to the child widget. Used by both online
/// and offline readers.
class HorizontalSwipeWrapper extends StatelessWidget {
  const HorizontalSwipeWrapper({
    super.key,
    required this.child,
    this.onSwipeLeft,
    this.onSwipeRight,
  });

  final Widget child;
  final VoidCallback? onSwipeLeft;
  final VoidCallback? onSwipeRight;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity < -300 && onSwipeLeft != null) {
          onSwipeLeft!();
        } else if (velocity > 300 && onSwipeRight != null) {
          onSwipeRight!();
        }
      },
      behavior: HitTestBehavior.translucent,
      child: child,
    );
  }
}

/// Wrapper for page-flip (horizontal) mode. Intercepts horizontal drag
/// gestures that go BEYOND the PageView's scroll boundaries — i.e.
/// swiping left on the last page or right on the first page. Only
/// those overscrolls trigger chapter navigation. Normal page-turn
/// swipes are handled by the PageView inside.
///
/// Used by both online and offline readers.
///
/// Implementation: we use `NotificationListener<ScrollNotification>` to
/// detect when the PageView reaches its boundary AND the user keeps
/// swiping. The OverscrollNotification fires at that point.
class PageModeWrapper extends StatefulWidget {
  const PageModeWrapper({super.key, this.onNext, this.onPrev, required this.child});
  final VoidCallback? onNext;
  final VoidCallback? onPrev;
  final Widget child;

  @override
  State<PageModeWrapper> createState() => _PageModeWrapperState();
}

class _PageModeWrapperState extends State<PageModeWrapper> {
  double _accumulatedOverscroll = 0;
  static const _threshold = 60.0; // px of overscroll to trigger chapter nav

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is OverscrollNotification &&
            notification.metrics.axis == Axis.horizontal) {
          _accumulatedOverscroll += notification.overscroll;
          if (_accumulatedOverscroll.abs() > _threshold) {
            // Flutter's OverscrollNotification.overscroll sign convention:
            //   POSITIVE = user is scrolling FORWARD past the max extent
            //     (in a LTR horizontal PageView, this means swiping LEFT
            //     on the LAST page → user wants NEXT chapter)
            //   NEGATIVE = user is scrolling BACKWARD past the min extent
            //     (swiping RIGHT on the FIRST page → user wants PREV chapter)
            if (_accumulatedOverscroll > 0 && widget.onNext != null) {
              widget.onNext!();
            } else if (_accumulatedOverscroll < 0 && widget.onPrev != null) {
              widget.onPrev!();
            }
            _accumulatedOverscroll = 0;
          }
        } else if (notification is ScrollEndNotification) {
          _accumulatedOverscroll = 0;
        }
        return false;
      },
      child: widget.child,
    );
  }
}

// ─── Tap zones ─────────────────────────────────────────────────────

/// Which third of the screen was tapped.
enum ReaderTapZone { left, center, right }

/// Detects taps on left (30%), center (40%), and right (30%) zones.
///
/// Used by both online and offline readers. The center zone opens
/// the reader settings sheet; the left/right zones navigate to the
/// previous/next chapter (or page, in page-flip mode).
class ReaderTapZones extends StatelessWidget {
  const ReaderTapZones({super.key, required this.onTap});
  final void Function(ReaderTapZone) onTap;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 3,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => onTap(ReaderTapZone.left),
          ),
        ),
        Expanded(
          flex: 4,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => onTap(ReaderTapZone.center),
          ),
        ),
        Expanded(
          flex: 3,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => onTap(ReaderTapZone.right),
          ),
        ),
      ],
    );
  }
}
