import 'package:flutter/material.dart';

/// Cores do Design System Bro
/// Coral como primária, Mint como secundária
class BroColors {
  BroColors._();

  // Cores Principais
  static const Color coral = Color(0xFFFF6B6B);       // Primary - Coral vibrante
  static const Color mint = Color(0xFF3DE98C);        // Secondary - Verde menta
  static const Color turquoise = Color(0xFF00CC7A);   // Accent - Verde turquesa
  static const Color cream = Color(0xFFF7F4ED);       // Background claro
  static const Color dark = Color(0xFF141414);        // Background escuro

  // Variações de Coral
  static const Color coralLight = Color(0xFFFF8A8A);
  static const Color coralDark = Color(0xFFE55555);

  // Variações de Mint
  static const Color mintLight = Color(0xFF6FF0A8);
  static const Color mintDark = Color(0xFF2BC670);

  // Cores de Superfície (Dark Mode)
  static const Color surface = Color(0xFF1E1E1E);
  static const Color surfaceLight = Color(0xFF2A2A2A);
  static const Color surfaceDark = Color(0xFF0A0A0A);

  // Cores de Texto
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFB0B0B0);
  static const Color textMuted = Color(0xFF707070);
  static const Color textOnCoral = Color(0xFFFFFFFF);
  static const Color textOnMint = Color(0xFF141414);

  // Status
  static const Color success = Color(0xFF3DE98C);     // Usa mint
  static const Color error = Color(0xFFFF6B6B);       // Usa coral
  static const Color warning = Color(0xFFFFB347);
  static const Color info = Color(0xFF00CC7A);        // Usa turquoise

  // Gradientes
  static const LinearGradient coralGradient = LinearGradient(
    colors: [coral, coralLight],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient mintGradient = LinearGradient(
    colors: [mint, turquoise],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient darkGradient = LinearGradient(
    colors: [dark, surface],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
}
