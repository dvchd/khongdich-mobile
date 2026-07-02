# Không Dịch — Mobile (Flutter)

Ứng dụng đọc truyện mobile cho [khongdich.com](https://khongdich.com). Android-first, xây dựng theo `docs/plan-flutter-app.md` (v4) trong repo backend.

## Trạng thái hiện tại (v0.4.0)

**Build:** `flutter analyze` → 0 lỗi · GitHub Actions build demo + prod APK song song, tự động publish lên GitHub Releases.

### Kiến trúc

Backend (`khongdich`) cung cấp JSON API tại `/api/v1/mobile/*` với Bearer JWT auth. App Flutter gọi trực tiếp JSON — không qua WebView, cookie, hay HTML scraping.

- **Auth:** `google_sign_in` trên thiết bị → exchange id_token qua `POST /api/v1/mobile/auth/token` → JWT server lưu trong `flutter_secure_storage` → gửi qua `Authorization: Bearer <jwt>` trên mọi request.
- **Đọc truyện:** mọi list/detail/chapter content đi qua JSON endpoint (`/api/v1/mobile/stories`, `/api/v1/mobile/chapters/{id}`, ...).
- **Ghi dữ liệu:** bookmark toggle, reading progress, sync, push register — tất cả JSON.
- **Đa môi trường:** app build 2 flavor:
  - **demo** → `https://demo.khongdich.com` (test nội bộ, package `com.khongdich.app.demo`)
  - **prod** → `https://khongdich.com` (chính thức, package `com.khongdich.app`)
  - Flavor baked-in qua `--dart-define=APP_ENV` + `--flavor`. Hai APK cài song song trên cùng thiết bị.
  - **Lưu ý:** không còn runtime env switcher trong Settings — mỗi flavor là 1 binary riêng, environment cố định tại build-time.

### Tính năng đã hoàn thành

| Tính năng | Trạng thái |
|---|---|
| Material 3 theme + design tokens | ✅ |
| Routing (go_router, 4-tab shell + nested routes) | ✅ |
| Dio + Bearer JWT + secure storage | ✅ |
| Google Sign-In → JWT exchange | ✅ |
| Sealed `ChapterContent` (text/manga/chat/video) | ✅ |
| Custom Dart markdown parser + renderer | ✅ |
| Chapter reader đa content_type (text/manga/chat/video) | ✅ |
| YouTube player (`youtube_player_flutter` v10) | ✅ |
| Manga viewer (`photo_view` + `cached_network_image`) | ✅ |
| Chat bubbles + progressive reveal (giống web) | ✅ |
| Reader settings (font, size, line height, theme sepia, scroll mode) | ✅ |
| Reading progress sync (local Drift + server PUT) | ✅ |
| Home / Search / Bookshelf / Profile / Settings | ✅ |
| Story detail (JSON `/api/v1/mobile/stories/{id_or_slug}`) | ✅ |
| Notifications (JSON `/api/v1/mobile/notifications`) | ✅ |
| Download manager + queue UI + real-time progress | ✅ |
| Tải offline + đọc offline (offline library + offline reader) | ✅ |
| **Manga offline image download** (tải cả ảnh về local) | ✅ |
| **Bookshelf tab "Tất cả"** (gộp bookmark + đã tải, dedupe) | ✅ |
| **Bookshelf auto-fallback offline** (bấm truyện đã tải → offline detail) | ✅ |
| **Story-level downloaded badge** (hiện trên bìa mọi screen) | ✅ |
| **Bottom nav trên story detail** (cả online + offline) | ✅ |
| On-device TTS (`audio_service` + `flutter_tts`) | ✅ |
| **TTS engine selector** (chọn `com.google.android.tts` / Samsung / ...) | ✅ |
| **TTS voice dropdown** (hiện cả locale: `vi-vn-language (vi-VN)`) | ✅ |
| TTS control panel (play/pause/speed/voice/engine/progress) | ✅ |
| TTS text highlighting (bôi đoạn đang đọc) | ✅ |
| Drift on-disk SQLite store (7 bảng, schema v4) | ✅ |
| Batch sync (`POST /api/v1/mobile/sync`) | ✅ |
| FCM push (`firebase_messaging`) | ✅ |
| Launcher icons (từ web OG image) | ✅ |
| Multi-env flavor build (demo / prod) | ✅ |
| GitHub Actions CI/CD → APK → Releases | ✅ |
| Theme app (system/light/dark) + persisted | ✅ |
| Page-flip mode (lật trang + chia trang theo TextPainter) | ✅ |
| Tap zones — center mở ReaderSettingsSheet | ✅ |
| Real-time download UX (Drift `watch()` streams) | ✅ |
| 120 FPS trên thiết bị hỗ trợ | ✅ |
| Splash screen (logo app, theme-aware) | ✅ |
| **Reader code refactor** — online + offline dùng chung `ReaderBody` | ✅ |

### Chưa hoàn thành / Trì hoãn

- iOS port (Phase 3)
- `firebase_crashlytics` / `firebase_analytics` (observability)

## Cấu trúc dự án

```
lib/
├── main.dart                            # Khởi tạo Firebase + Riverpod + 120fps
├── app.dart                             # MaterialApp.router + splash khi ApiClient loading
├── core/
│   ├── database/app_database.dart       # Drift schema (7 bảng, v4)
│   ├── markdown/                        # AST + parser + renderer + TTS preprocessor
│   ├── network/api_client.dart          # Dio + Bearer JWT + env từ dart-define
│   ├── observability/app_logger.dart
│   ├── router/app_router.dart           # go_router + OfflineChapterReader (dùng ReaderBody)
│   ├── shell/main_shell.dart            # bottom-nav shell + AppBottomNav
│   ├── theme/app_theme.dart             # M3 theme + ThemeModeNotifier
│   └── widgets/
│       └── app_bottom_nav.dart          # Reusable bottom nav (MainShell + detail screens)
├── features/
│   ├── auth/auth_screen.dart            # google_sign_in → /mobile/auth/token
│   ├── bookshelf/bookshelf_screen.dart  # 6-tab: Tất cả / Đang đọc / Đã đọc xong / Sẽ đọc / Yêu thích / Đã tải
│   ├── downloads/
│   │   ├── downloads_screen.dart        # TabBar: Đang tải + Đã tải (real-time Drift streams)
│   │   ├── offline_library_screen.dart  # StreamProvider + downloadedStoryIdsProvider
│   │   └── offline_story_detail_screen.dart   # + bottom nav
│   ├── home/{home_screen.dart, widgets/}
│   │   └── widgets/story_card.dart      # ConsumerWidget — auto green downloaded badge
│   ├── notifications/notifications_screen.dart
│   ├── profile/profile_screen.dart
│   ├── reader/
│   │   ├── chapter_reader_screen.dart   # Online reader — thin wrapper gọi ReaderBody
│   │   ├── chapter_provider.dart
│   │   ├── reader_settings_provider.dart
│   │   ├── services/reading_progress_service.dart
│   │   ├── views/                       # text/manga/chat/video views
│   │   └── widgets/
│   │       ├── reader_body.dart         # SHARED reader body (online + offline)
│   │       ├── reader_helpers.dart      # resolveReaderTheme, buildChapterContent, swipe/page wrappers
│   │       ├── chapter_list_sheet.dart  # SHARED chapter list bottom sheet
│   │       ├── reader_bar.dart          # App bar + TTS + chapter list + settings
│   │       └── reader_settings_sheet.dart
│   ├── search/search_screen.dart        # + offline fallback → bookshelf tab Đã tải
│   ├── settings/settings_screen.dart    # Theme app + reader settings (đã bỏ env switcher)
│   ├── story/story_detail_screen.dart   # 3:4 cover + download button + realtime + bottom nav
│   └── tts/
│       ├── tts_audio_handler.dart       # engine + voice + speed + chunk chaining
│       ├── tts_control_panel.dart       # Bottom sheet: play/pause/speed/voice/engine/progress
│       └── tts_mini_player.dart
├── models/{chapter_content,story}.dart
├── repositories/story_repository.dart    # JSON client cho mọi /api/v1/mobile endpoints
└── services/
    ├── download_manager.dart             # Serial queue + batch + manga image fetch
    └── manga_image_downloader.dart       # Download manga images → local files

android/
└── app/
    ├── google-services.placeholder.json
    ├── build.gradle.kts                  # demo + prod flavors, signing, desugaring
    └── src/{main,demo,prod,debug,profile}/
        └── res/values/strings.xml        # app_name override per flavor
```

## Chạy local

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # Drift codegen
flutter analyze       # 0 lỗi
flutter test

# Build demo flavor (demo.khongdich.com, package com.khongdich.app.demo)
flutter run --flavor=demo --dart-define=APP_ENV=demo

# Build prod flavor (khongdich.com, package com.khongdich.app)
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

---

## Thiết lập đăng nhập Google (OAuth 2.0 Client ID)

App dùng `google_sign_in` để lấy `id_token`, gửi lên backend đổi lấy JWT server. Backend verify `id_token` qua Google tokeninfo endpoint — cần biết trước **OAuth Client ID** mà app dùng để ký.

### Câu hỏi thường gặp

> **Có cần tạo 2 OAuth Client ID riêng cho demo và prod không?**

**CÓ.** Vì 2 flavor có 2 package name khác nhau:
- demo: `com.khongdich.app.demo`
- prod: `com.khongdich.app`

Mỗi OAuth Android Client ID được bind với **một package name duy nhất** + một SHA-1 fingerprint. Vì 2 flavor có 2 package name khác nhau, phải tạo 2 Client ID riêng.

Tuy nhiên, **có thể gộp 2 SHA-1 (debug + release) vào cùng 1 Client ID** — Google cho phép nhiều SHA-1 trên một Client ID. Vậy setup tối ưu:

| | Client ID "Demo" | Client ID "Prod" |
|---|---|---|
| Package name | `com.khongdich.app.demo` | `com.khongdich.app` |
| SHA-1 (debug keystore local) | ✅ | ✅ |
| SHA-1 (release keystore CI) | ✅ | ✅ |

### Bước 1 — Lấy SHA-1 fingerprint

#### Debug keystore (local dev)

Mặc định Flutter dùng debug keystore tại `~/.android/debug.keystore` với password `android`:

```bash
keytool -list -v \
  -keystore ~/.android/debug.keystore \
  -alias androiddebugkey \
  -storepass android \
  -keypass android | grep SHA1
```

Output:
```
SHA1: AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD
```

#### Release keystore (CI/CD)

Nếu đã có `khongdich-release.jks` (xem phần "Tạo keystore" ở trên):

```bash
keytool -list -v \
  -keystore khongdich-release.jks \
  -alias khongdich \
  -storepass <your-keystore-password> | grep SHA1
```

Copy cả 2 SHA-1 (debug + release) để thêm vào Client ID ở bước sau.

### Bước 2 — Tạo 2 Android OAuth Client ID trên Google Cloud Console

1. Vào **[Google Cloud Console](https://console.cloud.google.com/)** → chọn project (cùng project với Firebase của app).
2. Menu **APIs & Services** → **Credentials**.
3. Nút **+ CREATE CREDENTIALS** → **OAuth client ID**.
4. Form hiện ra (đúng như ảnh chụp màn hình):

   - **Application type**: `Android`
   - **Name**: `Không Dịch Android (Demo)` (chỉ là tên nội bộ, không hiển thị cho user)
   - **Package name**: `com.khongdich.app.demo`
   - **SHA-1 certificate fingerprint**: paste SHA-1 debug (local), bấm **ADD**, rồi paste SHA-1 release (CI).
5. Bấm **CREATE**. Copy Client ID (format `1234567890-abcdefg.apps.googleusercontent.com`).
6. **Lặp lại bước 3-5** cho prod:
   - **Name**: `Không Dịch Android (Prod)`
   - **Package name**: `com.khongdich.app`
   - **SHA-1**: cùng 2 SHA-1 như trên (debug + release).
   - Copy Client ID prod.

### Bước 3 — Cấu hình backend

Backend có env var `GOOGLE_MOBILE_CLIENT_IDS` chấp nhận **nhiều Client ID phân tách bằng dấu phẩy** (xem backend `verify_google_id_token`). Set cả 2:

```bash
# .env trên backend
GOOGLE_MOBILE_CLIENT_IDS=\
1234567890-aaaaaaa.apps.googleusercontent.com,\
0987654321-bbbbbbb.apps.googleusercontent.com
```

- Client ID demo để backend chấp nhận `id_token` từ app demo flavor.
- Client ID prod để backend chấp nhận `id_token` từ app prod flavor.
- Backend không quan tâm flavor nào — chỉ check `aud` (audience) của `id_token` có match một trong các Client ID được cấu hình.

Restart backend sau khi set env.

### Bước 4 — Cấu hình Firebase (google-services.json)

`google-services.json` chứa Firebase config + `oauth_client` section. Mobile app đọc file này khi khởi tạo Firebase.

1. Vào **[Firebase Console](https://console.firebase.google.com/)** → chọn project.
2. Menu **Project settings** (icon gear) → tab **General**.
3. Cuối trang, mục **Your apps** — chọn Android app có package `com.khongdich.app.demo` → **Download google-services.json**. Đây là file cho demo.
4. Tương tự với Android app có package `com.khongdich.app` → **Download google-services.json**. Đây là file cho prod.
5. File `google-services.json` từ Firebase **đã tự động chứa** cả 2 OAuth Client ID ở bước 2 (Firebase sync với Google Cloud). Nếu bạn thêm Client ID mới, có thể cần bấm **Download lại** để Firebase cập nhật `oauth_client` section.
6. Base64 encode 2 file và set làm GitHub secrets:

```bash
# Demo
base64 -w 0 google-services-demo.json
# Paste vào GitHub secret FIREBASE_CONFIG_DEMO_BASE64

# Prod
base64 -w 0 google-services-prod.json
# Paste vào GitHub secret FIREBASE_CONFIG_PROD_BASE64
```

### Bước 5 — Verify

```bash
# Build demo APK, cài lên thiết bị, đăng nhập Google → phải thành công
flutter run --flavor=demo --dart-define=APP_ENV=demo

# Build prod APK, cài lên thiết bị (cài song song với demo), đăng nhập Google → phải thành công
flutter run --flavor=prod --dart-define=APP_ENV=prod
```

Nếu đăng nhập báo lỗi `DEVELOPER_ERROR` → thường là do:
- SHA-1 chưa thêm vào Client ID (hoặc thêm sai).
- Package name trong Client ID không khớp `applicationId` của flavor.
- File `google-services.json` cũ (chưa có Client ID mới) — download lại từ Firebase.

### Kiểm tra nhanh trên Firebase

Trong Firebase Console → **Authentication** → **Sign-in method** → **Google** → đảm bảo **Enabled**. Mục **Authorized domains** không cần cấu hình cho mobile (chỉ áp dụng cho web OAuth).

---

## Tính năng TTS offline

**Định hướng: 100% on-device TTS offline.** App mobile KHÔNG tải file audio
từ server. Toàn bộ text-to-speech được thực hiện on-device qua `flutter_tts`
(Android system TTS). Chương được tải về (text content) → chia thành các
chunk ~500 ký tự → `flutter_tts.speak()` đọc tuần tự. Không cần mạng, không
tải MP3, không phụ thuộc backend.

- **100% on-device** qua `flutter_tts` + `audio_service`
- **Engine selector**: dropdown chọn TTS engine (`com.google.android.tts` mặc định, hoặc Samsung/Huawei nếu có)
- **Voice selector**: dropdown giọng đọc — hiện cả locale, vd: `vi-vn-language (vi-VN)`. Tự sort tiếng Việt lên đầu.
- **Tốc độ**: 0.5x – 2.5x, persisted to SharedPreferences
- **Highlight text**: đoạn đang đọc được bôi nền tint
- **Control panel**: bottom sheet với play/pause/stop/skip + progress bar
- **Mini player**: hiển thị trong reader khi TTS active
- **Foreground service**: phát nền, notification shade, MediaSession
- **Error recovery**: nếu init fail, tự retry lần sau. Control panel có
  nút "Thử lại" để retry thủ công + hiển thị lỗi (vd: chưa cài giọng tiếng Việt).

### Các bug đã fix (lịch sử)

Trước đây TTS offline bị several bugs khiến "sửa mấy lần vẫn không hoạt động":

1. **`_init()` đánh dấu initialised quá sớm** — nếu init fail (setEngine
   throw trên Samsung, getVoices malformed), handler bị broken vĩnh viễn,
   restart app cũng fail. Fix: `_initialised` chỉ set `true` ở cuối try
   block; provider vẫn return handler nhưng `_initialised` false → retry
   tự động lần sau; UI có nút "Thử lại" gọi `reinit()`.

2. **Re-entrancy race** — completion handler gọi `_speakCurrentChunk()`
   fire-and-forget TRƯỚC khi `speak()` Future resolve → trên Samsung/Huawei
   engine, speak() re-entrant bị drop → "TTS đọc 1 chunk rồi dừng". Fix:
   bỏ completion handler, dùng while-loop trong `_speakLoop()` với
   `awaitSpeakCompletion(true)`.

3. **Không chuyển chương khi tap headphone** — nếu TTS đang play/pause
   chương A, tap headphone ở chương B → `loadChapter` bị skip → user thấy
   "TTS không hoạt động". Fix: so sánh `handler.currentChapterId != chapter.id`
   → luôn stop + loadChapter + play khi chuyển chương.

4. **`speak()` return value bị ignore** — nếu engine reject (no Vietnamese
   voice), TTS hang silently ở chunk 0. Fix: check `result != 1` → surface
   error qua `processingState: error` + `errorMessage`. Control panel hiện
   banner lỗi với nút "Thử lại".

5. **`_savePlaybackState` block hot path** — DB write awaited giữa các
   chunk gây gap nghe được. Fix: fire-and-forget via `unawaited()`.

### Tại sao TTS offline có thể không có giọng tiếng Việt?

Một số thiết bị (đặc biệt ROM custom, ROM Trung Quốc) không cài sẵn giọng tiếng Việt. Cách khắc phục:

1. Android Settings → **Ngôn ngữ & nhập** → **Văn bản thành giọng nói** (Text-to-speech).
2. Chọn engine `Google` (`com.google.android.tts`).
3. Bấm **Cài đặt** → **Cài đặt giọng nói** → cài giọng `Vietnamese (Vietnam)`.
4. Quay lại app → mở TTS control panel → giọng tiếng Việt giờ sẽ xuất hiện trong dropdown.

Nếu TTS vẫn không đọc được, mở TTS control panel → xem banner lỗi → bấm
"Thử lại". Nếu vẫn lỗi, kiểm tra engine selector ở dropdown — thử đổi sang
engine khác (Google thay vì Samsung, hoặc ngược lại).

## Tính năng tải offline

- **Download manager**: serial queue, skip trùng, batch fetch (3+ chương)
- **Real-time UX**: Drift `watch()` streams — queue + library tự cập nhật khi tải xong
- **Story detail**: nút ⬇ tải toàn bộ chương, hiện progress "X/Y đã tải"
- **Manga offline**: tự động tải tất cả ảnh của chương về local storage (`<appSupportDir>/manga/<chapterId>/`). Khi offline, `MangaChapterView` render từ local files thay vì network.
- **Offline library**: tab "Đã tải" trong Downloads screen, grouped by story
- **Offline reader**: dùng chung `ReaderBody` với online reader — cùng UI, cùng tính năng (TTS, page-flip, tap zones, theme)
- **Bottom nav badge**: số chương đang tải hiện trên tab Tủ truyện
- **Bookshelf auto-fallback**: bấm truyện đã tải trong tab "Tất cả" (hoặc bất kỳ tab nào) → tự động vào offline story detail, không cần mạng
- **Migration path**: chương manga tải trước khi có image-download feature → khi mở offline reader lần đầu, app tự download on-demand

## License

Private.
