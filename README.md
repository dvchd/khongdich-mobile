# Không Dịch — Mobile (Flutter)

Mobile reader app for [khongdich.com](https://khongdich.com). Android-first
MVP, built from `docs/plan-flutter-app.md` (v4) in the backend repo.

## Status (v0.3.0)

**Build:** `flutter analyze` → 0 issues · `flutter test` → 27/27 passing ·
GitHub Actions builds **demo + prod** APKs in parallel and publishes them
to GitHub Releases.

### Architecture (v0.3 — Bearer JWT + JSON API)

The backend now ships a full mobile JSON API at `/api/v1/mobile/*` with
Bearer-JWT auth (see backend `src/api/mobile.rs`). The mobile app has been
rewritten to use it directly — **no more WebView, no more cookie jar, no
more HTML scraping**.

- **Auth**: `google_sign_in` on the device → exchange id_token via
  `POST /api/v1/mobile/auth/token` → server-issued JWT stored in
  `flutter_secure_storage` → sent on every request via
  `Authorization: Bearer <jwt>`.
- **Reads**: every list/detail/content fetch goes through a typed JSON
  endpoint (`/api/v1/mobile/stories`, `/api/v1/mobile/chapters/{id}`, …).
- **Writes**: bookmark toggle, reading-progress save, sync, push-token
  register — all JSON.
- **Environment switcher**: the app ships in two flavors:
  - **demo** → `https://demo.khongdich.com` (QA testing)
  - **prod** → `https://khongdich.com` (public)
  
  The flavor is baked in at build time via `--dart-define=APP_ENV=demo|prod`
  + `--flavor=demo|prod`. Each flavor has a distinct `applicationIdSuffix`
  so both can coexist on a single device. Users can also switch at runtime
  via Settings → Môi trường (persists to secure storage, requires app
  restart).

### What's wired

| Area | Plan ref | Status |
|---|---|---|
| Project layout (Appendix A) | §22 | ✅ |
| Material 3 theme + design tokens | §14.1 | ✅ |
| Routing (go_router, 4-tab shell + nested routes) | §14.3 | ✅ |
| Dio + Bearer JWT + secure storage | §10 | ✅ |
| Google Sign-In → JWT exchange | §5.1 | ✅ |
| Sealed `ChapterContent` model (text/manga/chat/video) | §4.3, §12.2 | ✅ |
| Custom Dart markdown parser + renderer | §13 | ✅ |
| Shared markdown fixtures (11 cases) | §13.5 | ✅ |
| Polymorphic chapter reader (text/manga/chat/video) | §14.4 | ✅ |
| YouTube player (`youtube_player_flutter` v10) | §4.5 | ✅ |
| Manga viewer (`photo_view` + `cached_network_image`) | §4.5 | ✅ |
| Chat bubbles with per-participant color | §4.5 | ✅ |
| Reader settings sheet (font, line height, theme, sepia) | §5.4 | ✅ |
| Reading progress sync (local Drift + server PUT) | §8.4 | ✅ |
| Home / Search / Bookshelf / Profile / Settings / Auth screens | §5, §14.3 | ✅ |
| Story detail (JSON `/api/v1/mobile/stories/{id_or_slug}`) | §5.3 | ✅ |
| Notifications (JSON `/api/v1/mobile/notifications`) | §6.2 | ✅ |
| Download manager + queue UI | §5.5, §8 | ✅ |
| On-device TTS via `audio_service` + `flutter_tts` | §9 | ✅ |
| Drift on-disk SQLite store | §8.2 | ✅ |
| Batch sync (`POST /api/v1/mobile/sync`) | §12.4 | ✅ |
| FCM push (`firebase_messaging` + `/api/v1/mobile/push/register`) | §15 | ✅ |
| Android launcher icons (generated from web OG image) | §14.1 | ✅ |
| Multi-env flavor build (demo / prod) | §17 | ✅ |
| GitHub Actions CI/CD → APK → Releases | §17 | ✅ |

### What's deferred

- iOS port (Phase 3)
- `firebase_crashlytics` / `firebase_analytics` (observability rollout)
- Drift schema migration story (currently v1)

## Project layout

```
lib/
├── main.dart                            # bootstraps Firebase + Riverpod
├── app.dart                             # MaterialApp.router
├── core/
│   ├── database/app_database.dart       # Drift schema (7 tables)
│   ├── markdown/
│   │   ├── ast.dart                      # sealed Block / Inline AST
│   │   ├── parser.dart                   # custom CommonMark parser
│   │   ├── renderer.dart                 # AST → Flutter widget tree
│   │   └── preprocessor_tts.dart         # md → TTS-friendly chunks
│   ├── network/api_client.dart           # Dio + Bearer JWT + env switcher
│   ├── observability/app_logger.dart
│   ├── router/app_router.dart
│   ├── shell/main_shell.dart             # bottom-nav shell
│   └── theme/app_theme.dart
├── features/
│   ├── auth/auth_screen.dart             # google_sign_in → /mobile/auth/token
│   ├── bookshelf/bookshelf_screen.dart
│   ├── downloads/downloads_screen.dart
│   ├── home/{home_screen.dart, widgets/}
│   ├── notifications/notifications_screen.dart
│   ├── profile/profile_screen.dart       # uses /mobile/auth/me
│   ├── reader/
│   │   ├── chapter_reader_screen.dart
│   │   ├── chapter_provider.dart
│   │   ├── reader_settings_provider.dart
│   │   ├── services/reading_progress_service.dart
│   │   ├── views/{text,manga,chat,video}_chapter_view.dart
│   │   └── widgets/{reader_chrome,reader_settings_sheet}.dart
│   ├── search/search_screen.dart
│   ├── settings/settings_screen.dart     # env switcher lives here
│   ├── story/story_detail_screen.dart
│   └── tts/{tts_audio_handler,tts_mini_player}.dart
├── models/{chapter_content,story}.dart
├── repositories/story_repository.dart    # unified JSON client
└── services/download_manager.dart        # offline download queue

android/
└── app/
    ├── google-services.placeholder.json   # CI overwrites with real config
    ├── build.gradle.kts                   # demo + prod flavors, signing
    └── src/main/res/
        ├── mipmap-*/ic_launcher*.png       # generated from web OG image
        ├── mipmap-anydpi-v26/ic_launcher*.xml  # adaptive icons
        ├── drawable/ic_launcher_splash.png # splash logo
        ├── drawable/launch_background.xml   # splash background
        └── values/ic_launcher_colors.xml    # adaptive icon bg color

scripts/generate_mobile_icons.py           # regenerates launcher icons
```

## Running locally

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # Drift codegen
flutter analyze       # 0 issues
flutter test          # 27 tests, all pass

# Build demo flavor (talks to demo.khongdich.com)
flutter run --flavor=demo --dart-define=APP_ENV=demo

# Build prod flavor (talks to khongdich.com)
flutter run --flavor=prod --dart-define=APP_ENV=prod
```

## CI/CD

`.github/workflows/ci.yml` runs on every push and PR:

1. **Analyze + Test** job — every push and PR. Runs `flutter analyze`
   and `flutter test`. Fails the build on any issue.
2. **Build Android (demo + prod)** matrix job — only on `main` pushes
   and `v*` tags. Builds two APKs in parallel:
   - `khongdich-demo-<sha>.apk` → talks to `demo.khongdich.com`
   - `khongdich-prod-<sha>.apk` → talks to `khongdich.com`
3. **Publish to GitHub Releases**:
   - On `v*` tags: creates a proper release with both APKs attached.
   - On `main` pushes: creates/updates `dev-<flavor>-<sha>` prereleases
     tagged "Dev build", so QA can always grab the latest APKs.

### Secrets

For full release signing + Firebase push notifications, set these repo
secrets:

| Secret | Purpose |
|---|---|
| `KHONGDICH_KEYSTORE_BASE64` | Base64-encoded `.jks` keystore for release signing |
| `KHONGDICH_KEYSTORE_PASSWORD` | Keystore password |
| `KHONGDICH_KEY_ALIAS` | Key alias inside the keystore |
| `KHONGDICH_KEY_PASSWORD` | Key password |
| `FIREBASE_CONFIG_DEMO_BASE64` | Base64 of `google-services.json` for the demo Firebase project |
| `FIREBASE_CONFIG_PROD_BASE64` | Base64 of `google-services.json` for the prod Firebase project |

If absent, the build falls back to debug signing + a placeholder
`google-services.json` (push notifications will be disabled, but the
APK still installs and runs).

To create a keystore:

```bash
keytool -genkey -v -keystore khongdich-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias khongdich
base64 -w 0 khongdich-release.jks  # paste into GitHub secret
```

## Launcher icons

The Android launcher icons (`mipmap-*/ic_launcher*.png`, adaptive
foreground, splash) are generated from the backend's existing web
`static/icons/og-default.png` (2598×2598 PNG). The generator script
lives at `scripts/generate_mobile_icons.py` and can be re-run any time
the web logo changes:

```bash
python3 scripts/generate_mobile_icons.py
```

It also produces a 512×512 `download/play-store-icon-512.png` for the
Play Store listing.

## License

Private. Not for distribution.
