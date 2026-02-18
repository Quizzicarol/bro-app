import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';

class OrderService {
  static String get baseUrl => AppConfig.defaultBackendUrl;
  static const Duration orderTimeout = Duration(hours: 24);

  /// Criar ordem de pagamento
  Future<Map<String, dynamic>> createOrder({
    required String userId,
    required String paymentType, // 'pix' ou 'boleto'
    required Map<String, dynamic> paymentData,
    required double amountBrl,
    required int amountSats,
    required String paymentHash,
  }) async {
    try {
      debugPrint('📝 Criando ordem: R\$ $amountBrl');
      
      final response = await http.post(
        Uri.parse('$baseUrl/orders/create'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'user_id': userId,
          'payment_type': paymentType,
          'payment_data': paymentData,
          'amount_brl': amountBrl,
          'amount_sats': amountSats,
          'payment_hash': paymentHash,
          'status': 'pending',
          'created_at': DateTime.now().toIso8601String(),
          'expires_at': DateTime.now().add(orderTimeout).toIso8601String(),
        }),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = json.decode(response.body);
        debugPrint('✅ Ordem criada: ${data['order_id']}');
        return data;
      }

      throw Exception('Failed to create order: ${response.statusCode}');
    } catch (e) {
      debugPrint('❌ Erro ao criar ordem: $e');
      rethrow;
    }
  }

  /// Obter detalhes da ordem
  Future<Map<String, dynamic>?> getOrder(String orderId) async {
    try {
      // Em modo teste, buscar do cache local
      if (AppConfig.testMode) {
        final prefs = await SharedPreferences.getInstance();
        
        // Buscar em todas as chaves de ordens (orders_*)
        final allKeys = prefs.getKeys();
        for (final key in allKeys) {
          if (key.startsWith('orders_')) {
            final ordersJson = prefs.getString(key);
            if (ordersJson != null) {
              final List<dynamic> ordersList = json.decode(ordersJson);
              final order = ordersList.firstWhere(
                (o) => o['id'] == orderId,
                orElse: () => null,
              );
              
              if (order != null) {
                debugPrint('✅ Ordem encontrada no cache ($key): $orderId');
                debugPrint('   Status: ${order['status']}, providerId: ${order['providerId']}');
                return Map<String, dynamic>.from(order);
              }
            }
          }
        }
        
        // Fallback: tentar chave antiga 'saved_orders'
        final ordersJson = prefs.getString('saved_orders');
        if (ordersJson != null) {
          final List<dynamic> ordersList = json.decode(ordersJson);
          final order = ordersList.firstWhere(
            (o) => o['id'] == orderId,
            orElse: () => null,
          );
          
          if (order != null) {
            debugPrint('✅ Ordem encontrada no cache (legacy): $orderId');
            return Map<String, dynamic>.from(order);
          }
        }
        
        debugPrint('⚠️ Ordem não encontrada no cache: $orderId');
        return null;
      }
      
      // Modo produção: buscar da API
      final response = await http.get(
        Uri.parse('$baseUrl/orders/$orderId'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        return json.decode(response.body);
      } else if (response.statusCode == 404) {
        return null;
      }

      throw Exception('Failed to get order: ${response.statusCode}');
    } catch (e) {
      debugPrint('❌ Erro ao buscar ordem: $e');
      rethrow;
    }
  }

  /// Listar ordens do usuário
  Future<List<Map<String, dynamic>>> getUserOrders(String userId) async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/orders/user/$userId'),
        headers: {'Content-Type': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return List<Map<String, dynamic>>.from(data['orders'] ?? []);
      }

      return [];
    } catch (e) {
      debugPrint('❌ Erro ao listar ordens: $e');
      return [];
    }
  }

  /// Cancelar ordem (apenas se status = 'pending')
  Future<bool> cancelOrder({
    required String orderId,
    required String userId,
    required String reason,
  }) async {
    try {
      debugPrint('🚫 Cancelando ordem: $orderId');
      
      final response = await http.post(
        Uri.parse('$baseUrl/orders/$orderId/cancel'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({
          'user_id': userId,
          'reason': reason,
          'cancelled_at': DateTime.now().toIso8601String(),
        }),
      );

      if (response.statusCode == 200) {
        debugPrint('✅ Ordem cancelada');
        return true;
      }

      debugPrint('❌ Falha ao cancelar: ${response.statusCode}');
      return false;
    } catch (e) {
      debugPrint('❌ Erro ao cancelar ordem: $e');
      return false;
    }
  }

  /// Verificar status da ordem periodicamente
  Future<String> checkOrderStatus(String orderId) async {
    try {
      final order = await getOrder(orderId);
      if (order == null) return 'not_found';
      
      return order['status'] ?? 'unknown';
    } catch (e) {
      debugPrint('❌ Erro ao verificar status: $e');
      return 'error';
    }
  }

  /// Verificar se ordem expirou
  bool isOrderExpired(DateTime expiresAt) {
    return DateTime.now().isAfter(expiresAt);
  }

  /// Calcular tempo restante
  Duration getTimeRemaining(DateTime expiresAt) {
    final now = DateTime.now();
    if (now.isAfter(expiresAt)) {
      return Duration.zero;
    }
    return expiresAt.difference(now);
  }

  /// Formatar tempo restante
  String formatTimeRemaining(Duration duration) {
    if (duration.inSeconds <= 0) return 'Expirado';
    
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    
    if (hours > 0) {
      return '$hours hora${hours > 1 ? 's' : ''} e $minutes min';
    } else {
      return '$minutes minuto${minutes > 1 ? 's' : ''}';
    }
  }
}
