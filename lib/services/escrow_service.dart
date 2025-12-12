import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config.dart';

class EscrowService {
  static const String baseUrl = 'http://10.0.2.2:3002';
  static const double providerFeePercent = 3.0;

  Future<Map<String, dynamic>> depositCollateral({required String tierId, required int amountSats}) async {
    // Em modo teste, simular depósito de garantia
    if (AppConfig.testMode) {
      debugPrint('🧪 Modo teste: simulando depósito de garantia');
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
    // Em modo teste, apenas logar
    if (AppConfig.testMode) {
      debugPrint('🧪 Modo teste: lockCollateral simulado para ordem $orderId');
      return;
    }
    await http.post(Uri.parse('$baseUrl/collateral/lock'), headers: {'Content-Type': 'application/json'}, body: json.encode({'provider_id': providerId, 'order_id': orderId, 'locked_sats': lockedSats}));
  }

  Future<void> unlockCollateral({required String providerId, required String orderId}) async {
    // Em modo teste, apenas logar
    if (AppConfig.testMode) {
      debugPrint('🧪 Modo teste: unlockCollateral simulado para ordem $orderId');
      return;
    }
    await http.post(Uri.parse('$baseUrl/collateral/unlock'), headers: {'Content-Type': 'application/json'}, body: json.encode({'provider_id': providerId, 'order_id': orderId}));
  }

  Future<Map<String, dynamic>> createEscrow({required String orderId, required String userId, required int amountSats}) async {
    // Em modo teste, simular criação de escrow
    if (AppConfig.testMode) {
      debugPrint('🧪 Modo teste: createEscrow simulado para ordem $orderId');
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
      debugPrint('🧪 Modo teste: releaseEscrow simulado para ordem $orderId');
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
      debugPrint('🧪 Modo teste: retornando sem garantia depositada');
      return null; // Provedor não tem garantia em modo teste
    }
    
    try {
      final response = await http.get(Uri.parse('$baseUrl/collateral/provider/$providerId'));
      if (response.statusCode == 200) {
        return json.decode(response.body) as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      debugPrint('❌ Erro ao buscar garantia do provedor: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> getAvailableOrdersForProvider({
    required String providerId,
    List<dynamic>? testOrders, // Lista de ordens de teste do OrderProvider
  }) async {
    // Em modo teste, retornar ordens mockadas do OrderProvider
    if (AppConfig.testMode && testOrders != null) {
      debugPrint('🔍 getAvailableOrdersForProvider - Total de ordens recebidas: ${testOrders.length}');
      debugPrint('🔍 Tipo das ordens: ${testOrders.runtimeType}');
      
      if (testOrders.isEmpty) {
        debugPrint('⚠️ NENHUMA ORDEM RECEBIDA DO ORDERPROVIDER!');
        return [];
      }
      
      final filteredOrders = testOrders
          .where((order) {
            final status = order.status;
            // Ordens disponíveis para provedor:
            // - pending: criada mas ainda não paga (se quiser aceitar antes)
            // - payment_received: pagamento Lightning recebido, pronta para provedor
            // - confirmed: pagamento confirmado
            // - awaiting_provider: aguardando provedor aceitar
            final isAvailable = status == 'pending' || 
                               status == 'payment_received' ||
                               status == 'awaiting_provider' || 
                               status == 'confirmed';
            debugPrint('  📋 Ordem ${order.id.substring(0, 8)}: status="$status", isAvailable=$isAvailable');
            return isAvailable;
          })
          .map((order) => {
                'id': order.id,
                'user_id': 'test_user',
                'user_name': 'Usuário Teste',
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
      
      debugPrint('📦 Ordens filtradas para provedor: ${filteredOrders.length}');
      
      if (filteredOrders.isEmpty && testOrders.isNotEmpty) {
        debugPrint('⚠️ TODAS AS ORDENS FORAM FILTRADAS! Verificar status das ordens.');
      } else if (filteredOrders.isNotEmpty) {
        debugPrint('✅ Ordens disponíveis:');
        for (var order in filteredOrders) {
          debugPrint('   - ${order['id'].toString().substring(0, 8)}: R\$ ${order['amount']} (${order['status']})');
        }
      }
      
      return filteredOrders;
    }

    // Produção: buscar do backend
    try {
      final response = await http.get(Uri.parse('$baseUrl/orders/available?provider_id=$providerId'));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return List<Map<String, dynamic>>.from(data['orders'] ?? []);
      }
      return [];
    } catch (e) {
      return [];
    }
  }
}
