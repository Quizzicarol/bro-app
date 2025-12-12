import 'package:flutter/material.dart';

/// Paleta de cores oficial do Bro
/// Baseada na identidade visual: https://id-preview--6d6295d6-969f-4078-8851-3721595583a6.lovable.app
class BroColors {
  BroColors._();

  // ============================================
  // CORES PRIMÁRIAS
  // ============================================
  
  /// Mint - Cor principal do app
  /// Representa: frescor, confiança, crescimento
  static const Color mint = Color(0xFF3DE98C);
  
  /// Coral - Cor de destaque/ação
  /// Representa: energia, urgência, atenção
  static const Color coral = Color(0xFFFF6B6B);
  
  /// Turquoise - Cor secundária
  /// Representa: estabilidade, segurança
  static const Color turquoise = Color(0xFF00CC7A);
  
  // ============================================
  // CORES DE FUNDO
  // ============================================
  
  /// Cream - Fundo claro (modo light)
  static const Color cream = Color(0xFFF7F4ED);
  
  /// Dark - Fundo escuro (modo dark)
  static const Color dark = Color(0xFF141414);
  
  /// Background secundário dark
  static const Color darkSurface = Color(0xFF1E1E1E);
  
  /// Background terciário dark
  static const Color darkCard = Color(0xFF252525);
  
  // ============================================
  // CORES DE TEXTO
  // ============================================
  
  /// Texto primário (modo dark)
  static const Color textPrimary = Color(0xFFFFFFFF);
  
  /// Texto secundário (modo dark)
  static const Color textSecondary = Color(0xB3FFFFFF); // 70% opacity
  
  /// Texto terciário (modo dark)
  static const Color textTertiary = Color(0x80FFFFFF); // 50% opacity
  
  /// Texto desabilitado
  static const Color textDisabled = Color(0x4DFFFFFF); // 30% opacity
  
  // ============================================
  // CORES DE STATUS
  // ============================================
  
  /// Sucesso
  static const Color success = Color(0xFF3DE98C); // Mint
  
  /// Erro
  static const Color error = Color(0xFFFF6B6B); // Coral
  
  /// Aviso
  static const Color warning = Color(0xFFFFB84D);
  
  /// Info
  static const Color info = Color(0xFF64B5F6);
  
  // ============================================
  // GRADIENTES
  // ============================================
  
  /// Gradiente principal (Mint → Turquoise)
  static const LinearGradient primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [mint, turquoise],
  );
  
  /// Gradiente de destaque (Coral → Mint)
  static const LinearGradient accentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [coral, mint],
  );
  
  /// Gradiente dark
  static const LinearGradient darkGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [dark, darkSurface],
  );
  
  // ============================================
  // MATERIAL COLOR SWATCH
  // ============================================
  
  static const MaterialColor mintSwatch = MaterialColor(
    0xFF3DE98C,
    <int, Color>{
      50: Color(0xFFE8FCF2),
      100: Color(0xFFC5F7DE),
      200: Color(0xFF9EF2C8),
      300: Color(0xFF77EDB2),
      400: Color(0xFF5AE9A0),
      500: Color(0xFF3DE98C),
      600: Color(0xFF37E684),
      700: Color(0xFF2FE379),
      800: Color(0xFF27DF6F),
      900: Color(0xFF1AD95C),
    },
  );
  
  static const MaterialColor coralSwatch = MaterialColor(
    0xFFFF6B6B,
    <int, Color>{
      50: Color(0xFFFFEDED),
      100: Color(0xFFFFD3D3),
      200: Color(0xFFFFB6B6),
      300: Color(0xFFFF9999),
      400: Color(0xFFFF8383),
      500: Color(0xFFFF6B6B),
      600: Color(0xFFFF6363),
      700: Color(0xFFFF5858),
      800: Color(0xFFFF4E4E),
      900: Color(0xFFFF3C3C),
    },
  );
}
