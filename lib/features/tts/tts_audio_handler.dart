import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/database/app_database.dart';
import '../../core/markdown/markdown.dart';
import '../../core/observability/app_logger.dart';
import '../../core/utils/notification_permission.dart';
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
  List<TtsChunk> _chunks = const [];
  int _currentChunk = 0;
  String? _currentChapterId;
  String? _currentStoryId;
  String? _currentStorySlug;
  int? _currentChapterNumber;
  int? _nextChapterNumber;
  bool _initialised = false;
  bool _isSpeaking = false; // Guard against re-entrant completion handlers
  // Future của speak loop hiện tại — dùng để cancel khi stop/pause.
  Future<void>? _speakLoopFuture;
  // Generation guard chống "zombie loop": một số engine không bao giờ
  // resolve `speak()` sau khi bị stop() giữa chừng → loop cũ treo vĩnh
  // viễn. Khi pause/stop/restart, ta tăng generation — loop cũ (nếu sau
  // này mới thức dậy) thấy generation lệch là thoát NGAY, không đụng vào
  // state, không phát âm thanh song song với loop mới.
  int _loopGeneration = 0;
  // Timers cho các sự kiện highlight trung gian TRONG một chunk (chunk
  // có thể chứa nhiều block ngắn — timers advance highlight qua từng
  // block tỷ lệ theo độ dài chữ). Cancel khi chunk xong / pause / stop.
  final List<Timer> _blockAdvanceTimers = [];

  /// Auto-advance: reader screens bật khi user chạm headphone — hết chương
  /// là tự chuyển chương kế + tự play tiếp. Nút Stop trong control panel
  /// (hoặc [stopAutoAdvance]) tắt chuỗi này; pause KHÔNG tắt (resume vẫn
  /// tiếp tục chuỗi).
  bool autoAdvanceEnabled = false;

  /// Đang restart loop để áp dụng tốc độ/giọng mới ngay lập tức —
  /// cancel/error handler check cờ này để không nhầm thành user stop.
  bool _restartPending = false;

  /// Skip thủ công từ notification/panel → vẫn chuyển chương kể cả khi
  /// autoAdvanceEnabled = false.
  bool _manualSkipPending = false;

  /// Phát khi TTS đọc xong một chương (tự nhiên HOẶC skip thủ công).
  /// Reader screens listen để chuyển chương + auto-load chương kế —
  /// design này thay callback `onChapterComplete` cũ: callback bị ghi đè
  /// bởi màn hình mới nhất và không có cách nào biết màn hình nào sở hữu
  /// nó → auto-advance đứt chuỗi hoặc navigate nhầm màn hình.
  final _chapterCompleteController =
      StreamController<TtsChapterCompleteEvent>.broadcast();
  Stream<TtsChapterCompleteEvent> get onChapterCompleted =>
      _chapterCompleteController.stream;

  // Audio session state — request/release audio focus để TTS không đè
  // lên nhạc/video đang phát và tự dừng khi có cuộc gọi/âm thanh khác.
  bool _sessionConfigured = false;

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

  /// Story slug + next chapter number — set bởi reader screen khi load
  /// chapter, để TTS có thể tự chuyển chương khi đọc xong.
  String? get currentStorySlug => _currentStorySlug;
  int? get nextChapterNumber => _nextChapterNumber;

  /// Read-only access to the chunk list of the currently-loaded chapter.
  /// Used by the reader to map chunk index → markdown block for highlight
  /// + auto-scroll. Returns an empty list when no chapter is loaded.
  List<String> get chunks => [for (final c in _chunks) c.text];

  /// Block-aligned chunk models of the currently-loaded chapter (the same
  /// length as [chunks]). Each entry carries the exact rendered-block
  /// indices the chunk covers.
  List<TtsChunk> get chunkModels => List.unmodifiable(_chunks);

  /// Index of the chunk currently being spoken. -1 when idle.
  int get currentChunkIndex => _currentChunk;

  /// Configure the audio session once (speech attributes + audio focus
  /// gain) và đăng ký interruption listener để tự pause khi có cuộc gọi
  /// hoặc ứng dụng khác chiếm quyền phát. Best-effort — mọi lỗi đều log
  /// warning, không bao giờ throw vào playback path.
  Future<void> _configureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      if (!_sessionConfigured) {
        await session.configure(const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playback,
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.speech,
            usage: AndroidAudioUsage.media,
          ),
          androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
          androidWillPauseWhenDucked: false,
        ));
        _sessionConfigured = true;
        // Auto-pause khi bị interruption (cuộc gọi, nhạc khác, ...).
        session.interruptionEventStream.listen((event) {
          if (!event.begin) return;
          AppLogger.info('TTS: interruption begin (${event.type.name})');
          if (event.type == AudioInterruptionType.duck) {
            // Duck → tiếp tục đọc nhỏ hơn là dừng; nhưng để an toàn với
            // speech thì pause rồi user bấm play tiếp.
          }
          unawaited(pause());
        });
      }
    } catch (e, s) {
      AppLogger.warning('TTS: audio session configure failed', e, s);
    }
  }

  /// Request audio focus trước khi bắt đầu đọc. Best-effort.
  Future<void> _activateAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.setActive(true);
    } catch (e, s) {
      AppLogger.warning('TTS: audio session activate failed', e, s);
    }
  }

  /// Release audio focus khi tạm dừng/dừng đọc. Best-effort.
  Future<void> _deactivateAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.setActive(false);
    } catch (e, s) {
      AppLogger.warning('TTS: audio session deactivate failed', e, s);
    }
  }

  Future<void>? _initFuture;

  /// Init guard — loadChapter/play/reinit có thể gọi _init đồng thời
  /// (vd. bấm "Thử lại" trong lúc đang play). Trước đây mỗi call chạy
  /// riêng một init → duplicate setEngine/getVoices race. Memoize
  /// in-flight future và retry lại sau nếu fail (never cached fail).
  Future<void> _init() {
    if (_initialised) return Future.value();
    return _initFuture ??= _doInit().whenComplete(() {
      _initFuture = null;
    });
  }

  Future<void> _doInit() async {
    try {
      AppLogger.info('TTS: starting init...');

      await _configureAudioSession();

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
            'TTS: ${_availableEngines.length} engines available: $_availableEngines',
          );

          final desired = _selectedEngine ?? defaultEngine?.toString();
          if (desired != null && _availableEngines.contains(desired)) {
            final setResult = await _tts.setEngine(desired);
            AppLogger.info('TTS: setEngine($desired) → $setResult');
            _selectedEngine = desired;
          } else if (_availableEngines.isNotEmpty) {
            // Fall back to first available engine. Đồng thời clear
            // _selectedEngine nếu giá trị cũ không còn tồn tại — nếu
            // không, control panel dùng value này cho DropdownButton
            // trong khi nó không nằm trong items → assertion crash.
            final setResult = await _tts.setEngine(_availableEngines.first);
            AppLogger.info(
              'TTS: setEngine(${_availableEngines.first}) fallback → $setResult',
            );
            _selectedEngine = _availableEngines.first;
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
          'voice tiếng Việt thủ công qua dropdown nếu engine support.',
        );
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
          AppLogger.info('TTS: ${_availableVoices.length} voices available');
          // Log first 5 Vietnamese voices để debug.
          final viVoices = _availableVoices
              .where(
                (v) => (v['locale'] ?? v['language'] ?? '')
                    .toLowerCase()
                    .startsWith('vi'),
              )
              .toList();
          AppLogger.info(
            'TTS: ${viVoices.length} Vietnamese voices: ${viVoices.take(3).map((v) => "${v['name']} (${v['locale'] ?? v['language']})").toList()}',
          );
          if (_selectedVoiceName != null) {
            final voice = _availableVoices
                .where((v) => v['name'] == _selectedVoiceName)
                .firstOrNull;
            if (voice != null) {
              await _tts.setVoice(voice);
              AppLogger.info('TTS: setVoice(${voice['name']}) → ok');
            } else {
              // Voice đã lưu không còn tồn tại trên engine hiện tại
              // (đổi engine, gỡ giọng...). Clear giá trị — nếu giữ
              // nguyên, control panel dùng nó cho DropdownButton trong
              // khi không nằm trong items → assertion crash.
              AppLogger.warning(
                'TTS: saved voice "$_selectedVoiceName" not found in current engine — clearing',
              );
              _selectedVoiceName = null;
              final prefs = await SharedPreferences.getInstance();
              await prefs.remove('tts.voice');
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
              'TTS: auto-selected Vietnamese voice ${voice['name']} (${voice['locale'] ?? voice['language']})',
            );
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
        playbackState.add(
          playbackState.value.copyWith(
            processingState: AudioProcessingState.error,
            errorMessage: msg.toString(),
          ),
        );
        // Force the pending speak() Future to resolve: một số engine
        // không bao giờ resolve speak() sau khi lỗi → loop treo vĩnh
        // viễn → pause/stop/loadChapter await _speakLoopFuture cũng treo
        // (TTS deadlock cho tới khi restart app). stop() là best-effort.
        try {
          _tts.stop();
        } catch (e) {
          AppLogger.warning('TTS: stop after error failed', e);
        }
      });

      _tts.setCancelHandler(() {
        AppLogger.info('TTS: cancel handler fired');
        // Đang restart để đổi tốc độ/giọng — đừng coi là user stop,
        // giữ nguyên trạng thái "đang phát" cho UI (loop mới sẽ chạy
        // lại ngay sau đó).
        if (_restartPending) return;
        _isSpeaking = false;
        playbackState.add(
          playbackState.value.copyWith(
            processingState: AudioProcessingState.idle,
            playing: false,
          ),
        );
      });

      // Chỉ set _initialised = true ở CUỐI try block. Nếu bất kỳ bước
      // nào throw, _initialised vẫn false → lần sau _init() sẽ retry.
      _initialised = true;
      AppLogger.info('TTS: init complete');
    } catch (e, s) {
      // Init failed — _initialised vẫn false, retry sẽ chạy lại lần sau.
      AppLogger.error(
        'TtsAudioHandler._init failed (will retry on next call)',
        e,
        s,
      );
    }
  }

  /// Retry init từ UI (vd: user bấm "Thử lại" khi TTS fail).
  /// Reset _initialised = false rồi gọi _init().
  Future<void> reinit() async {
    _initialised = false;
    await _init();
  }

  /// Await the speak loop defensively — nếu loop Future có lỗi (lý
  /// thuyết không thể sau các try/catch trong _speakLoop, nhưng phòng
  /// thủ) thì không rethrow vào UI caller.
  ///
  /// Có timeout: một số engine không resolve `speak()` sau khi stop
  /// giữa chừng → await vô hạn. Sau timeout ta bỏ rơi future cũ — loop
  /// cũ có bị "zombie" cũng vô hại nhờ generation guard.
  Future<void> _awaitSpeakLoop() async {
    final f = _speakLoopFuture;
    if (f == null) return;
    try {
      await f.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      AppLogger.warning(
          'TTS: speak loop did not exit after stop — proceeding (generation guard active)');
      if (identical(_speakLoopFuture, f)) {
        _speakLoopFuture = null;
      }
    } catch (e) {
      AppLogger.warning('TTS: speak loop future errored (ignored)', e);
      if (identical(_speakLoopFuture, f)) {
        _speakLoopFuture = null;
      }
    }
  }

  /// Vô hiệu hoá loop đang chạy (pause/stop/restart/skip gọi trước khi
  /// stop engine). Zombie loop sau này thức dậy sẽ thoát nhờ generation.
  void _invalidateSpeakLoop() {
    _loopGeneration++;
    _isSpeaking = false;
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
    // Android TTS chỉ áp rate mới cho các utterance MỚI — chunk hiện tại
    // (có thể 30-40s) vẫn chạy tốc độ cũ. Restart loop từ đầu chunk hiện
    // tại để tốc độ mới có hiệu lực NGAY LẬP TỨC, không cần stop+play.
    unawaited(_restartSpeakLoop());
  }

  /// Restart speak loop từ đầu chunk hiện tại — dùng khi user đổi tốc độ/
  /// giọng/engine giữa chừng. Android TextToSpeech không áp setting mới
  /// cho utterance đang đọc nên phải stop + speak lại chunk đó.
  Future<void> _restartSpeakLoop() async {
    if (!_isSpeaking) return;
    if (_currentChapterId == null || _chunks.isEmpty) return;
    _restartPending = true;
    _invalidateSpeakLoop();
    _cancelBlockAdvanceTimer();
    try {
      await _tts.stop();
    } catch (e) {
      AppLogger.warning('TTS: stop during restart failed', e);
    }
    await _awaitSpeakLoop();
    // User có thể đã stop/pause/loadChapter khác trong lúc chờ loop cũ
    // thoát → không tự ý phát lại.
    if (!_restartPending) return;
    _restartPending = false;
    if (_currentChapterId == null || _chunks.isEmpty) return;
    if (_speakLoopFuture != null) return;
    _isSpeaking = true;
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.pause,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        playing: true,
        processingState: AudioProcessingState.ready,
      ),
    );
    _chunkProgressController.add(_chunkProgressEvent(_currentChunk));
    _launchSpeakLoop();
  }

  /// Chạy speak loop mới + đăng ký whenComplete với identical-guard:
  /// nếu loop CŨ (zombie — engine resolve speak() muộn sau khi bị stop)
  /// hoàn thành sau khi loop MỚI đã khởi động, nó không được null mất
  /// reference của loop mới (sẽ làm pause/stop tưởng không có loop và
  /// play() khởi động loop thứ ba song song).
  void _launchSpeakLoop() {
    final f = _speakLoop();
    _speakLoopFuture = f;
    unawaited(
      f.whenComplete(() {
        if (identical(_speakLoopFuture, f)) {
          _speakLoopFuture = null;
        }
      }),
    );
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
    // Giọng mới cũng chỉ áp cho utterance mới → restart chunk hiện tại.
    unawaited(_restartSpeakLoop());
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
    // ⚠️ Issue #331: setEngine() re-instantiates native TextToSpeech
    // which initializes ASYNC. getVoices returns empty if called too
    // soon. Delay 500ms to let native TTS finish init.
    _selectedVoiceName = null;
    await prefs.remove('tts.voice');
    await Future.delayed(const Duration(milliseconds: 500));
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
    String? storySlug,
    int? nextChapterNumber,
  }) async {
    await _init();
    _restartPending = false;
    // Stop mọi playback đang chạy của chương cũ trước khi load chương mới.
    // Trước đây không có bước này → completion handler của chương cũ có
    // thể fire sau khi chương mới đã load, gây _currentChunk sai.
    if (_isSpeaking) {
      _invalidateSpeakLoop();
      await _tts.stop();
    }
    // Await the old speak loop to fully exit before loading the new
    // chapter. Without this, the old loop (still in `await _tts.speak()`)
    // may continue running after we set new `_chunks`/`_currentChunk`,
    // causing play() to return early (loop already running) or the old
    // loop to advance into the new chapter's chunks with stale state.
    await _awaitSpeakLoop();
    _cancelBlockAdvanceTimer();
    _chunks = TtsMarkdownPreprocessor.processWithBlocks(contentMarkdown);
    AppLogger.info('TTS: loaded chapter $chapterId — ${_chunks.length} chunks');
    _currentChapterId = chapterId;
    _currentStoryId = storyId;
    _currentStorySlug = storySlug;
    _currentChapterNumber = chapterNumber;
    _nextChapterNumber = nextChapterNumber;

    final state = await _db.getTtsState(chapterId);
    _currentChunk = state?.chunkIndex ?? 0;
    if (_currentChunk >= _chunks.length) _currentChunk = 0;

    // Reset error state từ chương cũ — trước đây error banner (errorMessage)
    // dính mãi trong control panel khi load chương khác sau một lỗi.
    playbackState.add(
      playbackState.value.copyWith(
        processingState: AudioProcessingState.idle,
        errorMessage: null,
        errorCode: null,
      ),
    );

    mediaItem.add(
      MediaItem(
        id: chapterId,
        album: storyTitle,
        title: chapterTitle,
        artist: storyTitle,
        duration: Duration(seconds: _chunks.length * 30),
      ),
    );
  }

  @override
  Future<void> play() async {
    if (_currentChapterId == null || _chunks.isEmpty) {
      AppLogger.warning('TTS: play() called but no chapter loaded');
      // Surface error để user biết thay vì silent return.
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.error,
          errorMessage:
              'Chưa load được chương để đọc. '
              'Thử mở lại chương rồi bấm headphone.',
        ),
      );
      return;
    }
    await _init();
    // Nếu init vẫn fail (vd: engine không có giọng tiếng Việt), _initialised
    // sẽ false. Surface error thay vì cố play → fail silently.
    if (!_initialised) {
      AppLogger.error('TTS: play() aborted — init failed, _initialised=false');
      playbackState.add(
        playbackState.value.copyWith(
          processingState: AudioProcessingState.error,
          errorMessage:
              'Không khởi tạo được TTS engine. '
              'Kiểm tra Google TTS engine + giọng tiếng Việt trong Android '
              'Settings → Text-to-speech. Sau đó bấm "Thử lại".',
        ),
      );
      return;
    }
    // Request audio focus (không đè nhạc/video khác đang phát).
    await _activateAudioSession();
    // Android 13+: nếu chưa cấp POST_NOTIFICATIONS, notification của
    // foreground service (thanh quản lý audio) bị hệ thống ẩn — xin
    // quyền trước khi phát. Best-effort, không block hot path.
    unawaited(NotificationPermission.request());
    // Check if the loop is already running BEFORE setting _isSpeaking.
    // If we set _isSpeaking first and then return, the guard works but
    // the ordering is confusing — _isSpeaking would be true even though
    // we didn't actually start anything new. Checking the loop future
    // first makes the intent clear: if a loop is running, play() is a
    // no-op regardless of _isSpeaking.
    if (_speakLoopFuture != null) {
      // Loop cũ đang chạy — không cần start lại.
      return;
    }
    _isSpeaking = true;
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.pause,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        playing: true,
        processingState: AudioProcessingState.ready,
      ),
    );
    _chunkProgressController.add(
      _chunkProgressEvent(_currentChunk),
    );
    // _launchSpeakLoop: whenComplete với identical-guard — loop cũ
    // (zombie) hoàn thành muộn không được null mất future của loop mới.
    _launchSpeakLoop();
  }

  @override
  Future<void> pause() async {
    _restartPending = false;
    _invalidateSpeakLoop();
    _cancelBlockAdvanceTimer();
    await _tts.stop();
    // Đợi loop hiện tại exit (nó sẽ exit do _isSpeaking = false).
    await _awaitSpeakLoop();
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        playing: false,
      ),
    );
    unawaited(_savePlaybackState(isPlaying: false));
    unawaited(_deactivateAudioSession());
  }

  @override
  Future<void> stop() async {
    _restartPending = false;
    _invalidateSpeakLoop();
    _cancelBlockAdvanceTimer();
    await _tts.stop();
    // Đợi loop hiện tại exit.
    await _awaitSpeakLoop();
    // Save playback state TRƯỚC khi reset _currentChunk = 0 — trước đây
    // reset trước rồi mới save nên vị trí nghe (chunk index) của chương
    // bị ghi đè thành 0 mỗi lần stop (kể cả stop khi chuyển chương) →
    // mở lại chương luôn bắt đầu từ chunk 0 thay vì tiếp tục vị trí cũ.
    unawaited(_savePlaybackState(isPlaying: false));
    _currentChunk = 0;
    playbackState.add(
      playbackState.value.copyWith(
        controls: const [],
        playing: false,
        processingState: AudioProcessingState.idle,
      ),
    );
    unawaited(_deactivateAudioSession());
  }

  @override
  Future<void> skipToNext() async {
    // Guard: không có gì đang phát (hoặc không có chương kế) → bỏ qua
    // thay vì đánh dấu chương đã đọc mà user chưa nghe.
    if (_currentChapterId == null || _chunks.isEmpty) return;
    // Dừng utterance hiện tại trước — trước đây skipToNext chỉ gọi
    // _onChapterComplete(): loop cũ còn chạy tới khi chunk hiện tại
    // (có thể 40-50s) đọc xong mới thoát, trong khi UI đã báo "idle"
    // và loadChapter của chương mới phải await _speakLoopFuture →
    // chuyển chương treo hàng chục giây + audio vẫn phát chương cũ.
    if (_isSpeaking) {
      _invalidateSpeakLoop();
      _cancelBlockAdvanceTimer();
      try {
        await _tts.stop();
      } catch (e) {
        AppLogger.warning('TTS: skipToNext stop failed', e);
      }
      await _awaitSpeakLoop();
    }
    _manualSkipPending = true;
    await _onChapterComplete();
  }

  /// Dừng hẳn + tắt chuỗi auto-advance — nút Stop trong control panel.
  /// (`stop()` thường được gọi nội bộ khi chuyển chương nên không được
  /// tự ý tắt auto-advance ở đó.)
  Future<void> stopAutoAdvance() async {
    autoAdvanceEnabled = false;
    await stop();
  }

  /// Speak loop — drive chunk chaining qua while-loop với
  /// `awaitSpeakCompletion(true)`. Mỗi iteration:
  ///   1. Check _isSpeaking + bounds
  ///   2. Fire-and-forget save state (không block hot path)
  ///   3. Emit chunk progress (kèm block index chính xác)
  ///   4. Lên lịch advance highlight qua từng block trong chunk (nếu
  ///      chunk gộp nhiều block ngắn) tỷ lệ theo độ dài chữ
  ///   5. await _tts.speak(chunk) — resolve khi chunk xong
  ///   6. Check speak() return value — nếu != 1, surface error
  ///   7. Advance _currentChunk
  /// Loop exit khi: _isSpeaking = false (pause/stop), hoặc hết chunks
  /// (chapter complete → gọi _onChapterComplete).
  Future<void> _speakLoop() async {
    // Capture generation — mọi _invalidateSpeakLoop() (pause/stop/restart/
    // skip) tăng generation → loop này thành "zombie" và phải thoát ngay
    // khi thức dậy, không được chạm state hay phát thêm âm thanh.
    final gen = _loopGeneration;
    while (_isSpeaking && gen == _loopGeneration && _currentChunk < _chunks.length) {
      final chunk = _chunks[_currentChunk];
      // Fire-and-forget — không block hot path giữa các chunk.
      unawaited(_savePlaybackState(isPlaying: true));
      _chunkProgressController.add(_chunkProgressEvent(_currentChunk));
      _scheduleBlockAdvance(chunk);
      AppLogger.info(
        'TTS: speaking chunk $_currentChunk/${_chunks.length} (${chunk.text.length} chars)',
      );
      // speak() với awaitSpeakCompletion(true) resolve khi chunk xong.
      // Bọc try/catch: nếu engine throw thay vì return, loop phải kết
      // thúc có kiểm soát + surface error — trước đây lỗi này thoát ra
      // khỏi Future của loop (unhandled async error) và khiến
      // _speakLoopFuture không bao giờ được null (TTS brick vĩnh viễn).
      int result;
      try {
        // flutter_tts trả dynamic (int trên Android) — cast an toàn.
        final raw = await _tts.speak(chunk.text);
        result = (raw is int) ? raw : int.tryParse('$raw') ?? 0;
      } catch (e, s) {
        AppLogger.error('TTS: speak() threw for chunk $_currentChunk', e, s);
        if (gen != _loopGeneration) return; // zombie loop
        _isSpeaking = false;
        playbackState.add(
          playbackState.value.copyWith(
            processingState: AudioProcessingState.error,
            errorMessage: 'TTS engine lỗi khi đọc: $e',
          ),
        );
        return;
      }
      // Bị stop/restart trong lúc await speak() → zombie loop, thoát.
      if (gen != _loopGeneration) return;
      _cancelBlockAdvanceTimer();
      // Check return value: 1 = success, 0 = failure (no voice, engine
      // not ready, text too long...). Trước đây ignore → TTS hang silently.
      if (result != 1) {
        AppLogger.error(
          'TTS: speak() returned $result for chunk $_currentChunk — engine rejected',
        );
        _isSpeaking = false;
        playbackState.add(
          playbackState.value.copyWith(
            processingState: AudioProcessingState.error,
            errorMessage:
                'TTS engine từ chối phát (result=$result). '
                'Có thể chưa cài giọng tiếng Việt — xem README mục TTS.',
          ),
        );
        return;
      }
      // Stopped/paused trong lúc await speak() → exit.
      if (!_isSpeaking) return;
      _currentChunk++;
    }
    // Loop exit tự nhiên = hết chunks = chapter complete.
    if (_isSpeaking && gen == _loopGeneration) {
      await _onChapterComplete();
    }
  }

  /// Build the progress event for chunk [chunkIndex]. Carries the exact
  /// rendered-block index where the chunk starts (the reader highlights
  /// it directly — no fuzzy text matching).
  TtsChunkProgress _chunkProgressEvent(int chunkIndex) {
    final blocks = _chunks[chunkIndex].blocks;
    return TtsChunkProgress(
      chapterId: _currentChapterId!,
      chunkIndex: chunkIndex,
      totalChunks: _chunks.length,
      blockIndex: blocks.isEmpty ? -1 : blocks.first.blockIndex,
    );
  }

  /// A chunk may bundle several short blocks (dialogue lines etc.).
  /// flutter_tts reports no per-word progress, so we approximate: each
  /// block inside the chunk gets its own highlight event, scheduled
  /// proportionally to its share of the chunk's characters at the
  /// current speech speed. Drift is at most a few seconds and resets at
  /// every chunk boundary (where we emit the exact position).
  ///
  /// Estimated Vietnamese TTS rate: ~12 chars/s at 1×.
  void _scheduleBlockAdvance(TtsChunk chunk) {
    _cancelBlockAdvanceTimer();
    final parts = chunk.blocks;
    if (parts.length < 2) return;
    final totalChars = chunk.text.length;
    if (totalChars == 0) return;
    final rate = 12.0 * _speed;
    var elapsed = Duration.zero;
    for (var i = 1; i < parts.length; i++) {
      final prev = parts[i - 1];
      elapsed += Duration(
        milliseconds: (prev.text.length / rate * 1000).round(),
      );
      final blockIndex = parts[i].blockIndex;
      _blockAdvanceTimers.add(Timer(elapsed, () {
        if (!_isSpeaking) return;
        _chunkProgressController.add(
          TtsChunkProgress(
            chapterId: _currentChapterId!,
            chunkIndex: _currentChunk,
            totalChunks: _chunks.length,
            blockIndex: blockIndex,
          ),
        );
      }));
    }
  }

  void _cancelBlockAdvanceTimer() {
    for (final t in _blockAdvanceTimers) {
      t.cancel();
    }
    _blockAdvanceTimers.clear();
  }

  Future<void> _onChapterComplete() async {
    AppLogger.info('TTS: chapter complete');
    _restartPending = false;
    _isSpeaking = false;
    _cancelBlockAdvanceTimer();
    // Release audio focus — chapter đã xong, không cần giữ nữa.
    unawaited(_deactivateAudioSession());
    // Save state với chunk index cuối TRƯỚC khi reset _currentChunk = 0.
    unawaited(_savePlaybackState(isPlaying: false));
    // markChapterRead ghi DB local — bọc try/catch để lỗi không thoát
    // ra ngoài (trước đây một lỗi DB ở đây làm hỏng loop future → TTS
    // brick). Progress sync server có chain riêng bên trong service.
    try {
      if (_currentStoryId != null && _currentChapterNumber != null) {
        await _progressService.markChapterRead(
          _currentStoryId!,
          _currentChapterNumber!,
        );
      }
    } catch (e, s) {
      AppLogger.warning('TTS: markChapterRead failed on chapter complete', e, s);
    }
    // Reset chunk index cho lần play tiếp theo.
    _currentChunk = 0;
    // ⚠️ DO NOT await _speakLoopFuture here. When _onChapterComplete is
    // called from inside _speakLoop() (the natural-completion path),
    // _speakLoopFuture is the Future of the CURRENT _speakLoop() execution.
    // Awaiting it would deadlock: the loop can't return until this method
    // returns, and this method can't return until the loop returns.
    //
    // The loop's whenComplete() callback in play() will null out
    // _speakLoopFuture when _speakLoop() exits. Only external entry points
    // (pause/stop/skipToNext) need to await _speakLoopFuture — they do so
    // directly.
    playbackState.add(
      playbackState.value.copyWith(
        controls: const [],
        playing: false,
        processingState: AudioProcessingState.idle,
      ),
    );
    // Broadcast cho reader screens — màn hình đang mở chương này sẽ tự
    // chuyển chương kế + auto-play (nếu autoAdvanceEnabled / manual skip).
    // Thứ tự: lấy snapshot TRƯỚC khi broadcast vì listener có thể gọi
    // loadChapter (ghi đè state) ngay trong lúc dispatch.
    final completed = TtsChapterCompleteEvent(
      chapterId: _currentChapterId!,
      chapterNumber: _currentChapterNumber ?? 0,
      storyId: _currentStoryId ?? '',
      nextChapterNumber: _nextChapterNumber,
      manualSkip: _manualSkipPending,
    );
    _manualSkipPending = false;
    try {
      _chapterCompleteController.add(completed);
    } catch (e, s) {
      AppLogger.warning('TTS: chapter-complete broadcast failed', e, s);
    }
  }

  Future<void> _savePlaybackState({required bool isPlaying}) async {
    if (_currentChapterId == null) return;
    try {
      await _db.upsertTtsState(
        TtsPlaybackStateCompanion.insert(
          chapterId: _currentChapterId!,
          storyId: _currentStoryId ?? '',
          chapterNumber: _currentChapterNumber ?? 0,
          chunkIndex: Value(_currentChunk),
          isPlaying: Value(isPlaying ? 1 : 0),
          lastPlayedAt: Value(DateTime.now().toIso8601String()),
        ),
      );
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
    this.blockIndex = -1,
  });
  final String chapterId;
  final int chunkIndex;
  final int totalChunks;

  /// Exact rendered-block index (into the `MarkdownParser` block list)
  /// currently being spoken. -1 when the chunk maps to no block.
  final int blockIndex;
}

/// Pure decision — màn hình reader nhận [TtsChapterCompleteEvent] có nên
/// chuyển chương kế + auto-play không? Tách riêng để unit-test được.
bool shouldAutoAdvanceTts({
  required bool matchesCurrentChapter,
  required bool autoAdvanceEnabled,
  required bool manualSkip,
  required int? nextChapterNumber,
}) {
  if (!matchesCurrentChapter) return false;
  if (nextChapterNumber == null) return false;
  return autoAdvanceEnabled || manualSkip;
}

/// Broadcast khi TTS đọc xong một chương (tự nhiên hoặc skip thủ công).
/// Reader screens dùng để auto-advance: chuyển chương kế + auto-play.
class TtsChapterCompleteEvent {
  const TtsChapterCompleteEvent({
    required this.chapterId,
    required this.chapterNumber,
    required this.storyId,
    this.nextChapterNumber,
    this.manualSkip = false,
  });

  /// Chương vừa đọc xong.
  final String chapterId;
  final int chapterNumber;
  final String storyId;

  /// Chương kế theo chapter number — null khi đây là chương cuối.
  final int? nextChapterNumber;

  /// True khi user chủ động bấm Skip (vẫn chuyển chương kể cả khi
  /// autoAdvanceEnabled = false); false khi hết chương tự nhiên.
  final bool manualSkip;
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
      config: AudioServiceConfig(
        androidNotificationChannelId: 'com.khongdich.app.tts',
        androidNotificationChannelName: 'Không Dịch — Đọc truyện',
        androidNotificationOngoing: true,
        // Keep notification visible when paused so user can resume from
        // lockscreen / notification shade. Previously this was true →
        // notification disappeared on pause → user couldn't resume without
        // opening the app.
        androidStopForegroundOnPause: false,
        // Show app icon in notification.
        androidNotificationIcon: 'drawable/ic_launcher_splash',
      ),
    );
    await handler._init();
  } catch (e, s) {
    // Log warning nhưng vẫn return handler. _initialised vẫn false →
    // retry tự động khi user tap play lần tiếp theo. UI có thể gọi
    // handler.reinit() để retry thủ công.
    AppLogger.warning(
      'ttsHandlerProvider: init failed (will retry on next use)',
      e,
      s,
    );
  }
  return handler;
});
