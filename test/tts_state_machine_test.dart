import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:khongdich_mobile/core/database/app_database.dart';
import 'package:khongdich_mobile/core/observability/app_logger.dart';
import 'package:khongdich_mobile/features/reader/services/reading_progress_service.dart';
import 'package:khongdich_mobile/features/tts/tts_audio_handler.dart';
import 'package:khongdich_mobile/models/chapter_content.dart';
import 'package:khongdich_mobile/services/chapter_cache_service.dart';

/// State-machine tests cho [TtsAudioHandler] — khóa các bug race đã fix:
///   - #7: play() gọi NGAY sau pause() không bị nuốt (trước đây no-op vì
///     `_speakLoopFuture != null` → TTS dừng vĩnh viễn).
///   - #8: pause() gọi NGAY sau play() không bị play() ghi đè state
///     (trước đây UI báo paused trong khi audio vẫn chạy).
///   - #9: setSpeed giữa chừng restart lại chunk với rate mới.
///   - #10: skipToNext/skipToPrevious + auto-advance khi hết chương do
///     HANDLER tự resolve + load + play — không cần màn hình nào.
///
/// FakeTts mô phỏng engine: `speak()` giữ future pending cho tới khi
/// `stop()` được gọi (giống engine thật không resolve speak() sau stop
/// giữa chừng) — nhờ đó test được race giữa các thao tác.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AppLogger.init();

  group('TtsAudioHandler state machine', () {
    late FakeTts tts;
    late AppDatabase db;
    late FakeCache cache;
    late FakeProgress progress;
    late TtsAudioHandler handler;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tts = FakeTts();
      db = AppDatabase.forTesting(NativeDatabase.memory());
      cache = FakeCache();
      progress = FakeProgress();
      handler = TtsAudioHandler(db, progress, cache, tts: tts);
    });

    tearDown(() => db.close());

    Future<void> loadChapter({
      int number = 1,
      int? next,
      int? prev,
      bool offline = false,
      String? markdown,
    }) =>
        handler.loadChapter(
          chapterId: 'ch-$number',
          storyId: 's1',
          storyTitle: 'Truyện 1',
          chapterTitle: 'Chương $number',
          chapterNumber: number,
          contentMarkdown: markdown ?? 'Nội dung chương $number.',
          storySlug: 'truyen-1',
          prevChapterNumber: prev,
          nextChapterNumber: next,
          offline: offline,
        );

    test('play sau load → playing + speak chunk đầu tiên', () async {
      await loadChapter();
      await handler.play();
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.playbackState.value.processingState,
          AudioProcessingState.ready);
      expect(tts.spoken, isNotEmpty);
      expect(handler.mediaItem.value?.title, 'Chương 1');
      await handler.stop();
    });

    test('pause rồi play ngay → cuối cùng vẫn playing (bug #7)', () async {
      await loadChapter();
      tts.speakCompletes = false; // speak treo cho tới khi stop()
      await handler.play();
      expect(tts.spoken.length, 1);

      final fPause = handler.pause();
      final fPlay = handler.play();
      await fPause;
      await fPlay;

      // Trước fix: play() bị nuốt vì _speakLoopFuture != null (loop cũ
      // đang thoát) → state dừng ở paused dù user bấm play.
      expect(handler.playbackState.value.playing, isTrue);
      expect(tts.spoken.length, 2); // loop mới đã launch + speak lại
      await handler.stop();
    });

    test('play rồi pause ngay → cuối cùng paused (bug #8)', () async {
      await loadChapter();
      tts.speakCompletes = false;
      final fPlay = handler.play();
      final fPause = handler.pause();
      await fPlay;
      await fPause;

      // Trước fix: pause() emit state sau khi await, ghi đè state playing
      // của play() → UI báo paused trong khi audio chạy.
      expect(handler.playbackState.value.playing, isFalse);
      expect(tts.spoken.length, 1);
    });

    test('setSpeed giữa chừng → restart chunk với rate mới (bug #9)',
        () async {
      await loadChapter();
      tts.speakCompletes = false;
      await handler.play();
      expect(tts.spoken.length, 1);

      await handler.setSpeed(1.5);
      await pumpEventQueue(times: 10);

      // (1.5 - 0.5) / 2 = 0.5 trên thang flutter_tts Android.
      expect(tts.speechRates.last, closeTo(0.5, 0.0001));
      // Restart: chunk hiện tại được speak lại với rate mới.
      expect(tts.spoken.length, 2);
      expect(handler.playbackState.value.playing, isTrue);
      await handler.stop();
    });

    test('đổi tốc độ liên tiếp → vẫn dùng rate cuối (bug #9 coalesce)',
        () async {
      await loadChapter();
      tts.speakCompletes = false;
      await handler.play();

      final f1 = handler.setSpeed(1.5);
      final f2 = handler.setSpeed(2.0);
      await f1;
      await f2;
      await pumpEventQueue(times: 10);

      expect(tts.speechRates.last, closeTo(0.75, 0.0001)); // (2.0-0.5)/2
      expect(handler.playbackState.value.playing, isTrue);
      await handler.stop();
    });

    test('stop giữa chừng → idle + controls rỗng', () async {
      await loadChapter();
      tts.speakCompletes = false;
      await handler.play();
      await handler.stop();

      expect(handler.playbackState.value.playing, isFalse);
      expect(handler.playbackState.value.processingState,
          AudioProcessingState.idle);
      expect(handler.playbackState.value.controls, isEmpty);
    });

    test('skipToNext (online) → handler tự load + play chương kế (bug #10)',
        () async {
      await loadChapter(number: 1, next: 2);
      tts.speakCompletes = false;
      await handler.play();

      final events = <TtsChapterCompleteEvent>[];
      final sub = handler.onChapterCompleted.listen(events.add);

      await handler.skipToNext();
      await pumpEventQueue(times: 10);

      expect(cache.requestedNumbers, contains(2));
      expect(handler.mediaItem.value?.title, 'Chương 2');
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.currentChapterId, 'ch-2');
      expect(events, hasLength(1));
      expect(events.single.manualSkip, isTrue);
      expect(events.single.chapterId, 'ch-1');
      expect(events.single.nextChapterNumber, 2);
      await sub.cancel();
      await handler.stop();
    });

    test('skipToPrevious (online) → handler tự load + play chương trước',
        () async {
      await loadChapter(number: 2, next: 3, prev: 1);
      tts.speakCompletes = false;
      await handler.play();

      await handler.skipToPrevious();
      await pumpEventQueue(times: 10);

      expect(cache.requestedNumbers, contains(1));
      expect(handler.mediaItem.value?.title, 'Chương 1');
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.currentChapterId, 'ch-1');
      await handler.stop();
    });

    test('skip khi không có chương đích → no-op, vẫn đang phát', () async {
      await loadChapter(number: 2, next: null, prev: null);
      tts.speakCompletes = false;
      await handler.play();

      await handler.skipToNext();
      await handler.skipToPrevious();
      await pumpEventQueue(times: 5);

      expect(cache.requestedNumbers, isEmpty);
      expect(handler.currentChapterId, 'ch-2');
      expect(handler.playbackState.value.playing, isTrue);
      await handler.stop();
    });

    test('skip khi đang pause → vẫn chuyển chương + play', () async {
      await loadChapter(number: 1, next: 2);
      await handler.play();
      tts.speakCompletes = false;
      await handler.pause();
      expect(handler.playbackState.value.playing, isFalse);

      await handler.skipToNext();
      await pumpEventQueue(times: 10);

      expect(handler.mediaItem.value?.title, 'Chương 2');
      expect(handler.playbackState.value.playing, isTrue);
      await handler.stop();
    });

    test('hết chương + autoAdvance → handler tự chuyển chương kế (không cần màn hình)',
        () async {
      handler.autoAdvanceEnabled = true;
      await loadChapter(number: 1, next: 2);
      final events = <TtsChapterCompleteEvent>[];
      final sub = handler.onChapterCompleted.listen(events.add);

      // Chỉ utterance đầu (chương 1) tự hoàn thành — chương 2 treo để
      // assert được trạng thái "đang phát chương 2" (bug #10).
      tts.speakCompletes = true;
      tts.autoCompleteCount = 1;
      await handler.play();
      await pumpEventQueue(times: 10);

      expect(cache.requestedNumbers, contains(2));
      expect(handler.mediaItem.value?.title, 'Chương 2');
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.currentChapterId, 'ch-2');
      expect(events, hasLength(1));
      expect(events.single.manualSkip, isFalse);
      await sub.cancel();
      await handler.stop();
    });

    test('hết chương + autoAdvance tắt → idle, KHÔNG tự chuyển', () async {
      await loadChapter(number: 1, next: 2);
      final events = <TtsChapterCompleteEvent>[];
      final sub = handler.onChapterCompleted.listen(events.add);

      tts.speakCompletes = true;
      await handler.play();
      await pumpEventQueue(times: 10);

      expect(cache.requestedNumbers, isEmpty);
      expect(handler.currentChapterId, 'ch-1');
      expect(handler.playbackState.value.playing, isFalse);
      expect(handler.playbackState.value.controls, hasLength(4));
      expect(events, hasLength(1));
      expect(events.single.nextChapterNumber, 2);
      await sub.cancel();
    });

    test('skipToNext offline → resolve từ downloaded_chapters', () async {
      await db.upsertDownloadedChapter(DownloadedChaptersCompanion.insert(
        chapterId: 'ch-2',
        storyId: 's1',
        storyTitle: 'Truyện 1',
        storySlug: 'truyen-1',
        chapterNumber: 2,
        chapterTitle: 'Chương 2',
        contentType: 'text',
        contentRaw: jsonEncode({
          'id': 'ch-2',
          'story_id': 's1',
          'story_title': 'Truyện 1',
          'story_slug': 'truyen-1',
          'chapter_number': 2,
          'title': 'Chương 2',
          'content_type': 'text',
          'content_version': 1,
          'word_count': 10,
          'is_published': true,
          'updated_at': '2026-01-01T00:00:00Z',
          'content_markdown': 'Nội dung chương hai.',
          'content_format': 'markdown',
        }),
        downloadedAt: '2026-01-01T00:00:00Z',
      ));

      await loadChapter(number: 1, next: 2, offline: true);
      tts.speakCompletes = false;
      await handler.play();

      await handler.skipToNext();
      await pumpEventQueue(times: 10);

      expect(handler.mediaItem.value?.title, 'Chương 2');
      expect(handler.currentChapterId, 'ch-2');
      expect(handler.playbackState.value.playing, isTrue);
      // Offline resolve đọc trực tiếp từ DB, không gọi cache/API.
      expect(cache.requestedNumbers, isEmpty);
      await handler.stop();
    });

    test('skipToNext online nhưng resolve fail → error state, giữ chương cũ',
        () async {
      await loadChapter(number: 1, next: 999);
      tts.speakCompletes = false;
      await handler.play();

      await handler.skipToNext();
      await pumpEventQueue(times: 10);

      expect(handler.currentChapterId, 'ch-1');
      expect(handler.playbackState.value.processingState,
          AudioProcessingState.error);
      expect(handler.playbackState.value.errorMessage, isNotNull);
    });
  });
}

/// Fake FlutterTts — không đụng platform channel. `speak()` treo cho tới
/// khi `stop()` được gọi (nếu [speakCompletes] = false), mô phỏng engine
/// thật không resolve speak() sau stop giữa chừng.
class FakeTts extends FlutterTts {
  final List<String> spoken = [];
  final List<double> speechRates = [];
  final List<Completer<int>> _pending = [];
  bool speakCompletes = true;
  /// Số utterance tự hoàn thành (không cần stop()). Test auto-advance
  /// set = 1 để chương đầu hoàn thành nhưng chương kế treo → assert
  /// được trạng thái "đang phát chương 2".
  int autoCompleteCount = 1 << 20;
  VoidCallback? onCancel;
  ErrorHandler? onError;

  @override
  Future<dynamic> speak(String text, {bool focus = false}) {
    spoken.add(text);
    final completer = Completer<int>();
    _pending.add(completer);
    if (speakCompletes && spoken.length <= autoCompleteCount) {
      completer.complete(1);
    }
    return completer.future;
  }

  @override
  Future<dynamic> stop() async {
    onCancel?.call();
    for (final c in _pending) {
      if (!c.isCompleted) c.complete(1);
    }
    _pending.clear();
    return 1;
  }

  @override
  Future<dynamic> setSpeechRate(double rate) async {
    speechRates.add(rate);
    return 1;
  }

  @override
  Future<dynamic> setLanguage(String language) async => 1;

  @override
  Future<dynamic> setPitch(double pitch) async => 1;

  @override
  Future<dynamic> setVolume(double volume) async => 1;

  @override
  Future<dynamic> awaitSpeakCompletion(bool awaitCompletion) async => 1;

  @override
  Future<dynamic> get getVoices async => null;

  @override
  Future<dynamic> get getEngines async => null;

  @override
  Future<dynamic> get getDefaultEngine async => null;

  @override
  Future<dynamic> get getLanguages async => null;

  @override
  void setCompletionHandler(VoidCallback callback) {}

  @override
  void setErrorHandler(ErrorHandler handler) {
    onError = handler;
  }

  @override
  void setCancelHandler(VoidCallback callback) {
    onCancel = callback;
  }
}

/// Fake cache — trả chapter theo số chương từ map, throw nếu không có
/// (mô phỏng API miss).
class FakeCache implements ChapterCacheService {
  final requestedNumbers = <int>[];

  @override
  Future<ChapterContent> getChapter({
    required String storyId,
    required int chapterNumber,
  }) async {
    requestedNumbers.add(chapterNumber);
    if (chapterNumber == 1 || chapterNumber == 2) {
      return TextChapterContent(
        id: 'ch-$chapterNumber',
        storyId: storyId,
        storyTitle: 'Truyện 1',
        storySlug: 'truyen-1',
        chapterNumber: chapterNumber,
        title: 'Chương $chapterNumber',
        contentVersion: 1,
        wordCount: 10,
        isPublished: true,
        prevChapter: chapterNumber > 1 ? chapterNumber - 1 : null,
        nextChapter: chapterNumber < 2 ? chapterNumber + 1 : null,
        updatedAt: DateTime(2026),
        contentMarkdown: 'Nội dung chương $chapterNumber.',
        contentFormat: 'markdown',
      );
    }
    throw StateError('Chapter $chapterNumber not found');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Fake progress — markChapterRead no-op.
class FakeProgress implements ReadingProgressService {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}
