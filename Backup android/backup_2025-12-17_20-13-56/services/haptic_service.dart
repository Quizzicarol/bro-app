import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

/// Serviço de feedback háptico para melhorar UX
/// Fornece vibração sutil em ações importantes
class HapticService {
  static final HapticService _instance = HapticService._internal();
  factory HapticService() => _instance;
  HapticService._internal();

  bool _enabled = true;
  
  /// Habilita/desabilita feedback háptico
  void setEnabled(bool enabled) {
    _enabled = enabled;
    debugPrint('📳 Haptic feedback ${enabled ? "habilitado" : "desabilitado"}');
  }
  
  bool get isEnabled => _enabled;

  /// Feedback leve - para toques e seleções
  Future<void> light() async {
    if (!_enabled) return;
    try {
      await HapticFeedback.lightImpact();
    } catch (e) {
      debugPrint('Haptic light error: $e');
    }
  }
  
  /// Feedback médio - para ações confirmadas
  Future<void> medium() async {
    if (!_enabled) return;
    try {
      await HapticFeedback.mediumImpact();
    } catch (e) {
      debugPrint('Haptic medium error: $e');
    }
  }
  
  /// Feedback pesado - para ações importantes
  Future<void> heavy() async {
    if (!_enabled) return;
    try {
      await HapticFeedback.heavyImpact();
    } catch (e) {
      debugPrint('Haptic heavy error: $e');
    }
  }
  
  /// Feedback de seleção - para mudanças de estado
  Future<void> selection() async {
    if (!_enabled) return;
    try {
      await HapticFeedback.selectionClick();
    } catch (e) {
      debugPrint('Haptic selection error: $e');
    }
  }
  
  /// Feedback de sucesso - vibração dupla
  Future<void> success() async {
    if (!_enabled) return;
    try {
      await HapticFeedback.mediumImpact();
      await Future.delayed(const Duration(milliseconds: 100));
      await HapticFeedback.lightImpact();
    } catch (e) {
      debugPrint('Haptic success error: $e');
    }
  }
  
  /// Feedback de erro - vibração tripla
  Future<void> error() async {
    if (!_enabled) return;
    try {
      await HapticFeedback.heavyImpact();
      await Future.delayed(const Duration(milliseconds: 80));
      await HapticFeedback.heavyImpact();
      await Future.delayed(const Duration(milliseconds: 80));
      await HapticFeedback.heavyImpact();
    } catch (e) {
      debugPrint('Haptic error error: $e');
    }
  }
  
  /// Feedback de warning - vibração longa
  Future<void> warning() async {
    if (!_enabled) return;
    try {
      await HapticFeedback.vibrate();
    } catch (e) {
      debugPrint('Haptic warning error: $e');
    }
  }
  
  /// Feedback para pagamento confirmado
  Future<void> paymentSuccess() async {
    if (!_enabled) return;
    try {
      // Padrão de celebração
      await HapticFeedback.mediumImpact();
      await Future.delayed(const Duration(milliseconds: 150));
      await HapticFeedback.lightImpact();
      await Future.delayed(const Duration(milliseconds: 100));
      await HapticFeedback.heavyImpact();
    } catch (e) {
      debugPrint('Haptic payment error: $e');
    }
  }
  
  /// Feedback para botão pressionado
  Future<void> buttonPress() async {
    if (!_enabled) return;
    await light();
  }
  
  /// Feedback para toggle/switch
  Future<void> toggle() async {
    if (!_enabled) return;
    await selection();
  }
  
  /// Feedback para pull-to-refresh
  Future<void> refresh() async {
    if (!_enabled) return;
    await medium();
  }
  
  /// Feedback para scan QR code bem sucedido
  Future<void> scanSuccess() async {
    if (!_enabled) return;
    await success();
  }
}
