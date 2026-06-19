# Không Dịch — Mobile (Flutter)

Mobile reader app for [khongdich.com](https://khongdich.com). Android-first
MVP scaffold, built from `docs/plan-flutter-app.md` (v4) in the backend
repo.

## Status

This is the **MVP scaffold** — the architectural backbone of Phase 1.
Everything listed in the plan's Appendix A project structure is in place
and the project passes `flutter analyze` (0 issues) and `flutter test`
(22/22).

| Area | Plan ref | Status |
|---|---|---|
| Project layout (Appendix A) | §22 | ✅ |
| Material 3 theme + design tokens | §14.1 | ✅ |
| Routing (go_router, 4-tab shell) | §14.3 | ✅ |
| Dio API client + JWT interceptor | §10.2 | ✅ |
| Sealed `ChapterContent` model (text/manga/chat/video) | §4.3, §12.2 | ✅ |
| Story / chapter repositories | §10.3 | ✅ |
| **Custom Dart markdown parser** (CommonMark core + strikethrough) | §13.1, §13.2 | ✅ |
| **MarkdownRenderer** → native widget tree | §4.4 | ✅ |
| TTS markdown preprocessor (pure Dart) | §9.4 | ✅ |
| **Shared markdown fixtures** (11 cases, mirrored to backend) | §13.5 | ✅ |
| Polymorphic chapter reader (text/manga/chat/video) | §14.4 | ✅ |
| Home / Search / Bookshelf / Profile / Settings / Auth screens | §5, §14.3 | ✅ |
| Story detail screen | §5.3 | ✅ |
| SQLite schema (record types + in-memory stub) | §8.2 | ✅ stub |
| Drift on-disk store | §8.2 | ⏳ Phase 1 milestone |
| On-device TTS (`flutter_tts` + `audio_service`) | §9 | ⏳ Phase 2 |
| Google Sign-In + JWT exchange | §5.1 | ⏳ Phase 2 |
| FCM push notifications | §15 | ⏳ Phase 2 |
| Firebase Crashlytics / Analytics | §16 | ⏳ Phase 2 |
| iOS port | §7.1 | ⏳ Phase 3 |

## Project layout

```
lib/
├── main.dart
├── app.dart                          # MaterialApp.router
├── core/
│   ├── api/api_client.dart           # Dio + JWT interceptor
│   ├── database/app_database.dart    # SQLite schema (stub, Drift-ready)
│   ├── markdown/
│   │   ├── ast.dart                  # sealed Block / Inline AST
│   │   ├── parser.dart               # custom CommonMark parser
│   │   ├── renderer.dart             # AST → Flutter widget tree
│   │   ├── preprocessor_tts.dart     # md → TTS-friendly chunks
│   │   └── markdown.dart             # barrel
│   ├── observability/app_logger.dart
│   ├── router/app_router.dart        # go_router config
│   ├── shell/main_shell.dart         # bottom-nav shell
│   ├── storage/secure_storage.dart   # JWT storage
│   └── theme/app_theme.dart          # M3 theme + design tokens
├── features/
│   ├── auth/auth_screen.dart
│   ├── bookshelf/bookshelf_screen.dart
│   ├── home/{home_screen.dart, widgets/story_card.dart}
│   ├── profile/profile_screen.dart
│   ├── reader/
│   │   ├── chapter_reader_screen.dart    # polymorphic dispatcher
│   │   ├── chapter_provider.dart
│   │   ├── reader_providers.dart
│   │   ├── reader_settings_provider.dart
│   │   ├── views/
│   │   │   ├── text_chapter_view.dart    # uses MarkdownRenderer
│   │   │   ├── manga_chapter_view.dart   # photo_view gallery
│   │   │   ├── chat_chapter_view.dart    # chat bubbles
│   │   │   └── video_chapter_view.dart   # YouTube placeholder
│   │   └── widgets/reader_chrome.dart
│   ├── search/search_screen.dart
│   ├── settings/settings_screen.dart
│   └── story/story_detail_screen.dart
├── models/
│   ├── chapter_content.dart          # sealed ChapterContent
│   └── story.dart
└── repositories/
    └── story_repository.dart

test/
├── fixtures/
│   └── markdown-fixtures.json        # shared with backend (plan §13.5)
├── markdown/
│   ├── fixtures_test.dart            # fixture sync test
│   └── parser_edge_cases_test.dart
└── widget_test.dart                  # app boot smoke test
```

## Running

```bash
flutter pub get
flutter analyze       # 0 issues
flutter test          # 22 tests, all pass
flutter run           # Android device / emulator required
```

To point at a dev backend:

```bash
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080
```

## Wiring the Phase-2 subsystems

Each Phase-2/3 subsystem is scaffolded but gated behind a feature flag
(pubspec comment). To enable:

### On-device TTS (Phase 2)

1. Uncomment `audio_service`, `flutter_tts`, `audio_session` in `pubspec.yaml`.
2. Add a `TtsAudioHandler` (plan §9.5) under `lib/features/tts/`.
3. Register the foreground service in `android/app/src/main/AndroidManifest.xml`.
4. Wire `AudioService.init()` in `main.dart` before `runApp`.

### Google Sign-In + JWT (Phase 2)

1. Uncomment `google_sign_in` and `app_links` in `pubspec.yaml`.
2. Create a Firebase project, drop `google-services.json` into
   `android/app/`.
3. Implement `POST /api/v1/auth/token` on the backend (plan §12.1).
4. Replace `AuthScreen`'s "coming soon" callback with a real sign-in flow.

### Drift on-disk store (Phase 1 milestone)

1. Uncomment `drift`, `sqlite3_flutter_libs`, `drift_dev`, `build_runner`
   in `pubspec.yaml`.
2. Convert each `*Record` class in `lib/core/database/app_database.dart`
   to a Drift `Table` subclass (the field types map 1:1).
3. Run `dart run build_runner build --delete-conflicting-outputs`.
4. Replace the `AppDatabase` stub with the generated `_$AppDatabase`.

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
