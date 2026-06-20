import 'package:audio_service/audio_service.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../../core/database/app_database.dart';
import '../../core/markdown/markdown.dart';
import '../../core/observability/app_logger.dart';
import '../reader/services/reading_progress_service.dart';

/// Foreground-service-backed TTS player for Không Dịch.
///
/// Plan §9 — 100% on-device, no server round-trips. Wraps `flutter_tts`
/// inside `audio_service` so playback survives screen lock + background
/// and exposes a [MediaItem] to the Android notification shade.
///
/// Only `content_type=text` chapters are TTS-eligible; manga/chat/video
/// are skipped (plan §9.1).
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

  Future<void> _init() async {
    if (_initialised) return;
    _initialised = true;
    try {
      // Check if vi-VN is available. On Android, the Google TTS engine
      // may not have Vietnamese installed — log a warning but don't
      // crash. The user will hear silence if no vi-VN voice exists.
      final languages = await _tts.getLanguages;
      if (languages != null) {
        final hasVi = languages.any((l) =>
            l.toString().toLowerCase().startsWith('vi')) == true;
        if (!hasVi) {
          AppLogger.warning(
              'TTS: Vietnamese voice not found. Available: $languages');
          // Try to set it anyway — some engines accept it and fall back.
        }
      }
      await _tts.setLanguage('vi-VN');
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      // Android speech rate: 0.0 = slowest, 1.0 = normal, 2.0 = fastest.
      // Default to 1.0 (normal speed). The old 0.5 was too slow.
      await _tts.setSpeechRate(1.0);
      await _tts.awaitSpeakCompletion(true);

      _tts.setCompletionHandler(() async {
        _currentChunk++;
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

  /// Load a text-content chapter into the TTS queue. Idempotent — calling
  /// twice with the same chapter just resets the chunk pointer.
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

    // Restore position if we have a saved chunk index.
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
      controls: [
        MediaControl.pause,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      playing: true,
      processingState: AudioProcessingState.ready,
    ));
    await _speakCurrentChunk();
  }

  @override
  Future<void> pause() async {
    await _tts.stop();
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
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

  /// Set TTS playback speed. Renames `speed` to match the parent class.
  @override
  Future<void> setSpeed(double speed) async {
    await _tts.setSpeechRate(_mapSpeedToRate(speed));
  }

  Future<void> _speakCurrentChunk() async {
    if (_currentChunk >= _chunks.length) return;
    await _savePlaybackState(isPlaying: true);
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

  /// Map 0.5×–2.0× user speed → flutter_tts speech rate (0.0–1.0).
  /// Android and iOS use different scales; we normalise to Android.
  double _mapSpeedToRate(double userSpeed) {
    return ((userSpeed - 0.5) / 1.5).clamp(0.0, 1.0);
  }
}

/// Singleton [TtsAudioHandler]. The handler is initialised lazily on the
/// first call to [TtsController.play]; until then it's just a thin
/// holder so the UI can read [playbackState].
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
    // Pre-initialise the TTS engine so the first play() call is fast.
    await handler._init();
  } catch (e, s) {
    AppLogger.warning('ttsHandlerProvider: AudioService.init failed', e, s);
    // Return the handler anyway — play() will try _init() again.
  }
  return handler;
});
