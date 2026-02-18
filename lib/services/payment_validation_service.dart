import 'package:flutter/foundation.dart';
import '../services/escrow_service.dart';
import '../services/api_service.dart';

/// Servi�o para valida��o de comprovantes e libera��o de fundos
class PaymentValidationService {
  final EscrowService _escrowService = EscrowService();
  final ApiService _apiService = ApiService();

  /// Validar comprovante de pagamento (pode ser autom�tico ou manual)
  /// 
  /// Fluxo:
  /// 1. Verificar se comprovante foi enviado
  /// 2. Valida��o autom�tica (OCR, an�lise de imagem) - opcional
  /// 3. Se aprovado: liberar escrow
  /// 4. Se rejeitado: permitir disputa
  Future<Map<String, dynamic>> validateReceipt({
    required String orderId,
    required String receiptUrl,
    bool autoApprove = false, // Para desenvolvimento/testes
  }) async {
    try {
      debugPrint('?? Validando comprovante para ordem $orderId');

      // Buscar detalhes da ordem
      final orderResponse = await _apiService.get('/api/orders/$orderId');
      if (orderResponse?['success'] != true) {
        throw Exception('Ordem n�o encontrada');
      }

      final order = orderResponse!['order'] as Map<String, dynamic>;
      final escrowId = order['escrow_id'] as String?;
      
      if (escrowId == null) {
        throw Exception('Escrow n�o encontrado para esta ordem');
      }

      // Valida��o autom�tica (simplificada por enquanto)
      bool isValid = autoApprove;
      
      if (!autoApprove) {
        // TODO: Implementar valida��o real
        // - An�lise OCR do comprovante
        // - Verifica��o de dados (valor, destinat�rio, data)
        // - Machine Learning para detectar fraudes
        
        // Por enquanto, marcar para revis�o manual
        await _apiService.post('/api/orders/$orderId/review', {
          'receipt_url': receiptUrl,
          'status': 'pending_review',
          'submitted_at': DateTime.now().toIso8601String(),
        });

        debugPrint('?? Comprovante enviado para revis�o manual');
        
        return {
          'success': true,
          'status': 'pending_review',
          'message': 'Comprovante enviado para revis�o. Voc� ser� notificado quando for aprovado.',
        };
      }

      // Se auto-aprovado (ou ap�s valida��o manual)
      if (isValid) {
        debugPrint('? Comprovante aprovado! Liberando fundos...');
        
        // Marcar como aprovado
        await _apiService.post('/api/orders/$orderId/approve', {
          'approved_at': DateTime.now().toIso8601String(),
          'approved_by': 'system', // ou admin_id
        });

        return {
          'success': true,
          'status': 'approved',
          'message': 'Comprovante aprovado! Fundos ser�o liberados.',
        };
      } else {
        debugPrint('? Comprovante rejeitado');
        
        await _apiService.post('/api/orders/$orderId/reject', {
          'rejected_at': DateTime.now().toIso8601String(),
          'reason': 'Comprovante inv�lido ou ileg�vel',
        });

        return {
          'success': false,
          'status': 'rejected',
          'message': 'Comprovante rejeitado. Entre em contato com o suporte.',
        };
      }
    } catch (e) {
      debugPrint('? Erro ao validar comprovante: $e');
      return {
        'success': false,
        'error': e.toString(),
      };
    }
  }

  /// Liberar fundos ap�s comprovante aprovado
  /// 
  /// Distribui:
  /// - Provedor: valor da conta + 3% de taxa
  /// - Plataforma: 2% de taxa
  /// - Desbloqueia garantia do provedor
  Future<bool> releaseFunds({
    required String orderId,
    required String escrowId,
    required String providerId,
  }) async {
    try {
      debugPrint('?? Liberando fundos para ordem $orderId');

      // Liberar escrow via API
      await _escrowService.releaseEscrow(
        escrowId: escrowId,
        orderId: orderId,
        providerId: providerId,
      );

      debugPrint('? Fundos liberados com sucesso!');
      
      // Atualizar status da ordem
      await _apiService.post('/api/orders/$orderId/complete', {
        'completed_at': DateTime.now().toIso8601String(),
        'status': 'completed',
      });

      return true;
    } catch (e) {
      debugPrint('? Erro ao liberar fundos: $e');
      return false;
    }
  }

  /// Processar ordem completa (validar + liberar)
  /// 
  /// Usado quando comprovante � aprovado manualmente
  Future<bool> processApprovedOrder({
    required String orderId,
  }) async {
    try {
      // Buscar detalhes da ordem
      final orderResponse = await _apiService.get('/api/orders/$orderId');
      if (orderResponse?['success'] != true) {
        throw Exception('Ordem n�o encontrada');
      }

      final order = orderResponse!['order'] as Map<String, dynamic>;
      final escrowId = order['escrow_id'] as String;
      final providerId = order['provider_id'] as String;

      // Liberar fundos
      return await releaseFunds(
        orderId: orderId,
        escrowId: escrowId,
        providerId: providerId,
      );
    } catch (e) {
      debugPrint('? Erro ao processar ordem: $e');
      return false;
    }
  }

  /// Auto-aprovar ap�s timeout (para desenvolvimento)
  /// 
  /// Em produ��o, isso seria feito por um worker backend
  Future<void> scheduleAutoApproval({
    required String orderId,
    required Duration timeout,
  }) async {
    debugPrint('? Agendando auto-aprova��o para ordem $orderId em ${timeout.inMinutes}min');
    
    // Aguardar timeout
    await Future.delayed(timeout);
    
    // Verificar se ainda est� pendente
    final orderResponse = await _apiService.get('/api/orders/$orderId');
    if (orderResponse?['success'] != true) return;

    final order = orderResponse!['order'] as Map<String, dynamic>;
    final status = order['status'] as String;

    if (status == 'payment_submitted') {
      debugPrint('? Timeout atingido! Auto-aprovando ordem $orderId');
      
      await validateReceipt(
        orderId: orderId,
        receiptUrl: order['receipt_url'] as String,
        autoApprove: true,
      );
    }
  }

  /// Rejeitar comprovante e abrir disputa
  Future<bool> rejectAndDispute({
    required String orderId,
    required String reason,
    required String rejectedBy, // 'admin' ou 'user'
  }) async {
    try {
      debugPrint('?? Rejeitando comprovante e abrindo disputa');

      // Rejeitar comprovante via API
      await _apiService.post('/api/orders/$orderId/reject', {
        'rejected_at': DateTime.now().toIso8601String(),
        'rejected_by': rejectedBy,
        'reason': reason,
        'status': 'disputed',
      });

      debugPrint('? Disputa aberta');
      return true;
    } catch (e) {
      debugPrint('? Erro ao rejeitar e abrir disputa: $e');
      return false;
    }
  }

  /// Consultar status de valida��o
  Future<Map<String, dynamic>?> getValidationStatus(String orderId) async {
    try {
      final response = await _apiService.get('/api/orders/$orderId/validation');
      
      if (response?['success'] == true) {
        return response!['validation'] as Map<String, dynamic>;
      }
      
      return null;
    } catch (e) {
      debugPrint('? Erro ao consultar status de valida��o: $e');
      return null;
    }
  }
}
