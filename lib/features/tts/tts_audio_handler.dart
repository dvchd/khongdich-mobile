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

  // Available voices
  List<Map<String, String>> _availableVoices = [];

  final _chunkProgressController =
      StreamController<TtsChunkProgress>.broadcast();
  Stream<TtsChunkProgress> get chunkProgress => _chunkProgressController.stream;

  double get speed => _speed;
  List<Map<String, String>> get availableVoices => _availableVoices;
  String? get selectedVoiceName => _selectedVoiceName;

  Future<void> _init() async {
    if (_initialised) return;
    _initialised = true;
    try {
      AppLogger.info('TTS: starting init...');

      // Load persisted settings
      final prefs = await SharedPreferences.getInstance();
      _speed = prefs.getDouble('tts.speed') ?? 1.0;
      _selectedVoiceName = prefs.getString('tts.voice');

      // On Android, set the TTS engine explicitly to ensure it's ready.
      // The default engine is usually "com.google.android.tts".
      if (!identical(0, 0.0)) {
        // This is a hack to ensure we're on Android — the check
        // `Platform.isAndroid` requires dart:io which we avoid in
        // this file for web compatibility. The flutter_tts plugin
        // handles platform detection internally.
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

      // Load available voices
      try {
        final voices = await _tts.getVoices;
        if (voices != null) {
          _availableVoices = (voices as List)
              .map((v) => Map<String, String>.from(v as Map))
              .where((v) =>
                  (v['locale'] ?? v['language'] ?? '')
                      .toLowerCase()
                      .startsWith('vi'))
              .toList();
          if (_selectedVoiceName != null) {
            final voice = _availableVoices
                .where((v) => v['name'] == _selectedVoiceName)
                .firstOrNull;
            if (voice != null) {
              await _tts.setVoice(voice);
            }
          }
          AppLogger.info(
              'TTS: ${_availableVoices.length} Vietnamese voices available');
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
