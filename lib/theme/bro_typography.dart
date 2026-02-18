import 'package:flutter/material.dart';

/// Tipografia oficial do Bro
/// Display: Fredoka (t�tulos, headers)
/// Body: Inter (corpo de texto, UI)
class BroTypography {
  BroTypography._();

  // ============================================
  // FONT FAMILIES
  // ============================================
  
  /// Font para t�tulos e headers
  static const String displayFont = 'Fredoka';
  
  /// Font para corpo de texto
  static const String bodyFont = 'Inter';
  
  // ============================================
  // DISPLAY STYLES (Fredoka)
  // ============================================
  
  /// Display Large - T�tulos principais
  static const TextStyle displayLarge = TextStyle(
    fontFamily: displayFont,
    fontSize: 57,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.25,
    height: 1.12,
  );
  
  /// Display Medium
  static const TextStyle displayMedium = TextStyle(
    fontFamily: displayFont,
    fontSize: 45,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.16,
  );
  
  /// Display Small
  static const TextStyle displaySmall = TextStyle(
    fontFamily: displayFont,
    fontSize: 36,
    fontWeight: FontWeight.w400,
    letterSpacing: 0,
    height: 1.22,
  );
  
  // ============================================
  // HEADLINE STYLES (Fredoka)
  // ============================================
  
  /// Headline Large
  static const TextStyle headlineLarge = TextStyle(
    fontFamily: displayFont,
    fontSize: 32,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.25,
  );
  
  /// Headline Medium
  static const TextStyle headlineMedium = TextStyle(
    fontFamily: displayFont,
    fontSize: 28,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.29,
  );
  
  /// Headline Small
  static const TextStyle headlineSmall = TextStyle(
    fontFamily: displayFont,
    fontSize: 24,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.33,
  );
  
  // ============================================
  // TITLE STYLES (Inter)
  // ============================================
  
  /// Title Large
  static const TextStyle titleLarge = TextStyle(
    fontFamily: bodyFont,
    fontSize: 22,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
    height: 1.27,
  );
  
  /// Title Medium
  static const TextStyle titleMedium = TextStyle(
    fontFamily: bodyFont,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.15,
    height: 1.5,
  );
  
  /// Title Small
  static const TextStyle titleSmall = TextStyle(
    fontFamily: bodyFont,
    fontSize: 14,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.1,
    height: 1.43,
  );
  
  // ============================================
  // BODY STYLES (Inter)
  // ============================================
  
  /// Body Large
  static const TextStyle bodyLarge = TextStyle(
    fontFamily: bodyFont,
    fontSize: 16,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.5,
    height: 1.5,
  );
  
  /// Body Medium
  static const TextStyle bodyMedium = TextStyle(
    fontFamily: bodyFont,
    fontSize: 14,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.25,
    height: 1.43,
  );
  
  /// Body Small
  static const TextStyle bodySmall = TextStyle(
    fontFamily: bodyFont,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.4,
    height: 1.33,
  );
  
  // ============================================
  // LABEL STYLES (Inter)
  // ============================================
  
  /// Label Large
  static const TextStyle labelLarge = TextStyle(
    fontFamily: bodyFont,
    fontSize: 14,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.1,
    height: 1.43,
  );
  
  /// Label Medium
  static const TextStyle labelMedium = TextStyle(
    fontFamily: bodyFont,
    fontSize: 12,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.5,
    height: 1.33,
  );
  
  /// Label Small
  static const TextStyle labelSmall = TextStyle(
    fontFamily: bodyFont,
    fontSize: 11,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.5,
    height: 1.45,
  );
  
  // ============================================
  // CUSTOM STYLES
  // ============================================
  
  /// Estilo para valores monet�rios
  static const TextStyle money = TextStyle(
    fontFamily: bodyFont,
    fontSize: 32,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    height: 1.2,
  );
  
  /// Estilo para badges
  static const TextStyle badge = TextStyle(
    fontFamily: bodyFont,
    fontSize: 10,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.5,
    height: 1.2,
  );
  
  /// Estilo para bot�es
  static const TextStyle button = TextStyle(
    fontFamily: bodyFont,
    fontSize: 16,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.5,
    height: 1.5,
  );
}
