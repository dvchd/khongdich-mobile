import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Reader display preferences (plan §5.4). Persisted to
/// `shared_preferences` so they survive across sessions.
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

  Map<String, dynamic> toJson() => {
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'fontFamily': fontFamily,
        'theme': theme.name,
      };

  factory ReaderSettings.fromJson(Map<String, dynamic> json) => ReaderSettings(
        fontSize: (json['fontSize'] as num?)?.toDouble() ?? 18,
        lineHeight: (json['lineHeight'] as num?)?.toDouble() ?? 1.6,
        fontFamily: json['fontFamily'] as String? ?? 'NotoSerif',
        theme: ReaderThemeMode.values.firstWhere(
          (m) => m.name == (json['theme'] as String?),
          orElse: () => ReaderThemeMode.system,
        ),
      );
}

enum ReaderThemeMode { system, light, dark, sepia }

final readerSettingsProvider =
    StateNotifierProvider<ReaderSettingsNotifier, ReaderSettings>(
  (ref) => ReaderSettingsNotifier(),
);

class ReaderSettingsNotifier extends StateNotifier<ReaderSettings> {
  ReaderSettingsNotifier() : super(const ReaderSettings()) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final fontSize = prefs.getDouble('reader.fontSize');
    final lineHeight = prefs.getDouble('reader.lineHeight');
    final fontFamily = prefs.getString('reader.fontFamily');
    final themeName = prefs.getString('reader.theme');
    state = ReaderSettings(
      fontSize: fontSize ?? state.fontSize,
      lineHeight: lineHeight ?? state.lineHeight,
      fontFamily: fontFamily ?? state.fontFamily,
      theme: ReaderThemeMode.values.firstWhere(
        (m) => m.name == themeName,
        orElse: () => ReaderThemeMode.system,
      ),
    );
  }

  Future<void> setFontSize(double v) async {
    state = state.copyWith(fontSize: v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('reader.fontSize', v);
  }

  Future<void> setLineHeight(double v) async {
    state = state.copyWith(lineHeight: v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('reader.lineHeight', v);
  }

  Future<void> setFontFamily(String v) async {
    state = state.copyWith(fontFamily: v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('reader.fontFamily', v);
  }

  Future<void> setTheme(ReaderThemeMode v) async {
    state = state.copyWith(theme: v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('reader.theme', v.name);
  }
}
