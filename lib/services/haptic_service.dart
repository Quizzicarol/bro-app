import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

/// Servi�o de feedback h�ptico para melhorar UX
/// Fornece vibra��o sutil em a��es importantes
class HapticService {
  static final HapticService _instance = HapticService._internal();
  factory HapticService() => _instance;
  HapticService._internal();

  bool _enabled = true;
  
  /// Habilita/desabilita feedback h�ptico
  void setEnabled(bool enabled) {
    _enabled = enabled;
    debugPrint('?? Haptic feedback ${enabled ? "habilitado" : "desabilitado"}');
  }
  
  bool get isEnabled => _enabled;

  /// Feedback leve - para toques e sele��es
  Future<void> light() async {
    if (!_enabled) return;
    try {
      await HapticFeedback.lightImpact();
    } catch (e) {
      debugPrint('Haptic light error: $e');
    }
  }
  
  /// Feedback m�dio - para a��es confirmadas
  Future<void> medium() async {
    if (!_enabled) return;
    try {
      await HapticFeedback.mediumImpact();
    } catch (e) {
      debugPrint('Haptic medium error: $e');
    }
  }
  
  /// Feedback pesado - para a��es importantes
  Future<void> heavy() async {
    if (!_enabled) return;
    try {
      await HapticFeedback.heavyImpact();
    } catch (e) {
      debugPrint('Haptic heavy error: $e');
    }
  }
  
  /// Feedback de sele��o - para mudan�as de estado
  Future<void> selection() async {
    if (!_enabled) return;
    try {
      await HapticFeedback.selectionClick();
    } catch (e) {
      debugPrint('Haptic selection error: $e');
    }
  }
  
  /// Feedback de sucesso - vibra��o dupla
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
  
  /// Feedback de erro - vibra��o tripla
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
  
  /// Feedback de warning - vibra��o longa
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
      // Padr�o de celebra��o
      await HapticFeedback.mediumImpact();
      await Future.delayed(const Duration(milliseconds: 150));
      await HapticFeedback.lightImpact();
      await Future.delayed(const Duration(milliseconds: 100));
      await HapticFeedback.heavyImpact();
    } catch (e) {
      debugPrint('Haptic payment error: $e');
    }
  }
  
  /// Feedback para bot�o pressionado
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
