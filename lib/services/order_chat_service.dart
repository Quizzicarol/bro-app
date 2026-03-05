import 'dart:async';
import 'package:bro_app/services/log_utils.dart';
import 'package:flutter/foundation.dart';
import '../services/api_service.dart';
import '../models/escrow_deposit.dart';

/// Serviço de chat real-time entre provider e cliente durante uma ordem
/// 
/// Usa polling para simular real-time (pode ser substituído por WebSocket/Nostr DMs)
class OrderChatService {
  static OrderChatService? _instance;
  static OrderChatService get instance => _instance ??= OrderChatService._();
  
  OrderChatService._();

  final _api = ApiService();
  final _messageStreamControllers = <String, StreamController<OrderMessage>>{};
  final _pollingTimers = <String, Timer>{};

  /// Stream de mensagens para uma ordem específica
  Stream<OrderMessage> messagesStream(String orderId) {
    if (!_messageStreamControllers.containsKey(orderId)) {
      _messageStreamControllers[orderId] = StreamController<OrderMessage>.broadcast();
      _startPolling(orderId);
    }
    return _messageStreamControllers[orderId]!.stream;
  }

  /// Iniciar polling de mensagens
  void _startPolling(String orderId) {
    // Polling a cada 3 segundos
    _pollingTimers[orderId] = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _fetchNewMessages(orderId),
    );
  }

  /// Buscar novas mensagens
  Future<void> _fetchNewMessages(String orderId) async {
    try {
      final messages = await getMessages(orderId);
      
      // Emitir cada mensagem no stream
      for (final message in messages) {
        _messageStreamControllers[orderId]?.add(message);
      }
    } catch (e) {
      broLog('❌ Erro ao buscar mensagens: $e');
    }
  }

  /// Parar polling para uma ordem
  void stopPolling(String orderId) {
    _pollingTimers[orderId]?.cancel();
    _pollingTimers.remove(orderId);
    _messageStreamControllers[orderId]?.close();
    _messageStreamControllers.remove(orderId);
  }

  /// Enviar mensagem de texto
  Future<bool> sendMessage({
    required String orderId,
    required String senderId,
    required String senderType,
    required String message,
  }) async {
    try {
      broLog('💬 Enviando mensagem...');

      final response = await _api.post('/api/chat/send', {
        'orderId': orderId,
        'senderId': senderId,
        'senderType': senderType,
        'message': message,
      });

      if (response?['success'] != true) {
        throw Exception(response?['error'] ?? 'Erro ao enviar mensagem');
      }

      broLog('✅ Mensagem enviada');
      return true;

    } catch (e) {
      broLog('❌ Erro ao enviar mensagem: $e');
      return false;
    }
  }

  /// Enviar comprovante (imagem ou PDF)
  Future<bool> sendReceipt({
    required String orderId,
    required String providerId,
    required String fileBase64,
    required String fileType, // 'image' | 'pdf'
    String message = 'Comprovante enviado',
  }) async {
    try {
      broLog('📎 Enviando comprovante...');

      final response = await _api.post('/api/chat/send-receipt', {
        'orderId': orderId,
        'providerId': providerId,
        'fileBase64': fileBase64,
        'fileType': fileType,
        'message': message,
      });

      if (response?['success'] != true) {
        throw Exception(response?['error'] ?? 'Erro ao enviar comprovante');
      }

      broLog('✅ Comprovante enviado');
      return true;

    } catch (e) {
      broLog('❌ Erro ao enviar comprovante: $e');
      return false;
    }
  }

  /// Obter todas as mensagens de uma ordem
  Future<List<OrderMessage>> getMessages(String orderId) async {
    try {
      final response = await _api.get('/api/chat/messages/$orderId');
      
      if (response?['success'] != true) {
        return [];
      }

      final messages = (response!['messages'] as List?)
          ?.map((json) => OrderMessage.fromJson(json))
          .toList() ?? [];

      return messages;

    } catch (e) {
      broLog('❌ Erro ao buscar mensagens: $e');
      return [];
    }
  }

  /// Marcar mensagens como lidas
  Future<void> markAsRead({
    required String orderId,
    required String userId,
  }) async {
    try {
      await _api.post('/api/chat/mark-read', {
        'orderId': orderId,
        'userId': userId,
      });
    } catch (e) {
      broLog('❌ Erro ao marcar como lido: $e');
    }
  }

  /// Contar mensagens não lidas
  Future<int> getUnreadCount({
    required String orderId,
    required String userId,
  }) async {
    try {
      final response = await _api.get('/api/chat/unread/$orderId/$userId');
      
      if (response?['success'] != true) {
        return 0;
      }

      return response!['count'] as int? ?? 0;

    } catch (e) {
      broLog('❌ Erro ao contar não lidas: $e');
      return 0;
    }
  }

  /// Limpar todos os recursos
  void dispose() {
    for (final timer in _pollingTimers.values) {
      timer.cancel();
    }
    for (final controller in _messageStreamControllers.values) {
      controller.close();
    }
    _pollingTimers.clear();
    _messageStreamControllers.clear();
  }
}
