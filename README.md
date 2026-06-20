# Không Dịch — Mobile (Flutter)

Ứng dụng đọc truyện mobile cho [khongdich.com](https://khongdich.com). Android-first, xây dựng theo `docs/plan-flutter-app.md` (v4) trong repo backend.

## Trạng thái hiện tại (v0.3.0)

**Build:** `flutter analyze` → 0 lỗi · `flutter test` → 27/27 pass · GitHub Actions build demo + prod APK song song, tự động publish lên GitHub Releases.

### Kiến trúc

Backend (`khongdich`) cung cấp JSON API tại `/api/v1/mobile/*` với Bearer JWT auth. App Flutter gọi trực tiếp JSON — không qua WebView, cookie, hay HTML scraping.

- **Auth:** `google_sign_in` trên thiết bị → exchange id_token qua `POST /api/v1/mobile/auth/token` → JWT server lưu trong `flutter_secure_storage` → gửi qua `Authorization: Bearer <jwt>` trên mọi request.
- **Đọc truyện:** mọi list/detail/chapter content đi qua JSON endpoint (`/api/v1/mobile/stories`, `/api/v1/mobile/chapters/{id}`, ...).
- **Ghi dữ liệu:** bookmark toggle, reading progress, sync, push register — tất cả JSON.
- **Đa môi trường:** app build 2 flavor:
  - **demo** → `https://demo.khongdich.com` (test nội bộ)
  - **prod** → `https://khongdich.com` (chính thức)
  - Flavor baked-in qua `--dart-define=APP_ENV` + `--flavor`. Có thể đổi runtime trong Settings → Môi trường.

### Tính năng đã hoàn thành

| Tính năng | Tham chiếu | Trạng thái |
|---|---|---|
| Material 3 theme + design tokens | §14.1 | ✅ |
| Routing (go_router, 4-tab shell + nested routes) | §14.3 | ✅ |
| Dio + Bearer JWT + secure storage | §10 | ✅ |
| Google Sign-In → JWT exchange | §5.1 | ✅ |
| Sealed `ChapterContent` (text/manga/chat/video) | §4.3 | ✅ |
| Custom Dart markdown parser + renderer | §13 | ✅ |
| Shared markdown fixtures (11 test cases) | §13.5 | ✅ |
| Chapter reader đa content_type (text/manga/chat/video) | §14.4 | ✅ |
| YouTube player (`youtube_player_flutter` v10) | §4.5 | ✅ |
| Manga viewer (`photo_view` + `cached_network_image`) | §4.5 | ✅ |
| Chat bubbles + progressive reveal (giống web) | §4.5 | ✅ |
| Reader settings (font, size, line height, theme sepia) | §5.4 | ✅ |
| Reading progress sync (local Drift + server PUT) | §8.4 | ✅ |
| Home / Search / Bookshelf / Profile / Settings | §5, §14.3 | ✅ |
| Story detail (JSON `/api/v1/mobile/stories/{id_or_slug}`) | §5.3 | ✅ |
| Notifications (JSON `/api/v1/mobile/notifications`) | §6.2 | ✅ |
| Download manager + queue UI + real-time progress | §5.5, §8 | ✅ |
| Tải offline + đọc offline (offline library + offline reader) | §8 | ✅ |
| On-device TTS (`audio_service` + `flutter_tts`) | §9 | ✅ |
| TTS control panel (chọn giọng đọc, tốc độ 0.5x–2.5x) | §9.5 | ✅ |
| TTS text highlighting (bôi đoạn đang đọc) | §9 | ✅ |
| Drift on-disk SQLite store (7 bảng) | §8.2 | ✅ |
| Batch sync (`POST /api/v1/mobile/sync`) | §12.4 | ✅ |
| FCM push (`firebase_messaging`) | §15 | ✅ |
| Launcher icons (từ web OG image) | §14.1 | ✅ |
| Multi-env flavor build (demo / prod) | §17 | ✅ |
| GitHub Actions CI/CD → APK → Releases | §17 | ✅ |
| Theme app (system/light/dark) + persisted | §5.7 | ✅ |
| Page-flip mode (lật trang + chia trang theo TextPainter) | §5.4 | ✅ |
| Tap zones (trái/phải/center) cho chuyển chương/trang | §5.4 | ✅ |
| Real-time download UX (Drift `watch()` streams) | §8 | ✅ |
| 120 FPS trên thiết bị hỗ trợ | — | ✅ |
| Splash screen (logo app, theme-aware) | — | ✅ |

### Chưa hoàn thành / Trì hoãn

- iOS port (Phase 3)
- `firebase_crashlytics` / `firebase_analytics` (observability)
- Drift schema migration (hiện v2)

## Cấu trúc dự án

```
lib/
├── main.dart                            # Khởi tạo Firebase + Riverpod + 120fps
├── app.dart                             # MaterialApp.router + splash khi ApiClient loading
├── core/
│   ├── database/app_database.dart       # Drift schema (7 bảng, v2)
│   ├── markdown/
│   │   ├── ast.dart                      # sealed Block / Inline AST
│   │   ├── parser.dart                   # custom CommonMark parser
│   │   ├── renderer.dart                 # AST → Flutter widget tree
│   │   └── preprocessor_tts.dart         # md → TTS-friendly chunks
│   ├── network/api_client.dart           # Dio + Bearer JWT + env switcher
│   ├── observability/app_logger.dart
│   ├── router/app_router.dart            # go_router + OfflineChapterReader
│   ├── shell/main_shell.dart             # bottom-nav shell + download badge
│   └── theme/app_theme.dart              # M3 theme + ThemeModeNotifier
├── features/
│   ├── auth/auth_screen.dart             # google_sign_in → /mobile/auth/token
│   ├── bookshelf/bookshelf_screen.dart   # 4-tab (reading/completed/plan/favorite) + offline tab
│   ├── downloads/
│   │   ├── downloads_screen.dart         # TabBar: Đang tải + Đã tải (real-time Drift streams)
│   │   ├── offline_library_screen.dart   # Thư viện offline (StreamProvider)
│   │   └── offline_story_detail_screen.dart
│   ├── home/{home_screen.dart, widgets/}
│   ├── notifications/notifications_screen.dart
│   ├── profile/profile_screen.dart       # Đăng nhập Google trực tiếp (không qua trang trung gian)
│   ├── reader/
│   │   ├── chapter_reader_screen.dart    # Online reader + page-flip + tap zones + TTS
│   │   ├── chapter_provider.dart
│   │   ├── reader_settings_provider.dart # Persisted to SharedPreferences
│   │   ├── services/reading_progress_service.dart
│   │   ├── views/
│   │   │   ├── text_chapter_view.dart    # Cuộn dọc + Lật trang (TextPainter measurement)
│   │   │   ├── manga_chapter_view.dart   # photo_view gallery
│   │   │   ├── chat_chapter_view.dart    # Progressive reveal + Messenger-style bubbles
│   │   │   └── video_chapter_view.dart   # YouTube native controls
│   │   └── widgets/
│   │       ├── reader_bar.dart           # App bar + TTS + chapter list + settings
│   │       └── reader_settings_sheet.dart # Font/size/line height/theme/scroll mode
│   ├── search/search_screen.dart         # Random stories ban đầu + search JSON
│   ├── settings/settings_screen.dart     # Theme app + env switcher + reader settings
│   ├── story/story_detail_screen.dart    # 3:4 cover + download button + realtime status
│   └── tts/
│       ├── tts_audio_handler.dart        # audio_service + flutter_tts + voice/speed
│       ├── tts_control_panel.dart        # Bottom sheet: play/pause/speed/voice/progress
│       └── tts_mini_player.dart          # Mini bar trong reader
├── models/{chapter_content,story}.dart
├── repositories/story_repository.dart    # JSON client cho mọi /api/v1/mobile endpoints
└── services/download_manager.dart        # Serial queue + batch fetch + skip duplicate

android/
└── app/
    ├── google-services.placeholder.json   # CI decode từ secret
    ├── build.gradle.kts                   # demo + prod flavors, signing, desugaring
    └── src/main/res/
        ├── mipmap-*/ic_launcher*.png       # Generated từ web OG image
        ├── mipmap-anydpi-v26/ic_launcher*.xml  # Adaptive icons
        ├── drawable/ic_launcher_splash.png
        └── values/ic_launcher_colors.xml

scripts/generate_mobile_icons.py           # Tạo launcher icons từ backend OG image
```

## Chạy local

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # Drift codegen
flutter analyze       # 0 lỗi
flutter test          # 27 tests

# Build demo flavor (demo.khongdich.com)
flutter run --flavor=demo --dart-define=APP_ENV=demo

# Build prod flavor (khongdich.com)
flutter run --flavor=prod --dart-define=APP_ENV=prod
```

## CI/CD

`.github/workflows/ci.yml` chạy trên mọi push và PR:

1. **Analyze + Test** — chạy `flutter analyze` + `flutter test`. Fail nếu có issue.
2. **Build Android (demo + prod)** — matrix build 2 APK song song:
   - `khongdich-demo-<sha>.apk` → demo.khongdich.com
   - `khongdich-prod-<sha>.apk` → khongdich.com
3. **Publish to GitHub Releases**:
   - Tag `v*` → release chính thức
   - Push main → `dev-<flavor>-<sha>` prerelease

### Secrets

| Secret | Mục đích |
|---|---|
| `KHONGDICH_KEYSTORE_BASE64` | Keystore signing (base64) |
| `KHONGDICH_KEYSTORE_PASSWORD` | Password keystore |
| `KHONGDICH_KEY_ALIAS` | Key alias |
| `KHONGDICH_KEY_PASSWORD` | Password key |
| `FIREBASE_CONFIG_DEMO_BASE64` | google-services.json cho demo |
| `FIREBASE_CONFIG_PROD_BASE64` | google-services.json cho prod |

Nếu thiếu secrets → fallback debug signing + placeholder Firebase (push disabled).

### Tạo keystore

```bash
keytool -genkey -v -keystore khongdich-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias khongdich
base64 -w 0 khongdich-release.jks  # Paste vào GitHub secret
```

## Launcher icons

Tạo từ backend `static/icons/og-default.png` (2598×2598):

```bash
python3 scripts/generate_mobile_icons.py
```

Sản xuất: mipmap-mdpi→xxxhdpi (48-192px), round icons, adaptive foreground (432px), splash (288px), Play Store 512px.

## Thiết lập đăng nhập Google trên mobile

1. **Google Cloud Console** → APIs & Services → Credentials
2. Tạo **Android** OAuth 2.0 Client ID (package: `com.khongdich.app` / `com.khongdich.app.demo`)
3. Copy client ID (format: `123-android.apps.googleusercontent.com`)
4. Set trên backend:
   ```bash
   GOOGLE_MOBILE_CLIENT_IDS=123-android.apps.googleusercontent.com
   ```
5. Restart backend
6. Trong mobile app's `google-services.json` (Firebase), `oauth_client` section phải chứa cùng client ID

Backend verify id_token qua Google's tokeninfo endpoint, check `iss`/`aud`/`email_verified`, rồi issue JWT.

## Tính năng TTS offline

- **100% on-device** qua `flutter_tts` + `audio_service`
- **Chọn giọng đọc**: dropdown giọng vi-VN từ `flutter_tts.getVoices()`
- **Tốc độ**: 0.5x – 2.5x, persisted to SharedPreferences
- **Highlight text**: đoạn đang đọc được bôi nền tint
- **Control panel**: bottom sheet với play/pause/stop/skip + progress bar
- **Mini player**: hiển thị trong reader khi TTS active
- **Foreground service**: phát nền, notification shade, MediaSession

## Tính năng tải offline

- **Download manager**: serial queue, skip trùng, batch fetch (3+ chương)
- **Real-time UX**: Drift `watch()` streams — queue + library tự cập nhật khi tải xong
- **Story detail**: nút ⬇ tải toàn bộ chương, hiện progress "X/Y đã tải"
- **Offline library**: tab "Đã tải" trong Downloads screen, grouped by story
- **Offline reader**: cùng UI như online reader (ReaderBar, TTS, page-flip, tap zones)
- **Bottom nav badge**: số chương đang tải hiện trên tab Tủ truyện

## License

Private.
