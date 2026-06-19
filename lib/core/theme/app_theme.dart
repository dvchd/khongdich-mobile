import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

/// Material 3 theme tokens for Không Dịch mobile app.
///
/// Per `docs/plan-flutter-app.md` §14.1 Design system:
///   Primary  #E11D48 (rose-600)
///   Dark bg  #0F172A
///   Dark card#1E293B
///   Light bg #F8FAFC
///   Light card #FFFFFF
///   Accent    #3B82F6
///   Heading   Noto Sans 700
///   Body      Noto Serif 400
///   UI        Noto Sans 400/500/600
///   Radius    8px/12px/99px
///   Spacing   4px grid
class AppTheme {
  AppTheme._();

  static const Color primary = Color(0xFFE11D48);
  static const Color accent = Color(0xFF3B82F6);

  static const Color lightBg = Color(0xFFF8FAFC);
  static const Color lightCard = Color(0xFFFFFFFF);
  static const Color lightSurfaceVariant = Color(0xFFF1F5F9);

  static const Color darkBg = Color(0xFF0F172A);
  static const Color darkCard = Color(0xFF1E293B);
  static const Color darkSurfaceVariant = Color(0xFF334155);

  static const double radiusSm = 8;
  static const double radiusMd = 12;
  static const double radiusPill = 99;

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: primary,
      onPrimary: Colors.white,
      secondary: accent,
      onSecondary: Colors.white,
      error: const Color(0xFFB91C1C),
      onError: Colors.white,
      surface: isDark ? darkCard : lightCard,
      onSurface: isDark ? const Color(0xFFF1F5F9) : const Color(0xFF0F172A),
      surfaceContainerHighest:
          isDark ? darkSurfaceVariant : lightSurfaceVariant,
    );

    final uiFont = GoogleFonts.notoSans();
    final headingFont = GoogleFonts.notoSans(fontWeight: FontWeight.w700);
    final bodyFont = GoogleFonts.notoSerif();

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: isDark ? darkBg : lightBg,
      canvasColor: isDark ? darkBg : lightBg,
      textTheme: GoogleFonts.notoSansTextTheme(
        isDark ? ThemeData.dark().textTheme : ThemeData.light().textTheme,
      ).copyWith(
        headlineLarge: headingFont.copyWith(
          fontSize: 32,
          fontWeight: FontWeight.w700,
          color: colorScheme.onSurface,
        ),
        headlineMedium: headingFont.copyWith(
          fontSize: 24,
          fontWeight: FontWeight.w700,
          color: colorScheme.onSurface,
        ),
        headlineSmall: headingFont.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: colorScheme.onSurface,
        ),
        bodyLarge: bodyFont.copyWith(
          fontSize: 18,
          height: 1.6,
          color: colorScheme.onSurface,
        ),
        bodyMedium: bodyFont.copyWith(
          fontSize: 16,
          height: 1.6,
          color: colorScheme.onSurface,
        ),
        titleMedium: uiFont.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface,
        ),
        labelLarge: uiFont.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? darkBg : lightBg,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: headingFont.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: colorScheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        color: isDark ? darkCard : lightCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
        ),
        margin: EdgeInsets.zero,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusPill),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusPill),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? darkCard : lightSurfaceVariant,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? darkBg : lightBg,
        indicatorColor: primary.withValues(alpha: 0.12),
        labelTextStyle: WidgetStateProperty.all(
          uiFont.copyWith(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colorScheme.onSurface.withValues(alpha: 0.08),
        thickness: 1,
        space: 1,
      ),
    );
  }
}

final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);
