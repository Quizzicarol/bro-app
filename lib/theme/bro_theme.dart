import 'package:flutter/material.dart';
import 'bro_colors.dart';
import 'bro_typography.dart';

/// Tema oficial do Bro App
/// Design System completo com modo dark
class BroTheme {
  BroTheme._();

  // ============================================
  // DARK THEME (Padrão do App)
  // ============================================
  
  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      
      // Cores
      colorScheme: const ColorScheme.dark(
        primary: BroColors.mint,
        onPrimary: BroColors.dark,
        secondary: BroColors.coral,
        onSecondary: Colors.white,
        tertiary: BroColors.turquoise,
        surface: BroColors.darkSurface,
        onSurface: BroColors.textPrimary,
        error: BroColors.error,
        onError: Colors.white,
      ),
      
      // Scaffold
      scaffoldBackgroundColor: BroColors.dark,
      
      // AppBar
      appBarTheme: const AppBarTheme(
        backgroundColor: BroColors.dark,
        foregroundColor: BroColors.textPrimary,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: BroTypography.displayFont,
          fontSize: 20,
          fontWeight: FontWeight.w500,
          color: BroColors.textPrimary,
        ),
      ),
      
      // Cards
      cardTheme: CardTheme(
        color: BroColors.darkSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      
      // Elevated Buttons
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: BroColors.mint,
          foregroundColor: BroColors.dark,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: BroTypography.button,
        ),
      ),
      
      // Outlined Buttons
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: BroColors.mint,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          side: const BorderSide(color: BroColors.mint, width: 2),
          textStyle: BroTypography.button,
        ),
      ),
      
      // Text Buttons
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: BroColors.mint,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          textStyle: BroTypography.button,
        ),
      ),
      
      // Floating Action Button
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: BroColors.mint,
        foregroundColor: BroColors.dark,
        elevation: 4,
        shape: CircleBorder(),
      ),
      
      // Input Decoration
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: BroColors.darkSurface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Colors.white12),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: BroColors.mint, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: BroColors.coral, width: 2),
        ),
        hintStyle: BroTypography.bodyMedium.copyWith(
          color: BroColors.textTertiary,
        ),
      ),
      
      // Bottom Navigation Bar
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: BroColors.darkSurface,
        selectedItemColor: BroColors.mint,
        unselectedItemColor: BroColors.textTertiary,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
      ),
      
      // Navigation Bar (Material 3)
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: BroColors.darkSurface,
        indicatorColor: BroColors.mint.withOpacity(0.2),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: BroColors.mint);
          }
          return const IconThemeData(color: BroColors.textTertiary);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return BroTypography.labelSmall.copyWith(color: BroColors.mint);
          }
          return BroTypography.labelSmall.copyWith(color: BroColors.textTertiary);
        }),
      ),
      
      // Chip
      chipTheme: ChipThemeData(
        backgroundColor: BroColors.darkSurface,
        selectedColor: BroColors.mint.withOpacity(0.2),
        labelStyle: BroTypography.labelMedium.copyWith(color: BroColors.textPrimary),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        side: const BorderSide(color: Colors.white12),
      ),
      
      // Dialog
      dialogTheme: DialogTheme(
        backgroundColor: BroColors.darkSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        titleTextStyle: BroTypography.headlineSmall.copyWith(
          color: BroColors.textPrimary,
        ),
        contentTextStyle: BroTypography.bodyMedium.copyWith(
          color: BroColors.textSecondary,
        ),
      ),
      
      // Snackbar
      snackBarTheme: SnackBarThemeData(
        backgroundColor: BroColors.darkCard,
        contentTextStyle: BroTypography.bodyMedium.copyWith(
          color: BroColors.textPrimary,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      
      // Progress Indicator
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: BroColors.mint,
        linearTrackColor: BroColors.darkSurface,
        circularTrackColor: BroColors.darkSurface,
      ),
      
      // Divider
      dividerTheme: const DividerThemeData(
        color: Colors.white12,
        thickness: 1,
        space: 1,
      ),
      
      // Icon
      iconTheme: const IconThemeData(
        color: BroColors.textPrimary,
        size: 24,
      ),
      
      // Text Theme
      textTheme: TextTheme(
        displayLarge: BroTypography.displayLarge.copyWith(color: BroColors.textPrimary),
        displayMedium: BroTypography.displayMedium.copyWith(color: BroColors.textPrimary),
        displaySmall: BroTypography.displaySmall.copyWith(color: BroColors.textPrimary),
        headlineLarge: BroTypography.headlineLarge.copyWith(color: BroColors.textPrimary),
        headlineMedium: BroTypography.headlineMedium.copyWith(color: BroColors.textPrimary),
        headlineSmall: BroTypography.headlineSmall.copyWith(color: BroColors.textPrimary),
        titleLarge: BroTypography.titleLarge.copyWith(color: BroColors.textPrimary),
        titleMedium: BroTypography.titleMedium.copyWith(color: BroColors.textPrimary),
        titleSmall: BroTypography.titleSmall.copyWith(color: BroColors.textPrimary),
        bodyLarge: BroTypography.bodyLarge.copyWith(color: BroColors.textPrimary),
        bodyMedium: BroTypography.bodyMedium.copyWith(color: BroColors.textSecondary),
        bodySmall: BroTypography.bodySmall.copyWith(color: BroColors.textTertiary),
        labelLarge: BroTypography.labelLarge.copyWith(color: BroColors.textPrimary),
        labelMedium: BroTypography.labelMedium.copyWith(color: BroColors.textSecondary),
        labelSmall: BroTypography.labelSmall.copyWith(color: BroColors.textTertiary),
      ),
    );
  }

  // ============================================
  // LIGHT THEME (Opcional)
  // ============================================
  
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      
      colorScheme: const ColorScheme.light(
        primary: BroColors.turquoise,
        onPrimary: Colors.white,
        secondary: BroColors.coral,
        onSecondary: Colors.white,
        tertiary: BroColors.mint,
        surface: BroColors.cream,
        onSurface: BroColors.dark,
        error: BroColors.error,
        onError: Colors.white,
      ),
      
      scaffoldBackgroundColor: BroColors.cream,
      
      appBarTheme: const AppBarTheme(
        backgroundColor: BroColors.cream,
        foregroundColor: BroColors.dark,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: BroTypography.displayFont,
          fontSize: 20,
          fontWeight: FontWeight.w500,
          color: BroColors.dark,
        ),
      ),
      
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: BroColors.turquoise,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: BroTypography.button,
        ),
      ),
    );
  }
}

// ============================================
// EXTENSÕES ÚTEIS
// ============================================

extension BroThemeExtension on BuildContext {
  /// Acesso rápido às cores do Bro
  BroColors get broColors => BroColors();
  
  /// Verifica se está em modo dark
  bool get isDarkMode => Theme.of(this).brightness == Brightness.dark;
  
  /// Cor primária atual
  Color get primaryColor => Theme.of(this).colorScheme.primary;
  
  /// Cor de fundo atual
  Color get backgroundColor => Theme.of(this).scaffoldBackgroundColor;
}
