import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/database/app_database.dart';
import '../../core/markdown/markdown.dart';
import '../../core/network/api_client.dart' show ApiException;
import '../../core/observability/app_logger.dart';
import '../../core/utils/notification_permission.dart';
import '../../models/chapter_content.dart';
import '../../services/chapter_cache_service.dart';
import '../reader/chapter_tts_support.dart';
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
///    player UI. Notification hiển thị ĐỦ điều khiển
///    `skipToPrevious | play/pause | skipToNext` (compact) + `stop`
///    (expanded) — user có thể chuyển chương khi app bị ẩn.
///
/// 3. Chunks: `TtsMarkdownPreprocessor.process()` split markdown thành
///    ~500-char plain-text chunks. Đọc tuần tự qua while-loop.
///
/// 4. **Handler owns chuyển chương** (không phải màn hình). Skip prev/
///    next + auto-advance khi hết chương đều do handler tự resolve
///    chương kế (online qua `ChapterCacheService`, offline qua Drift
///    `downloaded_chapters`) → hoạt động cả khi app bị ẩn. Màn hình
///    reader chỉ lắng nghe `onChapterCompleted` để điều hướng UI.
///
/// 5. **Operation chain** (`_serialized`): mọi thao tác đổi trạng thái
///    (play/pause/stop/skip/loadChapter/restart) chạy TUẦN TỰ theo đúng
///    thứ tự user bấm. Trước đây các method chạy song song → race
///    (xem bug #7, #8) làm "trạng thái phát/dừng không đồng bộ".
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
///   giữa các chunk. Bonus: capture chapter/chunk VÀO THỜI ĐIỂM GỌI
///   (trước đây đọc field lúc thực thi → có thể ghi state chương mới
///   vào row chương cũ khi auto-advance nhanh).
///
/// - **#7 play() race khi pause đang chạy**: play() trả về ngay nếu
///   `_speakLoopFuture != null` (loop cũ đang thoát) → user bấm play
///   nhanh sau pause bị nuốt, TTS dừng vĩnh viễn dù UI báo playing.
///   Fix: operation chain — play() chạy SAU khi pause() hoàn tất, và
///   `_playInner` không còn check future (generation guard lo zombie).
///
/// - **#8 pause() ghi đè state của play()**: pause() emit state paused
///   SAU khi await → play() launch giữa chừng bị ghi đè → UI báo
///   paused trong khi audio vẫn chạy. Fix: chain + emit state đúng thứ
///   tự thao tác.
///
/// - **#9 Speed desync**: `_restartSpeakLoop` trả về ngay khi
///   `!_isSpeaking` — bấm tốc độ lần 2 trong lúc restart lần 1 đang
///   chạy → thay đổi bị nuốt, chip UI hiện 2.0x nhưng đọc 1.5x. Fix:
///   restart chạy qua chain + coalesce (`_restartQueued`) — restart
///   cuối cùng luôn dùng tốc độ mới nhất.
///
/// - **#10 Skip từ notification khi app ẩn**: trước đây skipToNext chỉ
///   broadcast event rồi CHỜ màn hình reader load chương kế — không
///   màn hình nào mounted → không gì xảy ra. Giờ handler tự resolve +
///   load + play (online/offline), màn hình chỉ điều hướng. Thêm
///   `skipToPrevious` cho nút lùi chương.
///
/// - **#11 Straggler "speak.onCancel" giết loop mới**: flutter_tts
///   Android gửi cancel event ASYNC (engine `onStop` sau `stop()`) —
///   nó có thể tới TRỄ, khi loop mới đã relaunch (đổi tốc độ, pause→
///   play nhanh). Trước đây cancel handler set `_isSpeaking = false` →
///   loop mới chết sau đúng 1 chunk ("đổi tốc độ chỉ nghe được 1 đoạn
///   là dừng"). Fix: `_pendingStopCancel` counter — mỗi lần chúng ta
///   chủ động `stop()` một utterance đang chạy đều `_expectStopCancel()`
///   TRƯỚC; cancel handler tiêu thụ 1 event rồi bỏ qua (các op đã tự
///   emit state đúng). Cancel còn lại (genuine, không do chúng ta stop)
///   mới được coi là "engine tự dừng" → flip state.
class TtsAudioHandler extends BaseAudioHandler with QueueHandler {
  TtsAudioHandler(
    this._db,
    this._progressService,
    this._cache, {
    FlutterTts? tts,
  }) : _tts = tts ?? FlutterTts();

  final AppDatabase _db;
  final ReadingProgressService _progressService;
  final ChapterCacheService _cache;

  final FlutterTts _tts;
  List<TtsChunk> _chunks = const [];
  int _currentChunk = 0;
  String? _currentChapterId;
  String? _currentStoryId;
  String? _currentStorySlug;
  int? _currentChapterNumber;
  int? _nextChapterNumber;
  int? _prevChapterNumber;

  /// Nguồn chương hiện tại: `true` = offline (Drift downloaded_chapters),
  /// `false` = online (API qua ChapterCacheService). Quyết định cách
  /// resolve chương khi skip/auto-advance từ notification.
  bool _offlineMode = false;

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
  /// là handler tự chuyển chương kế + tự play tiếp (kể cả khi app bị ẩn).
  /// Nút Stop trong control panel (hoặc [stopAutoAdvance]) tắt chuỗi này;
  /// pause KHÔNG tắt (resume vẫn tiếp tục chuỗi).
  bool autoAdvanceEnabled = false;

  /// Chương mà user đã bấm nút X "dừng hẳn và đóng" — mini player ẩn cho
  /// tới khi user tap headphone lại (play()) hoặc load chương mới.
  String? _dismissedChapterId;

  /// Xem [_dismissedChapterId].
  String? get dismissedChapterId => _dismissedChapterId;

  /// Số cancel event ("speak.onCancel") mà engine dự kiến gửi sau các
  /// lần `_tts.stop()` do CHÍNH CHÚNG TA gọi (pause/stop/restart/skip/
  /// loadChapter). flutter_tts Android gửi event này ASYNC (engine
  /// `onStop`) — nó có thể tới SAU khi loop mới đã relaunch (restart
  /// tốc độ, pause→play nhanh). Nếu cancel handler không nuốt chúng,
  /// nó set `_isSpeaking = false` + emit `playing: false` trong khi
  /// loop mới đang chạy → loop chết sau đúng 1 chunk (bug "đổi tốc độ
  /// chỉ nghe được 1 đoạn là dừng"). Mỗi lần stop một utterance đang
  /// chạy chỉ sinh tối đa 1 onStop (queueMode QUEUE_FLUSH) → depth 1.
  /// Cap 3: engine không bao giờ gửi onStop sẽ không nuốt hết các
  /// genuine-cancel sau này.
  int _pendingStopCancel = 0;

  /// Đăng ký MỘT cancel event sẽ đến (do `_tts.stop()` của chính chúng
  /// ta) — gọi TRƯỚC mỗi lần stop một utterance đang chạy. Cancel
  /// handler sẽ tiêu thụ + bỏ qua nó (các op đã tự emit state đúng).
  void _expectStopCancel() {
    if (_pendingStopCancel < 3) _pendingStopCancel++;
  }

  /// Đã có restart đang chờ trong operation chain — tap tốc độ/giọng
  /// nhanh nhiều lần chỉ queue MỘT restart cuối (restart chạy sau cùng
  /// sẽ dùng setting mới nhất).
  bool _restartQueued = false;

  /// Operation chain — mọi thao tác đổi trạng thái chạy TUẦN TỰ.
  /// Xem bug #7/#8. Never cached fail: lỗi của op trước không chặn op sau.
  Future<void> _opChain = Future<void>.value();

  /// Phát khi TTS đọc xong một chương (tự nhiên HOẶC skip thủ công).
  /// Reader screens listen để điều hướng UI (chuyển chương) — VIỆC LOAD
  /// + PLAY chương kế do handler tự làm. Design này thay callback
  /// `onChapterComplete` cũ: callback bị ghi đè bởi màn hình mới nhất và
  /// không có cách nào biết màn hình nào sở hữu nó → auto-advance đứt
  /// chuỗi hoặc navigate nhầm màn hình; đồng thời không hoạt động khi
  /// app bị ẩn (không màn hình nào mounted).
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

  /// Số chương TRƯỚC chương hiện tại (null khi đây là chương đầu của
  /// nguồn hiện tại). Dùng cho nút skipToPrevious trên notification.
  int? get prevChapterNumber => _prevChapterNumber;

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

  /// Serialize mọi thao tác đổi trạng thái. Xem bug #7/#8 ở header.
  Future<T> _serialized<T>(Future<T> Function() op) {
    final result = _opChain.then((_) => op());
    _opChain = result.then<void>(
      (_) {},
      onError: (Object e, StackTrace s) {
        AppLogger.warning('TTS: serialized op failed', e, s);
      },
    );
    return result;
  }

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
        // stop() bên dưới có thể sinh thêm một onStop ("speak.onCancel")
        // từ engine — đăng ký trước để cancel handler không ghi đè
        // error state vừa emit.
        if (_isSpeaking) _expectStopCancel();
        _isSpeaking = false;
        // Vô hiệu hoá loop đang chạy — nó sẽ thoát ngay khi thức dậy
        // thay vì phát tiếp chunk kế của chapter trong lúc error state.
        _invalidateSpeakLoop();
        playbackState.add(
          playbackState.value.copyWith(
            controls: buildTtsControls(playing: false),
            androidCompactActionIndices: const [0, 1, 2],
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
        // Cancel do chính `_tts.stop()` của chúng ta (pause/stop/restart/
        // skip/loadChapter) — các op đó đã tự emit state đúng thứ tự.
        // Event này đến ASYNC nên có thể tới SAU khi loop mới đã relaunch
        // (bug "đổi tốc độ chỉ nghe được 1 đoạn là dừng") — nuốt nó.
        if (_pendingStopCancel > 0) {
          _pendingStopCancel--;
          return;
        }
        // Không đang speaking (đã pause/stop trước đó) → cancel vô nghĩa.
        // Bỏ qua để không ghi đè state idle/error — ví dụ stop() đã emit
        // controls rỗng, cancel tới sau không được hồi sinh nút play.
        if (!_isSpeaking) return;
        // Genuine cancel từ engine (KHÔNG do chúng ta stop) — ví dụ app
        // khác chiếm TTS engine. Engine không resolve speak() trong
        // trường hợp này nên loop hiện tại sẽ treo — ít nhất UI phản
        // ánh đúng trạng thái "đã dừng".
        _isSpeaking = false;
        playbackState.add(
          playbackState.value.copyWith(
            controls: buildTtsControls(playing: false),
            androidCompactActionIndices: const [0, 1, 2],
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
    _queueRestart();
  }

  /// Queue restart qua operation chain + coalesce: nhiều lần đổi tốc độ/
  /// giọng/engine liên tiếp chỉ tạo MỘT restart cuối cùng (chạy với
  /// setting mới nhất — bug #9).
  void _queueRestart() {
    if (_restartQueued) return;
    _restartQueued = true;
    unawaited(_serialized(() async {
      _restartQueued = false;
      await _restartSpeakLoopInner();
    }));
  }

  /// Restart speak loop từ đầu chunk hiện tại — dùng khi user đổi tốc độ/
  /// giọng/engine giữa chừng. Android TextToSpeech không áp setting mới
  /// cho utterance đang đọc nên phải stop + speak lại chunk đó.
  ///
  /// Chạy TRONG operation chain → không có pause/stop/play nào chen vào
  /// giữa chừng → relaunch sau khi loop cũ thoát là an toàn (bug #9).
  Future<void> _restartSpeakLoopInner() async {
    if (!_isSpeaking) return;
    if (_currentChapterId == null || _chunks.isEmpty) return;
    // stop() sẽ sinh một "speak.onCancel" async từ engine — đăng ký
    // trước để handler nuốt nó (nó tới TRỄ, sau khi loop mới đã chạy).
    _expectStopCancel();
    _invalidateSpeakLoop();
    _cancelBlockAdvanceTimer();
    try {
      await _tts.stop();
    } catch (e) {
      AppLogger.warning('TTS: stop during restart failed', e);
    }
    await _awaitSpeakLoop();
    if (_currentChapterId == null || _chunks.isEmpty) return;
    _isSpeaking = true;
    playbackState.add(
      playbackState.value.copyWith(
        controls: buildTtsControls(playing: true),
        androidCompactActionIndices: const [0, 1, 2],
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
    _queueRestart();
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
    _queueRestart();
    return _availableVoices;
  }

  /// Load chapter content để đọc. Chạy qua operation chain — load song
  /// song với play/pause/skip sẽ làm loạn state (bug #7/#8).
  ///
  /// [offline]: `true` = chương đang đọc là chương tải về (Drift) —
  /// prev/next sẽ được GIỚI HẠN trong danh sách chương đã tải và mọi
  /// skip/auto-advance resolve từ DB, không đụng mạng.
  Future<void> loadChapter({
    required String chapterId,
    required String storyId,
    required String storyTitle,
    required String chapterTitle,
    required int chapterNumber,
    required String contentMarkdown,
    String? storySlug,
    int? prevChapterNumber,
    int? nextChapterNumber,
    bool offline = false,
  }) =>
      _serialized(() => _loadChapterInner(
            chapterId: chapterId,
            storyId: storyId,
            storyTitle: storyTitle,
            chapterTitle: chapterTitle,
            chapterNumber: chapterNumber,
            contentMarkdown: contentMarkdown,
            storySlug: storySlug,
            prevChapterNumber: prevChapterNumber,
            nextChapterNumber: nextChapterNumber,
            offline: offline,
          ));

  Future<void> _loadChapterInner({
    required String chapterId,
    required String storyId,
    required String storyTitle,
    required String chapterTitle,
    required int chapterNumber,
    required String contentMarkdown,
    String? storySlug,
    int? prevChapterNumber,
    int? nextChapterNumber,
    bool offline = false,
  }) async {
    await _init();
    // Stop mọi playback đang chạy của chương cũ trước khi load chương mới.
    // Trước đây không có bước này → completion handler của chương cũ có
    // thể fire sau khi chương mới đã load, gây _currentChunk sai.
    if (_isSpeaking) {
      // stop() sinh "speak.onCancel" async từ engine — đăng ký trước để
      // cancel handler không ghi đè state của chương mới.
      _expectStopCancel();
      _invalidateSpeakLoop();
      try {
        await _tts.stop();
      } catch (e) {
        AppLogger.warning('TTS: stop before loadChapter failed', e);
      }
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
    _offlineMode = offline;
    _prevChapterNumber = prevChapterNumber;
    _nextChapterNumber = nextChapterNumber;
    // Load chương mới = phiên nghe mới → bỏ trạng thái "đã đóng" của
    // chương cũ để mini player hiện lại bình thường.
    _dismissedChapterId = null;
    if (offline) {
      // Offline: prev/next phải nằm TRONG danh sách chương đã tải —
      // prev/next từ API không biết chương nào user đã download. DB là
      // nguồn chân lý; fallback tham số truyền vào nếu DB lỗi.
      try {
        final siblings = await _db.getDownloadedChaptersForStory(storyId);
        final i = siblings.indexWhere((s) => s.chapterNumber == chapterNumber);
        if (i >= 0) {
          _prevChapterNumber =
              i > 0 ? siblings[i - 1].chapterNumber : null;
          _nextChapterNumber =
              i < siblings.length - 1 ? siblings[i + 1].chapterNumber : null;
        }
      } catch (e, s) {
        AppLogger.warning('TTS: offline sibling lookup failed', e, s);
      }
    }

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
  Future<void> play() => _serialized(() => _playInner());

  Future<void> _playInner() async {
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
    // Bấm play tường minh (reader headphone / panel) = user muốn nghe
    // lại → bỏ trạng thái "đã đóng mini player" nếu có.
    _dismissedChapterId = null;
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
    // Loop đang chạy → play() là no-op. KHÔNG check _speakLoopFuture:
    // future non-null trong khi _isSpeaking=false chỉ là loop cũ đang
    // thoát — generation guard đảm bảo nó không đụng state; launch loop
    // mới ngay là an toàn (bug #7).
    if (_isSpeaking) return;
    _isSpeaking = true;
    playbackState.add(
      playbackState.value.copyWith(
        controls: buildTtsControls(playing: true),
        androidCompactActionIndices: const [0, 1, 2],
        playing: true,
        processingState: AudioProcessingState.ready,
        errorMessage: null,
        errorCode: null,
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
  Future<void> pause() => _serialized(() => _pauseInner());

  Future<void> _pauseInner() async {
    // stop() sinh "speak.onCancel" async — có thể tới sau khi user bấm
    // play lại → đăng ký trước để không giết loop mới (bug #7 follow-up).
    final wasSpeaking = _isSpeaking;
    if (wasSpeaking) _expectStopCancel();
    _invalidateSpeakLoop();
    _cancelBlockAdvanceTimer();
    try {
      await _tts.stop();
    } catch (e) {
      AppLogger.warning('TTS: pause stop failed', e);
    }
    // Đợi loop hiện tại exit (nó sẽ exit do _isSpeaking = false).
    await _awaitSpeakLoop();
    playbackState.add(
      playbackState.value.copyWith(
        controls: buildTtsControls(playing: false),
        androidCompactActionIndices: const [0, 1, 2],
        playing: false,
      ),
    );
    unawaited(_savePlaybackState(isPlaying: false));
    unawaited(_deactivateAudioSession());
  }

  @override
  Future<void> stop() => _serialized(() => _stopInner());

  Future<void> _stopInner() async {
    final wasSpeaking = _isSpeaking;
    if (wasSpeaking) _expectStopCancel();
    _invalidateSpeakLoop();
    _cancelBlockAdvanceTimer();
    try {
      await _tts.stop();
    } catch (e) {
      AppLogger.warning('TTS: stop failed', e);
    }
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

  /// Chuyển chương KẾ — nút "next" trên notification / control panel.
  /// Handler tự resolve + load + play → hoạt động cả khi app bị ẩn
  /// (không cần màn hình reader nào mounted — bug #10).
  @override
  Future<void> skipToNext() =>
      _serialized(() => _skipInner(direction: 1));

  /// Chuyển chương TRƯỚC — nút "previous" trên notification / control
  /// panel. Cùng pipeline với skipToNext (resolve theo nguồn online/
  /// offline của chương hiện tại).
  @override
  Future<void> skipToPrevious() =>
      _serialized(() => _skipInner(direction: -1));

  Future<void> _skipInner({required int direction}) async {
    final chapterId = _currentChapterId;
    if (chapterId == null || _chunks.isEmpty) {
      AppLogger.info('TTS: skip ignored — no chapter loaded');
      return;
    }
    final targetNumber =
        direction > 0 ? _nextChapterNumber : _prevChapterNumber;
    if (targetNumber == null) {
      AppLogger.info(
        'TTS: skip ${direction > 0 ? 'next' : 'previous'} ignored — no target chapter',
      );
      return;
    }
    // Dừng utterance hiện tại trước — trước đây skipToNext chỉ gọi
    // _onChapterComplete(): loop cũ còn chạy tới khi chunk hiện tại
    // (có thể 40-50s) đọc xong mới thoát, trong khi UI đã báo "idle"
    // và loadChapter của chương mới phải await _speakLoopFuture →
    // chuyển chương treo hàng chục giây + audio vẫn phát chương cũ.
    if (_isSpeaking) {
      // stop() sinh "speak.onCancel" async — có thể tới trễ trong lúc
      // resolve/load chương mới → đăng ký trước để không ghi đè state
      // "đang phát" của chương mới.
      _expectStopCancel();
      _invalidateSpeakLoop();
      _cancelBlockAdvanceTimer();
      try {
        await _tts.stop();
      } catch (e) {
        AppLogger.warning('TTS: skip stop failed', e);
      }
      await _awaitSpeakLoop();
    }
    // Đánh dấu chương đang nghe đã đọc (user chủ động bỏ qua phần còn
    // lại) + lưu vị trí nghe để lần sau mở lại tiếp tục từ đó.
    try {
      if (_currentStoryId != null && _currentChapterNumber != null) {
        await _progressService.markChapterRead(
          _currentStoryId!,
          _currentChapterNumber!,
        );
      }
    } catch (e, s) {
      AppLogger.warning('TTS: markChapterRead on skip failed', e, s);
    }
    unawaited(_savePlaybackState(isPlaying: false));

    await _jumpToChapter(
      targetNumber: targetNumber,
      manualSkip: true,
      fromChapterId: chapterId,
    );
  }

  /// Resolve + load + play chương đích (skip hoặc auto-advance).
  ///
  /// Chỉ được gọi TỪ TRONG operation chain (skip) hoặc từ
  /// `_advanceAfterComplete` (cũng chạy trong chain) — KHÔNG tự gọi
  /// `_serialized` ở đây để tránh deadlock (op đang chạy chờ chính nó).
  Future<void> _jumpToChapter({
    required int targetNumber,
    required bool manualSkip,
    required String fromChapterId,
  }) async {
    final fromChapterNumber = _currentChapterNumber ?? 0;
    final fromStoryId = _currentStoryId ?? '';
    // Thông báo đang tải chương mới — notification hiện spinner thay vì
    // treo ở nút pause.
    playbackState.add(
      playbackState.value.copyWith(
        controls: const [MediaControl.stop],
        playing: false,
        processingState: AudioProcessingState.buffering,
      ),
    );
    final result = await _resolveChapter(targetNumber);
    final chapter = result.chapter;
    if (chapter == null) {
      AppLogger.warning(
          'TTS: resolve chapter $targetNumber failed (${result.failure?.name})');
      playbackState.add(
        playbackState.value.copyWith(
          controls: buildTtsControls(playing: false),
          androidCompactActionIndices: const [0, 1, 2],
          playing: false,
          processingState: AudioProcessingState.error,
          errorMessage: _resolveFailureMessage(
            targetNumber,
            result.failure,
            manualSkip: manualSkip,
          ),
        ),
      );
      return;
    }
    final markdown = chapterMarkdownOrNull(chapter);
    if (markdown == null) {
      AppLogger.info('TTS: target chapter $targetNumber has no TTS content');
      return;
    }
    await _loadChapterInner(
      chapterId: chapter.id,
      storyId: chapter.storyId,
      storyTitle: chapter.storyTitle,
      chapterTitle: chapter.title,
      chapterNumber: chapter.chapterNumber,
      contentMarkdown: markdown,
      storySlug: chapter.storySlug,
      prevChapterNumber: chapter.prevChapter,
      nextChapterNumber: chapter.nextChapter,
      offline: _offlineMode,
    );
    await _playInner();
    // Broadcast cho màn hình reader (nếu còn mounted) điều hướng UI
    // sang chương đích. Snapshot đã capture TRƯỚC khi loadChapter ghi
    // đè state.
    try {
      _chapterCompleteController.add(
        TtsChapterCompleteEvent(
          chapterId: fromChapterId,
          chapterNumber: fromChapterNumber,
          storyId: fromStoryId,
          nextChapterNumber: targetNumber,
          manualSkip: manualSkip,
        ),
      );
    } catch (e, s) {
      AppLogger.warning('TTS: chapter-complete broadcast failed', e, s);
    }
  }

  /// Resolve nội dung chương [chapterNumber] theo nguồn hiện tại:
  ///   - Offline: query Drift `downloaded_chapters` (không đụng mạng).
  ///   - Online: `ChapterCacheService.getChapter` (memory → DB → API).
  /// Trả [TtsResolveResult] — chapter hoặc LÝ DO thất bại để thông báo
  /// đúng cho user (VIP ≠ mạng ≠ chưa tải — trước đây chỉ có 1 message
  /// "kiểm tra kết nối" chung chung).
  Future<TtsResolveResult> _resolveChapter(int chapterNumber) async {
    final storyId = _currentStoryId;
    if (storyId == null) {
      return const TtsResolveResult.failed(TtsResolveFailure.notFound);
    }
    if (_offlineMode) {
      try {
        final row = await (_db.select(_db.downloadedChapters)
              ..where((t) => t.storyId.equals(storyId))
              ..where((t) => t.chapterNumber.equals(chapterNumber)))
            .getSingleOrNull();
        if (row == null) {
          AppLogger.info(
              'TTS: offline chapter $chapterNumber not downloaded');
          return const TtsResolveResult.failed(
              TtsResolveFailure.notDownloaded);
        }
        final json = jsonDecode(row.contentRaw) as Map<String, dynamic>;
        final fullJson = <String, dynamic>{
          ...json,
          'content_markdown': json['content_markdown'] ?? '',
          'content_type': row.contentType,
          'story_title': row.storyTitle,
          'story_slug': row.storySlug,
          'chapter_number': row.chapterNumber,
          'title': row.chapterTitle,
        };
        final chapter = ChapterContent.fromJson(fullJson);
        return chapterMarkdownOrNull(chapter) == null
            ? const TtsResolveResult.failed(TtsResolveFailure.notFound)
            : TtsResolveResult.success(chapter);
      } catch (e, s) {
        AppLogger.warning('TTS: offline chapter resolve failed', e, s);
        return const TtsResolveResult.failed(TtsResolveFailure.network);
      }
    }
    try {
      return TtsResolveResult.success(await _cache.getChapter(
        storyId: storyId,
        chapterNumber: chapterNumber,
      ));
    } on ApiException catch (e) {
      AppLogger.warning(
          'TTS: online chapter resolve failed with status ${e.status}');
      return TtsResolveResult.failed(
        e.status == 403
            ? TtsResolveFailure.vipLocked
            : (e.status == 404
                ? TtsResolveFailure.notFound
                : TtsResolveFailure.network),
      );
    } on StateError catch (_) {
      // getChapter throw khi chapterNumber không có trong chapter list
      // (chưa publish / đánh số lại).
      return const TtsResolveResult.failed(TtsResolveFailure.notFound);
    } catch (e, s) {
      AppLogger.warning('TTS: online chapter resolve failed', e, s);
      return const TtsResolveResult.failed(TtsResolveFailure.network);
    }
  }

  /// Message lỗi cho user theo nguyên nhân resolve thất bại.
  String _resolveFailureMessage(
    int chapterNumber,
    TtsResolveFailure? failure, {
    required bool manualSkip,
  }) =>
      ttsResolveFailureMessage(
        chapterNumber,
        failure,
        manualSkip: manualSkip,
      );

  /// Dừng hẳn + tắt chuỗi auto-advance — nút Stop trong control panel.
  /// (`stop()` thường được gọi nội bộ khi chuyển chương nên không được
  /// tự ý tắt auto-advance ở đó.)
  Future<void> stopAutoAdvance() async {
    autoAdvanceEnabled = false;
    await stop();
  }

  /// Nút X của mini player: dừng hẳn + ẩn bottom bar. Khác với stop():
  /// stop() vẫn giữ chương loaded để play lại (bar vẫn hiện); dismiss()
  /// đánh dấu [_dismissedChapterId] để mini player ẩn đi cho tới khi
  /// user tap headphone lại (play()) hoặc load chương mới.
  Future<void> dismiss() async {
    _dismissedChapterId = _currentChapterId;
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

  /// Chạy khi loop đọc hết chunks của chương.
  ///
  /// 1. Đánh dấu chương đã đọc + lưu vị trí + reset chunk về 0.
  /// 2. Nếu auto-advance (hoặc manual skip) và còn chương kế: queue
  ///    `_advanceAfterComplete` qua operation chain để HANDLER tự resolve
  ///    + load + play chương kế — hoạt động cả khi app bị ẩn (bug #10).
  ///    KHÔNG await trực tiếp ở đây: loop hiện tại đang chờ hàm này,
  ///    trong khi chain op cần loop thoát → deadlock. Không có màn hình
  ///    nào tham gia load/play nữa — màn hình chỉ điều hướng UI khi nhận
  ///    event broadcast.
  /// 3. Không advance → emit idle + controls (vẫn có nút play/prev/next
  ///    trên notification để user tiếp tục từ lockscreen).
  Future<void> _onChapterComplete() async {
    AppLogger.info('TTS: chapter complete');
    _isSpeaking = false;
    _cancelBlockAdvanceTimer();
    // Release audio focus — chapter đã xong, không cần giữ nữa.
    unawaited(_deactivateAudioSession());
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
    // Reset chunk index cho lần play tiếp theo TRƯỚC khi save — chương
    // đã nghe xong, lần sau mở lại sẽ bắt đầu từ đầu thay vì dính ở
    // chunk cuối (tức mở ra là "complete" lại ngay lập tức).
    _currentChunk = 0;
    unawaited(_savePlaybackState(isPlaying: false));

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

    final completed = TtsChapterCompleteEvent(
      chapterId: _currentChapterId!,
      chapterNumber: _currentChapterNumber ?? 0,
      storyId: _currentStoryId ?? '',
      nextChapterNumber: _nextChapterNumber,
      manualSkip: false,
    );

    if (autoAdvanceEnabled && completed.nextChapterNumber != null) {
      // Handler tự chuyển chương — xem header "Handler owns chuyển
      // chương". Chạy qua chain (không await) để không đua với pause/
      // stop user bấm đúng lúc; op sẽ kiểm tra lại chương hiện tại vẫn
      // là chương vừa xong + autoAdvanceEnabled vẫn bật trước khi load.
      unawaited(_serialized(() => _advanceAfterComplete(completed)));
    } else {
      playbackState.add(
        playbackState.value.copyWith(
          controls: buildTtsControls(playing: false),
          androidCompactActionIndices: const [0, 1, 2],
          playing: false,
          processingState: AudioProcessingState.idle,
        ),
      );
    }
    // Broadcast cho reader screens — màn hình đang mở chương này sẽ tự
    // điều hướng sang chương kế (load/play đã do handler lo).
    try {
      _chapterCompleteController.add(completed);
    } catch (e, s) {
      AppLogger.warning('TTS: chapter-complete broadcast failed', e, s);
    }
  }

  /// Auto-advance sau khi hết chương tự nhiên — chạy TRONG operation
  /// chain (queue bởi `_onChapterComplete`). Guard lại mọi điều kiện
  /// tại THỜI ĐIỂM THỰC THI: user có thể đã stop (tắt auto-advance)
  /// hoặc load chương khác trong lúc chờ chain.
  Future<void> _advanceAfterComplete(TtsChapterCompleteEvent completed) async {
    if (_currentChapterId != completed.chapterId) return;
    if (!autoAdvanceEnabled || completed.nextChapterNumber == null) return;
    final target = completed.nextChapterNumber!;
    playbackState.add(
      playbackState.value.copyWith(
        controls: const [MediaControl.stop],
        playing: false,
        processingState: AudioProcessingState.buffering,
      ),
    );
    final result = await _resolveChapter(target);
    final chapter = result.chapter;
    if (chapter == null) {
      AppLogger.warning(
          'TTS: auto-advance resolve chapter $target failed (${result.failure?.name})');
      playbackState.add(
        playbackState.value.copyWith(
          controls: buildTtsControls(playing: false),
          androidCompactActionIndices: const [0, 1, 2],
          playing: false,
          processingState: AudioProcessingState.error,
          errorMessage: _resolveFailureMessage(
            target,
            result.failure,
            manualSkip: false,
          ),
        ),
      );
      return;
    }
    final markdown = chapterMarkdownOrNull(chapter);
    if (markdown == null) return;
    await _loadChapterInner(
      chapterId: chapter.id,
      storyId: chapter.storyId,
      storyTitle: chapter.storyTitle,
      chapterTitle: chapter.title,
      chapterNumber: chapter.chapterNumber,
      contentMarkdown: markdown,
      storySlug: chapter.storySlug,
      prevChapterNumber: chapter.prevChapter,
      nextChapterNumber: chapter.nextChapter,
      offline: _offlineMode,
    );
    await _playInner();
  }

  /// Lưu vị trí nghe vào DB. Capture chapter/chunk NGAY KHI GỌI (bug #6):
  /// trước đây đọc field lúc thực thi → auto-advance nhanh có thể ghi
  /// state chương mới vào row chương cũ.
  Future<void> _savePlaybackState({required bool isPlaying}) {
    final chapterId = _currentChapterId;
    if (chapterId == null) return Future.value();
    final storyId = _currentStoryId ?? '';
    final chapterNumber = _currentChapterNumber ?? 0;
    final chunkIndex = _currentChunk;
    try {
      return _db.upsertTtsState(
        TtsPlaybackStateCompanion.insert(
          chapterId: chapterId,
          storyId: storyId,
          chapterNumber: chapterNumber,
          chunkIndex: Value(chunkIndex),
          isPlaying: Value(isPlaying ? 1 : 0),
          lastPlayedAt: Value(DateTime.now().toIso8601String()),
        ),
      );
    } catch (e, s) {
      AppLogger.warning('TtsAudioHandler._savePlaybackState', e, s);
      return Future.value();
    }
  }
}

/// Danh sách điều khiển cho `playbackState` — notification shade hiển thị
/// tối đa 3 nút compact (config `androidCompactActionIndices: [0,1,2]`):
/// `skipToPrevious | play/pause | skipToNext`; `stop` nằm ở expanded view.
/// Luôn đủ 4 nút (kể cả khi không có chương trước/sau — nút đó no-op)
/// để chỉ số compact không bao giờ vượt danh sách.
List<MediaControl> buildTtsControls({required bool playing}) => [
      MediaControl.skipToPrevious,
      playing ? MediaControl.pause : MediaControl.play,
      MediaControl.skipToNext,
      MediaControl.stop,
    ];

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
/// điều hướng sang chương đích không? Tách riêng để unit-test được.
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

/// Nguyên nhân resolve chương thất bại — để báo lỗi đúng cho user
/// (VIP ≠ mạng ≠ chưa tải ≠ không tồn tại).
enum TtsResolveFailure { network, vipLocked, notFound, notDownloaded }

/// Kết quả resolve chương cho skip/auto-advance — chapter hoặc lý do
/// thất bại, không bao giờ cả hai.
class TtsResolveResult {
  const TtsResolveResult.success(ChapterContent this.chapter)
      : failure = null;

  const TtsResolveResult.failed(TtsResolveFailure this.failure)
      : chapter = null;

  final ChapterContent? chapter;
  final TtsResolveFailure? failure;
}

/// Message lỗi cho user khi skip/auto-advance không resolve được chương
/// — mỗi nguyên nhân một thông điệp riêng (trước đây chỉ có "kiểm tra
/// kết nối" chung chung, VIP cũng báo mạng).
String ttsResolveFailureMessage(
  int chapterNumber,
  TtsResolveFailure? failure, {
  required bool manualSkip,
}) {
  final prefix = manualSkip
      ? 'Không chuyển được sang chương $chapterNumber'
      : 'Không đọc tiếp được chương $chapterNumber';
  return switch (failure) {
    TtsResolveFailure.vipLocked =>
      '$prefix — chương này là chương VIP, bạn chưa được cấp quyền '
          'đọc. Liên hệ tác giả để được mở khóa.',
    TtsResolveFailure.notFound => '$prefix — không tìm thấy chương này.',
    TtsResolveFailure.notDownloaded =>
      '$prefix — chương này chưa được tải về máy. Kết nối mạng và tải '
          'chương trước khi nghe offline.',
    _ => '$prefix — kiểm tra kết nối rồi thử lại.',
  };
}

/// Broadcast khi TTS đọc xong một chương (tự nhiên hoặc skip thủ công).
/// Reader screens dùng để điều hướng UI sang chương đích.
///
/// Load + play chương đích do HANDLER tự làm (online/offline) — màn hình
/// chỉ navigate. Vì vậy event hoạt động cả khi app bị ẩn: handler vẫn
/// chuyển chương, màn hình chỉ không navigate (không có màn hình nào
/// mounted — không sao).
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

  /// Chương ĐÍCH để điều hướng tới — với skip tự nhiên/next là chương
  /// kế; với skipToPrevious là chương trước. null khi không có đích
  /// (chương cuối / chương đầu / resolve fail).
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
  final cache = ref.watch(chapterCacheServiceProvider);
  final handler = TtsAudioHandler(db, progress, cache);
  try {
    await AudioService.init(
      builder: () => handler,
      config: AudioServiceConfig(
        androidNotificationChannelId: 'com.khongdich.app.tts',
        androidNotificationChannelName: 'Không Dịch — Đọc truyện',
        // androidNotificationOngoing phải để false khi
        // androidStopForegroundOnPause = false — audio_service assert
        // `!androidNotificationOngoing || androidStopForegroundOnPause`
        // (xem AudioServiceConfig). Trước đây set ongoing=true → assert
        // FAIL trong debug build → AudioService.init throw → media
        // notification KHÔNG BAO GIỜ hiển thị (user không điều khiển
        // được gì khi ẩn app). Đúng cách giữ notification khi pause là
        // stopForegroundOnPause=false (service vẫn foreground → system
        // giữ notification, user resume được từ lockscreen).
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
