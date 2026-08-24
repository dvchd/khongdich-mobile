# AGENTS.md

## Workflow Rules

### Trước khi commit/push

Chạy theo đúng thứ tự:

- `flutter analyze` — phải sạch, không để issue nào
- `flutter test` — tất cả phải xanh (hiện 234 tests)

Khi sửa `lib/features/tts/tts_audio_handler.dart`, bắt buộc chạy riêng `flutter test test/tts_state_machine_test.dart` — file này khóa các bug race của TTS (chú thích bug #1–#11 trong header của handler).

CI chạy `flutter analyze` và `flutter test` song song (2 job) trên mọi push/PR; khi push tag `v*` job `build-android` build APK + AAB prod (có cache Gradle, daemon bật) rồi đăng lên GitHub Release và **tự upload AAB lên Closed Testing (track `PLAY_TRACK_NAME` = `Closed Test`) qua GitHub Action** bằng service account `play-release@khongdich-play` (secret `PLAY_SERVICE_ACCOUNT_JSON` — base64 file key JSON, xem skill android-release). Commit hỏng CI = hỏng release.

### Release notes (nguồn duy nhất)

- Nguồn duy nhất: `docs/release-notes/v<version>.md` (tiếng Việt) và `v<version>.en-US.md` (tiếng Anh) — viết markdown, commit TRƯỚC khi bump version (script `scripts/bump_version.sh` fail nếu thiếu).
- **GitHub Release** đọc thẳng file md qua `body_path` (markdown render đẹp) — body viết đầy đủ, không giới hạn độ dài.
- **Play Console** đọc cùng file đó, CI dùng `scripts/md_to_whatsnew.py` → plain text `play/whatsnew/whatsnew-vi|en-US` → upload qua `whatsNewDirectory`. Khối `<!-- whatsnew:start -->` … `<!-- whatsnew:end -->` trong file md là bản tóm tắt viết tay dành cho Play Console, **bắt buộc ≤500 ký tự** (script fail nếu vượt, không auto-cắt khối viết tay). Thiếu khối → fallback strip+truncate toàn body (mất phần sau — tránh dùng).
- Mẫu cấu trúc + ví dụ: `docs/release-notes/TEMPLATE.md`.
- `scripts/bump_version.sh` kiểm tra 2 file tồn tại + validate khối whatsnew trước khi tạo tag.

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
- **LUÔN bật GPU host** (`hw.gpu.enabled=yes`, `hw.gpu.mode=host` trong `~/.android/avd/*.avd/config.ini`). Máy có Intel Iris Xe + KVM nên host GPU nhanh hơn hẳn software rendering (swiftshader). Xác nhận GPU hoạt động: log emulator có `vulkan_mode_selected:host gles_mode_selected:host` + `Found physical GPU 'Intel ...'`. Chú ý: image `google_apis_playstore` (API 33) khi tạo mới mặc định `hw.gpu.enabled=no` — phải sửa config.ini trước khi boot, nếu không emulator chạy swiftshader rất chậm (UI dump tới 5-10s thay vì <1s).
- Image emulator: `google_apis` (API 35) dùng bình thường, **Google Sign-In đã hoạt động** (thông tin cũ "luôn fail `[16] Account reauth failed`" đã lỗi thời — đừng còn tránh Google login hay bắt dùng ảnh `google_apis_playstore`). Vẫn giữ AVD `Pixel_6_Pro_API_33_Play` dự phòng khi gặp sự cố GMS lạ; xem `~/.android/avd/*.avd/config.ini` dòng `image.sysdir.1` để biết image nào.
- `-no-audio` làm Google TTS thỉnh thoảng lỗi synth giữa chừng → engine tự cancel (KHÔNG phải lỗi app). Hành vi đúng: UI chuyển về paused, bấm play phục hồi được.
- Build + cài: `flutter build apk --debug --flavor prod && adb install -r build/app/outputs/flutter-apk/app-prod-debug.apk`
- Log TTS: `adb logcat -s flutter:I | grep "TTS:"` — chuỗi "speaking chunk X/N", "cancel handler fired", "loaded chapter …", "chapter complete" là đủ để xác minh state machine.
- UI tree: `adb shell uiautomator dump /sdcard/ui.xml && adb shell cat /sdcard/ui.xml`. Nếu lỗi "could not get idle state" → thường do notification shade đang mở/animating: `adb shell cmd statusbar collapse` rồi dump lại. Cũng có thể do file dump cũ còn sót — `rm -f /sdcard/ui.xml` trước khi dump.
- Mini player nằm ở y ≈ 2840–3120 trong dump. Nút X = content-desc "Dừng hẳn và đóng".
- Media key (đường notification/lockscreen) test bằng `adb shell input keyevent 87|88|85|86` (next/prev/play-pause/stop).
- Mạng emulator thỉnh thoảng "Software caused connection abort" khi fetch chương → `adb shell am force-stop com.khongdich.app` rồi mở lại app (Dio giữ connection pool cũ).
- Không đọc được ảnh trong phiên làm việc → luôn xác minh UI qua uiautomator dump + logcat, không qua screencap.
