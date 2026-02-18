import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/withdrawal.dart';

/// Serviço para gerenciar histórico de saques
class WithdrawalService {
  static const String _storageKeyPrefix = 'withdrawals_';
  
  /// Salvar um saque realizado
  Future<void> saveWithdrawal({
    required String orderId,
    required int amountSats,
    required String destination,
    required String destinationType,
    required String status,
    String? txId,
    String? error,
    required String userPubkey,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storageKey = '$_storageKeyPrefix$userPubkey';
      
      // Gerar ID único
      final id = '${DateTime.now().millisecondsSinceEpoch}_${orderId.substring(0, 8)}';
      
      final withdrawal = Withdrawal(
        id: id,
        orderId: orderId,
        amountSats: amountSats,
        destination: destination,
        destinationType: destinationType,
        createdAt: DateTime.now(),
        status: status,
        txId: txId,
        error: error,
      );
      
      // Carregar saques existentes
      final existingJson = prefs.getString(storageKey);
      List<Map<String, dynamic>> withdrawals = [];
      
      if (existingJson != null) {
        final decoded = jsonDecode(existingJson);
        if (decoded is List) {
          withdrawals = List<Map<String, dynamic>>.from(decoded);
        }
      }
      
      // Adicionar novo saque
      withdrawals.add(withdrawal.toJson());
      
      // Salvar
      await prefs.setString(storageKey, jsonEncode(withdrawals));
      
      debugPrint('✅ Saque registrado: ${withdrawal.id} - $amountSats sats - $status');
    } catch (e) {
      debugPrint('❌ Erro ao salvar saque: $e');
    }
  }
  
  /// Buscar saques de uma ordem específica
  Future<List<Withdrawal>> getWithdrawalsByOrder({
    required String orderId,
    required String userPubkey,
  }) async {
    try {
      final allWithdrawals = await getAllWithdrawals(userPubkey: userPubkey);
      return allWithdrawals.where((w) => w.orderId == orderId).toList();
    } catch (e) {
      debugPrint('❌ Erro ao buscar saques da ordem: $e');
      return [];
    }
  }
  
  /// Buscar todos os saques do usuário
  Future<List<Withdrawal>> getAllWithdrawals({
    required String userPubkey,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storageKey = '$_storageKeyPrefix$userPubkey';
      
      final json = prefs.getString(storageKey);
      if (json == null) return [];
      
      final decoded = jsonDecode(json);
      if (decoded is! List) return [];
      
      final withdrawals = decoded
          .map((item) => Withdrawal.fromJson(item))
          .toList();
      
      // Ordenar por data (mais recente primeiro)
      withdrawals.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      
      return withdrawals;
    } catch (e) {
      debugPrint('❌ Erro ao buscar saques: $e');
      return [];
    }
  }
  
  /// Calcular total sacado de uma ordem
  Future<int> getTotalWithdrawnFromOrder({
    required String orderId,
    required String userPubkey,
  }) async {
    final withdrawals = await getWithdrawalsByOrder(
      orderId: orderId,
      userPubkey: userPubkey,
    );
    
    // Somar apenas saques bem-sucedidos
    int total = 0;
    for (final w in withdrawals) {
      if (w.status == 'success') {
        total += w.amountSats;
      }
    }
    return total;
  }
  
  /// Calcular total sacado pelo usuário
  Future<int> getTotalWithdrawn({
    required String userPubkey,
  }) async {
    final withdrawals = await getAllWithdrawals(userPubkey: userPubkey);
    
    int total = 0;
    for (final w in withdrawals) {
      if (w.status == 'success') {
        total += w.amountSats;
      }
    }
    return total;
  }
}
