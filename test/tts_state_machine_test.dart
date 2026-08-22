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
/// Markdown ~3 chunks (mỗi đoạn ~390 ký tự → mỗi đoạn 1 chunk) để test
/// speak loop chuyển chunk — đoạn ngắn 1 chunk sẽ kết thúc chương ngay.
String multiChunkMarkdown() {
  final paragraphs = <String>[];
  for (var i = 1; i <= 3; i++) {
    final buf = StringBuffer();
    for (var j = 1; j <= 30; j++) {
      buf.write('Đoạn $i câu $j.');
    }
    paragraphs.add(buf.toString().trim());
  }
  return paragraphs.join('\n\n');
}

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

    // ── Hybrid offline/online: nghe truyện đã tải liên tục khi có mạng ──
    test('skipToNext offline nhưng chương CHƯA tải → fallback online '
        '(nghe liên tục, không dừng ở chương cuối đã tải)', () async {
      await loadChapter(number: 1, next: 2, offline: true);
      tts.speakCompletes = false;
      await handler.play();

      await handler.skipToNext();
      await pumpEventQueue(times: 10);

      expect(handler.currentChapterId, 'ch-2');
      expect(handler.mediaItem.value?.title, 'Chương 2');
      expect(handler.playbackState.value.playing, isTrue);
      // Chương 2 không có trong DB → fallback qua cache (FakeCache trả ch-2).
      expect(cache.requestedNumbers, contains(2));
      await handler.stop();
    });

    test('skipToNext offline, chưa tải, cache fail (notFound) → error state',
        () async {
      await loadChapter(number: 1, next: 999, offline: true);
      tts.speakCompletes = false;
      await handler.play();

      await handler.skipToNext();
      await pumpEventQueue(times: 10);

      expect(handler.currentChapterId, 'ch-1');
      expect(handler.playbackState.value.processingState,
          AudioProcessingState.error);
      expect(handler.playbackState.value.errorMessage, contains('chương 999'));
      await handler.stop();
    });

    test('skipToNext offline, chưa tải, cache fail vì MẠNG → báo "chưa tải"',
        () async {
      cache.throwNetwork = true;
      await loadChapter(number: 1, next: 2, offline: true);
      tts.speakCompletes = false;
      await handler.play();

      await handler.skipToNext();
      await pumpEventQueue(times: 10);

      expect(handler.currentChapterId, 'ch-1');
      expect(handler.playbackState.value.processingState,
          AudioProcessingState.error);
      expect(handler.playbackState.value.errorMessage, contains('chưa được tải'));
      await handler.stop();
    });

    test('loadChapter offline GIỮ NGUYÊN prev/next truyền vào '
        '(reader truyền full-list → nghe liên tục)', () async {
      // DB chỉ có ch-2 → trước đây handler ghi đè next=null (chặn chuỗi
      // nghe ở chương cuối đã tải). Nay phải giữ next=3 do reader truyền.
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

      await loadChapter(number: 2, next: 3, prev: 1, offline: true);
      expect(handler.nextChapterNumber, 3);
      expect(handler.prevChapterNumber, 1);
    });

    // ── Bug "đổi tốc độ chỉ nghe được 1 đoạn là dừng" ─────────────────
    // Engine thật gửi "speak.onCancel" ASYNC sau stop() — nó đến TRỄ,
    // khi loop mới đã relaunch. Trước fix, cancel handler set
    // _isSpeaking = false → loop mới chết sau đúng 1 chunk.
    test('straggler cancel sau restart tốc độ → loop mới vẫn đọc tiếp',
        () async {
      tts.deferCancelOnStop = true;
      tts.speakCompletes = false;
      await loadChapter(markdown: multiChunkMarkdown());
      await handler.play();
      expect(tts.spoken.length, 1);

      await handler.setSpeed(1.5);
      await pumpEventQueue(times: 10);
      expect(tts.spoken.length, 2); // restart speak lại chunk hiện tại
      expect(handler.playbackState.value.playing, isTrue);

      // "speak.onCancel" của utterance CŨ tới trễ — sau khi loop mới chạy.
      tts.fireDeferredCancel();
      await pumpEventQueue(times: 5);
      expect(handler.playbackState.value.playing, isTrue);

      // Chunk đầu (đang treo) hoàn thành → loop phải TỰ chuyển chunk kế
      // (trước fix: dừng tại đây vì _isSpeaking đã bị cancel handler đè).
      tts.completeNextSpeak();
      await pumpEventQueue(times: 5);
      expect(tts.spoken.length, 3);
      expect(handler.playbackState.value.playing, isTrue);
      await handler.stop();
    });

    test('straggler cancel sau pause→play nhanh → vẫn phát tiếp', () async {
      tts.deferCancelOnStop = true;
      tts.speakCompletes = false;
      await loadChapter(markdown: multiChunkMarkdown());
      await handler.play();
      expect(tts.spoken.length, 1);

      await handler.pause();
      await handler.play();
      expect(tts.spoken.length, 2);

      // onStop của lần pause tới trễ — sau khi loop mới đã chạy.
      tts.fireDeferredCancel();
      await pumpEventQueue(times: 5);
      expect(handler.playbackState.value.playing, isTrue);

      tts.completeNextSpeak();
      await pumpEventQueue(times: 5);
      expect(tts.spoken.length, 3);
      expect(handler.playbackState.value.playing, isTrue);
      await handler.stop();
    });

    test('straggler cancel sau stop → không hồi sinh nút điều khiển',
        () async {
      tts.deferCancelOnStop = true;
      tts.speakCompletes = false;
      await loadChapter(markdown: multiChunkMarkdown());
      await handler.play();
      await handler.stop();

      expect(handler.playbackState.value.controls, isEmpty);
      expect(handler.playbackState.value.playing, isFalse);

      // "speak.onCancel" tới trễ — không được ghi đè state idle của stop.
      tts.fireDeferredCancel();
      await pumpEventQueue(times: 5);
      expect(handler.playbackState.value.controls, isEmpty);
      expect(handler.playbackState.value.playing, isFalse);
      expect(handler.playbackState.value.processingState,
          AudioProcessingState.idle);
    });

    test('genuine cancel (không do chúng ta stop) → state paused', () async {
      tts.speakCompletes = false;
      await loadChapter(markdown: multiChunkMarkdown());
      await handler.play();
      expect(handler.playbackState.value.playing, isTrue);

      // Engine tự cancel (vd: app khác chiếm TTS) — không có stop() nào
      // trước đó → handler phải cập nhật UI thành "đã dừng".
      tts.fireDeferredCancel();
      await pumpEventQueue(times: 5);
      expect(handler.playbackState.value.playing, isFalse);
      await handler.stop();
    });

    // ── Nút X "dừng hẳn và đóng" ───────────────────────────────────────
    test('dismiss → stop + đánh dấu đóng; play lại → mở lại', () async {
      handler.autoAdvanceEnabled = true;
      tts.speakCompletes = false;
      await loadChapter(number: 1, next: 2);
      await handler.play();
      expect(handler.playbackState.value.playing, isTrue);

      await handler.dismiss();
      expect(handler.playbackState.value.playing, isFalse);
      expect(handler.playbackState.value.controls, isEmpty);
      expect(handler.dismissedChapterId, 'ch-1');
      expect(handler.autoAdvanceEnabled, isFalse);

      // Tap headphone lại → play() bỏ trạng thái "đã đóng" (bar hiện lại).
      await handler.play();
      expect(handler.dismissedChapterId, isNull);
      expect(handler.playbackState.value.playing, isTrue);
      await handler.stop();
    });

    test('dismiss chương A → load chương B → dismissed bị clear', () async {
      tts.speakCompletes = false;
      await loadChapter(number: 1, next: 2);
      await handler.play();
      await handler.dismiss();
      expect(handler.dismissedChapterId, 'ch-1');

      await loadChapter(number: 2, prev: 1);
      expect(handler.dismissedChapterId, isNull);
      expect(handler.currentChapterId, 'ch-2');
      await handler.stop();
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
  /// True = `stop()` KHÔNG gọi cancel handler ngay — mô phỏng engine
  /// thật gửi "speak.onCancel" ASYNC (tới trễ, sau khi loop mới đã
  /// relaunch). Test phải gọi [fireDeferredCancel] để mô phỏng event.
  bool deferCancelOnStop = false;
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
    if (!deferCancelOnStop) onCancel?.call();
    for (final c in _pending) {
      if (!c.isCompleted) c.complete(1);
    }
    _pending.clear();
    return 1;
  }

  /// Mô phỏng "speak.onCancel" đến TRỄ từ engine (sau stop).
  void fireDeferredCancel() {
    onCancel?.call();
  }

  /// Hoàn thành utterance đang treo gần nhất (speak() resolve 1).
  void completeNextSpeak() {
    for (final c in _pending.reversed) {
      if (!c.isCompleted) {
        c.complete(1);
        return;
      }
    }
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

  /// True = mọi request throw lỗi MẠNG (không phải notFound) — test
  /// mapping lỗi của hybrid resolve offline.
  bool throwNetwork = false;

  @override
  Future<ChapterContent> getChapter({
    required String storyId,
    required int chapterNumber,
  }) async {
    requestedNumbers.add(chapterNumber);
    if (throwNetwork) {
      throw Exception('network down');
    }
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
