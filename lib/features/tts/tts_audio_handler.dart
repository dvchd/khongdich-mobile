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
/// Supports voice selection, speed control (0.5x–2.5x), and per-chunk
/// progress reporting for text highlighting.
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

  // User settings (persisted)
  double _speed = 1.0; // 0.5 to 2.5
  String? _selectedVoiceName;

  // Available voices
  List<Map<String, String>> _availableVoices = [];

  /// Stream of the current chunk index for text highlighting.
  /// Emits (chapterId, chunkIndex, totalChunks) whenever the TTS
  /// advances to a new chunk.
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
      // Load persisted settings
      final prefs = await SharedPreferences.getInstance();
      _speed = prefs.getDouble('tts.speed') ?? 1.0;
      _selectedVoiceName = prefs.getString('tts.voice');

      // Check vi-VN availability
      final languages = await _tts.getLanguages;
      if (languages != null) {
        final hasVi = languages.any((l) =>
            l.toString().toLowerCase().startsWith('vi')) == true;
        if (!hasVi) {
          AppLogger.warning(
              'TTS: Vietnamese voice not found. Available: $languages');
        }
      }
      await _tts.setLanguage('vi-VN');
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      await _applySpeed();
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
          // Apply persisted voice
          if (_selectedVoiceName != null) {
            final voice = _availableVoices
                .where((v) => v['name'] == _selectedVoiceName)
                .firstOrNull;
            if (voice != null) {
              await _tts.setVoice(voice);
            }
          }
          AppLogger.info('TTS: ${_availableVoices.length} Vietnamese voices available');
        }
      } catch (e) {
        AppLogger.warning('TTS: getVoices failed', e);
      }

      _tts.setCompletionHandler(() async {
        _currentChunk++;
        _chunkProgressController.add(TtsChunkProgress(
          chapterId: _currentChapterId ?? '',
          chunkIndex: _currentChunk,
          totalChunks: _chunks.length,
        ));
        if (_currentChunk < _chunks.length) {
          await _speakCurrentChunk();
        } else {
          await _onChapterComplete();
        }
      });

      _tts.setErrorHandler((msg) {
        AppLogger.error('TTS error', msg);
        playbackState.add(playbackState.value.copyWith(
          processingState: AudioProcessingState.error,
          errorMessage: msg.toString(),
        ));
      });

      _tts.setCancelHandler(() {
        playbackState.add(playbackState.value.copyWith(
          processingState: AudioProcessingState.idle,
          playing: false,
        ));
      });
    } catch (e, s) {
      AppLogger.error('TtsAudioHandler._init failed', e, s);
    }
  }

  Future<void> _applySpeed() async {
    // flutter_tts Android: 0.0 = slowest, 1.0 = normal.
    // Map user-facing 0.5–2.5 → 0.0–1.0.
    final rate = ((_speed - 0.5) / 2.0).clamp(0.0, 1.0);
    await _tts.setSpeechRate(rate);
  }

  /// Set playback speed (0.5–2.5x). Persists to SharedPreferences.
  @override
  Future<void> setSpeed(double userSpeed) async {
    _speed = userSpeed.clamp(0.5, 2.5);
    await _applySpeed();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('tts.speed', _speed);
  }

  /// Set the voice by name. Persists to SharedPreferences.
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
    if (_currentChapterId == null || _chunks.isEmpty) return;
    await _init();
    playbackState.add(playbackState.value.copyWith(
      controls: [MediaControl.pause, MediaControl.skipToNext, MediaControl.stop],
      playing: true,
      processingState: AudioProcessingState.ready,
    ));
    // Emit initial progress
    _chunkProgressController.add(TtsChunkProgress(
      chapterId: _currentChapterId!,
      chunkIndex: _currentChunk,
      totalChunks: _chunks.length,
    ));
    await _speakCurrentChunk();
  }

  @override
  Future<void> pause() async {
    await _tts.stop();
    playbackState.add(playbackState.value.copyWith(
      controls: [MediaControl.play, MediaControl.skipToNext, MediaControl.stop],
      playing: false,
    ));
    await _savePlaybackState(isPlaying: false);
  }

  @override
  Future<void> stop() async {
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
    await _savePlaybackState(isPlaying: true);
    _chunkProgressController.add(TtsChunkProgress(
      chapterId: _currentChapterId!,
      chunkIndex: _currentChunk,
      totalChunks: _chunks.length,
    ));
    await _tts.speak(_chunks[_currentChunk]);
  }

  Future<void> _onChapterComplete() async {
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

/// Emitted on every chunk boundary for text highlighting.
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
