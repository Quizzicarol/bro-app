import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config.dart';

class EscrowService {
  static String get baseUrl => AppConfig.defaultBackendUrl;
  
  /// Taxa do provedor Bro (3%) - usa o valor centralizado do AppConfig
  static double get providerFeePercent => AppConfig.providerFeePercent * 100;

  Future<Map<String, dynamic>> depositCollateral({required String tierId, required int amountSats}) async {
    // Em modo teste, simular dep�sito de garantia
    if (AppConfig.testMode) {
      debugPrint('?? Modo teste: simulando dep�sito de garantia');
      return {
        'invoice': 'lnbc${amountSats}n1test_invoice_for_tier_$tierId',
        'deposit_id': 'test_deposit_${DateTime.now().millisecondsSinceEpoch}',
      };
    }
    
    final response = await http.post(Uri.parse('$baseUrl/collateral/deposit'), headers: {'Content-Type': 'application/json'}, body: json.encode({'tier_id': tierId, 'amount_sats': amountSats}));
    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return {'invoice': data['invoice'], 'deposit_id': data['deposit_id']};
    }
    throw Exception('Failed');
  }

  Future<void> lockCollateral({required String providerId, required String orderId, required int lockedSats}) async {
    // Em modo teste OU providerTestMode, apenas logar
    if (AppConfig.testMode || AppConfig.providerTestMode) {
      debugPrint('?? Modo teste: lockCollateral simulado para ordem $orderId');
      return;
    }
    
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/collateral/lock'), 
        headers: {'Content-Type': 'application/json'}, 
        body: json.encode({'provider_id': providerId, 'order_id': orderId, 'locked_sats': lockedSats}),
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint('?? Timeout ao travar garantia - continuando mesmo assim');
          return http.Response('{}', 408); // Retorna timeout mas continua
        },
      );
      
      debugPrint('?? lockCollateral response: ${response.statusCode}');
    } catch (e) {
      // Logar erro mas n�o bloquear - a garantia � gerenciada localmente
      debugPrint('?? Erro ao chamar lockCollateral no backend: $e');
      debugPrint('   Continuando com garantia local...');
    }
  }

  Future<void> unlockCollateral({required String providerId, required String orderId}) async {
    // Em modo teste OU providerTestMode, apenas logar
    if (AppConfig.testMode || AppConfig.providerTestMode) {
      debugPrint('?? Modo teste: unlockCollateral simulado para ordem $orderId');
      return;
    }
    
    try {
      await http.post(
        Uri.parse('$baseUrl/collateral/unlock'), 
        headers: {'Content-Type': 'application/json'}, 
        body: json.encode({'provider_id': providerId, 'order_id': orderId}),
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint('?? Timeout ao liberar garantia - continuando mesmo assim');
          return http.Response('{}', 408);
        },
      );
    } catch (e) {
      debugPrint('?? Erro ao chamar unlockCollateral no backend: $e');
    }
  }

  Future<Map<String, dynamic>> createEscrow({required String orderId, required String userId, required int amountSats}) async {
    // Em modo teste, simular cria��o de escrow
    if (AppConfig.testMode) {
      debugPrint('?? Modo teste: createEscrow simulado para ordem $orderId');
      return {
        'escrow_id': 'test_escrow_${DateTime.now().millisecondsSinceEpoch}',
        'order_id': orderId,
        'amount_sats': amountSats,
      };
    }
    
    final response = await http.post(Uri.parse('$baseUrl/escrow/create'), headers: {'Content-Type': 'application/json'}, body: json.encode({'order_id': orderId, 'user_id': userId, 'amount_sats': amountSats}));
    if (response.statusCode == 200) return json.decode(response.body);
    throw Exception('Failed');
  }

  Future<void> releaseEscrow({required String escrowId, required String orderId, required String providerId}) async {
    // Em modo teste, apenas logar
    if (AppConfig.testMode) {
      debugPrint('?? Modo teste: releaseEscrow simulado para ordem $orderId');
      return;
    }
    await http.post(Uri.parse('$baseUrl/escrow/release'), headers: {'Content-Type': 'application/json'}, body: json.encode({'escrow_id': escrowId, 'order_id': orderId, 'provider_id': providerId}));
  }

  Future<bool> validateProviderCanAcceptOrder({required String providerId, required double orderValueBrl}) async {
    return true;
  }

  Future<Map<String, dynamic>?> getProviderCollateral(String providerId) async {
    // Em modo teste, retornar null (sem garantia) para permitir testes
    if (AppConfig.testMode) {
      debugPrint('?? Modo teste: retornando sem garantia depositada');
      return null; // Provedor n�o tem garantia em modo teste
    }
    
    try {
      final response = await http.get(Uri.parse('$baseUrl/collateral/provider/$providerId'));
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      debugPrint('? Erro ao buscar garantia do provedor: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> getAvailableOrdersForProvider({
    required String providerId,
    required List<dynamic> orders, // Lista de ordens do OrderProvider (via Nostr)
    String? currentUserPubkey, // Pubkey do provedor atual para excluir suas pr�prias ordens
  }) async {
    // SEMPRE usar as ordens do OrderProvider (P2P via Nostr)
    // O backend centralizado n�o � mais necess�rio para ordens
    debugPrint('?? getAvailableOrdersForProvider - Total de ordens recebidas: ${orders.length}');
    debugPrint('?? Pubkey do provedor: ${currentUserPubkey?.substring(0, 8) ?? "null"}...');
    
    if (orders.isEmpty) {
      debugPrint('?? NENHUMA ORDEM RECEBIDA DO ORDERPROVIDER!');
      return [];
    }
    
    final filteredOrders = orders
        .where((order) {
          final status = order.status;
          
          // NOTA: Permitimos que o provedor veja suas pr�prias ordens para testes
          // Em produ��o, pode querer descomentar o filtro abaixo:
          // final orderPubkey = order.userPubkey;
          // if (currentUserPubkey != null && orderPubkey == currentUserPubkey) {
          //   debugPrint('  ?? Ordem ${order.id.substring(0, 8)}: PULADA (pr�pria ordem)');
          //   return false;
          // }
          
          // Ordens dispon�veis para provedor:
          // - pending: criada mas ainda n�o paga (se quiser aceitar antes)
          // - payment_received: pagamento Lightning recebido, pronta para provedor
          // - confirmed: pagamento confirmado
          // - awaiting_provider: aguardando provedor aceitar
          final isAvailable = status == 'pending' || 
                             status == 'payment_received' ||
                             status == 'awaiting_provider' || 
                             status == 'confirmed';
          debugPrint('  ?? Ordem ${order.id.substring(0, 8)}: status="$status", isAvailable=$isAvailable');
          return isAvailable;
        })
        .map((order) => {
              'id': order.id,
              'user_id': order.userPubkey ?? 'unknown',
              'user_name': 'Usu�rio ${order.userPubkey?.substring(0, 6) ?? "?"}...',
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
    
    debugPrint('?? Ordens filtradas para provedor: ${filteredOrders.length}');
    
    if (filteredOrders.isEmpty && orders.isNotEmpty) {
      debugPrint('?? TODAS AS ORDENS FORAM FILTRADAS! Verificar status ou se s�o todas do pr�prio usu�rio.');
    } else if (filteredOrders.isNotEmpty) {
      debugPrint('? Ordens dispon�veis:');
      for (var order in filteredOrders) {
        debugPrint('   - ${order['id'].toString().substring(0, 8)}: R\$ ${order['amount']} (${order['status']})');
      }
    }
    
    return filteredOrders;
  }
}
