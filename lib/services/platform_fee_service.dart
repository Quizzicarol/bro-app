import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';
import 'lnaddress_service.dart';

/// Serviço para rastrear taxas da plataforma
/// 
/// MODO ATUAL: TRACKING ONLY
/// - Taxas vão 100% para provedores
/// - Este serviço apenas REGISTRA as taxas para análise futura
/// - Quando tivermos servidor próprio ou Breez Spark permitir split,
///   ativaremos a coleta automática via [enableAutoCollection]
/// 
/// MODO FUTURO: AUTO COLLECTION (quando disponível)
/// - Pagamentos passam pela carteira master (PlatformWalletService)
/// - Split automático: 98% provedor / 2% plataforma
class PlatformFeeService {
  static const String _feeRecordsKey = 'platform_fee_records';
  static const String _totalCollectedKey = 'platform_total_collected';
  static const String _autoCollectionKey = 'platform_auto_collection_enabled';
  
  /// Taxa da plataforma (2%)
  /// Atualmente apenas registrada, não cobrada
  static const double platformFeePercent = 0.02;
  
  /// Verifica se a coleta automática está habilitada
  /// DESABILITADO até termos infraestrutura própria
  static Future<bool> isAutoCollectionEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoCollectionKey) ?? false;
  }
  
  /// Habilita/desabilita coleta automática
  /// USE APENAS quando tivermos servidor próprio ou Breez permitir
  static Future<void> setAutoCollection(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoCollectionKey, enabled);
  }

  /// Registra uma taxa de transação (TRACKING ONLY)
  /// Chamado quando um pagamento é confirmado
  /// A taxa é registrada mas NÃO cobrada do provedor
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

  // ========== ENVIO REAL DA TAXA ==========
  
  // Callback para efetuar o pagamento (será injetado pelo LightningProvider)
  static Future<Map<String, dynamic>?> Function(String invoice)? _payInvoiceCallback;
  static String _currentBackend = 'unknown';

  /// Configura o callback de pagamento (chamar na inicialização do app)
  static void setPaymentCallback(
    Future<Map<String, dynamic>?> Function(String invoice) callback,
    String backend,
  ) {
    _payInvoiceCallback = callback;
    _currentBackend = backend;
    debugPrint('💼 PlatformFeeService configurado com backend: $backend');
  }

  /// Envia a taxa da plataforma para o Lightning Address configurado
  /// Retorna true se o pagamento foi bem sucedido
  static Future<bool> sendPlatformFee({
    required String orderId,
    required int totalSats,
  }) async {
    // Calcular taxa da plataforma: 2% do valor total
    final platformFeeSats = (totalSats * AppConfig.platformFeePercent).round();
    
    if (platformFeeSats <= 0) {
      debugPrint('💼 Taxa da plataforma = 0 sats, ignorando...');
      return true;
    }

    if (AppConfig.platformLightningAddress.isEmpty) {
      debugPrint('⚠️ platformLightningAddress não configurado!');
      return false;
    }

    debugPrint('');
    debugPrint('💼 ════════════════════════════════════════════════');
    debugPrint('💼 ENVIANDO TAXA DA PLATAFORMA');
    debugPrint('💼 Ordem: ${orderId.length > 8 ? orderId.substring(0, 8) : orderId}...');
    debugPrint('💼 Valor total: $totalSats sats');
    debugPrint('💼 Taxa (${(AppConfig.platformFeePercent * 100).toStringAsFixed(0)}%): $platformFeeSats sats');
    debugPrint('💼 Destino: ${AppConfig.platformLightningAddress}');
    debugPrint('💼 Backend: $_currentBackend');
    debugPrint('💼 ════════════════════════════════════════════════');
    debugPrint('');

    if (_payInvoiceCallback == null) {
      debugPrint('❌ ERRO: Callback de pagamento não configurado!');
      debugPrint('   Certifique-se de chamar PlatformFeeService.setPaymentCallback() na inicialização');
      return false;
    }

    try {
      final platformAddress = AppConfig.platformLightningAddress;

      // Detectar tipo de endereço Lightning
      if (platformAddress.contains('@')) {
        // Lightning Address (user@domain.com)
        debugPrint('💼 Resolvendo Lightning Address: $platformAddress');
        
        final lnAddressService = LnAddressService();
        final result = await lnAddressService.getInvoice(
          lnAddress: platformAddress,
          amountSats: platformFeeSats,
          comment: 'Bro Platform Fee - ${orderId.length > 8 ? orderId.substring(0, 8) : orderId}',
        );

        debugPrint('💼 Resultado LNURL: success=${result['success']}, hasInvoice=${result['invoice'] != null}');

        if (result['success'] != true || result['invoice'] == null) {
          debugPrint('❌ Falha ao obter invoice do LN Address: ${result['error'] ?? 'unknown'}');
          return false;
        }

        final invoice = result['invoice'] as String;
        debugPrint('💼 Invoice obtido: ${invoice.substring(0, 50)}...');
        debugPrint('💼 Pagando via $_currentBackend...');

        final payResult = await _payInvoiceCallback!(invoice);
        
        if (payResult != null && payResult['success'] == true) {
          debugPrint('');
          debugPrint('✅ ════════════════════════════════════════════════');
          debugPrint('✅ TAXA DA PLATAFORMA PAGA COM SUCESSO!');
          debugPrint('✅ Valor: $platformFeeSats sats');
          debugPrint('✅ Destino: $platformAddress');
          debugPrint('✅ Backend: $_currentBackend');
          debugPrint('✅ ════════════════════════════════════════════════');
          debugPrint('');
          
          // Marcar como coletada no tracking
          await markAsCollected([orderId]);
          
          return true;
        } else {
          debugPrint('❌ Falha no pagamento: $payResult');
          return false;
        }

      } else if (platformAddress.toLowerCase().startsWith('lno1')) {
        // BOLT12 Offer - ainda não suportado
        debugPrint('⚠️ BOLT12 Offer detectado - não suportado ainda');
        return false;

      } else if (platformAddress.toLowerCase().startsWith('ln')) {
        // Invoice BOLT11 direto
        debugPrint('💼 Pagando invoice BOLT11 direto...');
        
        final payResult = await _payInvoiceCallback!(platformAddress);
        
        if (payResult != null && payResult['success'] == true) {
          debugPrint('✅ TAXA DA PLATAFORMA PAGA COM SUCESSO via $_currentBackend!');
          await markAsCollected([orderId]);
          return true;
        } else {
          debugPrint('❌ Falha no pagamento: $payResult');
          return false;
        }
      }

      debugPrint('⚠️ Tipo de endereço não reconhecido: $platformAddress');
      return false;

    } catch (e, stack) {
      debugPrint('❌ ERRO ao pagar taxa da plataforma: $e');
      debugPrint('   Stack: $stack');
      return false;
    }
  }
}
