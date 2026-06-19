import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/auth_screen.dart';
import '../../features/bookshelf/bookshelf_screen.dart';
import '../../features/home/home_screen.dart';
import '../../features/profile/profile_screen.dart';
import '../../features/reader/chapter_reader_screen.dart';
import '../../features/search/search_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/story/story_detail_screen.dart';
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
        path: '/story/:id',
        name: 'story_detail',
        builder: (context, state) =>
            StoryDetailScreen(storyId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/chapter/:chapterId',
        name: 'chapter_reader',
        builder: (context, state) =>
            ChapterReaderScreen(chapterId: state.pathParameters['chapterId']!),
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
      body: Center(
        child: Text('Route not found: ${state.uri}'),
      ),
    ),
  );
});
