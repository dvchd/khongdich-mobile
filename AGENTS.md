# AGENTS.md

## Workflow Rules

### Trước khi commit/push

Chạy theo đúng thứ tự:

- `flutter analyze` — phải sạch, không để issue nào
- `flutter test` — tất cả phải xanh (hiện 146 tests)

Khi sửa `lib/features/tts/tts_audio_handler.dart`, bắt buộc chạy riêng `flutter test test/tts_state_machine_test.dart` — file này khóa các bug race của TTS (chú thích bug #1–#11 trong header của handler).

CI chạy `flutter analyze` và `flutter test` song song (2 job) trên mọi push/PR; khi push tag `v*` job `build-android` build APK + AAB prod (có cache Gradle, daemon bật) rồi đăng lên GitHub Release và **tự upload AAB lên Closed Testing (track `alpha`) qua GitHub Action** bằng service account `play-release@khongdich-play` (secret `PLAY_SERVICE_ACCOUNT_JSON` — base64 file key JSON, xem skill android-release). Release notes CI tự sinh theo tag (`play/whatsnew/whatsnew-vi|en-US`). Commit hỏng CI = hỏng release.

### Commit message

Tiếng Việt, prefix conventional (`fix(tts):`, `feat(reader):`, ...) như các commit gần đây. Commit trực tiếp cho các thay đổi tự chứa (small fix), chỉ hỏi khi thay đổi lớn/mập mờ.

## Kiến thức TTS (flutter_tts + audio_service) — đọc trước khi sửa

- **flutter_tts Android gửi `speak.onCancel` ASYNC** (engine `onStop`) sau mỗi lần `stop()` — event này có thể tới TRỄ, khi loop mới đã relaunch. Mọi chỗ chủ động stop một utterance đang chạy (restart/pause/stop/skip/loadChapter/error handler) phải gọi `_expectStopCancel()` TRƯỚC khi `_tts.stop()`; cancel handler tiêu thụ đúng 1 event rồi bỏ qua. KHÔNG đưa lại kiểu cờ `_restartPending` cũ — nó để lọt straggler và làm loop chết sau đúng 1 chunk (bug #11).
- `queueMode` của flutter_tts mặc định QUEUE_FLUSH → tối đa 1 utterance đang chạy → 1 stop() = tối đa 1 onStop. Đừng đổi sang QUEUE_ADD trừ khi tính lại counter.
- `stop()` KHÔNG được tự ý tắt `autoAdvanceEnabled` (nó được gọi nội bộ khi chuyển chương). Tắt chuỗi auto-advance dùng `stopAutoAdvance()` (nút Stop) hoặc `dismiss()` (nút X).
- Nút X mini player = `handler.dismiss()` → đặt `dismissedChapterId` + stop. `_loadChapterInner`/`_playInner` clear nó để bar hiện lại khi user tap headphone hoặc load chương mới.
- Mọi thao tác đổi trạng thái chạy qua operation chain `_serialized()` — thêm thao tác mới (play/pause/stop/skip) PHẢI serialize, không chạy song song.
- `_speakLoop` dùng while-loop với `awaitSpeakCompletion(true)`, KHÔNG dùng completion handler để chain chunk (re-entrancy race trên Samsung/Huawei — bug #2).
- Mini player + control panel lắng nghe `chunkProgress` PHẢI lọc theo `chapterId` và reset khi playbackState idle/error/buffering, kèm fallback về `handler.currentChunkIndex`/`chunkModels` (panel mở ngay sau play sẽ bỏ lỡ event progress đầu tiên).

## Test trên emulator (thủ công)

- **RAM local hạn chế: KHÔNG build và chạy máy ảo cùng lúc.** Muốn test trên máy ảo thì build APK trước, TẮT emulator rồi mới build bản tiếp theo; build xong mới bật emulator cài + test. Tương tự, không chạy `flutter test`/`flutter analyze` trong lúc emulator đang chạy nếu thấy thiếu RAM.
- AVD: `Pixel_6_Pro_API_35`. Khởi động: `~/Android/Sdk/emulator/emulator -avd Pixel_6_Pro_API_35 -no-snapshot -no-audio &`
- `-no-audio` làm Google TTS thỉnh thoảng lỗi synth giữa chừng → engine tự cancel (KHÔNG phải lỗi app). Hành vi đúng: UI chuyển về paused, bấm play phục hồi được.
- Build + cài: `flutter build apk --debug --flavor prod && adb install -r build/app/outputs/flutter-apk/app-prod-debug.apk`
- Log TTS: `adb logcat -s flutter:I | grep "TTS:"` — chuỗi "speaking chunk X/N", "cancel handler fired", "loaded chapter …", "chapter complete" là đủ để xác minh state machine.
- UI tree: `adb shell uiautomator dump /sdcard/ui.xml && adb shell cat /sdcard/ui.xml`. Nếu lỗi "could not get idle state" → thường do notification shade đang mở/animating: `adb shell cmd statusbar collapse` rồi dump lại. Cũng có thể do file dump cũ còn sót — `rm -f /sdcard/ui.xml` trước khi dump.
- Mini player nằm ở y ≈ 2840–3120 trong dump. Nút X = content-desc "Dừng hẳn và đóng".
- Media key (đường notification/lockscreen) test bằng `adb shell input keyevent 87|88|85|86` (next/prev/play-pause/stop).
- Mạng emulator thỉnh thoảng "Software caused connection abort" khi fetch chương → `adb shell am force-stop com.khongdich.app` rồi mở lại app (Dio giữ connection pool cũ).
- Không đọc được ảnh trong phiên làm việc → luôn xác minh UI qua uiautomator dump + logcat, không qua screencap.
