import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../features/auth/auth_screen.dart';
import '../../features/bookshelf/bookshelf_screen.dart';
import '../../features/downloads/downloads_screen.dart';
import '../../features/downloads/offline_library_screen.dart';
import '../../features/downloads/offline_story_detail_screen.dart';
import '../../features/home/home_screen.dart';
import '../../features/notifications/notifications_screen.dart';
import '../../features/profile/profile_screen.dart';
import '../../features/reader/chapter_reader_screen.dart';
import '../../features/reader/reader_settings_provider.dart';
import '../../features/reader/views/chat_chapter_view.dart';
import '../../features/reader/views/text_chapter_view.dart';
import '../../features/reader/widgets/reader_bar.dart';
import '../../features/reader/widgets/reader_settings_sheet.dart';
import '../../features/search/search_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/story/story_detail_screen.dart';
import '../../features/tts/tts_audio_handler.dart';
import '../../features/tts/tts_control_panel.dart';
import '../../features/tts/tts_mini_player.dart';
import '../../core/database/app_database.dart';
import '../../core/markdown/markdown.dart' show ReaderTheme;
import '../../core/theme/app_theme.dart';
import '../../models/chapter_content.dart';
import '../shell/main_shell.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/home',
    routes: [
      ShellRoute(
        builder: (context, state, child) => MainShell(child: child),
        routes: [
          GoRoute(
            path: '/home',
            name: 'home',
            builder: (context, state) => const HomeScreen(),
          ),
          GoRoute(
            path: '/search',
            name: 'search',
            builder: (context, state) => const SearchScreen(),
          ),
          GoRoute(
            path: '/bookshelf',
            name: 'bookshelf',
            builder: (context, state) => const BookshelfScreen(),
          ),
          GoRoute(
            path: '/profile',
            name: 'profile',
            builder: (context, state) => const ProfileScreen(),
          ),
        ],
      ),
      GoRoute(
        path: '/story/:slug',
        name: 'story_detail',
        builder: (context, state) =>
            StoryDetailScreen(storySlug: state.pathParameters['slug']!),
      ),
      GoRoute(
        path: '/chapter/:ref',
        name: 'chapter_reader',
        builder: (context, state) {
          final raw = state.pathParameters['ref']!;
          final parts = raw.split(':');
          if (parts.length != 2) {
            return Scaffold(
              body: Center(child: Text('Route không hợp lệ: $raw')),
            );
          }
          final storyId = parts[0];
          final chapterNumber = int.tryParse(parts[1]) ?? 1;
          return ChapterReaderScreen(
            key: ValueKey('chapter-$storyId-$chapterNumber'),
            storyId: storyId,
            chapterNumber: chapterNumber,
          );
        },
      ),
      // Offline chapter reader — loads from local Drift DB, no network.
      GoRoute(
        path: '/chapter-offline/:chapterId',
        name: 'chapter_offline',
        builder: (context, state) {
          final chapterId = state.pathParameters['chapterId']!;
          return OfflineChapterReader(
            key: ValueKey('offline-chapter-$chapterId'),
            chapterId: chapterId,
          );
        },
      ),
      // Offline story detail — shows cover, author, synopsis, chapter list.
      GoRoute(
        path: '/offline-story/:storyId',
        name: 'offline_story_detail',
        builder: (context, state) {
          return OfflineStoryDetailScreen(storyId: state.pathParameters['storyId']!);
        },
      ),
      GoRoute(
        path: '/notifications',
        name: 'notifications',
        builder: (context, state) => const NotificationsScreen(),
      ),
      GoRoute(
        path: '/downloads',
        name: 'downloads',
        builder: (context, state) => const DownloadsScreen(),
      ),
      GoRoute(
        path: '/offline-library',
        name: 'offline_library',
        builder: (context, state) => const OfflineLibraryScreen(),
      ),
      GoRoute(
        path: '/settings',
        name: 'settings',
        builder: (context, state) => const SettingsScreen(),
      ),
      GoRoute(
        path: '/auth',
        name: 'auth',
        builder: (context, state) => const AuthScreen(),
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(child: Text('Route not found: ${state.uri}')),
    ),
  );
});

/// Reads a downloaded chapter from the local Drift DB and displays it
/// using the same reader UI (ReaderBar, TTS, page modes). No network required.
class OfflineChapterReader extends ConsumerStatefulWidget {
  const OfflineChapterReader({super.key, required this.chapterId});
  final String chapterId;

  @override
  ConsumerState<OfflineChapterReader> createState() => _OfflineChapterReaderState();
}

class _OfflineChapterReaderState extends ConsumerState<OfflineChapterReader> {
  DownloadedChapter? _row;
  ChapterContent? _chapter;
  List<DownloadedChapter> _siblings = [];
  bool _loading = true;
  // Chrome is always visible — tap-center opens the settings sheet
  // instead of toggling the AppBar.
  final bool _chromeVisible = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(appDatabaseProvider);
    final row = await (db.select(db.downloadedChapters)
          ..where((t) => t.chapterId.equals(widget.chapterId)))
        .getSingleOrNull();
    if (row == null || !mounted) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    // Find siblings (same story, also downloaded), sorted by chapterNumber.
    final all = await (db.select(db.downloadedChapters)
          ..where((t) => t.storyId.equals(row.storyId))
          ..orderBy([(t) => OrderingTerm.asc(t.chapterNumber)]))
        .get();
    final json = jsonDecode(row.contentRaw) as Map<String, dynamic>;
    final fullJson = <String, dynamic>{
      ...json,
      'content_markdown': json['content_markdown'] ?? '',
      'content_type': row.contentType,
      'story_title': row.storyTitle,
      'story_slug': row.storySlug,
      'chapter_number': row.chapterNumber,
      'title': row.chapterTitle,
    };
    if (mounted) {
      setState(() {
        _row = row;
        _chapter = ChapterContent.fromJson(fullJson);
        _siblings = all;
        _loading = false;
      });
    }
  }

  int get _currentIndex =>
      _siblings.indexWhere((s) => s.chapterId == widget.chapterId);

  void _goPrev() {
    final i = _currentIndex;
    if (i > 0) {
      context.go('/chapter-offline/${_siblings[i - 1].chapterId}');
    }
  }

  void _goNext() {
    final i = _currentIndex;
    if (i >= 0 && i < _siblings.length - 1) {
      context.go('/chapter-offline/${_siblings[i + 1].chapterId}');
    }
  }

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const ReaderSettingsSheet(),
    );
  }

  void _openChapterList() {
    final ch = _chapter;
    if (ch == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => _OfflineChapterListSheet(
        siblings: _siblings,
        currentChapterId: widget.chapterId,
      ),
    );
  }

  void _toggleTts(TextChapterContent chapter) async {
    try {
      final handler = await ref.read(ttsHandlerProvider.future);
      final state = handler.playbackState.value;
      if (!state.playing || state.processingState == AudioProcessingState.idle) {
        await handler.loadChapter(
          chapterId: chapter.id,
          storyId: chapter.storyId,
          storyTitle: chapter.storyTitle,
          chapterTitle: chapter.title,
          chapterNumber: chapter.chapterNumber,
          contentMarkdown: chapter.contentMarkdown,
        );
        await handler.play();
      }
      if (mounted) {
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          builder: (_) => const TtsControlPanel(),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('TTS lỗi: $e')));
      }
    }
  }

  void _onTapZone(ReaderTapZone zone) {
    switch (zone) {
      case ReaderTapZone.left:
        _goPrev();
      case ReaderTapZone.right:
        _goNext();
      case ReaderTapZone.center:
        // Tap center → open the reader settings sheet (matches the
        // online reader and popular apps like NovelFever).
        _openSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_row == null || _chapter == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Chương không có trong bộ nhớ.')),
      );
    }
    final chapter = _chapter!;
    final settings = ref.watch(readerSettingsProvider);

    final brightness = switch (settings.theme) {
      ReaderThemeMode.light => Brightness.light,
      ReaderThemeMode.sepia => Brightness.light,
      ReaderThemeMode.dark => Brightness.dark,
      ReaderThemeMode.system => MediaQuery.of(context).platformBrightness,
    };
    final readerTheme = _resolveReaderTheme(settings, brightness);
    final isPageMode = settings.scrollMode == ReaderScrollMode.horizontal;
    final isSepia = settings.theme == ReaderThemeMode.sepia;
    final isReaderLight = brightness == Brightness.light && !isSepia;
    final readerBgColor = isSepia
        ? const Color(0xFFF5E6C8)
        : (isReaderLight ? const Color(0xFFFAFAFA) : const Color(0xFF0F172A));

    final content = _buildContent(chapter, readerTheme, isPageMode);
    final i = _currentIndex;
    final hasPrev = i > 0;
    final hasNext = i >= 0 && i < _siblings.length - 1;

    final body = isPageMode
        ? _OfflinePageModeWrapper(
            onNext: hasNext ? _goNext : null,
            onPrev: hasPrev ? _goPrev : null,
            child: content,
          )
        : _OfflineSwipeWrapper(
            onSwipeLeft: hasNext ? _goNext : null,
            onSwipeRight: hasPrev ? _goPrev : null,
            child: content,
          );

    return ReaderBar(
      chapter: chapter,
      onPrev: hasPrev ? _goPrev : null,
      onNext: hasNext ? _goNext : null,
      onOpenSettings: _openSettings,
      onOpenChapterList: _openChapterList,
      onToggleTts: chapter is TextChapterContent
          ? () => _toggleTts(chapter)
          : null,
      chromeVisible: _chromeVisible,
      child: ColoredBox(
        color: readerBgColor,
        child: Stack(
          children: [
            body,
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: TtsMiniPlayer(chapter: chapter),
            ),
            // Tap zones for edge navigation
            // Skip for chat — it handles its own tap to reveal next message.
            if (chapter is! ChatChapterContent)
              Positioned.fill(
                child: ReaderTapZones(onTap: _onTapZone),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(
      ChapterContent chapter, ReaderTheme theme, bool isPageMode) {
    return switch (chapter) {
      TextChapterContent(:final contentMarkdown) => TextChapterView(
          markdown: contentMarkdown,
          theme: theme,
          isPageMode: isPageMode,
        ),
      MangaChapterContent(:final images) => ListView.builder(
          itemCount: images.length,
          itemBuilder: (_, i) => ColoredBox(
            color: Colors.transparent,
            child: CachedNetworkImage(
              imageUrl: images[i].url,
              fit: BoxFit.fitWidth,
              errorWidget: (_, _, _) => SizedBox(
                height: 200,
                child: Center(
                  child: Icon(Icons.broken_image,
                      size: 36,
                      color: theme.bodyStyle.color?.withValues(alpha: 0.4)),
                ),
              ),
            ),
          ),
        ),
      ChatChapterContent(:final participants, :final messages) =>
        ChatChapterView(
          participants: participants,
          messages: messages,
        ),
      VideoChapterContent(:final video) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.videocam,
                    size: 48,
                    color: theme.bodyStyle.color?.withValues(alpha: 0.4)),
                const SizedBox(height: 12),
                Text('Video: ${video.videoId}',
                    style: TextStyle(color: theme.bodyStyle.color)),
                const SizedBox(height: 8),
                Text('Cần kết nối mạng để xem video.',
                    style: TextStyle(
                        fontSize: 13,
                        color: theme.bodyStyle.color?.withValues(alpha: 0.5))),
              ],
            ),
          ),
        ),
    };
  }

  ReaderTheme _resolveReaderTheme(ReaderSettings s, Brightness brightness) {
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
      paragraphSpacing: 12,
      codeStyle: GoogleFonts.robotoMono(
        fontSize: 15,
        color: textColor,
        backgroundColor: blockBg,
      ),
      quoteColor: const Color(0xFFE11D48),
      blockBackground: blockBg,
    );
  }
}

/// Horizontal swipe for vertical scroll mode (offline).
class _OfflineSwipeWrapper extends StatelessWidget {
  const _OfflineSwipeWrapper({
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

/// Page-flip overscroll wrapper (offline).
class _OfflinePageModeWrapper extends StatefulWidget {
  const _OfflinePageModeWrapper({this.onNext, this.onPrev, required this.child});
  final VoidCallback? onNext;
  final VoidCallback? onPrev;
  final Widget child;

  @override
  State<_OfflinePageModeWrapper> createState() => _OfflinePageModeWrapperState();
}

class _OfflinePageModeWrapperState extends State<_OfflinePageModeWrapper> {
  double _accumulatedOverscroll = 0;
  static const _threshold = 60.0;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is OverscrollNotification &&
            notification.metrics.axis == Axis.horizontal) {
          _accumulatedOverscroll += notification.overscroll;
          if (_accumulatedOverscroll.abs() > _threshold) {
            // Flutter's OverscrollNotification.overscroll sign:
            //   POSITIVE = scrolling FORWARD past max extent
            //     = swiping LEFT on the LAST page → NEXT chapter
            //   NEGATIVE = scrolling BACKWARD past min extent
            //     = swiping RIGHT on the FIRST page → PREV chapter
            //
            // Must match the online _PageModeWrapper convention.
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

/// Offline chapter list bottom sheet.
class _OfflineChapterListSheet extends StatelessWidget {
  const _OfflineChapterListSheet({
    required this.siblings,
    required this.currentChapterId,
  });
  final List<DownloadedChapter> siblings;
  final String currentChapterId;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Text('Danh sách chương',
                        style: Theme.of(context).textTheme.titleMedium),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: siblings.length,
                  itemBuilder: (_, i) {
                    final s = siblings[i];
                    final isCurrent = s.chapterId == currentChapterId;
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: isCurrent
                            ? AppTheme.primary
                            : Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                        child: Text(
                          '${s.chapterNumber}',
                          style: TextStyle(
                            color: isCurrent
                                ? Colors.white
                                : Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ),
                      title: Text(
                        s.chapterTitle.isEmpty
                            ? 'Chương ${s.chapterNumber}'
                            : s.chapterTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: isCurrent
                            ? TextStyle(
                                fontWeight: FontWeight.bold,
                                color: AppTheme.primary,
                              )
                            : null,
                      ),
                      trailing: isCurrent
                          ? const Icon(Icons.check_circle,
                              color: AppTheme.primary, size: 20)
                          : null,
                      onTap: () {
                        context.go('/chapter-offline/${s.chapterId}');
                        Navigator.of(context).pop();
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
