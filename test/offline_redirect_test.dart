import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:khongdich_mobile/core/database/app_database.dart';
import 'package:khongdich_mobile/features/bookshelf/bookshelf_screen.dart';
import 'package:khongdich_mobile/features/downloads/offline_library_screen.dart'
    show offlineLibraryStreamProvider;
import 'package:khongdich_mobile/features/home/home_screen.dart';

/// Regression test cho UX offline:
///   1. Home lỗi MẠNG (không có response) + có truyện đã tải → auto
///      redirect sang Tủ truyện tab "Đã tải" (chip cuối, được scroll
///      vào tầm nhìn).
///   2. Home lỗi mạng + KHÔNG có truyện tải → giữ màn hình lỗi, không
///      redirect, không hiện nút "Xem truyện đã tải".
class _FakeHomeNotifier extends HomeNotifier {
  _FakeHomeNotifier(super.ref);

  @override
  Future<void> refresh() async {
    state = AsyncValue.error(
      DioException.connectionError(
        requestOptions: RequestOptions(path: '/api/v1/mobile/stories'),
        reason: 'offline',
      ),
      StackTrace.current,
    );
  }
}

class _FakeBookshelfNotifier extends BookshelfNotifier {
  _FakeBookshelfNotifier(super.ref) {
    state = const AsyncValue.data([]);
  }

  @override
  Future<void> refresh() async {}
}

DownloadedChapter _downloadedRow() => DownloadedChapter(
      chapterId: 'c1',
      storyId: 's1',
      storyTitle: 'Truyện test',
      storySlug: 'truyen-test',
      chapterNumber: 1,
      chapterTitle: 'Chương 1',
      contentType: 'text',
      contentRaw: '{}',
      contentVersion: 1,
      wordCount: 10,
      downloadedAt: '2026-01-01T00:00:00Z',
      lastReadAt: null,
      isRead: 0,
      coverUrl: null,
      storyAuthor: null,
      storySynopsis: null,
      source: 'manual_download',
    );

void main() {
  testWidgets('offline + có truyện đã tải → auto-redirect Tủ truyện tab Đã tải',
      (tester) async {
    tester.view.physicalSize = const Size(420 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const HomeScreen()),
        GoRoute(path: '/bookshelf', builder: (_, _) => const BookshelfScreen()),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith((ref) => _FakeHomeNotifier(ref)),
          bookshelfProvider.overrideWith((ref) => _FakeBookshelfNotifier(ref)),
          offlineLibraryStreamProvider.overrideWith(
            (ref) => Stream.value([_downloadedRow()]),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    // Home hiển thị lỗi mạng trước, rồi redirect sang bookshelf.
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    // Đã nằm ở Tủ truyện.
    expect(find.text('Tủ truyện'), findsOneWidget);


    // Tab "Đã tải" được chọn.
    final chip = tester.widget<FilterChip>(
      find.widgetWithText(FilterChip, 'Đã tải'),
    );
    expect(chip.selected, true);

    // Chip row scroll để chip "Đã tải" nằm trong tầm nhìn (screen hẹp
    // 420px → 6 chips không vừa → phải scroll tới chip cuối).
    final chipRect = tester.getRect(find.widgetWithText(FilterChip, 'Đã tải'));
    expect(chipRect.left, greaterThanOrEqualTo(0));
    expect(chipRect.right, lessThanOrEqualTo(420));
  });

  testWidgets('offline + KHÔNG có truyện tải → giữ màn hình lỗi, có nút Thử lại',
      (tester) async {
    tester.view.physicalSize = const Size(420 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const HomeScreen()),
        GoRoute(path: '/bookshelf', builder: (_, _) => const BookshelfScreen()),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith((ref) => _FakeHomeNotifier(ref)),
          bookshelfProvider.overrideWith((ref) => _FakeBookshelfNotifier(ref)),
          offlineLibraryStreamProvider.overrideWith(
            (ref) => Stream.value(const <DownloadedChapter>[]),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    // Vẫn ở Home với màn hình lỗi — KHÔNG redirect, không có nút
    // "Xem truyện đã tải" (không có gì để xem).
    expect(find.text('Không có kết nối mạng'), findsOneWidget);
    expect(find.text('Thử lại'), findsOneWidget);
    expect(find.text('Xem truyện đã tải'), findsNothing);
    expect(find.text('Tủ truyện'), findsNothing);
  });

  testWidgets('offline + có truyện tải → màn lỗi có nút "Xem truyện đã tải"',
      (tester) async {
    tester.view.physicalSize = const Size(420 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      initialLocation: '/home',
      routes: [
        GoRoute(path: '/home', builder: (_, _) => const HomeScreen()),
        GoRoute(path: '/bookshelf', builder: (_, _) => const BookshelfScreen()),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          homeProvider.overrideWith((ref) => _FakeHomeNotifier(ref)),
          bookshelfProvider.overrideWith((ref) => _FakeBookshelfNotifier(ref)),
          offlineLibraryStreamProvider.overrideWith(
            (ref) => Stream.value([_downloadedRow()]),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    // Chỉ pump 1 frame — màn lỗi hiện trước khi redirect hoàn tất;
    // nút "Xem truyện đã tải" phải hiện làm fallback.
    await tester.pump();
    await tester.pump();

    // Màn lỗi hiện tại phải có nút fallback khi có truyện đã tải.
    expect(find.text('Xem truyện đã tải'), findsOneWidget);
  });
}
