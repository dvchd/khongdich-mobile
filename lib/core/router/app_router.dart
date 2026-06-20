import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/auth_screen.dart';
import '../../features/bookshelf/bookshelf_screen.dart';
import '../../features/downloads/downloads_screen.dart';
import '../../features/downloads/offline_library_screen.dart';
import '../../features/home/home_screen.dart';
import '../../features/notifications/notifications_screen.dart';
import '../../features/profile/profile_screen.dart';
import '../../features/reader/chapter_reader_screen.dart';
import '../../features/reader/views/chat_chapter_view.dart';
import '../../features/search/search_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/story/story_detail_screen.dart';
import '../../core/database/app_database.dart';
import '../../core/markdown/markdown.dart';
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
          return OfflineChapterReader(chapterId: state.pathParameters['chapterId']!);
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
/// using the same chapter reader UI. No network required.
class OfflineChapterReader extends ConsumerWidget {
  const OfflineChapterReader({super.key, required this.chapterId});
  final String chapterId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.watch(appDatabaseProvider);
    return FutureBuilder<DownloadedChapter?>(
      future: (db.select(db.downloadedChapters)
            ..where((t) => t.chapterId.equals(chapterId)))
          .getSingleOrNull(),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final row = snapshot.data;
        if (row == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Chương không có trong bộ nhớ.')),
          );
        }
        final json = jsonDecode(row.contentRaw) as Map<String, dynamic>;
        // Merge the stored common fields + content_type-specific fields.
        final fullJson = <String, dynamic>{
          ...json,
          'content_markdown': json['content_markdown'] ?? '',
          'content_type': row.contentType,
          'story_title': row.storyTitle,
          'story_slug': row.storySlug,
          'chapter_number': row.chapterNumber,
          'title': row.chapterTitle,
        };
        final chapter = ChapterContent.fromJson(fullJson);
        final isDark = Theme.of(context).brightness == Brightness.dark;
        final bgColor = isDark ? const Color(0xFF0F172A) : const Color(0xFFFAFAFA);
        return Scaffold(
          backgroundColor: bgColor,
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () {
                if (context.canPop()) {
                  context.pop();
                } else {
                  context.go('/offline-library');
                }
              },
            ),
            title: Text(
              'Ch.${chapter.chapterNumber}: ${chapter.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          body: _OfflineContent(chapter: chapter),
        );
      },
    );
  }
}

class _OfflineContent extends StatelessWidget {
  const _OfflineContent({required this.chapter});
  final ChapterContent chapter;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final readerTheme = ReaderTheme.defaults(isDark ? Brightness.dark : Brightness.light);
    // Must wrap in ColoredBox with matching background so text is visible
    // regardless of app theme. Without this, dark text on dark scaffold
    // = invisible.
    final bgColor = isDark ? const Color(0xFF0F172A) : const Color(0xFFFAFAFA);
    final textColor = isDark ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A);
    // Override the reader theme's body color to match background.
    final fixedTheme = ReaderTheme(
      bodyStyle: readerTheme.bodyStyle.copyWith(color: textColor),
      headingStyles: {
        for (final e in readerTheme.headingStyles.entries)
          e.key: e.value.copyWith(color: textColor),
      },
      accentColor: readerTheme.accentColor,
      paragraphSpacing: readerTheme.paragraphSpacing,
      codeStyle: readerTheme.codeStyle.copyWith(color: textColor),
      quoteColor: readerTheme.quoteColor,
      blockBackground: readerTheme.blockBackground,
    );

    return ColoredBox(
      color: bgColor,
      child: switch (chapter) {
        TextChapterContent(:final contentMarkdown) => SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: MarkdownRenderer(
              blocks: MarkdownParser().parse(contentMarkdown),
              theme: fixedTheme,
            ),
          ),
        MangaChapterContent(:final images) => ListView.builder(
            itemCount: images.length,
            itemBuilder: (_, i) => ColoredBox(
              color: bgColor,
              child: CachedNetworkImage(
                imageUrl: images[i].url,
                fit: BoxFit.fitWidth,
                errorWidget: (_, _, _) => SizedBox(
                  height: 200,
                  child: Center(
                    child: Icon(Icons.broken_image, size: 36, color: textColor.withValues(alpha: 0.4)),
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
                  Icon(Icons.videocam, size: 48, color: textColor.withValues(alpha: 0.4)),
                  const SizedBox(height: 12),
                  Text('Video: ${video.videoId}', style: TextStyle(color: textColor)),
                  const SizedBox(height: 8),
                  Text('Cần kết nối mạng để xem video.',
                      style: TextStyle(fontSize: 13, color: textColor.withValues(alpha: 0.5))),
                ],
              ),
            ),
          ),
      },
    );
  }
}
