import 'package:flutter/foundation.dart';

/// Servi�o de Rate Limiting para prevenir abuso
/// Limita tentativas de opera��es sens�veis por per�odo de tempo
class RateLimitService {
  static final RateLimitService _instance = RateLimitService._internal();
  factory RateLimitService() => _instance;
  RateLimitService._internal();

  // Configura��es de limites
  static const int maxLoginAttempts = 5;
  static const int loginLockoutMinutes = 15;
  static const int maxPaymentAttempts = 10;
  static const int paymentLockoutMinutes = 30;
  static const int maxApiCallsPerMinute = 60;

  // Contadores em mem�ria
  final Map<String, List<DateTime>> _attemptLog = {};
  
  /// Verifica se uma opera��o est� bloqueada por rate limit
  Future<RateLimitResult> checkRateLimit({
    required String operation,
    required String identifier,
    int maxAttempts = 5,
    int windowMinutes = 15,
  }) async {
    final key = '${operation}_$identifier';
    final now = DateTime.now();
    final windowStart = now.subtract(Duration(minutes: windowMinutes));
    
    // Limpar tentativas antigas
    _attemptLog[key] = (_attemptLog[key] ?? [])
        .where((time) => time.isAfter(windowStart))
        .toList();
    
    final attempts = _attemptLog[key]!.length;
    
    if (attempts >= maxAttempts) {
      final oldestAttempt = _attemptLog[key]!.first;
      final unlockTime = oldestAttempt.add(Duration(minutes: windowMinutes));
      final remainingSeconds = unlockTime.difference(now).inSeconds;
      
      debugPrint('?? Rate limit atingido para $key. Desbloqueio em ${remainingSeconds}s');
      
      return RateLimitResult(
        allowed: false,
        remainingAttempts: 0,
        retryAfterSeconds: remainingSeconds > 0 ? remainingSeconds : 0,
      );
    }
    
    return RateLimitResult(
      allowed: true,
      remainingAttempts: maxAttempts - attempts,
      retryAfterSeconds: 0,
    );
  }
  
  /// Registra uma tentativa de opera��o
  void recordAttempt({
    required String operation,
    required String identifier,
  }) {
    final key = '${operation}_$identifier';
    _attemptLog[key] = _attemptLog[key] ?? [];
    _attemptLog[key]!.add(DateTime.now());
    debugPrint('?? Tentativa registrada: $key (${_attemptLog[key]!.length} total)');
  }
  
  /// Limpa tentativas ap�s sucesso (ex: login bem sucedido)
  void clearAttempts({
    required String operation,
    required String identifier,
  }) {
    final key = '${operation}_$identifier';
    _attemptLog.remove(key);
    debugPrint('? Tentativas limpas para $key');
  }
  
  /// Verifica rate limit para login
  Future<RateLimitResult> checkLoginLimit(String userId) {
    return checkRateLimit(
      operation: 'login',
      identifier: userId,
      maxAttempts: maxLoginAttempts,
      windowMinutes: loginLockoutMinutes,
    );
  }
  
  /// Verifica rate limit para pagamentos
  Future<RateLimitResult> checkPaymentLimit(String userId) {
    return checkRateLimit(
      operation: 'payment',
      identifier: userId,
      maxAttempts: maxPaymentAttempts,
      windowMinutes: paymentLockoutMinutes,
    );
  }
  
  /// Verifica rate limit para chamadas de API
  Future<RateLimitResult> checkApiLimit(String endpoint) {
    return checkRateLimit(
      operation: 'api',
      identifier: endpoint,
      maxAttempts: maxApiCallsPerMinute,
      windowMinutes: 1,
    );
  }
}

class RateLimitResult {
  final bool allowed;
  final int remainingAttempts;
  final int retryAfterSeconds;
  
  RateLimitResult({
    required this.allowed,
    required this.remainingAttempts,
    required this.retryAfterSeconds,
  });
  
  String get retryAfterFormatted {
    if (retryAfterSeconds <= 0) return '';
    final minutes = retryAfterSeconds ~/ 60;
    final seconds = retryAfterSeconds % 60;
    if (minutes > 0) {
      return '$minutes min ${seconds}s';
    }
    return '${seconds}s';
  }
}
