import 'package:flutter/foundation.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:dio/dio.dart';
import '../config.dart';
import 'api_service.dart';

class EscrowService {
  /// Taxa do provedor Bro (3%) - usa o valor centralizado do AppConfig
  static double get providerFeePercent => AppConfig.providerFeePercent * 100;

  /// Dio instance do ApiService (com NIP-98 auth)
  Dio get _dio => ApiService().dio;

  Future<Map<String, dynamic>> depositCollateral({required String tierId, required int amountSats}) async {
    // Em modo teste, simular depósito de garantia
    if (AppConfig.testMode) {
      broLog('🧪 Modo teste: simulando depósito de garantia');
      return {
        'invoice': 'lnbc${amountSats}n1test_invoice_for_tier_$tierId',
        'deposit_id': 'test_deposit_${DateTime.now().millisecondsSinceEpoch}',
      };
    }
    
    try {
      final response = await _dio.post('/collateral/deposit', data: {'tierId': tierId, 'amountSats': amountSats, 'amountBrl': 0});
      return {'invoice': response.data['invoice'], 'deposit_id': response.data['deposit_id']};
    } catch (e) {
      broLog('⚠️ Erro ao depositar garantia: $e');
      rethrow;
    }
  }

  Future<void> lockCollateral({required String providerId, required String orderId, required int lockedSats}) async {
    // Em modo teste OU providerTestMode, apenas logar
    if (AppConfig.testMode || AppConfig.providerTestMode) {
      broLog('🧪 Modo teste: lockCollateral simulado para ordem $orderId');
      return;
    }
    
    try {
      final response = await _dio.post(
        '/collateral/lock', 
        data: {'orderId': orderId, 'lockedSats': lockedSats},
      ).timeout(const Duration(seconds: 10));
      
      broLog('🔒 lockCollateral response: ${response.statusCode}');
    } catch (e) {
      // Logar erro mas não bloquear - a garantia é gerenciada localmente
      broLog('⚠️ Erro ao chamar lockCollateral no backend: $e');
      broLog('   Continuando com garantia local...');
    }
  }

  Future<void> unlockCollateral({required String providerId, required String orderId}) async {
    // Em modo teste OU providerTestMode, apenas logar
    if (AppConfig.testMode || AppConfig.providerTestMode) {
      broLog('🧪 Modo teste: unlockCollateral simulado para ordem $orderId');
      return;
    }
    
    try {
      await _dio.post(
        '/collateral/unlock', 
        data: {'orderId': orderId},
      ).timeout(const Duration(seconds: 10));
    } catch (e) {
      broLog('⚠️ Erro ao chamar unlockCollateral no backend: $e');
    }
  }

  Future<Map<String, dynamic>> createEscrow({required String orderId, required String userId, required int amountSats}) async {
    // Em modo teste, simular criação de escrow
    if (AppConfig.testMode) {
      broLog('🧪 Modo teste: createEscrow simulado para ordem $orderId');
      return {
        'escrow_id': 'test_escrow_${DateTime.now().millisecondsSinceEpoch}',
        'order_id': orderId,
        'amount_sats': amountSats,
      };
    }
    
    try {
      final response = await _dio.post('/escrow/create', data: {'orderId': orderId, 'btcAmount': amountSats / 100000000});
      return response.data as Map<String, dynamic>;
    } catch (e) {
      broLog('⚠️ Erro ao criar escrow: $e');
      rethrow;
    }
  }

  Future<void> releaseEscrow({required String escrowId, required String orderId, required String providerId}) async {
    // Em modo teste, apenas logar
    if (AppConfig.testMode) {
      broLog('🧪 Modo teste: releaseEscrow simulado para ordem $orderId');
      return;
    }
    try {
      await _dio.post('/escrow/release', data: {'orderId': orderId}).timeout(const Duration(seconds: 15));
    } catch (e) {
      broLog('⚠️ Erro ao liberar escrow no backend: $e');
      broLog('   Sats já foram pagos via Lightning - escrow release é apenas bookkeeping');
    }
  }

  Future<bool> validateProviderCanAcceptOrder({required String providerId, required double orderValueBrl}) async {
    return true;
  }

  Future<Map<String, dynamic>?> getProviderCollateral(String providerId) async {
    // Em modo teste, retornar null (sem garantia) para permitir testes
    if (AppConfig.testMode) {
      broLog('🧪 Modo teste: retornando sem garantia depositada');
      return null; // Provedor não tem garantia em modo teste
    }
    
    try {
      final response = await _dio.get('/collateral/$providerId');
      if (response.statusCode == 200) {
        return response.data as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      broLog('❌ Erro ao buscar garantia do provedor: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> getAvailableOrdersForProvider({
    required String providerId,
    required List<dynamic> orders, // Lista de ordens do OrderProvider (via Nostr)
    String? currentUserPubkey, // Pubkey do provedor atual para excluir suas próprias ordens
  }) async {
    // SEMPRE usar as ordens do OrderProvider (P2P via Nostr)
    // O backend centralizado não é mais necessário para ordens
    broLog('🔍 getAvailableOrdersForProvider - Total de ordens recebidas: ${orders.length}');
    broLog('🔍 Pubkey do provedor: ${currentUserPubkey?.substring(0, 8) ?? "null"}...');
    
    if (orders.isEmpty) {
      broLog('⚠️ NENHUMA ORDEM RECEBIDA DO ORDERPROVIDER!');
      return [];
    }
    
    final filteredOrders = orders
        .where((order) {
          final status = order.status;
          
          // NOTA: Permitimos que o provedor veja suas próprias ordens para testes
          // Em produção, pode querer descomentar o filtro abaixo:
          // final orderPubkey = order.userPubkey;
          // if (currentUserPubkey != null && orderPubkey == currentUserPubkey) {
          //   broLog('  ⏭️ Ordem ${order.id.substring(0, 8)}: PULADA (própria ordem)');
          //   return false;
          // }
          
          // Ordens disponíveis para provedor:
          // - pending: criada mas ainda não paga (se quiser aceitar antes)
          // - payment_received: pagamento Lightning recebido, pronta para provedor
          // - confirmed: pagamento confirmado
          // - awaiting_provider: aguardando provedor aceitar
          final isAvailable = status == 'pending' || 
                             status == 'payment_received' ||
                             status == 'awaiting_provider' || 
                             status == 'confirmed';
          broLog('  📋 Ordem ${order.id.substring(0, 8)}: status="$status", isAvailable=$isAvailable');
          return isAvailable;
        })
        .map((order) => {
              'id': order.id,
              'user_id': order.userPubkey ?? 'unknown',
              'user_name': 'Usuário ${order.userPubkey?.substring(0, 6) ?? "?"}...',
              'amount': order.amount, // Campo correto para provider_orders_screen
              'amount_brl': order.amount,
              'amount_sats': (order.btcAmount * 100000000).toInt(),
              'status': order.status,
              'payment_type': order.billType,
              'created_at': order.createdAt.toIso8601String(),
              'expires_at': order.createdAt.add(const Duration(hours: 24)).toIso8601String(),
            })
        .toList()
        .cast<Map<String, dynamic>>();
    
    broLog('📦 Ordens filtradas para provedor: ${filteredOrders.length}');
    
    if (filteredOrders.isEmpty && orders.isNotEmpty) {
      broLog('⚠️ TODAS AS ORDENS FORAM FILTRADAS! Verificar status ou se são todas do próprio usuário.');
    } else if (filteredOrders.isNotEmpty) {
      broLog('✅ Ordens disponíveis:');
      for (var order in filteredOrders) {
        broLog('   - ${order['id'].toString().substring(0, 8)}: R\$ ${order['amount']} (${order['status']})');
      }
    }
    
    return filteredOrders;
  }
}
