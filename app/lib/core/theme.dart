import 'package:flutter/material.dart';

/// ثيم موحّد للنظام: عربي، RTL، ألوان هادئة، خط واضح.
/// المبدأ: بساطة قصوى للمستخدم غير المتخصص.
class AppTheme {
  static const Color primary = Color(0xFF1B6B4C);
  static const Color primaryDark = Color(0xFF124D37);
  static const Color accent = Color(0xFF2E7DD1);
  static const Color bg = Color(0xFFF4F6F8);
  static const Color card = Colors.white;
  static const Color success = Color(0xFF1E8E4E);
  static const Color warning = Color(0xFFC77700);
  static const Color danger = Color(0xFFC0392B);
  static const Color textMain = Color(0xFF1F2933);
  static const Color textMuted = Color(0xFF6B7280);

  static ThemeData light() {
    final base = ThemeData(
      useMaterial3: true,
      fontFamily: 'NotoNaskhArabic',
      colorScheme: ColorScheme.fromSeed(
        seedColor: primary,
        primary: primary,
        secondary: accent,
        surface: card,
      ),
      scaffoldBackgroundColor: bg,
    );

    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: primary,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 1,
        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 0),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          minimumSize: const Size(120, 48),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          minimumSize: const Size(120, 48),
          side: const BorderSide(color: primary),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primary, width: 2),
        ),
      ),
    );
  }
}
