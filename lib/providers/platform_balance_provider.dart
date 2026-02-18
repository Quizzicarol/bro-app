import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

/// Provider para gerenciar o saldo da plataforma (taxas acumuladas)
class PlatformBalanceProvider with ChangeNotifier {
  double _balanceSats = 0.0;
  double _totalEarnings = 0.0;
  List<Map<String, dynamic>> _transactions = [];

  double get balanceSats => _balanceSats;
  double get totalEarnings => _totalEarnings;
  List<Map<String, dynamic>> get transactions => List.unmodifiable(_transactions);

  PlatformBalanceProvider() {
    _loadBalance();
  }

  /// Carregar saldo do SharedPreferences
  Future<void> _loadBalance() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _balanceSats = prefs.getDouble('platform_balance') ?? 0.0;
      _totalEarnings = prefs.getDouble('platform_total_earnings') ?? 0.0;
      
      final transactionsJson = prefs.getString('platform_transactions');
      if (transactionsJson != null) {
        final List<dynamic> decoded = json.decode(transactionsJson);
        _transactions = decoded.map((e) => Map<String, dynamic>.from(e)).toList();
      }
      
      notifyListeners();
      debugPrint('?? Saldo da plataforma carregado: $_balanceSats sats');
    } catch (e) {
      debugPrint('? Erro ao carregar saldo da plataforma: $e');
    }
  }

  /// Salvar saldo no SharedPreferences
  Future<void> _saveBalance() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('platform_balance', _balanceSats);
      await prefs.setDouble('platform_total_earnings', _totalEarnings);
      await prefs.setString('platform_transactions', json.encode(_transactions));
      
      debugPrint('?? Saldo da plataforma salvo: $_balanceSats sats');
    } catch (e) {
      debugPrint('? Erro ao salvar saldo da plataforma: $e');
    }
  }

  /// Adicionar taxa da plataforma (2% de cada transa��o)
  Future<void> addPlatformFee({
    required String orderId,
    required double amountSats,
    required String orderDescription,
  }) async {
    final transaction = {
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'type': 'platform_fee',
      'amount': amountSats,
      'orderId': orderId,
      'description': orderDescription,
      'timestamp': DateTime.now().toIso8601String(),
    };

    _transactions.insert(0, transaction);
    _balanceSats += amountSats;
    _totalEarnings += amountSats;

    await _saveBalance();
    notifyListeners();

    debugPrint('?? Taxa da plataforma adicionada: $amountSats sats (Ordem: ${orderId.substring(0, 8)})');
  }

  /// Simular saque da plataforma (apenas para teste/gest�o)
  Future<void> withdraw({
    required double amountSats,
    required String destination,
    required String type, // 'lightning' ou 'onchain'
  }) async {
    if (amountSats > _balanceSats) {
      throw Exception('Saldo insuficiente');
    }

    final transaction = {
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'type': 'withdrawal',
      'amount': -amountSats,
      'destination': destination,
      'withdrawType': type,
      'timestamp': DateTime.now().toIso8601String(),
    };

    _transactions.insert(0, transaction);
    _balanceSats -= amountSats;

    await _saveBalance();
    notifyListeners();

    debugPrint('?? Saque da plataforma: $amountSats sats via $type');
  }

  /// Limpar hist�rico (apenas para testes)
  Future<void> clearHistory() async {
    _transactions.clear();
    _balanceSats = 0.0;
    _totalEarnings = 0.0;
    await _saveBalance();
    notifyListeners();
  }
}
