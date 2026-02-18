import 'dart:async';
import 'package:flutter/foundation.dart';
import '../providers/breez_provider_export.dart';

/// Serviço para monitorar pagamentos Lightning/Onchain automaticamente
class PaymentMonitorService {
  final BreezProvider _breezProvider;
  Timer? _monitorTimer;
  final Map<String, PaymentMonitorCallback> _callbacks = {};
  
  PaymentMonitorService(this._breezProvider);

  /// Inicia monitoramento de um pagamento específico
  void monitorPayment({
    required String paymentId,
    required String paymentHash,
    required PaymentMonitorCallback onStatusChange,
    Duration checkInterval = const Duration(seconds: 3),
  }) {
    debugPrint('🔍 Iniciando monitoramento do pagamento: $paymentId');
    
    _callbacks[paymentId] = onStatusChange;
    
    // Cancelar timer anterior se existir
    _monitorTimer?.cancel();
    
    // Criar novo timer para polling
    _monitorTimer = Timer.periodic(checkInterval, (_) async {
      await _checkPaymentStatus(paymentId, paymentHash);
    });
  }

  /// Para o monitoramento de um pagamento
  void stopMonitoring(String paymentId) {
    debugPrint('🛑 Parando monitoramento do pagamento: $paymentId');
    _callbacks.remove(paymentId);
    
    // Se não há mais callbacks, cancela o timer
    if (_callbacks.isEmpty) {
      _monitorTimer?.cancel();
      _monitorTimer = null;
    }
  }

  /// Para todos os monitoramentos
  void stopAll() {
    debugPrint('🛑 Parando todos os monitoramentos');
    _callbacks.clear();
    _monitorTimer?.cancel();
    _monitorTimer = null;
  }

  /// Verifica status do pagamento
  Future<void> _checkPaymentStatus(String paymentId, String paymentHash) async {
    final callback = _callbacks[paymentId];
    if (callback == null) return;

    try {
      final status = await _breezProvider.checkPaymentStatus(paymentHash);
      
      if (status['paid'] == true) {
        debugPrint('✅ Pagamento $paymentId confirmado!');
        callback(PaymentStatus.confirmed, status);
        stopMonitoring(paymentId); // Para de monitorar após confirmação
      } else if (status['error'] != null) {
        debugPrint('❌ Erro no pagamento $paymentId: ${status['error']}');
        callback(PaymentStatus.failed, status);
      } else {
        debugPrint('⏳ Pagamento $paymentId ainda pendente...');
        callback(PaymentStatus.pending, status);
      }
    } catch (e) {
      debugPrint('⚠️ Erro ao verificar status: $e');
      callback(PaymentStatus.error, {'error': e.toString()});
    }
  }

  /// Monitora endereço onchain (verifica se fundos foram recebidos)
  void monitorOnchainAddress({
    required String paymentId,
    required String address,
    required int expectedSats,
    required PaymentMonitorCallback onStatusChange,
    Duration checkInterval = const Duration(seconds: 5), // Reduzido para 5s para detecção mais rápida
  }) {
    debugPrint('🔍 Iniciando monitoramento onchain: $address');
    
    _callbacks[paymentId] = onStatusChange;
    
    _monitorTimer?.cancel();
    
    _monitorTimer = Timer.periodic(checkInterval, (_) async {
      await _checkOnchainBalance(paymentId, address, expectedSats);
    });
  }

  /// Verifica balance onchain (usando Breez SDK)
  Future<void> _checkOnchainBalance(
    String paymentId,
    String address,
    int expectedSats,
  ) async {
    final callback = _callbacks[paymentId];
    if (callback == null) return;

    try {
      // Breez SDK Spark gerencia automaticamente swaps
      // Verificar se há pagamentos recentes recebidos
      final payments = await _breezProvider.listPayments();
      
      // IMPORTANTE: Apenas considerar pagamentos dos últimos 30 minutos
      final thirtyMinutesAgo = DateTime.now().subtract(const Duration(minutes: 30));
      
      // Procurar por pagamento onchain recente com valor próximo ao esperado
      for (final payment in payments) {
        // Verificar timestamp se disponível
        final paymentTime = payment['timestamp'] != null 
            ? DateTime.fromMillisecondsSinceEpoch(payment['timestamp'] as int)
            : null;
        
        // Só considerar se for recente (últimos 30 min) ou timestamp não disponível
        final isRecent = paymentTime == null || paymentTime.isAfter(thirtyMinutesAgo);
        
        if (isRecent &&
            payment['type'] == 'received' && 
            payment['amountSats'] != null &&
            (payment['amountSats'] as int) >= expectedSats * 0.95) { // 5% margem
          
          debugPrint('✅ Pagamento onchain $paymentId detectado!');
          callback(PaymentStatus.confirmed, payment);
          stopMonitoring(paymentId);
          return;
        }
      }
      
      debugPrint('⏳ Aguardando pagamento onchain $paymentId...');
      callback(PaymentStatus.pending, {'address': address});
    } catch (e) {
      debugPrint('⚠️ Erro ao verificar onchain: $e');
      callback(PaymentStatus.error, {'error': e.toString()});
    }
  }

  void dispose() {
    stopAll();
  }
}

/// Status de um pagamento
enum PaymentStatus {
  pending,
  confirmed,
  failed,
  error,
}

/// Callback para mudanças de status
typedef PaymentMonitorCallback = void Function(
  PaymentStatus status,
  Map<String, dynamic> data,
);
