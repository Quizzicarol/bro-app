import 'dart:async';
import 'package:flutter/material.dart';
import '../config.dart';
import 'breez_provider.dart';
import 'breez_liquid_provider.dart';

/// Tipos de backend Lightning
enum LightningBackend {
  spark,   // Breez SDK Spark (VTXO)
  liquid,  // Breez SDK Liquid (L-BTC + Boltz)
}

/// Abstração que unifica Breez SDK Spark e Liquid
/// 
/// Estratégia:
/// 1. SEMPRE tenta usar Spark primeiro (menores taxas)
/// 2. Se Spark falhar, tenta Liquid como fallback
/// 3. Quando usar Liquid, as taxas são calculadas e embutidas
/// 
/// IMPORTANTE: As taxas do Liquid devem ser embutidas no spread da cotação
/// pelo chamador usando calculateTotalFees() e adjustPriceForLiquidFees()
class LightningProvider with ChangeNotifier {
  final BreezProvider _sparkProvider;
  final BreezLiquidProvider _liquidProvider;
  
  LightningBackend _currentBackend = LightningBackend.spark;
  bool _isInitialized = false;
  bool _isLoading = false;
  String? _error;
  
  // Estatísticas de uso
  int _sparkAttempts = 0;
  int _sparkFailures = 0;
  int _liquidAttempts = 0;
  int _liquidFailures = 0;
  
  // Cache de última falha Spark para evitar retry imediato
  DateTime? _lastSparkFailure;
  static const _sparkCooldownSeconds = 60; // Esperar 1 min antes de tentar Spark novamente
  
  LightningProvider(this._sparkProvider, this._liquidProvider);
  
  // Getters
  LightningBackend get currentBackend => _currentBackend;
  bool get isInitialized => _isInitialized;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isUsingSpark => _currentBackend == LightningBackend.spark;
  bool get isUsingLiquid => _currentBackend == LightningBackend.liquid;
  
  BreezProvider get sparkProvider => _sparkProvider;
  BreezLiquidProvider get liquidProvider => _liquidProvider;
  
  // Estatísticas
  int get sparkAttempts => _sparkAttempts;
  int get sparkFailures => _sparkFailures;
  int get liquidAttempts => _liquidAttempts;
  int get liquidFailures => _liquidFailures;
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
  
  /// Calcula as taxas totais para uma transação Liquid
  /// Inclui: taxa Boltz (0.25% + 200 sats) + taxa rede (50 sats)
  /// 
  /// Retorna em sats
  static int calculateLiquidFees(int amountSats) {
    return BreezLiquidProvider.calculateLiquidFee(amountSats);
  }
  
  /// Calcula o spread adicional em porcentagem para cobrir taxas Liquid
  /// 
  /// Exemplo: Se amountSats = 10000, e taxas = 275 sats
  /// Spread adicional = 275/10000 = 0.0275 = 2.75%
  static double calculateLiquidSpread(int amountSats) {
    return BreezLiquidProvider.calculateLiquidSpread(amountSats);
  }
  
  /// Ajusta um preço em BRL para embutir taxas do Liquid
  /// 
  /// Exemplo: 
  ///   - Preço original: R$ 100,00 (para 10.000 sats)
  ///   - Taxas Liquid: ~275 sats (2.75%)
  ///   - Preço ajustado: R$ 100,00 + 2.75% = R$ 102,75
  /// 
  /// O usuário paga R$ 102,75 e recebe R$ 100,00 em Bitcoin líquido
  static double adjustPriceForLiquidFees(double priceBrl, int amountSats) {
    final spread = calculateLiquidSpread(amountSats);
    return priceBrl * (1 + spread);
  }
  
  /// Calcula o valor em sats que o usuário deve pagar para receber um valor líquido
  /// 
  /// netAmountSats = valor que o usuário quer receber
  /// Retorna = valor que ele precisa enviar (incluindo taxas)
  static int calculateGrossAmount(int netAmountSats) {
    return BreezLiquidProvider.calculateGrossAmount(netAmountSats);
  }

  /// Inicializa o provider (tenta Spark primeiro, depois Liquid se habilitado)
  Future<bool> initialize({String? mnemonic}) async {
    if (_isInitialized) return true;
    
    _setLoading(true);
    _setError(null);
    
    debugPrint('⚡ LightningProvider: Inicializando backends...');
    
    // Sempre inicializar Spark primeiro
    bool sparkOk = false;
    try {
      sparkOk = await _sparkProvider.initialize(mnemonic: mnemonic);
      if (sparkOk) {
        _currentBackend = LightningBackend.spark;
        debugPrint('✅ Spark inicializado - usando como primário');
      }
    } catch (e) {
      debugPrint('❌ Erro ao inicializar Spark: $e');
    }
    
    // Se Spark falhou e Liquid fallback está habilitado, inicializar Liquid
    if (!sparkOk && AppConfig.enableLiquidFallback) {
      try {
        final liquidOk = await _liquidProvider.initialize(mnemonic: mnemonic);
        if (liquidOk) {
          _currentBackend = LightningBackend.liquid;
          debugPrint('✅ Liquid inicializado como fallback (Spark falhou)');
        }
      } catch (e) {
        debugPrint('❌ Erro ao inicializar Liquid fallback: $e');
      }
    }
    
    // Pelo menos um backend deve estar ok
    _isInitialized = _sparkProvider.isInitialized || _liquidProvider.isInitialized;
    
    if (!_isInitialized) {
      _setError('Nenhum backend Lightning disponível');
    }
    
    _setLoading(false);
    return _isInitialized;
  }

  /// Obter saldo total (Spark + Liquid)
  Future<int> getBalance() async {
    int total = 0;
    
    if (_sparkProvider.isInitialized) {
      final sparkResult = await _sparkProvider.getBalance();
      final sparkBalance = int.tryParse(sparkResult['balance']?.toString() ?? '0') ?? 0;
      total += sparkBalance;
    }
    
    if (_liquidProvider.isInitialized) {
      total += await _liquidProvider.getBalance();
    }
    
    return total;
  }
  
  /// Obter saldo separado por backend
  Future<Map<LightningBackend, int>> getBalanceByBackend() async {
    final result = <LightningBackend, int>{};
    
    if (_sparkProvider.isInitialized) {
      final sparkResult = await _sparkProvider.getBalance();
      result[LightningBackend.spark] = int.tryParse(sparkResult['balance']?.toString() ?? '0') ?? 0;
    }
    
    if (_liquidProvider.isInitialized) {
      result[LightningBackend.liquid] = await _liquidProvider.getBalance();
    }
    
    return result;
  }

  /// Criar invoice com fallback automático
  /// 
  /// IMPORTANTE: Se retornar com 'isLiquid': true, as taxas devem ser embutidas
  /// no spread da cotação pelo chamador!
  /// 
  /// Retorna:
  ///   - success: bool
  ///   - bolt11: String (invoice BOLT11)
  ///   - isLiquid: bool (true se usou Liquid - calcular taxas!)
  ///   - fees: int (taxas estimadas em sats, se Liquid)
  ///   - backend: String ('spark' ou 'liquid')
  Future<Map<String, dynamic>?> createInvoice({
    required int amountSats,
    String? description,
  }) async {
    _setLoading(true);
    _setError(null);
    
    // 1. Tentar Spark primeiro (se não estiver em cooldown)
    if (_sparkProvider.isInitialized && _shouldTrySpark) {
      _sparkAttempts++;
      debugPrint('⚡ Tentando criar invoice via Spark...');
      
      try {
        final result = await _sparkProvider.createInvoice(
          amountSats: amountSats,
          description: description,
        );
        
        if (result != null && result['success'] == true) {
          _currentBackend = LightningBackend.spark;
          _setLoading(false);
          
          debugPrint('✅ Invoice criado via Spark');
          return {
            ...result,
            'isLiquid': false,
            'backend': 'spark',
          };
        } else {
          _sparkFailures++;
          _lastSparkFailure = DateTime.now();
          debugPrint('❌ Spark falhou: ${result?['error']}');
        }
      } catch (e) {
        _sparkFailures++;
        _lastSparkFailure = DateTime.now();
        debugPrint('❌ Erro ao criar invoice Spark: $e');
      }
    } else if (!_shouldTrySpark) {
      debugPrint('⏳ Spark em cooldown, pulando...');
    }
    
    // 2. Fallback para Liquid se habilitado
    if (AppConfig.enableLiquidFallback) {
      // Inicializar Liquid se ainda não foi
      if (!_liquidProvider.isInitialized) {
        debugPrint('💧 Inicializando Liquid para fallback...');
        final mnemonic = _sparkProvider.mnemonic;
        await _liquidProvider.initialize(mnemonic: mnemonic);
      }
      
      if (_liquidProvider.isInitialized) {
        _liquidAttempts++;
        debugPrint('💧 Tentando criar invoice via Liquid (fallback)...');
        
        try {
          final result = await _liquidProvider.createInvoice(
            amountSats: amountSats,
            description: description,
          );
          
          if (result != null && result['success'] == true) {
            _currentBackend = LightningBackend.liquid;
            _setLoading(false);
            
            final fees = calculateLiquidFees(amountSats);
            debugPrint('✅ Invoice criado via Liquid (fallback)');
            debugPrint('💰 Taxas estimadas: $fees sats');
            
            return {
              ...result,
              'isLiquid': true,
              'backend': 'liquid',
              'fees': fees,
              'feePercent': calculateLiquidSpread(amountSats) * 100,
            };
          } else {
            _liquidFailures++;
            debugPrint('❌ Liquid também falhou: ${result?['error']}');
          }
        } catch (e) {
          _liquidFailures++;
          debugPrint('❌ Erro ao criar invoice Liquid: $e');
        }
      }
    }
    
    // 3. Todos os backends falharam
    _setError('Não foi possível criar invoice - todos os backends falharam');
    _setLoading(false);
    return {
      'success': false,
      'error': 'Nenhum backend Lightning disponível no momento',
    };
  }

  /// Pagar invoice com fallback automático
  /// 
  /// Tenta pagar usando o backend que tem saldo suficiente
  Future<Map<String, dynamic>?> payInvoice(String bolt11) async {
    _setLoading(true);
    _setError(null);
    
    // 1. Tentar Spark primeiro se tem saldo
    if (_sparkProvider.isInitialized) {
      final sparkResult = await _sparkProvider.getBalance();
      final sparkBalance = int.tryParse(sparkResult['balance']?.toString() ?? '0') ?? 0;
      if (sparkBalance > 0) {
        debugPrint('⚡ Tentando pagar via Spark (saldo: $sparkBalance sats)...');
        
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
          debugPrint('❌ Pagamento Spark falhou: $e');
        }
      }
    }
    
    // 2. Fallback para Liquid
    if (_liquidProvider.isInitialized) {
      final liquidBalance = await _liquidProvider.getBalance();
      if (liquidBalance > 0) {
        debugPrint('💧 Tentando pagar via Liquid (saldo: $liquidBalance sats)...');
        
        try {
          final result = await _liquidProvider.payInvoice(bolt11);
          if (result != null && result['success'] == true) {
            _setLoading(false);
            return {
              ...result,
              'backend': 'liquid',
            };
          }
        } catch (e) {
          debugPrint('❌ Pagamento Liquid falhou: $e');
        }
      }
    }
    
    _setError('Não foi possível pagar - saldo insuficiente ou backends indisponíveis');
    _setLoading(false);
    return {
      'success': false,
      'error': 'Saldo insuficiente em todos os backends',
    };
  }
  
  /// Forçar uso de backend específico
  void forceBackend(LightningBackend backend) {
    _currentBackend = backend;
    notifyListeners();
    debugPrint('🔧 Backend forçado para: $backend');
  }
  
  /// Resetar cooldown do Spark (forçar nova tentativa)
  void resetSparkCooldown() {
    _lastSparkFailure = null;
    debugPrint('🔄 Cooldown do Spark resetado');
  }
  
  /// Debug: obter estatísticas
  Map<String, dynamic> getStats() {
    return {
      'currentBackend': _currentBackend.name,
      'sparkInitialized': _sparkProvider.isInitialized,
      'liquidInitialized': _liquidProvider.isInitialized,
      'sparkAttempts': _sparkAttempts,
      'sparkFailures': _sparkFailures,
      'sparkSuccessRate': '${(sparkSuccessRate * 100).toStringAsFixed(1)}%',
      'liquidAttempts': _liquidAttempts,
      'liquidFailures': _liquidFailures,
      'sparkInCooldown': !_shouldTrySpark,
    };
  }

  @override
  void dispose() {
    // Providers são gerenciados externamente
    super.dispose();
  }
}
