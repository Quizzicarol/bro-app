import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'api_service.dart';

class ProviderService {
  static final ProviderService _instance = ProviderService._internal();
  factory ProviderService() => _instance;
  ProviderService._internal();

  final ApiService _apiService = ApiService();

  /// Busca ordens disponíveis para aceitar (status=pending)
  Future<List<Map<String, dynamic>>> fetchAvailableOrders() async {
    try {
      final orders = await _apiService.listOrders(status: 'pending', limit: 50);
      return orders.map((order) => Map<String, dynamic>.from(order)).toList();
    } catch (e) {
      debugPrint('❌ Erro ao buscar ordens disponíveis: $e');
      return [];
    }
  }

  /// Busca ordens do provedor específico
  Future<List<Map<String, dynamic>>> fetchMyOrders(String providerId) async {
    try {
      final dio = Dio(BaseOptions(
        baseUrl: _apiService.baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      ));

      final response = await dio.get('/api/orders/list', queryParameters: {
        'providerId': providerId,
        'limit': 100,
      });

      final orders = response.data['orders'] ?? [];
      return orders.map<Map<String, dynamic>>((order) => Map<String, dynamic>.from(order)).toList();
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

  /// Busca histórico de ordens completadas
  Future<List<Map<String, dynamic>>> fetchHistory(String providerId) async {
    try {
      final dio = Dio(BaseOptions(
        baseUrl: _apiService.baseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      ));

      final response = await dio.get('/api/orders/list', queryParameters: {
        'providerId': providerId,
        'status': 'completed',
        'limit': 100,
      });

      final orders = response.data['orders'] ?? [];
      return orders.map<Map<String, dynamic>>((order) => Map<String, dynamic>.from(order)).toList();
    } catch (e) {
      debugPrint('❌ Erro ao buscar histórico: $e');
      return [];
    }
  }
}
