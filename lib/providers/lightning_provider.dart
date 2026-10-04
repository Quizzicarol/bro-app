import 'dart:async';
import 'package:bro_app/services/log_utils.dart';
import 'package:flutter/material.dart';
import '../services/platform_fee_service.dart';
import 'breez_provider_export.dart';

/// Tipos de backend Lightning
enum LightningBackend {
  spark,   // Breez SDK Spark (VTXO)
}

/// Abstração do backend Lightning (Breez SDK Spark, nodeless e self-custodial)
/// 
/// NOTA: O fallback Liquid (flutter_breez_liquid) foi REMOVIDO — o repositório
/// upstream (breez/breez-sdk-liquid-flutter) foi deletado do GitHub (404),
/// quebrando builds limpos (Codemagic). O app agora é Spark-only.
class LightningProvider with ChangeNotifier {
  final BreezProvider _sparkProvider;
  
  LightningBackend _currentBackend = LightningBackend.spark;
  bool _isInitialized = false;
  bool _isLoading = false;
  String? _error;
  
  // Estatísticas de uso
  int _sparkAttempts = 0;
  int _sparkFailures = 0;
  
  // Cache de última falha Spark para evitar retry imediato
  DateTime? _lastSparkFailure;
  static const _sparkCooldownSeconds = 60; // Esperar 1 min antes de tentar Spark novamente
  
  LightningProvider(this._sparkProvider);
  
  // Getters
  LightningBackend get currentBackend => _currentBackend;
  bool get isInitialized => _isInitialized;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isUsingSpark => _currentBackend == LightningBackend.spark;
  
  BreezProvider get sparkProvider => _sparkProvider;
  
  // Estatísticas
  int get sparkAttempts => _sparkAttempts;
  int get sparkFailures => _sparkFailures;
  double get sparkSuccessRate => _sparkAttempts > 0 
      ? (_sparkAttempts - _sparkFailures) / _sparkAttempts 
      : 1.0;
  
  void _setLoading(bool v) {
    _isLoading = v;
    notifyListeners();
  }

  void _setError(String? e) {
    _error = e;
    notifyListeners();
  }

  /// Verifica se deve tentar Spark ou se está em cooldown por falhas recentes
  bool get _shouldTrySpark {
    if (_lastSparkFailure == null) return true;
    
    final elapsed = DateTime.now().difference(_lastSparkFailure!);
    return elapsed.inSeconds >= _sparkCooldownSeconds;
  }

  /// Inicializa o provider (Spark)
  Future<bool> initialize({String? mnemonic}) async {
    if (_isInitialized) return true;
    
    _setLoading(true);
    _setError(null);
    
    broLog('⚡ LightningProvider: Inicializando backend Spark...');
    
    try {
      final sparkOk = await _sparkProvider.initialize(mnemonic: mnemonic);
      if (sparkOk) {
        _currentBackend = LightningBackend.spark;
        broLog('✅ Spark inicializado');
      }
    } catch (e) {
      broLog('❌ Erro ao inicializar Spark: $e');
    }
    
    _isInitialized = _sparkProvider.isInitialized;
    
    if (!_isInitialized) {
      _setError('Backend Lightning (Spark) não disponível');
    } else {
      // IMPORTANTE: Configurar callback do PlatformFeeService para envio de taxas
      _configurePlatformFeeCallback();
    }
    
    _setLoading(false);
    return _isInitialized;
  }
  
  /// Configura o callback do PlatformFeeService com o método payInvoice deste provider
  void _configurePlatformFeeCallback() {
    PlatformFeeService.setPaymentCallback(
      (String invoice) => payInvoice(invoice),
      'Spark',
    );
    // Anti re-pagamento: registra o acesso ao histórico REAL da carteira (Spark),
    // que sobrevive à reinstalação. O PlatformFeeService usa isso para não re-pagar
    // uma taxa que já saiu, mesmo se o registro local foi perdido.
    PlatformFeeService.setWalletHistoryFetcher(() => _sparkProvider.getAllPayments());
    broLog('💼 PlatformFeeService configurado para usar Spark');
  }

  /// Obter saldo total
  Future<int> getBalance() async {
    if (_sparkProvider.isInitialized) {
      final sparkResult = await _sparkProvider.getBalance();
      return int.tryParse(sparkResult['balance']?.toString() ?? '0') ?? 0;
    }
    return 0;
  }
  
  /// Obter saldo separado por backend
  Future<Map<LightningBackend, int>> getBalanceByBackend() async {
    final result = <LightningBackend, int>{};
    
    if (_sparkProvider.isInitialized) {
      final sparkResult = await _sparkProvider.getBalance();
      result[LightningBackend.spark] = int.tryParse(sparkResult['balance']?.toString() ?? '0') ?? 0;
    }
    
    return result;
  }

  /// Criar invoice via Spark
  /// 
  /// Retorna:
  ///   - success: bool
  ///   - bolt11: String (invoice BOLT11)
  ///   - backend: String ('spark')
  Future<Map<String, dynamic>?> createInvoice({
    int? amountSats,
    String? description,
  }) async {
    _setLoading(true);
    _setError(null);
    
    // Tentar Spark (se não estiver em cooldown)
    if (_sparkProvider.isInitialized && _shouldTrySpark) {
      _sparkAttempts++;
      broLog('⚡ Tentando criar invoice via Spark...');
      
      try {
        final result = await _sparkProvider.createInvoice(
          amountSats: amountSats,
          description: description,
        );
        
        if (result != null && result['success'] == true) {
          _currentBackend = LightningBackend.spark;
          _setLoading(false);
          
          broLog('✅ Invoice criado via Spark');
          return {
            ...result,
            'backend': 'spark',
          };
        } else {
          _sparkFailures++;
          _lastSparkFailure = DateTime.now();
          broLog('❌ Spark falhou: ${result?['error']}');
        }
      } catch (e) {
        _sparkFailures++;
        _lastSparkFailure = DateTime.now();
        broLog('❌ Erro ao criar invoice Spark: $e');
      }
    } else if (!_shouldTrySpark) {
      broLog('⏳ Spark em cooldown, pulando...');
    }
    
    // Spark falhou ou não está inicializado
    _setError('Não foi possível criar invoice - backend Spark indisponível');
    _setLoading(false);
    return {
      'success': false,
      'error': 'Backend Lightning (Spark) indisponível no momento',
    };
  }

  /// Pagar invoice via Spark
  Future<Map<String, dynamic>?> payInvoice(String bolt11) async {
    _setLoading(true);
    _setError(null);
    
    // Tentar Spark se tem saldo
    if (_sparkProvider.isInitialized) {
      final sparkResult = await _sparkProvider.getBalance();
      final sparkBalance = int.tryParse(sparkResult['balance']?.toString() ?? '0') ?? 0;
      if (sparkBalance > 0) {
        broLog('⚡ Tentando pagar via Spark (saldo: $sparkBalance sats)...');
        
        try {
          final result = await _sparkProvider.payInvoice(bolt11);
          if (result != null && result['success'] == true) {
            _setLoading(false);
            return {
              ...result,
              'backend': 'spark',
            };
          }
        } catch (e) {
          broLog('❌ Pagamento Spark falhou: $e');
        }
      }
    }
    
    _setError('Não foi possível pagar - saldo insuficiente ou backend indisponível');
    _setLoading(false);
    return {
      'success': false,
      'error': 'Saldo insuficiente ou backend Spark indisponível',
    };
  }
  
  /// Forçar uso de backend específico
  void forceBackend(LightningBackend backend) {
    _currentBackend = backend;
    notifyListeners();
    broLog('🔧 Backend forçado para: $backend');
  }
  
  /// Resetar cooldown do Spark (forçar nova tentativa)
  void resetSparkCooldown() {
    _lastSparkFailure = null;
    broLog('🔄 Cooldown do Spark resetado');
  }
  
  /// Debug: obter estatísticas
  Map<String, dynamic> getStats() {
    return {
      'currentBackend': _currentBackend.name,
      'sparkInitialized': _sparkProvider.isInitialized,
      'sparkAttempts': _sparkAttempts,
      'sparkFailures': _sparkFailures,
      'sparkSuccessRate': '${(sparkSuccessRate * 100).toStringAsFixed(1)}%',
      'sparkInCooldown': !_shouldTrySpark,
    };
  }

  @override
  void dispose() {
    // Providers são gerenciados externamente
    super.dispose();
  }
}
