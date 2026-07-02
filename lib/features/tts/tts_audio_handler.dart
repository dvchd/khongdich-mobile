import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/database/app_database.dart';
import '../../core/markdown/markdown.dart';
import '../../core/observability/app_logger.dart';
import '../reader/services/reading_progress_service.dart';

/// Foreground-service-backed TTS player for Không Dịch.
///
/// **Định hướng: 100% on-device TTS offline.**
///
/// App mobile KHÔNG tải file audio từ server. Toàn bộ text-to-speech
/// được thực hiện on-device qua `flutter_tts` (Android system TTS).
/// Chương được tải về (text content) → `TtsMarkdownPreprocessor` chia
/// thành các chunk ~500 ký tự → `flutter_tts.speak()` đọc tuần tự.
///
/// **Key architecture notes:**
///
/// 1. `flutter_tts` với `awaitSpeakCompletion(true)`: `speak()` Future
///    resolve khi utterance hoàn tất. Chúng ta dùng **while-loop** trong
///    `_speakLoop()` để chain các chunk — KHÔNG dùng completion handler
///    (xem bug #2 bên dưới). Completion handler được set thành no-op
///    để tránh re-entrancy race.
///
/// 2. `audio_service` wrap handler để Android treat như foreground media
///    service. `playbackState` stream drive notification shade + mini
///    player UI.
///
/// 3. Chunks: `TtsMarkdownPreprocessor.process()` split markdown thành
///    ~500-char plain-text chunks. Đọc tuần tự qua while-loop.
///
/// **Các bug đã fix (so với phiên bản trước):**
///
/// - **#1 Init failure recovery**: `_initialised` chỉ set `true` ở CUỐI
///   try block. Nếu init fail, lần sau gọi `_init()` sẽ retry. Provider
///   cũng cho phép retry qua `reinit()`.
///
/// - **#2 Re-entrancy race**: completion handler trước đây gọi
///   `_speakCurrentChunk()` fire-and-forget TRƯỚC khi `speak()` Future
///   resolve → trên Samsung/Huawei engine, speak() re-entrant bị drop →
///   "TTS đọc 1 chunk rồi dừng". Fix: bỏ completion handler, dùng
///   while-loop trong `_speakLoop()` với `awaitSpeakCompletion(true)`.
///
/// - **#5 speak() return value**: check `result != 1` → surface error
///   thay vì hang silently.
///
/// - **#6 _savePlaybackState fire-and-forget**: không block hot path
///   giữa các chunk.
class TtsAudioHandler extends BaseAudioHandler with QueueHandler {
  TtsAudioHandler(this._db, this._progressService);

  final AppDatabase _db;
  final ReadingProgressService _progressService;

  final FlutterTts _tts = FlutterTts();
  List<String> _chunks = const [];
  int _currentChunk = 0;
  String? _currentChapterId;
  String? _currentStoryId;
  int? _currentChapterNumber;
  bool _initialised = false;
  bool _isSpeaking = false; // Guard against re-entrant completion handlers
  // Future của speak loop hiện tại — dùng để cancel khi stop/pause.
  Future<void>? _speakLoopFuture;

  // User settings (persisted)
  double _speed = 1.0;
  String? _selectedVoiceName;
  String? _selectedEngine;

  // Available voices — List<Map> with keys `name`, `locale`.
  List<Map<String, String>> _availableVoices = [];
  // Available TTS engines — List of package names like
  // "com.google.android.tts", "com.samsung.SMT", etc.
  List<String> _availableEngines = [];

  final _chunkProgressController =
      StreamController<TtsChunkProgress>.broadcast();
  Stream<TtsChunkProgress> get chunkProgress => _chunkProgressController.stream;

  double get speed => _speed;
  List<Map<String, String>> get availableVoices => _availableVoices;
  List<String> get availableEngines => _availableEngines;
  String? get selectedVoiceName => _selectedVoiceName;
  String? get selectedEngine => _selectedEngine;
  /// ID của chương hiện đang load (hoặc đang play). Dùng cho UI quyết định
  /// có cần stop + reload khi user tap headphone ở chương khác.
  String? get currentChapterId => _currentChapterId;

  Future<void> _init() async {
    if (_initialised) return;
    try {
      AppLogger.info('TTS: starting init...');

      // Load persisted settings
      final prefs = await SharedPreferences.getInstance();
      _speed = prefs.getDouble('tts.speed') ?? 1.0;
      _selectedVoiceName = prefs.getString('tts.voice');
      _selectedEngine = prefs.getString('tts.engine');

      // ── Engine selection ────────────────────────────────────────
      // On Android, flutter_tts exposes getEngines / getDefaultEngine /
      // setEngine. Setting the engine explicitly is important — when
      // the device has multiple TTS engines installed (Google, Samsung,
      // Huawei, etc.), the default may not support Vietnamese voices.
      // We pick the user's saved engine, then the system default, then
      // the first available.
      try {
        final defaultEngine = await _tts.getDefaultEngine;
        AppLogger.info('TTS: default engine = $defaultEngine');
        final engines = await _tts.getEngines;
        if (engines != null) {
          _availableEngines = (engines as List)
              .map((e) => e?.toString() ?? '')
              .where((s) => s.isNotEmpty)
              .toList();
          AppLogger.info(
              'TTS: ${_availableEngines.length} engines available: $_availableEngines');

          final desired = _selectedEngine ?? defaultEngine?.toString();
          if (desired != null && _availableEngines.contains(desired)) {
            final setResult = await _tts.setEngine(desired);
            AppLogger.info('TTS: setEngine($desired) → $setResult');
          } else if (_availableEngines.isNotEmpty) {
            // Fall back to first available engine.
            final setResult =
                await _tts.setEngine(_availableEngines.first);
            AppLogger.info(
                'TTS: setEngine(${_availableEngines.first}) fallback → $setResult');
          }
        }
      } catch (e, s) {
        AppLogger.warning('TTS: engine enumeration failed', e, s);
      }

      // Set language — thử nhiều format vì các engine trả về kết quả khác nhau:
      //   - Engine cũ (Google TTS `com.google.android.tts`): chấp nhận 'vi-VN'
      //   - Engine mới (Speech Recognition and Synthesis from Google): có thể
      //     chỉ chấp nhận 'vi_VN' hoặc 'vi'
      //   - Samsung/Huawei: format riêng
      // Thử lần lượt: vi-VN → vi_VN → vi. Dừng lại ở format đầu tiên trả về
      // 0 (success) hoặc 1 (already set). Nếu tất cả fail (-1/-2), vẫn giữ
      // format cuối — user có thể chọn voice tiếng Việt thủ công qua dropdown.
      final langCandidates = ['vi-VN', 'vi_VN', 'vi'];
      int langResult = -2;
      for (final lang in langCandidates) {
        // flutter_tts.setLanguage returns dynamic (1 on Android, possibly
        // different on iOS). Cast to int — the plugin contract is int.
        final raw = await _tts.setLanguage(lang);
        langResult = (raw is int) ? raw : int.tryParse('$raw') ?? -2;
        AppLogger.info('TTS: setLanguage($lang) → $langResult');
        if (langResult == 0 || langResult == 1) break;
      }

      // Log available languages để debug (nếu setLanguage fail, user có thể
      // xem log biết engine có support tiếng Việt không).
      if (langResult == -1 || langResult == -2) {
        AppLogger.warning(
            'TTS: vi-* not available (result=$langResult). User có thể chọn '
            'voice tiếng Việt thủ công qua dropdown nếu engine support.');
        try {
          final langs = await _tts.getLanguages;
          if (langs != null) {
            final langList = (langs as List)
                .map((l) => l?.toString() ?? '')
                .where((s) => s.isNotEmpty)
                .toList();
            AppLogger.info('TTS: available languages = $langList');
          }
        } catch (e) {
          AppLogger.warning('TTS: getLanguages failed', e);
        }
      }

      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      await _applySpeed();

      // CRITICAL: awaitSpeakCompletion(true) makes the speak() Future
      // resolve when the utterance is done. We use this + a while-loop
      // in _speakLoop() to chain chunks — see _speakLoop for details.
      await _tts.awaitSpeakCompletion(true);

      // ── Load voices ─────────────────────────────────────────────
      // We load ALL voices (not just vi-*) so the user can pick any
      // installed voice. The previous filter (`locale.startsWith('vi')`)
      // was too strict and hid voices that the device actually had
      // installed — particularly when the engine returned locale in
      // a non-standard format like "vi_VN" vs "vi-VN".
      try {
        final voices = await _tts.getVoices;
        if (voices != null) {
          _availableVoices = (voices as List)
              .map((v) => Map<String, String>.from(v as Map))
              .toList();
          // Sort: Vietnamese voices first (so they appear at the top
          // of the dropdown), then everything else alphabetically.
          _availableVoices.sort((a, b) {
            final aLocale = (a['locale'] ?? a['language'] ?? '').toLowerCase();
            final bLocale = (b['locale'] ?? b['language'] ?? '').toLowerCase();
            final aVi = aLocale.startsWith('vi') ? 0 : 1;
            final bVi = bLocale.startsWith('vi') ? 0 : 1;
            if (aVi != bVi) return aVi.compareTo(bVi);
            return (a['name'] ?? '').compareTo(b['name'] ?? '');
          });
          AppLogger.info(
              'TTS: ${_availableVoices.length} voices available');
          // Log first 5 Vietnamese voices để debug.
          final viVoices = _availableVoices
              .where((v) => (v['locale'] ?? v['language'] ?? '')
                  .toLowerCase()
                  .startsWith('vi'))
              .toList();
          AppLogger.info(
              'TTS: ${viVoices.length} Vietnamese voices: ${viVoices.take(3).map((v) => "${v['name']} (${v['locale'] ?? v['language']})").toList()}');
          if (_selectedVoiceName != null) {
            final voice = _availableVoices
                .where((v) => v['name'] == _selectedVoiceName)
                .firstOrNull;
            if (voice != null) {
              await _tts.setVoice(voice);
              AppLogger.info('TTS: setVoice(${voice['name']}) → ok');
            } else {
              AppLogger.warning(
                  'TTS: saved voice "$_selectedVoiceName" not found in current engine');
            }
          } else if (viVoices.isNotEmpty) {
            // Auto-select first Vietnamese voice if user hasn't picked one.
            // This helps when setLanguage() failed but the engine still has
            // Vietnamese voices available (common with Google's new
            // "Speech Recognition and Synthesis" engine).
            final voice = viVoices.first;
            await _tts.setVoice(voice);
            _selectedVoiceName = voice['name'];
            AppLogger.info(
                'TTS: auto-selected Vietnamese voice ${voice['name']} (${voice['locale'] ?? voice['language']})');
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('tts.voice', _selectedVoiceName!);
          }
        }
      } catch (e) {
        AppLogger.warning('TTS: getVoices failed', e);
      }

      // ── Handlers ────────────────────────────────────────────────
      // Completion handler: NO-OP. Chunk chaining được drive bởi while-loop
      // trong _speakLoop(), KHÔNG phải bởi completion handler. Trước đây
      // completion handler gọi _speakCurrentChunk() fire-and-forget gây
      // re-entrancy race (speak() re-entrant bị drop trên Samsung/Huawei).
      // Với awaitSpeakCompletion(true), while-loop đợi speak() resolve
      // (khi chunk xong) rồi mới advance → không race.
      _tts.setCompletionHandler(() {
        // Intentionally empty — see comment above.
      });

      _tts.setErrorHandler((msg) {
        AppLogger.error('TTS error: $msg');
        _isSpeaking = false;
        playbackState.add(playbackState.value.copyWith(
          processingState: AudioProcessingState.error,
          errorMessage: msg.toString(),
        ));
      });

      _tts.setCancelHandler(() {
        AppLogger.info('TTS: cancel handler fired');
        _isSpeaking = false;
        playbackState.add(playbackState.value.copyWith(
          processingState: AudioProcessingState.idle,
          playing: false,
        ));
      });

      // Chỉ set _initialised = true ở CUỐI try block. Nếu bất kỳ bước
      // nào throw, _initialised vẫn false → lần sau _init() sẽ retry.
      _initialised = true;
      AppLogger.info('TTS: init complete');
    } catch (e, s) {
      // Init failed — _initialised vẫn false, retry sẽ chạy lại lần sau.
      AppLogger.error('TtsAudioHandler._init failed (will retry on next call)', e, s);
    }
  }

  /// Retry init từ UI (vd: user bấm "Thử lại" khi TTS fail).
  /// Reset _initialised = false rồi gọi _init().
  Future<void> reinit() async {
    _initialised = false;
    await _init();
  }

  Future<void> _applySpeed() async {
    // flutter_tts Android: 0.0 = slowest, 1.0 = normal.
    // Map user-facing 0.5–2.5 → 0.0–1.0.
    final rate = ((_speed - 0.5) / 2.0).clamp(0.0, 1.0);
    await _tts.setSpeechRate(rate);
    AppLogger.info('TTS: setSpeechRate($rate) for user speed $_speed');
  }

  @override
  Future<void> setSpeed(double speed) async {
    _speed = speed.clamp(0.5, 2.5);
    await _applySpeed();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('tts.speed', _speed);
  }

  Future<void> setVoice(String? voiceName) async {
    _selectedVoiceName = voiceName;
    if (voiceName != null) {
      final voice = _availableVoices
          .where((v) => v['name'] == voiceName)
          .firstOrNull;
      if (voice != null) {
        await _tts.setVoice(voice);
      }
    }
    final prefs = await SharedPreferences.getInstance();
    if (voiceName != null) {
      await prefs.setString('tts.voice', voiceName);
    } else {
      await prefs.remove('tts.voice');
    }
  }

  /// Switch the active TTS engine (e.g. from "com.google.android.tts"
  /// to "com.samsung.SMT"). After switching, re-enumerate voices
  /// because each engine exposes its own voice list.
  ///
  /// Returns the new list of available voices so the caller can
  /// update its dropdown.
  Future<List<Map<String, String>>> setEngine(String? engineName) async {
    _selectedEngine = engineName;
    if (engineName != null && _availableEngines.contains(engineName)) {
      await _tts.setEngine(engineName);
      AppLogger.info('TTS: setEngine($engineName)');
    }
    final prefs = await SharedPreferences.getInstance();
    if (engineName != null) {
      await prefs.setString('tts.engine', engineName);
    } else {
      await prefs.remove('tts.engine');
    }
    // Re-fetch voices for the new engine. Reset the selected voice
    // because the previous voice name likely doesn't exist on the
    // new engine.
    _selectedVoiceName = null;
    await prefs.remove('tts.voice');
    try {
      final voices = await _tts.getVoices;
      if (voices != null) {
        _availableVoices = (voices as List)
            .map((v) => Map<String, String>.from(v as Map))
            .toList();
        _availableVoices.sort((a, b) {
          final aLocale = (a['locale'] ?? a['language'] ?? '').toLowerCase();
          final bLocale = (b['locale'] ?? b['language'] ?? '').toLowerCase();
          final aVi = aLocale.startsWith('vi') ? 0 : 1;
          final bVi = bLocale.startsWith('vi') ? 0 : 1;
          if (aVi != bVi) return aVi.compareTo(bVi);
          return (a['name'] ?? '').compareTo(b['name'] ?? '');
        });
      }
    } catch (e) {
      AppLogger.warning('TTS: re-fetch voices after engine switch failed', e);
    }
    return _availableVoices;
  }

  Future<void> loadChapter({
    required String chapterId,
    required String storyId,
    required String storyTitle,
    required String chapterTitle,
    required int chapterNumber,
    required String contentMarkdown,
  }) async {
    await _init();
    // Stop mọi playback đang chạy của chương cũ trước khi load chương mới.
    // Trước đây không có bước này → completion handler của chương cũ có
    // thể fire sau khi chương mới đã load, gây _currentChunk sai.
    if (_isSpeaking) {
      _isSpeaking = false;
      await _tts.stop();
    }
    _chunks = TtsMarkdownPreprocessor.process(contentMarkdown);
    AppLogger.info(
        'TTS: loaded chapter $chapterId — ${_chunks.length} chunks');
    _currentChapterId = chapterId;
    _currentStoryId = storyId;
    _currentChapterNumber = chapterNumber;

    final state = await _db.getTtsState(chapterId);
    _currentChunk = state?.chunkIndex ?? 0;
    if (_currentChunk >= _chunks.length) _currentChunk = 0;

    mediaItem.add(MediaItem(
      id: chapterId,
      album: storyTitle,
      title: chapterTitle,
      artist: storyTitle,
      duration: Duration(seconds: _chunks.length * 30),
    ));
  }

  @override
  Future<void> play() async {
    if (_currentChapterId == null || _chunks.isEmpty) {
      AppLogger.warning('TTS: play() called but no chapter loaded');
      return;
    }
    await _init();
    _isSpeaking = true;
    playbackState.add(playbackState.value.copyWith(
      controls: [MediaControl.pause, MediaControl.skipToNext, MediaControl.stop],
      playing: true,
      processingState: AudioProcessingState.ready,
    ));
    _chunkProgressController.add(TtsChunkProgress(
      chapterId: _currentChapterId!,
      chunkIndex: _currentChunk,
      totalChunks: _chunks.length,
    ));
    // Start the speak loop. Nếu loop cũ vẫn đang chạy (vd: user press play
    // nhanh 2 lần), đợi nó kết thúc trước. Thực tế _isSpeaking guard trong
    // loop sẽ khiến loop cũ exit sớm.
    if (_speakLoopFuture != null) {
      // Loop cũ đang chạy — _isSpeaking đã true, không cần start lại.
      return;
    }
    _speakLoopFuture = _speakLoop();
    // Fire-and-forget — loop tự kết thúc khi chapter complete hoặc stop.
    unawaited(_speakLoopFuture!.then((_) {
      _speakLoopFuture = null;
    }));
  }

  @override
  Future<void> pause() async {
    _isSpeaking = false;
    await _tts.stop();
    // Đợi loop hiện tại exit (nó sẽ exit do _isSpeaking = false).
    if (_speakLoopFuture != null) {
      await _speakLoopFuture;
    }
    playbackState.add(playbackState.value.copyWith(
      controls: [MediaControl.play, MediaControl.skipToNext, MediaControl.stop],
      playing: false,
    ));
    unawaited(_savePlaybackState(isPlaying: false));
  }

  @override
  Future<void> stop() async {
    _isSpeaking = false;
    await _tts.stop();
    // Đợi loop hiện tại exit.
    if (_speakLoopFuture != null) {
      await _speakLoopFuture;
    }
    _currentChunk = 0;
    playbackState.add(playbackState.value.copyWith(
      controls: const [],
      playing: false,
      processingState: AudioProcessingState.idle,
    ));
    unawaited(_savePlaybackState(isPlaying: false));
  }

  @override
  Future<void> skipToNext() => _onChapterComplete();

  /// Speak loop — drive chunk chaining qua while-loop với
  /// `awaitSpeakCompletion(true)`. Mỗi iteration:
  ///   1. Check _isSpeaking + bounds
  ///   2. Fire-and-forget save state (không block hot path)
  ///   3. Emit chunk progress
  ///   4. await _tts.speak(chunk) — resolve khi chunk xong
  ///   5. Check speak() return value — nếu != 1, surface error
  ///   6. Advance _currentChunk
  /// Loop exit khi: _isSpeaking = false (pause/stop), hoặc hết chunks
  /// (chapter complete → gọi _onChapterComplete).
  Future<void> _speakLoop() async {
    while (_isSpeaking && _currentChunk < _chunks.length) {
      final chunk = _chunks[_currentChunk];
      // Fire-and-forget — không block hot path giữa các chunk.
      unawaited(_savePlaybackState(isPlaying: true));
      _chunkProgressController.add(TtsChunkProgress(
        chapterId: _currentChapterId!,
        chunkIndex: _currentChunk,
        totalChunks: _chunks.length,
      ));
      AppLogger.info(
          'TTS: speaking chunk $_currentChunk/${_chunks.length} (${chunk.length} chars)');
      // speak() với awaitSpeakCompletion(true) resolve khi chunk xong.
      final result = await _tts.speak(chunk);
      // Check return value: 1 = success, 0 = failure (no voice, engine
      // not ready, text too long...). Trước đây ignore → TTS hang silently.
      if (result != 1) {
        AppLogger.error(
            'TTS: speak() returned $result for chunk $_currentChunk — engine rejected');
        _isSpeaking = false;
        playbackState.add(playbackState.value.copyWith(
          processingState: AudioProcessingState.error,
          errorMessage: 'TTS engine từ chối phát (result=$result). '
              'Có thể chưa cài giọng tiếng Việt — xem README mục TTS.',
        ));
        return;
      }
      // Stopped/paused trong lúc await speak() → exit.
      if (!_isSpeaking) return;
      _currentChunk++;
    }
    // Loop exit tự nhiên = hết chunks = chapter complete.
    if (_isSpeaking) {
      await _onChapterComplete();
    }
  }

  Future<void> _onChapterComplete() async {
    AppLogger.info('TTS: chapter complete');
    _isSpeaking = false;
    // Save state với chunk index cuối TRƯỚC khi stop() reset _currentChunk = 0.
    unawaited(_savePlaybackState(isPlaying: false));
    if (_currentStoryId != null && _currentChapterNumber != null) {
      await _progressService.markChapterRead(
        _currentStoryId!,
        _currentChapterNumber!,
      );
    }
    // Reset chunk index cho lần play tiếp theo.
    _currentChunk = 0;
    if (_speakLoopFuture != null) {
      await _speakLoopFuture;
    }
    playbackState.add(playbackState.value.copyWith(
      controls: const [],
      playing: false,
      processingState: AudioProcessingState.idle,
    ));
  }

  Future<void> _savePlaybackState({required bool isPlaying}) async {
    if (_currentChapterId == null) return;
    try {
      await _db.upsertTtsState(TtsPlaybackStateCompanion.insert(
        chapterId: _currentChapterId!,
        storyId: _currentStoryId ?? '',
        chapterNumber: _currentChapterNumber ?? 0,
        chunkIndex: Value(_currentChunk),
        isPlaying: Value(isPlaying ? 1 : 0),
        lastPlayedAt: Value(DateTime.now().toIso8601String()),
      ));
    } catch (e, s) {
      AppLogger.warning('TtsAudioHandler._savePlaybackState', e, s);
    }
  }
}

class TtsChunkProgress {
  const TtsChunkProgress({
    required this.chapterId,
    required this.chunkIndex,
    required this.totalChunks,
  });
  final String chapterId;
  final int chunkIndex;
  final int totalChunks;
}

/// Provider cho TtsAudioHandler. Nếu init fail, vẫn return handler nhưng
/// `_initialised` sẽ false → lần sau `loadChapter`/`play` gọi `_init()`
/// sẽ retry. UI có thể gọi `handler.reinit()` để retry thủ công.
final ttsHandlerProvider = FutureProvider<TtsAudioHandler>((ref) async {
  final db = ref.watch(appDatabaseProvider);
  final progress = ref.watch(readingProgressServiceProvider);
  final handler = TtsAudioHandler(db, progress);
  try {
    await AudioService.init(
      builder: () => handler,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.khongdich.app.tts',
        androidNotificationChannelName: 'Không Dịch — Đọc truyện',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
    await handler._init();
  } catch (e, s) {
    // Log warning nhưng vẫn return handler. _initialised vẫn false →
    // retry tự động khi user tap play lần tiếp theo. UI có thể gọi
    // handler.reinit() để retry thủ công.
    AppLogger.warning('ttsHandlerProvider: init failed (will retry on next use)', e, s);
  }
  return handler;
});
