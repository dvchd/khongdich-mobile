import 'package:audio_service/audio_service.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:khongdich_mobile/core/database/app_database.dart';
import 'package:khongdich_mobile/core/router/app_router.dart'
    show locationHasBottomNav;
import 'package:khongdich_mobile/features/tts/tts_audio_handler.dart';
import 'package:khongdich_mobile/features/tts/tts_now_playing_bar.dart';

import 'tts_state_machine_test.dart' show FakeCache, FakeProgress, FakeTts;

/// Unit test cho vị trí của now-playing bar toàn cục: `locationHasBottomNav`
/// quyết định có cần chừa chỗ cho bottom nav không để bar không đè lên nav.
void main() {
  test('các tab MainShell có bottom nav', () {
    expect(locationHasBottomNav('/home'), isTrue);
    expect(locationHasBottomNav('/search'), isTrue);
    expect(locationHasBottomNav('/bookshelf'), isTrue);
    expect(locationHasBottomNav('/profile'), isTrue);
  });

  test('story detail online/offline có bottom nav', () {
    expect(locationHasBottomNav('/story/hello-world'), isTrue);
    expect(locationHasBottomNav('/offline-story/story-1'), isTrue);
  });

  test('reader và các màn khác không có bottom nav', () {
    expect(locationHasBottomNav('/chapter/story-1:5'), isFalse);
    expect(locationHasBottomNav('/chapter-offline/ch-1'), isFalse);
    expect(locationHasBottomNav('/settings'), isFalse);
    expect(locationHasBottomNav('/downloads'), isFalse);
    expect(locationHasBottomNav('/story-comments/story-1'), isFalse);
  });

  test('prefix /story/ không khớp nhầm /story-comments hoặc /story-reviews', () {
    expect(locationHasBottomNav('/story-comments/abc'), isFalse);
    expect(locationHasBottomNav('/story-reviews/abc'), isFalse);
  });

  group('TtsNowPlayingBar ẩn/hiện theo dismissedChapterId', () {
    late FakeTts tts;
    late AppDatabase db;
    late TtsAudioHandler handler;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tts = FakeTts();
      db = AppDatabase.forTesting(NativeDatabase.memory());
      handler = TtsAudioHandler(db, FakeProgress(), FakeCache(), tts: tts);
    });

    tearDown(() => db.close());

    Future<void> pumpBar(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ttsHandlerProvider.overrideWith((ref) async => handler),
          ],
          child: const MaterialApp(
            home: Scaffold(body: TtsNowPlayingBar()),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> loadChapterOnly(WidgetTester tester) async {
      // runAsync: loadChapter/_init chờ platform channel thật (audio_session,
      // prefs) — phải chạy trên real event loop, không phải FakeAsync của
      // testWidgets nếu không sẽ treo vĩnh viễn.
      await tester.runAsync(() => handler.loadChapter(
            chapterId: 'ch-1',
            storyId: 's1',
            storyTitle: 'Truyện 1',
            chapterTitle: 'Chương 1',
            chapterNumber: 1,
            contentMarkdown: 'Nội dung chương 1.',
            storySlug: 'truyen-1',
          ));
    }

    /// Đẩy thẳng PlaybackState — mô phỏng event mà handler phát sau
    /// play()/stop() mà KHÔNG chạy speak loop thật.
    void pushState(AudioProcessingState state, bool playing) {
      handler.playbackState.add(PlaybackState(
        controls: const [],
        systemActions: const {},
        processingState: state,
        playing: playing,
      ));
    }

    testWidgets('X khi đang phát → bar ẩn ngay', (tester) async {
      await pumpBar(tester);
      await loadChapterOnly(tester);
      pushState(AudioProcessingState.ready, true);
      await tester.pump();
      expect(find.text('Truyện 1'), findsOneWidget);

      // X khi playing: dismiss → stop() phát idle/false (khác ready/true)
      // → listener phải rebuild và bar biến mất.
      await tester.runAsync(() => handler.dismiss());
      await tester.pump();
      expect(find.text('Truyện 1'), findsNothing);
    });

    testWidgets('X ngay sau Stop vẫn phải ẩn bar (regression bar kẹt)',
        (tester) async {
      await pumpBar(tester);
      await loadChapterOnly(tester);
      await tester.pump(); // flush rebuild do loadChapter phát sự kiện
      expect(find.text('Truyện 1'), findsOneWidget);

      // Baseline sau nút Stop: idle/not-playing, bar CÒN hiện (đúng thiết
      // kế: giữ chương để nghe lại).
      pushState(AudioProcessingState.idle, false);
      await tester.pump();
      expect(find.text('Truyện 1'), findsOneWidget);

      // X khi đã stopped: dismiss() → stop() phát lại idle/not-playing
      // y hệt event trước. Trước fix, listener playbackState bỏ qua event
      // trùng → bar không rebuild → KẸT trên màn hình dù đã dismissed.
      await tester.runAsync(() => handler.dismiss());
      await tester.pump();
      expect(find.text('Truyện 1'), findsNothing);
    });
  });
}
