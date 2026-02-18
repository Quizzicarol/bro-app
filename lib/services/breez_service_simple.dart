// Servi�o Lightning Simplificado (Mock - substitua com Breez SDK real)
import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';

class BreezServiceSimple {
  static final BreezServiceSimple _instance = BreezServiceSimple._internal();
  factory BreezServiceSimple() => _instance;
  BreezServiceSimple._internal();

  bool _isInitialized = false;
  int _balance = 100000; // 100k sats de teste
  
  // Callbacks
  Function(Map<String, dynamic>)? onPaymentReceived;

  // Inicializar
  Future<bool> initialize({required String apiKey, String? mnemonic}) async {
    debugPrint('?? Inicializando Breez (Mock)...');
    await Future.delayed(const Duration(seconds: 1));
    
    _isInitialized = true;
    
    debugPrint('? Breez inicializado (Mock)!');
    return true;
  }

  // Criar Invoice
  Future<Map<String, dynamic>?> createInvoice({
    required int amountSats,
    String? description,
  }) async {
    if (!_isInitialized) return null;
    
    debugPrint('? Criando invoice: $amountSats sats');
    
    final paymentHash = _generateHash();
    final invoice = _generateMockInvoice(amountSats);
    
    return {
      'bolt11': invoice,
      'paymentHash': paymentHash,
      'amountSats': amountSats,
      'description': description,
    };
  }

  // Pagar Invoice
  Future<Map<String, dynamic>?> payInvoice({
    required String bolt11,
    int? amountSats,
  }) async {
    if (!_isInitialized) return null;
    
    debugPrint('? Pagando invoice (Mock)...');
    await Future.delayed(const Duration(seconds: 1));
    
    final amount = amountSats ?? 1000;
    _balance -= amount;
    
    return {
      'success': true,
      'amountSats': amount,
      'paymentHash': _generateHash(),
    };
  }

  // Gerar Endere�o On-chain  
  Future<Map<String, dynamic>?> createOnchainAddress() async {
    if (!_isInitialized) return null;
    
    debugPrint('? Gerando endere�o on-chain (Mock)...');
    
    return {
      'address': 'bc1q${_generateHash().substring(0, 38)}',
      'minAmount': 10000,
      'maxAmount': 1000000,
    };
  }

  // Obter Saldo
  Future<int> getBalance() async {
    return _balance;
  }

  // Listar Pagamentos
  Future<List<Map<String, dynamic>>> listPayments() async {
    return [
      {
        'id': _generateHash(),
        'type': 'incoming',
        'amountSats': 50000,
        'status': 'settled',
        'timestamp': DateTime.now().subtract(const Duration(hours: 2)).toIso8601String(),
      },
      {
        'id': _generateHash(),
        'type': 'outgoing',
        'amountSats': 25000,
        'status': 'settled',
        'timestamp': DateTime.now().subtract(const Duration(hours: 5)).toIso8601String(),
      },
    ];
  }

  // Sync
  Future<void> sync() async {
    await Future.delayed(const Duration(milliseconds: 500));
  }

  // Desconectar
  Future<void> disconnect() async {
    _isInitialized = false;
    debugPrint('?? Breez desconectado');
  }

  // Helpers
  String _generateHash() {
    final random = Random();
    return List.generate(64, (_) => random.nextInt(16).toRadixString(16)).join();
  }

  String _generateMockInvoice(int amountSats) {
    return 'lnbc${amountSats}n1pj${_generateHash().substring(0, 50)}';
  }

  // Getters
  bool get isInitialized => _isInitialized;
  Map<String, dynamic>? get nodeState => {
    'channelsBalanceMsat': _balance * 1000,
    'id': _generateHash(),
    'blockHeight': 800000,
  };
}
