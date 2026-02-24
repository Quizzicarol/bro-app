import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'api_service.dart';
import 'nostr_order_service.dart';
import '../config.dart';

class ProviderService {
  static final ProviderService _instance = ProviderService._internal();
  factory ProviderService() => _instance;
  ProviderService._internal();

  final ApiService _apiService = ApiService();
  final NostrOrderService _nostrOrderService = NostrOrderService();

  /// Busca ordens disponíveis para aceitar (status=pending)
  /// SEGURANÇA: Retorna APENAS ordens de OUTROS usuários que estão disponíveis
  /// CORREÇÃO: SEMPRE usa Nostr, não mais condicional ao testMode
  Future<List<Map<String, dynamic>>> fetchAvailableOrders() async {
    try {
      // CORREÇÃO: SEMPRE buscar do Nostr - API REST não funciona para P2P
      debugPrint('🔍 Buscando ordens disponíveis do Nostr...');
      final orders = await _nostrOrderService.fetchPendingOrders();
      
      // SEGURANÇA: Filtrar apenas ordens pendentes (sem providerId ainda)
      final availableOrders = orders.where((order) {
        // Ordem pendente = disponível para aceitar
        if (order.status != 'pending' && order.status != 'payment_received') return false;
        // Ordem já aceita por alguém = não disponível
        if (order.providerId != null && order.providerId!.isNotEmpty) return false;
        return true;
      }).toList();
      
      debugPrint('📋 ${availableOrders.length} ordens disponíveis para aceitar');
      return availableOrders.map((order) => order.toJson()).toList();
    } catch (e) {
      debugPrint('❌ Erro ao buscar ordens disponíveis: $e');
      return [];
    }
  }

  /// Busca ordens do provedor específico (usando Nostr)
  Future<List<Map<String, dynamic>>> fetchMyOrders(String providerId) async {
    try {
      debugPrint('🔍 Buscando ordens do provedor via Nostr...');
      
      // Buscar do Nostr - precisa do pubkey do provedor
      final orders = await _nostrOrderService.fetchProviderOrders(providerId);
      debugPrint('📋 Encontradas ${orders.length} ordens do provedor no Nostr');
      
      // Filtrar apenas ordens ativas (não completed, não cancelled, não liquidated)
      final activeOrders = orders.where((order) {
        final status = order.status;
        return status != 'completed' && status != 'cancelled' && status != 'liquidated';
      }).toList();
      
      debugPrint('📋 ${activeOrders.length} ordens ativas após filtro');
      
      return activeOrders.map((order) => order.toJson()).toList();
    } catch (e) {
      debugPrint('❌ Erro ao buscar minhas ordens: $e');
      return [];
    }
  }

  /// Aceita uma ordem
  Future<bool> acceptOrder(String orderId, String providerId) async {
    try {
      return await _apiService.acceptOrder(orderId, providerId);
    } catch (e) {
      debugPrint('❌ Erro ao aceitar ordem: $e');
      return false;
    }
  }

  /// Rejeita uma ordem
  Future<bool> rejectOrder(String orderId, String reason) async {
    try {
      return await _apiService.updateOrderStatus(
        orderId: orderId,
        status: 'rejected',
        metadata: {'rejectionReason': reason},
      );
    } catch (e) {
      debugPrint('❌ Erro ao rejeitar ordem: $e');
      return false;
    }
  }

  /// Busca estatísticas do provedor
  Future<Map<String, dynamic>?> getStats(String providerId) async {
    try {
      return await _apiService.getProviderStats(providerId);
    } catch (e) {
      debugPrint('❌ Erro ao buscar estatísticas: $e');
      return null;
    }
  }

  /// Upload de comprovante de pagamento
  Future<bool> uploadProof(String orderId, List<int> imageData) async {
    try {
      final dio = Dio(BaseOptions(
        baseUrl: _apiService.baseUrl,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30),
      ));

      final formData = FormData.fromMap({
        'proof': MultipartFile.fromBytes(
          imageData,
          filename: 'proof_$orderId.jpg',
        ),
      });

      final response = await dio.post(
        '/api/orders/upload-proof/$orderId',
        data: formData,
      );

      return response.data['success'] ?? false;
    } catch (e) {
      debugPrint('❌ Erro ao fazer upload do comprovante: $e');
      return false;
    }
  }

  /// Marca ordem como paga pelo provedor
  Future<bool> markAsPaid(String orderId) async {
    try {
      return await _apiService.updateOrderStatus(
        orderId: orderId,
        status: 'paid',
      );
    } catch (e) {
      debugPrint('❌ Erro ao marcar como paga: $e');
      return false;
    }
  }

  /// Busca histórico de ordens completadas (usando Nostr)
  Future<List<Map<String, dynamic>>> fetchHistory(String providerId) async {
    try {
      debugPrint('🔍 Buscando histórico do provedor via Nostr...');
      
      // Buscar do Nostr
      final orders = await _nostrOrderService.fetchProviderOrders(providerId);
      
      // Filtrar apenas ordens completadas, liquidadas ou canceladas (histórico)
      final completedOrders = orders.where((order) {
        final status = order.status;
        return status == 'completed' || status == 'liquidated' || status == 'cancelled';
      }).toList();
      
      debugPrint('📋 ${completedOrders.length} ordens completadas no histórico');
      
      return completedOrders.map((order) => order.toJson()).toList();
    } catch (e) {
      debugPrint('❌ Erro ao buscar histórico: $e');
      return [];
    }
  }
}
