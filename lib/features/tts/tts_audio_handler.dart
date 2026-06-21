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
/// Plan §9 — 100% on-device. Wraps `flutter_tts` inside `audio_service`.
///
/// **Key architecture notes:**
///
/// 1. `flutter_tts` is a **fire-and-forget** API on Android. `speak()`
///    returns immediately — the completion is reported via the
///    `setCompletionHandler` callback, NOT via the Future. We must
///    NOT await `speak()` expecting it to block until speech is done.
///    Instead, we use `awaitSpeakCompletion(true)` which makes the
///    Future resolve on completion, but the completion handler still
///    fires regardless.
///
/// 2. `audio_service` wraps our handler so Android treats it as a
///    foreground media service. The `playbackState` stream drives
///    the notification shade + the mini player UI.
///
/// 3. Chunks: `TtsMarkdownPreprocessor.process()` splits markdown into
///    ~500-char plain-text chunks. We speak them sequentially. The
///    completion handler advances to the next chunk.
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

  Future<void> _init() async {
    if (_initialised) return;
    _initialised = true;
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

      // Set language FIRST — this is critical. If the language is not
      // available, speak() will silently fail.
      final langResult = await _tts.setLanguage('vi-VN');
      AppLogger.info('TTS: setLanguage(vi-VN) → $langResult');

      // If setLanguage returned 0 (success) or 1 (already set), we're good.
      // If it returned -1 (not available) or -2 (language missing), try
      // falling back to English so at least something is heard.
      if (langResult == -1 || langResult == -2) {
        AppLogger.warning('TTS: vi-VN not available, trying en-US fallback');
        await _tts.setLanguage('en-US');
      }

      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      await _applySpeed();

      // CRITICAL: awaitSpeakCompletion(true) makes the speak() Future
      // resolve when the utterance is done. Without this, speak()
      // resolves immediately and our chunk chaining breaks.
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
          if (_selectedVoiceName != null) {
            final voice = _availableVoices
                .where((v) => v['name'] == _selectedVoiceName)
                .firstOrNull;
            if (voice != null) {
              await _tts.setVoice(voice);
            }
          }
        }
      } catch (e) {
        AppLogger.warning('TTS: getVoices failed', e);
      }

      // Completion handler — fires when a chunk finishes speaking.
      // This is the main driver of chunk chaining.
      _tts.setCompletionHandler(() {
        AppLogger.info('TTS: completion handler fired (chunk $_currentChunk)');
        if (!_isSpeaking) return; // Guard: ignore if we've stopped
        _currentChunk++;
        _chunkProgressController.add(TtsChunkProgress(
          chapterId: _currentChapterId ?? '',
          chunkIndex: _currentChunk,
          totalChunks: _chunks.length,
        ));
        if (_currentChunk < _chunks.length) {
          _speakCurrentChunk(); // Fire-and-forget — don't await
        } else {
          _onChapterComplete(); // Fire-and-forget
        }
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

      AppLogger.info('TTS: init complete');
    } catch (e, s) {
      AppLogger.error('TtsAudioHandler._init failed', e, s);
    }
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
    // Start speaking — don't await. The completion handler will chain
    // to the next chunk.
    await _speakCurrentChunk();
  }

  @override
  Future<void> pause() async {
    _isSpeaking = false;
    await _tts.stop();
    playbackState.add(playbackState.value.copyWith(
      controls: [MediaControl.play, MediaControl.skipToNext, MediaControl.stop],
      playing: false,
    ));
    await _savePlaybackState(isPlaying: false);
  }

  @override
  Future<void> stop() async {
    _isSpeaking = false;
    await _tts.stop();
    _currentChunk = 0;
    playbackState.add(playbackState.value.copyWith(
      controls: const [],
      playing: false,
      processingState: AudioProcessingState.idle,
    ));
    await _savePlaybackState(isPlaying: false);
  }

  @override
  Future<void> skipToNext() => _onChapterComplete();

  Future<void> _speakCurrentChunk() async {
    if (_currentChunk >= _chunks.length) return;
    if (!_isSpeaking) return;
    await _savePlaybackState(isPlaying: true);
    _chunkProgressController.add(TtsChunkProgress(
      chapterId: _currentChapterId!,
      chunkIndex: _currentChunk,
      totalChunks: _chunks.length,
    ));
    final chunk = _chunks[_currentChunk];
    AppLogger.info(
        'TTS: speaking chunk $_currentChunk/${_chunks.length} (${chunk.length} chars)');
    // speak() with awaitSpeakCompletion(true) will resolve when done.
    // The completion handler also fires. Both are safe — the handler
    // has a _isSpeaking guard.
    await _tts.speak(chunk);
  }

  Future<void> _onChapterComplete() async {
    AppLogger.info('TTS: chapter complete');
    _isSpeaking = false;
    if (_currentStoryId != null && _currentChapterNumber != null) {
      await _progressService.markChapterRead(
        _currentStoryId!,
        _currentChapterNumber!,
      );
    }
    await stop();
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
    AppLogger.warning('ttsHandlerProvider: AudioService.init failed', e, s);
  }
  return handler;
});
