import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Serviço para rastrear taxas da plataforma
/// Registra todas as taxas de 2% que devem ser coletadas
class PlatformFeeService {
  static const String _feeRecordsKey = 'platform_fee_records';
  static const String _totalCollectedKey = 'platform_total_collected';
  static const double platformFeePercent = 0.02; // 2%

  /// Registra uma taxa de transação
  /// Chamado quando um pagamento é confirmado
  static Future<void> recordFee({
    required String orderId,
    required double transactionBrl,
    required int transactionSats,
    required String providerPubkey,
    required String clientPubkey,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    
    // Calcular taxa
    final feeBrl = transactionBrl * platformFeePercent;
    final feeSats = (transactionSats * platformFeePercent).round();
    
    // Criar registro
    final record = {
      'orderId': orderId,
      'timestamp': DateTime.now().toIso8601String(),
      'transactionBrl': transactionBrl,
      'transactionSats': transactionSats,
      'feeBrl': feeBrl,
      'feeSats': feeSats,
      'providerPubkey': providerPubkey,
      'clientPubkey': clientPubkey,
      'collected': false, // Marca se a taxa foi efetivamente transferida
    };
    
    // Carregar registros existentes
    final existingJson = prefs.getString(_feeRecordsKey);
    List<Map<String, dynamic>> records = [];
    if (existingJson != null) {
      records = List<Map<String, dynamic>>.from(jsonDecode(existingJson));
    }
    
    // Adicionar novo registro
    records.add(record);
    
    // Salvar
    await prefs.setString(_feeRecordsKey, jsonEncode(records));
  }

  /// Obtém todos os registros de taxas
  static Future<List<Map<String, dynamic>>> getAllFeeRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString(_feeRecordsKey);
    if (json == null) return [];
    return List<Map<String, dynamic>>.from(jsonDecode(json));
  }

  /// Obtém taxas pendentes (não coletadas)
  static Future<List<Map<String, dynamic>>> getPendingFees() async {
    final records = await getAllFeeRecords();
    return records.where((r) => r['collected'] != true).toList();
  }

  /// Calcula total de taxas pendentes
  static Future<Map<String, dynamic>> getPendingTotals() async {
    final pending = await getPendingFees();
    
    double totalBrl = 0;
    int totalSats = 0;
    
    for (final record in pending) {
      totalBrl += (record['feeBrl'] as num?)?.toDouble() ?? 0;
      totalSats += (record['feeSats'] as num?)?.toInt() ?? 0;
    }
    
    return {
      'totalBrl': totalBrl,
      'totalSats': totalSats,
      'count': pending.length,
      'records': pending,
    };
  }

  /// Calcula total histórico (todas as taxas)
  static Future<Map<String, dynamic>> getHistoricalTotals() async {
    final records = await getAllFeeRecords();
    
    double totalBrl = 0;
    int totalSats = 0;
    double collectedBrl = 0;
    int collectedSats = 0;
    
    for (final record in records) {
      final feeBrl = (record['feeBrl'] as num?)?.toDouble() ?? 0;
      final feeSats = (record['feeSats'] as num?)?.toInt() ?? 0;
      
      totalBrl += feeBrl;
      totalSats += feeSats;
      
      if (record['collected'] == true) {
        collectedBrl += feeBrl;
        collectedSats += feeSats;
      }
    }
    
    return {
      'totalBrl': totalBrl,
      'totalSats': totalSats,
      'collectedBrl': collectedBrl,
      'collectedSats': collectedSats,
      'pendingBrl': totalBrl - collectedBrl,
      'pendingSats': totalSats - collectedSats,
      'totalTransactions': records.length,
    };
  }

  /// Marca taxas como coletadas
  static Future<void> markAsCollected(List<String> orderIds) async {
    final prefs = await SharedPreferences.getInstance();
    final records = await getAllFeeRecords();
    
    for (var record in records) {
      if (orderIds.contains(record['orderId'])) {
        record['collected'] = true;
        record['collectedAt'] = DateTime.now().toIso8601String();
      }
    }
    
    await prefs.setString(_feeRecordsKey, jsonEncode(records));
  }

  /// Marca todas as taxas pendentes como coletadas
  static Future<int> markAllAsCollected() async {
    final pending = await getPendingFees();
    final orderIds = pending.map((r) => r['orderId'] as String).toList();
    await markAsCollected(orderIds);
    return orderIds.length;
  }

  /// Limpa todos os registros (use com cuidado!)
  static Future<void> clearAllRecords() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_feeRecordsKey);
    await prefs.remove(_totalCollectedKey);
  }

  /// Exporta registros para JSON (backup)
  static Future<String> exportToJson() async {
    final records = await getAllFeeRecords();
    final totals = await getHistoricalTotals();
    
    return jsonEncode({
      'exportDate': DateTime.now().toIso8601String(),
      'totals': totals,
      'records': records,
    });
  }
}
