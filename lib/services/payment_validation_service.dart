import 'package:bro_app/services/log_utils.dart';
import 'package:flutter/foundation.dart';
import '../services/escrow_service.dart';
import '../services/api_service.dart';

/// Serviço para validação de comprovantes e liberação de fundos
class PaymentValidationService {
  final EscrowService _escrowService = EscrowService();
  final ApiService _apiService = ApiService();

  /// Validar comprovante de pagamento (pode ser automático ou manual)
  /// 
  /// Fluxo:
  /// 1. Verificar se comprovante foi enviado
  /// 2. Validação automática (OCR, análise de imagem) - opcional
  /// 3. Se aprovado: liberar escrow
  /// 4. Se rejeitado: permitir disputa
  Future<Map<String, dynamic>> validateReceipt({
    required String orderId,
    required String receiptUrl,
    bool autoApprove = false, // Para desenvolvimento/testes
  }) async {
    try {
      broLog('🔍 Validando comprovante para ordem $orderId');

      // Buscar detalhes da ordem
      final orderResponse = await _apiService.get('/api/orders/$orderId');
      if (orderResponse?['success'] != true) {
        throw Exception('Ordem não encontrada');
      }

      final order = orderResponse!['order'] as Map<String, dynamic>;
      final escrowId = order['escrow_id'] as String?;
      
      if (escrowId == null) {
        throw Exception('Escrow não encontrado para esta ordem');
      }

      // Validação automática (simplificada por enquanto)
      bool isValid = autoApprove;
      
      if (!autoApprove) {
        // TODO: Implementar validação real
        // - Análise OCR do comprovante
        // - Verificação de dados (valor, destinatário, data)
        // - Machine Learning para detectar fraudes
        
        // Por enquanto, marcar para revisão manual
        await _apiService.post('/api/orders/$orderId/review', {
          'receipt_url': receiptUrl,
          'status': 'pending_review',
          'submitted_at': DateTime.now().toIso8601String(),
        });

        broLog('📋 Comprovante enviado para revisão manual');
        
        return {
          'success': true,
          'status': 'pending_review',
          'message': 'Comprovante enviado para revisão. Você será notificado quando for aprovado.',
        };
      }

      // Se auto-aprovado (ou após validação manual)
      if (isValid) {
        broLog('✅ Comprovante aprovado! Liberando fundos...');
        
        // Marcar como aprovado
        await _apiService.post('/api/orders/$orderId/approve', {
          'approved_at': DateTime.now().toIso8601String(),
          'approved_by': 'system', // ou admin_id
        });

        return {
          'success': true,
          'status': 'approved',
          'message': 'Comprovante aprovado! Fundos serão liberados.',
        };
      } else {
        broLog('❌ Comprovante rejeitado');
        
        await _apiService.post('/api/orders/$orderId/reject', {
          'rejected_at': DateTime.now().toIso8601String(),
          'reason': 'Comprovante inválido ou ilegível',
        });

        return {
          'success': false,
          'status': 'rejected',
          'message': 'Comprovante rejeitado. Entre em contato com o suporte.',
        };
      }
    } catch (e) {
      broLog('❌ Erro ao validar comprovante: $e');
      return {
        'success': false,
        'error': e.toString(),
      };
    }
  }

  /// Liberar fundos após comprovante aprovado
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
      broLog('💸 Liberando fundos para ordem $orderId');

      // Liberar escrow via API
      await _escrowService.releaseEscrow(
        escrowId: escrowId,
        orderId: orderId,
        providerId: providerId,
      );

      // Desbloquear garantia do provedor
      await _escrowService.unlockCollateral(
        providerId: providerId,
        orderId: orderId,
      );

      broLog('✅ Fundos liberados com sucesso!');
      
      // Atualizar status da ordem
      await _apiService.post('/api/orders/$orderId/complete', {
        'completed_at': DateTime.now().toIso8601String(),
        'status': 'completed',
      });

      return true;
    } catch (e) {
      broLog('❌ Erro ao liberar fundos: $e');
      return false;
    }
  }

  /// Processar ordem completa (validar + liberar)
  /// 
  /// Usado quando comprovante é aprovado manualmente
  Future<bool> processApprovedOrder({
    required String orderId,
  }) async {
    try {
      // Buscar detalhes da ordem
      final orderResponse = await _apiService.get('/api/orders/$orderId');
      if (orderResponse?['success'] != true) {
        throw Exception('Ordem não encontrada');
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
      broLog('❌ Erro ao processar ordem: $e');
      return false;
    }
  }

  /// Auto-aprovar após timeout (para desenvolvimento)
  /// 
  /// Em produção, isso seria feito por um worker backend
  Future<void> scheduleAutoApproval({
    required String orderId,
    required Duration timeout,
  }) async {
    broLog('⏰ Agendando auto-aprovação para ordem $orderId em ${timeout.inMinutes}min');
    
    // Aguardar timeout
    await Future.delayed(timeout);
    
    // Verificar se ainda está pendente
    final orderResponse = await _apiService.get('/api/orders/$orderId');
    if (orderResponse?['success'] != true) return;

    final order = orderResponse!['order'] as Map<String, dynamic>;
    final status = order['status'] as String;

    if (status == 'payment_submitted') {
      broLog('⏰ Timeout atingido! Auto-aprovando ordem $orderId');
      
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
      broLog('⚠️ Rejeitando comprovante e abrindo disputa');

      // Rejeitar comprovante via API
      await _apiService.post('/api/orders/$orderId/reject', {
        'rejected_at': DateTime.now().toIso8601String(),
        'rejected_by': rejectedBy,
        'reason': reason,
        'status': 'disputed',
      });

      broLog('✅ Disputa aberta');
      return true;
    } catch (e) {
      broLog('❌ Erro ao rejeitar e abrir disputa: $e');
      return false;
    }
  }

  /// Consultar status de validação
  Future<Map<String, dynamic>?> getValidationStatus(String orderId) async {
    try {
      final response = await _apiService.get('/api/orders/$orderId/validation');
      
      if (response?['success'] == true) {
        return response!['validation'] as Map<String, dynamic>;
      }
      
      return null;
    } catch (e) {
      broLog('❌ Erro ao consultar status de validação: $e');
      return null;
    }
  }
}
