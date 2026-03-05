import 'package:flutter/foundation.dart';

/// Wrapper de log que só imprime em modo debug.
/// Em produção (release/profile), nenhuma mensagem é emitida,
/// evitando exposição de dados sensíveis via adb logcat.
void broLog(String message) {
  if (kDebugMode) {
    debugPrint(message);
  }
}
