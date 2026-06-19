# Không Dịch — Mobile (Flutter)

Mobile reader app for [khongdich.com](https://khongdich.com). Android-first
MVP, built from `docs/plan-flutter-app.md` (v4) in the backend repo.

## Status (v0.2.0)

**Build:** `flutter analyze` → 0 issues · `flutter test` → 27/27 passing ·
GitHub Actions builds APK + AAB and publishes them to GitHub Releases.

### What's wired

| Area | Plan ref | Status |
|---|---|---|
| Project layout (Appendix A) | §22 | ✅ |
| Material 3 theme + design tokens | §14.1 | ✅ |
| Routing (go_router, 4-tab shell + nested routes) | §14.3 | ✅ |
| Dio + CookieJar (cookie-based auth) | §10 | ✅ |
| WebView Google OAuth → cookie sync | §5.1 | ✅ hybrid (no Bearer yet) |
| CSRF handling (`Origin` header bypass) | backend `csrf.rs` | ✅ |
| Sealed `ChapterContent` model (text/manga/chat/video) | §4.3, §12.2 | ✅ |
| **Custom Dart markdown parser** (CommonMark core + strikethrough) | §13.1, §13.2 | ✅ |
| **MarkdownRenderer** → native widget tree | §4.4 | ✅ |
| TTS markdown preprocessor (pure Dart) | §9.4 | ✅ |
| **Shared markdown fixtures** (11 cases, mirrored to backend) | §13.5 | ✅ |
| Polymorphic chapter reader (text/manga/chat/video) | §14.4 | ✅ |
| YouTube player (`youtube_player_flutter`) | §4.5 | ✅ |
| Manga viewer (`photo_view` + `cached_network_image`) | §4.5 | ✅ |
| Chat bubbles | §4.5 | ✅ |
| Reader settings sheet (font, line height, theme, sepia) | §5.4 | ✅ |
| Reading progress sync (local Drift + server PUT) | §8.4 | ✅ |
| Home / Search / Bookshelf / Profile / Settings / Auth screens | §5, §14.3 | ✅ |
| Story detail screen (HTML scrape — no JSON yet) | §5.3 | ✅ |
| Notifications screen (HTML scrape — no JSON yet) | §6.2 | ✅ |
| Download manager + queue UI | §5.5, §8 | ✅ |
| On-device TTS via `audio_service` + `flutter_tts` | §9 | ✅ |
| Drift on-disk SQLite store | §8.2 | ✅ |
| GitHub Actions CI/CD → APK + AAB → Releases | §17 | ✅ |

### What's deferred

- `google_sign_in` + `POST /api/v1/auth/token` (waiting on backend)
- FCM push notifications (waiting on backend `POST /api/v1/push/register`)
- iOS port (Phase 3)
- Drift schema migration story (currently v1, no migrations needed yet)

## Architecture

The backend's JSON API is **incomplete** — only `/api/v1/search`,
`/api/v1/bookmarks`, `/api/v1/reading-progress`, `/api/v1/notifications`
(stream + read/delete), `/api/v1/csrf-token` exist. The story list,
story detail, chapter list, and chapter content endpoints from plan §12
are **not yet implemented** in the backend.

To unblock the mobile app we use a **hybrid strategy**:

1. **Reads** of story lists / story detail / chapter content go through
   `HtmlStoryDataSource` + `ChapterReaderDataSource`, which scrape the
   SSR HTML pages (`/`, `/truyen/{slug}`, `/truyen/{slug}/chuong/{num}`).
   The HTML is parsed by the `html` Dart package and rebuilt into the
   same DTOs the future JSON endpoints will return.
2. **Writes** (bookmark toggle, reading-progress save, search) use the
   existing JSON endpoints via Dio.
3. **Auth** uses a WebView-based Google OAuth flow: the WebView opens
   `/dang-nhap`, the user completes OAuth, and we copy the resulting
   `kd_auth` cookie from the WebView's CookieManager into our shared
   `PersistCookieJar`. When the backend ships `POST /api/v1/auth/token`,
   swap to `google_sign_in` + Bearer JWT.
4. **CSRF** is handled by setting `Origin: <baseUrl>` on every mutating
   call. The backend's CSRF middleware passes requests whose `Origin`
   host matches the `Host` header (same-origin fallback).

When the backend JSON endpoints land, swapping each `HtmlStoryDataSource`
method for a one-line `dio.get('/api/v1/stories')` is a mechanical
change — the return types already match the planned JSON shapes.

## Project layout

```
lib/
├── main.dart
├── app.dart
├── core/
│   ├── database/app_database.dart       # Drift schema (7 tables)
│   ├── markdown/
│   │   ├── ast.dart                      # sealed Block / Inline AST
│   │   ├── parser.dart                   # custom CommonMark parser
│   │   ├── renderer.dart                 # AST → Flutter widget tree
│   │   └── preprocessor_tts.dart         # md → TTS-friendly chunks
│   ├── network/api_client.dart           # Dio + CookieJar + CSRF
│   ├── observability/app_logger.dart
│   ├── router/app_router.dart
│   ├── shell/main_shell.dart             # bottom-nav shell
│   └── theme/app_theme.dart
├── features/
│   ├── auth/auth_screen.dart             # WebView OAuth flow
│   ├── bookshelf/bookshelf_screen.dart
│   ├── downloads/downloads_screen.dart
│   ├── home/{home_screen.dart, widgets/}
│   ├── notifications/notifications_screen.dart
│   ├── profile/profile_screen.dart
│   ├── reader/
│   │   ├── chapter_reader_screen.dart
│   │   ├── chapter_provider.dart
│   │   ├── reader_settings_provider.dart
│   │   ├── services/reading_progress_service.dart
│   │   ├── views/{text,manga,chat,video}_chapter_view.dart
│   │   └── widgets/{reader_chrome,reader_settings_sheet}.dart
│   ├── search/search_screen.dart
│   ├── settings/settings_screen.dart
│   ├── story/story_detail_screen.dart
│   └── tts/
│       ├── tts_audio_handler.dart        # audio_service + flutter_tts
│       └── tts_mini_player.dart
├── models/{chapter_content,story}.dart
├── repositories/
│   ├── story_repository.dart             # unified read/write client
│   ├── html_story_data_source.dart       # SSR HTML scraping
│   └── chapter_reader_data_source.dart   # chapter HTML scraping
└── services/download_manager.dart        # offline download queue

test/
├── fixtures/markdown-fixtures.json
├── markdown/{fixtures,parser_edge_cases}_test.dart
└── widget_test.dart
```

## Running locally

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # Drift codegen
flutter analyze       # 0 issues
flutter test          # 27 tests, all pass
flutter run           # Android device / emulator required
```

To point at a dev backend:

```bash
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:3000
```

## CI/CD

`.github/workflows/ci.yml` runs on every push and PR:

1. **Analyze + Test** job — every push and PR. Runs `flutter analyze`
   and `flutter test`. Fails the build on any issue.
2. **Build Android** job — only on `main` pushes and `v*` tags. Runs
   `flutter build apk --release` + `flutter build appbundle --release`
   and uploads artifacts.
3. **Publish to GitHub Releases**:
   - On `v*` tags: creates a proper release with the APK + AAB attached.
   - On `main` pushes: creates/updates a `dev-<sha>` prerelease tagged
     "Dev build", so users can always grab the latest APK from the
     Releases page.

### Signing

The release build is signed if these repo secrets are set:

- `KHONGDICH_KEYSTORE_BASE64` — base64-encoded `.jks` keystore
- `KHONGDICH_KEYSTORE_PASSWORD` — keystore password
- `KHONGDICH_KEY_ALIAS` — key alias
- `KHONGDICH_KEY_PASSWORD` — key password

If the secrets are absent, the build falls back to the debug signing
config — useful for dev builds. To create a keystore:

```bash
keytool -genkey -v -keystore khongdich-release.jks \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias khongdich
base64 -w 0 khongdich-release.jks  # paste into GitHub secret
```

## Markdown fixture sync

The shared fixtures live in `test/fixtures/markdown-fixtures.json`. The
backend mirror is `docs/markdown-fixtures.json` in the `khongdich` repo
(plan §13.7 — Option 1: manual copy). When the Rust renderer changes:

1. Update `docs/markdown-fixtures.json` in the backend repo.
2. Run backend tests to verify.
3. Copy the file here.
4. Run `flutter test test/markdown/fixtures_test.dart` — must pass.
5. Commit both repos together.

## License

Private. Not for distribution.
