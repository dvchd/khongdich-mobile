import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
import '../../features/reader/widgets/chapter_list_sheet.dart';
import '../../features/reader/widgets/reader_body.dart';
import '../../features/reader/widgets/reader_settings_sheet.dart';
import '../../features/search/search_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/story/story_detail_screen.dart';
import '../../features/tts/tts_audio_handler.dart';
import '../../features/tts/tts_control_panel.dart';
import '../../core/database/app_database.dart';
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
/// using the **shared** [ReaderBody] widget — same UI as the online
/// reader, only the data source differs.
///
/// Plan §5.4 — the only offline-specific behaviour is:
///   - Loading the chapter from `downloaded_chapters` (Drift).
///   - Resolving prev/next chapter from the local `siblings` list
///     (chapters of the same story that are also downloaded).
///   - Marking the chapter as read in the local Drift DB when the
///     user scrolls near the end (no API call).
///   - Building the chapter-list sheet from the local siblings.
///
/// Everything else (reader chrome, theme resolution, content
/// rendering, page-flip / swipe wrappers, tap zones, TTS) is handled
/// by [ReaderBody] and its helpers in `reader_helpers.dart`.
class OfflineChapterReader extends ConsumerStatefulWidget {
  const OfflineChapterReader({super.key, required this.chapterId});
  final String chapterId;

  @override
  ConsumerState<OfflineChapterReader> createState() => _OfflineChapterReaderState();
}

class _OfflineChapterReaderState extends ConsumerState<OfflineChapterReader> {
  ChapterContent? _chapter;
  List<DownloadedChapter> _siblings = [];
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final db = ref.read(appDatabaseProvider);
      final row = await (db.select(db.downloadedChapters)
            ..where((t) => t.chapterId.equals(widget.chapterId)))
          .getSingleOrNull();
      if (row == null) {
        if (mounted) {
          setState(() {
            _loading = false;
            _loadError = 'Chương không có trong bộ nhớ.';
          });
        }
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
          _chapter = ChapterContent.fromJson(fullJson);
          _siblings = all;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = 'Lỗi khi tải chương: $e';
        });
      }
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
      builder: (_) => ChapterListSheet(
        entries: [
          for (final s in _siblings)
            ChapterListEntry(number: s.chapterNumber, title: s.chapterTitle),
        ],
        currentChapter: ch.chapterNumber,
        onSelect: (number) {
          // Find the sibling with this chapter number and navigate
          // to its offline chapter route.
          final target = _siblings
              .where((s) => s.chapterNumber == number)
              .firstOrNull;
          if (target != null) {
            context.go('/chapter-offline/${target.chapterId}');
          }
        },
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

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_chapter == null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(_loadError ?? 'Chương không có trong bộ nhớ.')),
      );
    }
    final chapter = _chapter!;
    final settings = ref.watch(readerSettingsProvider);
    final i = _currentIndex;
    final hasPrev = i > 0;
    final hasNext = i >= 0 && i < _siblings.length - 1;

    return Scaffold(
      body: ReaderBody(
        chapter: chapter,
        settings: settings,
        onPrev: hasPrev ? _goPrev : null,
        onNext: hasNext ? _goNext : null,
        onOpenSettings: _openSettings,
        onOpenChapterList: _openChapterList,
        onToggleTts:
            chapter is TextChapterContent ? () => _toggleTts(chapter) : null,
        onChapterNearEnd: () async {
          // Mark the chapter as read in the local Drift DB. No API
          // call — this is offline-only.
          try {
            final db = ref.read(appDatabaseProvider);
            await db.markChapterRead(widget.chapterId);
          } catch (_) {/* best-effort */}
        },
      ),
    );
  }
}
