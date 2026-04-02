import 'package:flutter/foundation.dart';
import 'package:bro_app/services/log_utils.dart';
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
      broLog('🔍 Buscando ordens disponíveis do Nostr...');
      final orders = await _nostrOrderService.fetchPendingOrders();
      
      // SEGURANÇA: Filtrar apenas ordens pendentes (sem providerId ainda)
      final availableOrders = orders.where((order) {
        // Ordem pendente = disponível para aceitar
        if (order.status != 'pending' && order.status != 'payment_received') return false;
        // Ordem já aceita por alguém = não disponível
        if (order.providerId != null && order.providerId!.isNotEmpty) return false;
        return true;
      }).toList();
      
      broLog('📋 ${availableOrders.length} ordens disponíveis para aceitar');
      return availableOrders.map((order) => order.toJson()).toList();
    } catch (e) {
      broLog('❌ Erro ao buscar ordens disponíveis: $e');
      return [];
    }
  }

  /// Busca ordens do provedor específico (usando Nostr)
  Future<List<Map<String, dynamic>>> fetchMyOrders(String providerId) async {
    try {
      broLog('🔍 Buscando ordens do provedor via Nostr...');
      
      // Buscar do Nostr - precisa do pubkey do provedor
      final orders = await _nostrOrderService.fetchProviderOrders(providerId);
      broLog('📋 Encontradas ${orders.length} ordens do provedor no Nostr');
      
      // v436: Mostrar TODAS as ordens incluindo completed para o provedor ver confirmações
      // Antes filtrava completed/cancelled/liquidated, o que fazia ordens confirmadas
      // desaparecerem do dashboard sem o provedor saber
      // Manter apenas filtro de cancelled (ninguém precisa ver ordens canceladas)
      final visibleOrders = orders.where((order) {
        final status = order.status;
        return status != 'cancelled';
      }).toList();
      
      broLog('📋 ${visibleOrders.length} ordens visíveis (excluídas: cancelled)');
      
      return visibleOrders.map((order) => order.toJson()).toList();
    } catch (e) {
      broLog('❌ Erro ao buscar minhas ordens: $e');
      return [];
    }
  }

  /// Aceita uma ordem
  Future<bool> acceptOrder(String orderId, String providerId) async {
    try {
      return await _apiService.acceptOrder(orderId, providerId);
    } catch (e) {
      broLog('❌ Erro ao aceitar ordem: $e');
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
      broLog('❌ Erro ao rejeitar ordem: $e');
      return false;
    }
  }

  /// Busca estatísticas do provedor
  Future<Map<String, dynamic>?> getStats(String providerId) async {
    try {
      return await _apiService.getProviderStats(providerId);
    } catch (e) {
      broLog('❌ Erro ao buscar estatísticas: $e');
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
      broLog('❌ Erro ao fazer upload do comprovante: $e');
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
      broLog('❌ Erro ao marcar como paga: $e');
      return false;
    }
  }

  /// Busca histórico de ordens completadas (usando Nostr)
  Future<List<Map<String, dynamic>>> fetchHistory(String providerId) async {
    try {
      broLog('🔍 Buscando histórico do provedor via Nostr...');
      
      // Buscar do Nostr
      final orders = await _nostrOrderService.fetchProviderOrders(providerId);
      
      // Filtrar apenas ordens completadas, liquidadas ou canceladas (histórico)
      final completedOrders = orders.where((order) {
        final status = order.status;
        return status == 'completed' || status == 'liquidated' || status == 'cancelled';
      }).toList();
      
      broLog('📋 ${completedOrders.length} ordens completadas no histórico');
      
      return completedOrders.map((order) => order.toJson()).toList();
    } catch (e) {
      broLog('❌ Erro ao buscar histórico: $e');
      return [];
    }
  }
}
