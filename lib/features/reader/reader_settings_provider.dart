import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Reader display preferences (plan §5.4). Persisted to Drift `app_settings`
/// in a later milestone; for the MVP build they live in memory.
class ReaderSettings {
  const ReaderSettings({
    this.fontSize = 18,
    this.lineHeight = 1.6,
    this.fontFamily = 'NotoSerif',
    this.theme = ReaderThemeMode.system,
  });

  final double fontSize;
  final double lineHeight;
  final String fontFamily;
  final ReaderThemeMode theme;

  ReaderSettings copyWith({
    double? fontSize,
    double? lineHeight,
    String? fontFamily,
    ReaderThemeMode? theme,
  }) =>
      ReaderSettings(
        fontSize: fontSize ?? this.fontSize,
        lineHeight: lineHeight ?? this.lineHeight,
        fontFamily: fontFamily ?? this.fontFamily,
        theme: theme ?? this.theme,
      );
}

enum ReaderThemeMode { system, light, dark, sepia }

final readerSettingsProvider =
    StateNotifierProvider<ReaderSettingsNotifier, ReaderSettings>(
  (ref) => ReaderSettingsNotifier(),
);

class ReaderSettingsNotifier extends StateNotifier<ReaderSettings> {
  ReaderSettingsNotifier() : super(const ReaderSettings());

  void setFontSize(double v) => state = state.copyWith(fontSize: v);
  void setLineHeight(double v) => state = state.copyWith(lineHeight: v);
  void setFontFamily(String v) => state = state.copyWith(fontFamily: v);
  void setTheme(ReaderThemeMode v) => state = state.copyWith(theme: v);
}
