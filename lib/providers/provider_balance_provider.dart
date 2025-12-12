import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'dart:convert';
import '../models/provider_balance.dart';
import '../config.dart';
import 'breez_provider_export.dart';

/// Provider para gerenciar o saldo do provedor
class ProviderBalanceProvider with ChangeNotifier {
  ProviderBalance? _balance;
  bool _isLoading = false;
  String? _error;
  BreezProvider? _breezProvider;

  static const String _balanceKey = 'provider_balance';

  ProviderBalance? get balance => _balance;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get hasBalance => _balance != null;

  /// Definir BreezProvider para integração de pagamentos
  void setBreezProvider(BreezProvider breezProvider) {
    _breezProvider = breezProvider;
  }

  /// Inicializar: carregar saldo salvo
  Future<void> initialize(String providerId) async {
    _isLoading = true;
    notifyListeners();

    try {
      if (AppConfig.testMode) {
        await _loadSavedBalance();
        
        // Se não tem saldo, criar um novo vazio
        if (_balance == null || _balance!.providerId != providerId) {
          _balance = ProviderBalance(
            providerId: providerId,
            availableBalanceSats: 0,
            totalEarnedSats: 0,
            transactions: [],
            updatedAt: DateTime.now(),
          );
          await _saveBalance();
          debugPrint('💰 Novo saldo criado para provedor $providerId');
        } else {
          debugPrint('💰 Saldo carregado: ${_balance!.availableBalanceSats} sats');
        }
      }

      _isLoading = false;
      notifyListeners();
    } catch (e) {
      debugPrint('❌ Erro ao inicializar saldo: $e');
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Carregar saldo do SharedPreferences
  Future<void> _loadSavedBalance() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final balanceJson = prefs.getString(_balanceKey);
      
      if (balanceJson != null) {
        final data = json.decode(balanceJson) as Map<String, dynamic>;
        _balance = ProviderBalance.fromJson(data);
        debugPrint('💰 Saldo carregado do storage');
      }
    } catch (e) {
      debugPrint('❌ Erro ao carregar saldo: $e');
    }
  }

  /// Salvar saldo no SharedPreferences
  Future<void> _saveBalance() async {
    if (_balance == null || !AppConfig.testMode) return;
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final balanceJson = json.encode(_balance!.toJson());
      await prefs.setString(_balanceKey, balanceJson);
      debugPrint('💾 Saldo salvo: ${_balance!.availableBalanceSats} sats');
    } catch (e) {
      debugPrint('❌ Erro ao salvar saldo: $e');
    }
  }

  /// Adicionar ganho (earning) ao saldo
  Future<bool> addEarning({
    required String orderId,
    required String orderDescription,
    required double amountSats,
  }) async {
    if (_balance == null) return false;

    try {
      final transaction = BalanceTransaction(
        id: const Uuid().v4(),
        type: 'earning',
        amountSats: amountSats,
        orderId: orderId,
        orderDescription: orderDescription,
        createdAt: DateTime.now(),
      );

      final newTransactions = [..._balance!.transactions, transaction];
      
      _balance = _balance!.copyWith(
        availableBalanceSats: _balance!.availableBalanceSats + amountSats,
        totalEarnedSats: _balance!.totalEarnedSats + amountSats,
        transactions: newTransactions,
        updatedAt: DateTime.now(),
      );

      await _saveBalance();
      notifyListeners();

      debugPrint('✅ Ganho adicionado: +$amountSats sats ($orderDescription)');
      return true;
    } catch (e) {
      debugPrint('❌ Erro ao adicionar ganho: $e');
      _error = e.toString();
      return false;
    }
  }

  /// Saque Lightning (integrado com Breez SDK)
  Future<bool> withdrawLightning({
    required double amountSats,
    required String invoice,
  }) async {
    if (_balance == null) {
      _error = 'Saldo não inicializado';
      return false;
    }
    
    if (_balance!.availableBalanceSats < amountSats) {
      _error = 'Saldo insuficiente';
      return false;
    }

    _isLoading = true;
    notifyListeners();

    try {
      String? paymentHash;
      
      // Em produção: usar Breez SDK para pagar a invoice
      if (!AppConfig.testMode && _breezProvider != null) {
        debugPrint('⚡ Tentando saque Lightning via Breez SDK...');
        
        final result = await _breezProvider!.payInvoice(invoice);
        
        if (result == null || result['success'] != true) {
          throw Exception(result?['error'] ?? 'Erro ao pagar invoice');
        }
        
        paymentHash = result['payment']?['paymentHash'];
        debugPrint('✅ Invoice paga! Hash: $paymentHash');
      } else {
        // Modo teste: simular pagamento
        debugPrint('🧪 Saque Lightning simulado (modo teste)');
        await Future.delayed(const Duration(seconds: 1));
        paymentHash = 'test_${DateTime.now().millisecondsSinceEpoch}';
      }

      // Registrar transação no saldo
      final transaction = BalanceTransaction(
        id: const Uuid().v4(),
        type: 'withdrawal_lightning',
        amountSats: -amountSats, // Negativo para saque
        invoice: invoice,
        txHash: paymentHash,
        createdAt: DateTime.now(),
      );

      final newTransactions = [..._balance!.transactions, transaction];
      
      _balance = _balance!.copyWith(
        availableBalanceSats: _balance!.availableBalanceSats - amountSats,
        transactions: newTransactions,
        updatedAt: DateTime.now(),
      );

      await _saveBalance();
      
      _isLoading = false;
      notifyListeners();

      debugPrint('✅ Saque Lightning registrado: -$amountSats sats');
      return true;
    } catch (e) {
      debugPrint('❌ Erro ao sacar Lightning: $e');
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// Saque Onchain 
  /// NOTA: Breez SDK Spark é Lightning-only. Para onchain real, usar:
  /// 1. Swap out via submarine swap (Lightning → Onchain)
  /// 2. Ou integrar com outra wallet onchain
  Future<bool> withdrawOnchain({
    required double amountSats,
    required String address,
  }) async {
    if (_balance == null) {
      _error = 'Saldo não inicializado';
      return false;
    }
    
    if (_balance!.availableBalanceSats < amountSats) {
      _error = 'Saldo insuficiente';
      return false;
    }

    _isLoading = true;
    notifyListeners();

    try {
      String txHash;
      
      // Modo teste: simular transação onchain
      if (AppConfig.testMode) {
        debugPrint('🧪 Saque Onchain simulado (modo teste)');
        await Future.delayed(const Duration(seconds: 2));
        txHash = 'onchain_test_${DateTime.now().millisecondsSinceEpoch}';
      } else {
        // TODO: Implementar submarine swap ou integração com wallet onchain
        // Por enquanto, retornar erro em produção
        throw Exception('Saque onchain não disponível ainda. Use Lightning.');
      }

      // Registrar transação no saldo
      final transaction = BalanceTransaction(
        id: const Uuid().v4(),
        type: 'withdrawal_onchain',
        amountSats: -amountSats, // Negativo para saque
        txHash: txHash,
        createdAt: DateTime.now(),
      );

      final newTransactions = [..._balance!.transactions, transaction];
      
      _balance = _balance!.copyWith(
        availableBalanceSats: _balance!.availableBalanceSats - amountSats,
        transactions: newTransactions,
        updatedAt: DateTime.now(),
      );

      await _saveBalance();
      
      _isLoading = false;
      notifyListeners();

      debugPrint('✅ Saque Onchain registrado: -$amountSats sats');
      return true;
    } catch (e) {
      debugPrint('❌ Erro ao sacar Onchain: $e');
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// Limpar erro
  void clearError() {
    _error = null;
    notifyListeners();
  }

  /// Refresh
  Future<void> refresh(String providerId) async {
    await initialize(providerId);
  }
}
