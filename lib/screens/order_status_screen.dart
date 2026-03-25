import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:image_picker/image_picker.dart';
import '../services/order_service.dart';
import '../services/dispute_service.dart';
import '../services/lnaddress_service.dart';
import '../services/withdrawal_service.dart';
import '../services/nostr_order_service.dart';
import '../services/nip44_service.dart';
import '../services/platform_fee_service.dart';
import '../models/withdrawal.dart';
import '../providers/breez_provider_export.dart';
import '../providers/breez_liquid_provider.dart';
import '../providers/lightning_provider.dart';
import '../providers/order_provider.dart';
import '../providers/provider_balance_provider.dart';
import '../providers/platform_balance_provider.dart';
import '../config.dart';
import '../l10n/app_localizations.dart';
import '../services/notification_service.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:flutter/services.dart';

/// Tela exibida após pagamento confirmado
/// Mostra status da ordem e aguarda provedor aceitar
class OrderStatusScreen extends StatefulWidget {
  final String orderId;
  final String? userId;
  final double amountBrl;
  final int amountSats;

  const OrderStatusScreen({
    Key? key,
    required this.orderId,
    this.userId,
    required this.amountBrl,
    required this.amountSats,
  }) : super(key: key);

  @override
  State<OrderStatusScreen> createState() => _OrderStatusScreenState();
}

class _OrderStatusScreenState extends State<OrderStatusScreen> {
  final OrderService _orderService = OrderService();
  final NotificationService _notificationService = NotificationService();
  Timer? _statusCheckTimer;
  Timer? _countdownTimer;
  
  Map<String, dynamic>? _orderDetails;
  String _currentStatus = 'pending';
  bool _isLoading = true;
  String? _error;
  DateTime? _expiresAt;
  
  // Dados da disputa para exibição no relatório
  String? _disputeReason;
  String? _disputeDescription;
  DateTime? _disputeCreatedAt;
  String? _userEvidence; // v236: evidência foto do usuário (base64)
  
  // Dados de resolução de disputa (vindo do mediador)
  Map<String, dynamic>? _disputeResolution;
  
  // v337: Pagamento pendente pós-resolução de disputa a favor do provedor
  bool _disputePaymentPending = false;
  bool _isPayingDisputeResolution = false;
  
  // v237: Mensagens do mediador para o usuário
  List<Map<String, dynamic>> _mediatorMessages = [];
  bool _loadingMediatorMessages = false;

  @override
  void initState() {
    super.initState();
    _loadOrderDetails();
    _startStatusPolling();
    _fetchResolutionIfNeeded();
    _fetchMediatorMessagesForUser();
  }

  @override
  void dispose() {
    _statusCheckTimer?.cancel();
    _countdownTimer?.cancel();
    _paymentCheckTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadOrderDetails() async {
    try {
      Map<String, dynamic>? order;
      
      // Primeiro tenta pelo OrderService (com tratamento de exceção)
      try {
        order = await _orderService.getOrder(widget.orderId);
      } catch (serviceError) {
        broLog('⚠️ OrderService falhou: $serviceError');
        // Continua para tentar o OrderProvider
      }
      
      // Se não encontrou, tenta buscar pelo OrderProvider (que tem as ordens em memória)
      if (order == null && mounted) {
        broLog('⚠️ Ordem não encontrada no OrderService, tentando OrderProvider...');
        try {
          final orderProvider = Provider.of<OrderProvider>(context, listen: false);
          final orderFromProvider = orderProvider.orders.firstWhere(
            (o) => o.id == widget.orderId,
            orElse: () => throw Exception('Ordem não encontrada no OrderProvider'),
          );
          // Converter Order para Map
          order = orderFromProvider.toJson();
          broLog('✅ Ordem encontrada no OrderProvider: ${widget.orderId}');
        } catch (providerError) {
          broLog('⚠️ OrderProvider também falhou: $providerError');
        }
      }
      
      if (order != null) {
        if (!mounted) return;
        setState(() {
          _orderDetails = order;
          _currentStatus = order!['status'] ?? 'pending';
          // Calcular expiração baseada em proofReceivedAt (metadado real)
          _expiresAt = _calculateExpiresAt(order!);
          _isLoading = false;
        });
        // CORREÇÃO v234: Iniciar countdown se a ordem JÁ está em awaiting_confirmation
        // Antes o timer só era iniciado na transição de status, não ao abrir a tela
        if (_currentStatus == 'awaiting_confirmation' && _expiresAt != null) {
          _startCountdownTimer();
        }
        // Auto-pagamento de ordens liquidadas é feito pelo OrderProvider no sync
      } else {
        if (!mounted) return;
        setState(() {
          _error = 'Ordem não encontrada';
          _isLoading = false;
        });
      }
    } catch (e) {
      broLog('❌ Erro ao carregar ordem: $e');
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }
/// Busca resolução de disputa do Nostr (se a ordem tiver passado por disputa)
  Future<void> _fetchResolutionIfNeeded() async {
    // Aguardar dados da ordem carregarem
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    
    // Buscar resolução para qualquer ordem (pode ter sido disputada e já resolvida)
    try {
      final nostrService = NostrOrderService();
      final resolution = await nostrService.fetchDisputeResolution(widget.orderId);
      if (resolution != null && mounted) {
        // v337: Verificar se pagamento ao provedor ainda é necessário
        bool paymentNeeded = false;
        if (resolution['resolution'] == 'resolved_provider') {
          final orderProvider = context.read<OrderProvider>();
          final order = orderProvider.getOrderById(widget.orderId);
          final alreadyPaid = order?.metadata?['disputeProviderPaid'] == true;
          if (!alreadyPaid) {
            paymentNeeded = true;
            broLog('⚠️ Disputa resolvida a favor do provedor - pagamento pendente!');
          }
        }
        setState(() {
          _disputeResolution = resolution;
          _disputePaymentPending = paymentNeeded;
        });
        broLog('✅ Resolução de disputa encontrada para ${widget.orderId.substring(0, 8)}');
        
        // v390: Atualizar status da ordem se ainda está 'disputed' — corrige dashboard
        try {
          final orderProvider = context.read<OrderProvider>();
          final order = orderProvider.getOrderById(widget.orderId);
          if (order != null && order.status == 'disputed') {
            final newStatus = resolution['resolution'] == 'resolved_user' ? 'cancelled' : 'completed';
            final updatedMetadata = {
              ...?order.metadata,
              'wasDisputed': true,
              'disputeResolvedAt': DateTime.now().toIso8601String(),
            };
            orderProvider.updateOrderWithMetadata(
              orderId: widget.orderId,
              status: newStatus,
              metadata: updatedMetadata,
            );
            broLog('⚖️ Ordem ${widget.orderId.substring(0, 8)} atualizada: disputed → $newStatus (wasDisputed=true)');
          }
        } catch (e) {
          broLog('⚠️ Erro ao atualizar status da disputa resolvida: $e');
        }
        
        // v338: AUTO-PAY — pagar provedor automaticamente sem interação do usuário
        if (paymentNeeded && mounted) {
          broLog('🤖 [AutoPay] Iniciando pagamento automático ao provedor...');
          // Delay breve para garantir que UI renderizou
          await Future.delayed(const Duration(seconds: 1));
          if (mounted) {
            _handleDisputePayment(autoMode: true);
          }
        }
      }
    } catch (e) {
      broLog('⚠️ Erro ao buscar resolução: $e');
    }
  }
  
  /// v237: Busca mensagens do mediador direcionadas a este usuário para esta ordem
  Future<void> _fetchMediatorMessagesForUser() async {
    // Aguardar dados da ordem carregarem
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    
    setState(() => _loadingMediatorMessages = true);
    
    try {
      final orderProvider = context.read<OrderProvider>();
      final userPubkey = orderProvider.currentUserPubkey;
      if (userPubkey == null || userPubkey.isEmpty) {
        if (mounted) setState(() => _loadingMediatorMessages = false);
        return;
      }
      
      final nostrService = NostrOrderService();
      final messages = await nostrService.fetchMediatorMessages(
        userPubkey, 
        orderId: widget.orderId,
      );
      
      if (mounted) {
        setState(() {
          _mediatorMessages = messages;
          _loadingMediatorMessages = false;
        });
        if (messages.isNotEmpty) {
          broLog('📨 Usuário: ${messages.length} mensagens do mediador para ordem ${widget.orderId.substring(0, 8)}');
        }
      }
    } catch (e) {
      broLog('⚠️ Erro ao buscar mensagens do mediador: $e');
      if (mounted) setState(() => _loadingMediatorMessages = false);
    }
  }
  
  
  /// Trata mudancas de status e envia notificacoes
  void _handleStatusChange(String newStatus) {
    switch (newStatus) {
      case 'accepted':
        _notificationService.notifyOrderAccepted(
          orderId: widget.orderId,
          broName: _orderDetails?['provider_id']?.substring(0, 8) ?? 'Bro',
        );
        break;
      case 'awaiting_confirmation':
      case 'payment_submitted':
        _notificationService.notifyPaymentReceived(
          orderId: widget.orderId,
          amount: widget.amountBrl,
        );
        break;
      case 'completed':
        _notificationService.notifyOrderCompleted(
          orderId: widget.orderId,
          amount: widget.amountBrl,
        );
        // Se veio de disputed, buscar resolução para mostrar detalhes
        if (_currentStatus == 'disputed' && _disputeResolution == null) {
          _fetchResolutionIfNeeded();
        }
        break;
      case 'liquidated':
        _notificationService.notifyOrderAutoLiquidated(
          orderId: widget.orderId,
          amountBrl: widget.amountBrl,
        );
        // Auto-pagamento é feito pelo OrderProvider._autoPayLiquidatedOrders() no sync
        break;
      case 'disputed':
        _notificationService.notifyDisputeOpened(orderId: widget.orderId);
        break;
    }
  }

  /// Calcula quando a ordem expira baseado no timestamp real do comprovante
  DateTime _calculateExpiresAt(Map<String, dynamic> order) {
    // 1. Tentar expires_at do backend
    if (order['expires_at'] != null) {
      try {
        return DateTime.parse(order['expires_at']);
      } catch (_) {}
    }
    // 2. Tentar proofReceivedAt ou receipt_submitted_at do metadata
    final metadata = order['metadata'] as Map<String, dynamic>?;
    if (metadata != null) {
      final submittedAt = metadata['receipt_submitted_at'] as String?
          ?? metadata['proofReceivedAt'] as String?;
      if (submittedAt != null) {
        try {
          return DateTime.parse(submittedAt).add(const Duration(hours: 36));
        } catch (_) {}
      }
    }
    // 3. Fallback: updatedAt + 36h
    if (order['updatedAt'] != null) {
      try {
        return DateTime.parse(order['updatedAt']).add(const Duration(hours: 36));
      } catch (_) {}
    }
    // 4. Último recurso
    return DateTime.now().add(const Duration(hours: 36));
  }

  /// Inicia timer para atualizar o countdown na UI a cada 30s
  void _startCountdownTimer() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  void _startStatusPolling() {
    // PERFORMANCE: Intervalo aumentado de 5s para 15s
    // O syncOrdersFromNostr tem throttle interno que evita syncs < 10s
    _statusCheckTimer = Timer.periodic(const Duration(seconds: 15), (timer) async {
      // CORREÇÃO: Verificar se a tela ainda está montada antes de fazer qualquer coisa
      if (!mounted) {
        timer.cancel();
        return;
      }
      
      // CORREÇÃO: Sincronizar com Nostr para buscar atualizações (aceites, comprovantes)
      final orderProvider = Provider.of<OrderProvider>(context, listen: false);
      
      // Forçar sincronização com Nostr a cada polling
      try {
        await orderProvider.syncOrdersFromNostr();
      } catch (e) {
        broLog('⚠️ Erro ao sincronizar Nostr no polling: $e');
      }
      
      if (!mounted) return;
      
      final order = orderProvider.getOrderById(widget.orderId);
      final status = order?.status ?? _currentStatus;
      
      // Atualizar orderDetails com dados mais recentes (incluindo metadata/proofImage)
      if (order != null && mounted) {
        final orderMap = order.toJson();
        setState(() {
          _orderDetails = orderMap;
          _expiresAt = _calculateExpiresAt(orderMap);
        });
      }
      
      if (status != _currentStatus) {
        // Notificar sobre mudanca de status
        _handleStatusChange(status);
        if (!mounted) return;
        setState(() {
          _currentStatus = status;
        });

        // Iniciar countdown timer quando chega em awaiting_confirmation
        if (status == 'awaiting_confirmation') {
          _startCountdownTimer();
        }

        // Parar polling em estados FINAIS (completed, cancelled, liquidated)
        // NOTA: disputed NÃO para o polling — precisa detectar resolução da mediação
        if (status == 'completed' || status == 'cancelled' || status == 'liquidated') {
          timer.cancel();
          _countdownTimer?.cancel();
        }
      }

      // REMOVIDO: Ordens em 'pending' NÃO expiram
      // Só expiram após Bro aceitar e usuário demorar 36h para confirmar
      // A expiração só deve ocorrer no status 'awaiting_confirmation'
      if (!mounted) return;
      if (_currentStatus == 'awaiting_confirmation' && _expiresAt != null && _orderService.isOrderExpired(_expiresAt!)) {
        timer.cancel();
        _showExpiredDialog();
      }
      
    });
  }

  void _showExpiredDialog() {
    final l = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(l.t('order_time_expired')),
        content: Text(
          l.t('order_time_expired_content'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.t('order_wait')),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _handleCancelOrder();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: Text(l.t('order_cancel')),
          ),
        ],
      ),
    );
  }

  Future<void> _handleCancelOrder() async {
    final l = AppLocalizations.of(context)!;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.t('order_cancel_confirm_title')),
        content: Text(
          l.t('order_cancel_confirm_content'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.t('no')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: Text(l.t('order_yes_cancel')),
          ),
        ],
      ),
    );

    if (confirm == true) {
      setState(() => _isLoading = true);
      
      bool success = false;
      
      // SEMPRE cancelar localmente primeiro (modo P2P via Nostr)
      // Isso garante que funciona mesmo sem backend
      try {
        final orderProvider = Provider.of<OrderProvider>(context, listen: false);
        await orderProvider.updateOrderStatusLocal(widget.orderId, 'cancelled');
        success = true;
        broLog('✅ Ordem ${widget.orderId} cancelada localmente');
      } catch (e) {
        broLog('⚠️ Erro ao cancelar ordem local: $e');
      }
      
      // Se não está em modo teste, também tentar notificar backend (com timeout)
      if (!AppConfig.testMode && !success) {
        try {
          success = await _orderService.cancelOrder(
            orderId: widget.orderId,
            userId: widget.userId ?? '',
            reason: l.t('order_cancelled_by_user'),
          ).timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              broLog('⚠️ Timeout ao cancelar no backend, usando cancelamento local');
              return false;
            },
          );
          
          // Se backend falhou mas temos acesso local, cancelar local mesmo assim
          if (!success) {
            final orderProvider = Provider.of<OrderProvider>(context, listen: false);
            await orderProvider.updateOrderStatusLocal(widget.orderId, 'cancelled');
            success = true;
            broLog('✅ Ordem ${widget.orderId} cancelada localmente (fallback)');
          }
        } catch (e) {
          broLog('⚠️ Erro ao cancelar no backend: $e');
          // Tentar cancelar local como fallback
          try {
            final orderProvider = Provider.of<OrderProvider>(context, listen: false);
            await orderProvider.updateOrderStatusLocal(widget.orderId, 'cancelled');
            success = true;
            broLog('✅ Ordem ${widget.orderId} cancelada localmente (fallback)');
          } catch (e2) {
            broLog('❌ Erro ao cancelar ordem local (fallback): $e2');
          }
        }
      }

      setState(() => _isLoading = false);

      if (success && mounted) {
        // Atualizar status da ordem na tela para mostrar que foi cancelada
        setState(() {
          _currentStatus = 'cancelled';
        });
        
        // Mostrar confirmação simples
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.t('order_cancelled_success')),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.t('order_cancel_error')),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // Mantido para uso manual pelo usuário (botão de saque na tela)
  void _showWithdrawInstructions() {
    _showWithdrawModal();
  }

  // ==================== MODAL DE SAQUE COMPLETO ====================
  void _showWithdrawModal() async {
    final l = AppLocalizations.of(context)!;
    // Obter saldo real da carteira
    final breezProvider = Provider.of<BreezProvider>(context, listen: false);
    final balanceInfo = await breezProvider.getBalance();
    final realBalance = int.tryParse(balanceInfo?['balance']?.toString() ?? '0') ?? 0;
    
    final amountController = TextEditingController(text: realBalance.toString());
    final destinationController = TextEditingController();
    bool isSending = false;
    bool isResolvingLnAddress = false;
    String? errorMessage;
    String? infoMessage;
    int? minSats;
    int? maxSats;
    
    if (!mounted) return;
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom + 20,
              left: 20,
              right: 20,
              top: 20,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: const Icon(Icons.send, color: Colors.orange),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l.t('order_withdraw_sats'),
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              l.tp('order_wallet_balance', {'balance': realBalance.toString()}),
                              style: TextStyle(
                                color: realBalance > 0 ? Colors.green : Colors.red,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white54),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  
                  // Campo de valor
                  Text(
                    l.t('order_withdraw_amount'),
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: amountController,
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                    keyboardType: TextInputType.number,
                    enabled: !isSending && !isResolvingLnAddress,
                    decoration: InputDecoration(
                      hintText: l.t('order_amount_hint'),
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                      prefixIcon: const Icon(Icons.bolt, color: Colors.orange),
                      suffixText: 'sats',
                      suffixStyle: const TextStyle(color: Colors.orange),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFF333333)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFF333333)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Colors.orange),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Botão MAX
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () {
                        amountController.text = realBalance.toString();
                      },
                      child: Text(
                        l.tp('order_max_balance', {'balance': realBalance.toString()}),
                        style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  
                  // Info sobre limites do destino
                  if (infoMessage != null) ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.blue.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.blue.withOpacity(0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline, color: Colors.blue, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              infoMessage!,
                              style: const TextStyle(color: Colors.blue, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  
                  const SizedBox(height: 4),
                  
                  // Campo de destino
                  Text(
                    l.t('order_destination_label'),
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: destinationController,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    maxLines: 3,
                    enabled: !isSending && !isResolvingLnAddress,
                    decoration: InputDecoration(
                      hintText: l.t('order_destination_hint'),
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFF333333)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFF333333)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Colors.orange),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  
                  // Botões Colar e Escanear
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: (isSending || isResolvingLnAddress) ? null : () async {
                            final clipboard = await Clipboard.getData('text/plain');
                            if (clipboard?.text != null) {
                              destinationController.text = clipboard!.text!.trim();
                            }
                          },
                          icon: const Icon(Icons.paste, size: 18),
                          label: Text(l.t('order_paste')),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.orange,
                            side: const BorderSide(color: Colors.orange),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: (isSending || isResolvingLnAddress) ? null : () async {
                            final scanned = await _showQRScannerModal();
                            if (scanned != null && scanned.isNotEmpty) {
                              setModalState(() {
                                destinationController.text = scanned;
                              });
                            }
                          },
                          icon: const Icon(Icons.qr_code_scanner, size: 18),
                          label: Text(l.t('order_scan')),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.green,
                            side: const BorderSide(color: Colors.green),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                  
                  // Mensagem de erro
                  if (errorMessage != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.withOpacity(0.3)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline, color: Colors.red, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              errorMessage!,
                              style: const TextStyle(color: Colors.red, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  
                  const SizedBox(height: 20),
                  
                  // Botão Enviar
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: (isSending || isResolvingLnAddress) ? null : () async {
                        final destination = destinationController.text.trim();
                        final amountText = amountController.text.trim();
                        
                        // Validar valor
                        final amount = int.tryParse(amountText);
                        if (amount == null || amount <= 0) {
                          setModalState(() => errorMessage = l.t('order_enter_valid_amount'));
                          return;
                        }
                        
                        if (amount > realBalance) {
                          setModalState(() => errorMessage = l.tp('order_insufficient_balance', {'balance': realBalance.toString()}));
                          return;
                        }
                        
                        // Validar destino
                        if (destination.isEmpty) {
                          setModalState(() => errorMessage = l.t('order_paste_or_scan'));
                          return;
                        }
                        
                        setModalState(() {
                          errorMessage = null;
                          infoMessage = null;
                        });
                        
                        String invoiceToSend = destination;
                        
                        // Verificar se é Lightning Address ou LNURL
                        if (LnAddressService.isLightningAddress(destination) || 
                            LnAddressService.isLnurl(destination)) {
                          setModalState(() {
                            isResolvingLnAddress = true;
                            infoMessage = l.t('order_checking_limits');
                          });
                          
                          final lnService = LnAddressService();
                          
                          // Primeiro resolver para ver os limites
                          Map<String, dynamic> resolved;
                          if (LnAddressService.isLnurl(destination)) {
                            resolved = await lnService.resolveLnurl(destination);
                          } else {
                            resolved = await lnService.resolveLnAddress(destination);
                          }
                          
                          if (resolved['success'] != true) {
                            setModalState(() {
                              isResolvingLnAddress = false;
                              infoMessage = null;
                              errorMessage = resolved['error'] ?? l.t('order_resolve_error');
                            });
                            return;
                          }
                          
                          minSats = resolved['minSats'] as int?;
                          maxSats = resolved['maxSats'] as int?;
                          
                          // Verificar se o valor está nos limites
                          if (minSats != null && amount < minSats!) {
                            setModalState(() {
                              isResolvingLnAddress = false;
                              infoMessage = l.tp('order_destination_range', {'min': minSats.toString(), 'max': maxSats.toString()});
                              errorMessage = l.tp('order_min_amount', {'min': minSats.toString(), 'amount': amount.toString()});
                            });
                            return;
                          }
                          
                          if (maxSats != null && amount > maxSats!) {
                            setModalState(() {
                              isResolvingLnAddress = false;
                              infoMessage = l.tp('order_destination_range', {'min': minSats.toString(), 'max': maxSats.toString()});
                              errorMessage = l.tp('order_max_amount', {'max': maxSats.toString(), 'amount': amount.toString()});
                            });
                            return;
                          }
                          
                          setModalState(() {
                            infoMessage = l.tp('order_getting_invoice', {'amount': amount.toString()});
                          });
                          
                          final result = await lnService.getInvoice(
                            lnAddress: destination,
                            amountSats: amount,
                            comment: 'Saque Bro App',
                          );
                          
                          if (result['success'] != true) {
                            setModalState(() {
                              isResolvingLnAddress = false;
                              infoMessage = null;
                              errorMessage = result['error'] ?? l.t('order_error_get_invoice');
                            });
                            return;
                          }
                          
                          invoiceToSend = result['invoice'] as String;
                          setModalState(() {
                            isResolvingLnAddress = false;
                            infoMessage = null;
                          });
                        } else if (!destination.toLowerCase().startsWith('lnbc') && 
                                   !destination.toLowerCase().startsWith('lntb')) {
                          setModalState(() => errorMessage = l.t('order_invalid_destination'));
                          return;
                        }
                        
                        // Determinar tipo de destino
                        String destType = 'invoice';
                        if (LnAddressService.isLnurl(destination)) {
                          destType = 'lnurl';
                        } else if (LnAddressService.isLightningAddress(destination)) {
                          destType = 'lnaddress';
                        }
                        
                        // Enviar pagamento
                        setModalState(() {
                          isSending = true;
                          infoMessage = l.tp('order_sending_amount', {'amount': amount.toString()});
                        });
                        
                        try {
                          final breezProvider = Provider.of<BreezProvider>(context, listen: false);
                          final result = await breezProvider.payInvoice(invoiceToSend);
                          
                          if (result != null && result['success'] == true) {
                            // Registrar saque bem-sucedido
                            final withdrawalService = WithdrawalService();
                            await withdrawalService.saveWithdrawal(
                              orderId: widget.orderId,
                              amountSats: amount,
                              destination: destination,
                              destinationType: destType,
                              status: 'success',
                              txId: result['paymentHash'] ?? result['txId'],
                              userPubkey: widget.userId ?? 'anonymous',
                            );
                            
                            if (context.mounted) {
                              Navigator.pop(context); // Fechar modal
                              ScaffoldMessenger.of(this.context).showSnackBar(
                                SnackBar(
                                  content: Text(l.tp('order_withdraw_success', {'amount': amount.toString()})),
                                  backgroundColor: Colors.green,
                                ),
                              );
                              // Recarregar a tela para mostrar o saque registrado
                              setState(() {});
                            }
                          } else {
                            final errMsg = result?['error'] ?? l.t('order_payment_failed_msg');
                            
                            // Registrar saque que falhou
                            final withdrawalService = WithdrawalService();
                            await withdrawalService.saveWithdrawal(
                              orderId: widget.orderId,
                              amountSats: amount,
                              destination: destination,
                              destinationType: destType,
                              status: 'failed',
                              error: errMsg,
                              userPubkey: widget.userId ?? 'anonymous',
                            );
                            
                            setModalState(() {
                              isSending = false;
                              errorMessage = errMsg;
                            });
                          }
                        } catch (e) {
                          // Registrar erro
                          final withdrawalService = WithdrawalService();
                          await withdrawalService.saveWithdrawal(
                            orderId: widget.orderId,
                            amountSats: amount,
                            destination: destination,
                            destinationType: destType,
                            status: 'failed',
                            error: e.toString(),
                            userPubkey: widget.userId ?? 'anonymous',
                          );
                          
                          setModalState(() {
                            isSending = false;
                            errorMessage = l.tp('order_error_generic', {'error': e.toString()});
                          });
                        }
                      },
                      icon: (isSending || isResolvingLnAddress)
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.bolt),
                      label: Text(
                        isResolvingLnAddress 
                            ? l.t('order_resolving_address') 
                            : (isSending ? l.t('order_sending') : l.t('order_send_sats')),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // Outras opções
                  Center(
                    child: TextButton(
                      onPressed: () {
                        Navigator.pop(context);
                        // Voltar para home para criar nova ordem
                        Navigator.popUntil(context, (route) => route.isFirst);
                      },
                      child: Text(
                        l.t('order_create_new_order'),
                        style: const TextStyle(color: Colors.white54),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // QR Scanner Modal
  Future<String?> _showQRScannerModal() async {
    final l = AppLocalizations.of(context)!;
    String? scannedCode;
    
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                color: Color(0xFF1A1A1A),
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.qr_code_scanner, color: Colors.green, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.t('order_scan_destination'),
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          l.t('order_scan_subtitle'),
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            
            // Scanner
            Expanded(
              child: MobileScanner(
                onDetect: (capture) {
                  final List<Barcode> barcodes = capture.barcodes;
                  broLog('📷 QR Scanner detectou ${barcodes.length} códigos');
                  
                  for (final barcode in barcodes) {
                    final code = barcode.rawValue;
                    broLog('📷 Código raw: $code');
                    
                    if (code != null && code.isNotEmpty) {
                      String cleaned = code.trim();
                      broLog('📷 Código limpo: $cleaned');
                      
                      // Remover prefixos comuns de URI
                      final lowerCleaned = cleaned.toLowerCase();
                      if (lowerCleaned.startsWith('lightning:')) {
                        cleaned = cleaned.substring(10);
                      } else if (lowerCleaned.startsWith('bitcoin:')) {
                        cleaned = cleaned.substring(8);
                      } else if (lowerCleaned.startsWith('lnurl:')) {
                        cleaned = cleaned.substring(6);
                      }
                      
                      // Remover parâmetros de query string se houver
                      if (cleaned.contains('?')) {
                        cleaned = cleaned.split('?')[0];
                      }
                      
                      broLog('📷 Código após limpeza: $cleaned');
                      
                      // BOLT11 Invoice - aceitar qualquer coisa que comece com ln
                      if (cleaned.toLowerCase().startsWith('lnbc') || 
                          cleaned.toLowerCase().startsWith('lntb') ||
                          cleaned.toLowerCase().startsWith('lnurl')) {
                        scannedCode = cleaned;
                        broLog('✅ Invoice detectada: $scannedCode');
                        Navigator.pop(ctx);
                        return;
                      }
                      
                      // Lightning Address (user@domain.com)
                      if (cleaned.contains('@') && cleaned.contains('.')) {
                        // Limpar e validar
                        final cleanedAddress = LnAddressService.cleanAddress(cleaned);
                        if (LnAddressService.isLightningAddress(cleanedAddress)) {
                          scannedCode = cleanedAddress;
                          broLog('✅ LN Address detectado: $scannedCode');
                          Navigator.pop(ctx);
                          return;
                        }
                      }
                      
                      // Se não reconheceu, mas tem conteúdo, aceitar mesmo assim
                      // O usuário pode ter escaneado algo que o app não conhece
                      if (cleaned.length > 10) {
                        scannedCode = cleaned;
                        broLog('⚠️ Código não reconhecido, aceitando: $scannedCode');
                        Navigator.pop(ctx);
                        return;
                      }
                    }
                  }
                },
              ),
            ),
            
            // Dica
            Container(
              padding: const EdgeInsets.all(20),
              color: const Color(0xFF1A1A1A),
              child: Column(
                children: [
                  const Icon(Icons.lightbulb_outline, color: Colors.amber, size: 24),
                  const SizedBox(height: 8),
                  Text(
                    l.t('order_scan_instruction'),
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    
    return scannedCode;
  }

  Widget _buildWithdrawOptionCard({
    required IconData icon,
    required String title,
    required String description,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.deepPurple.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: Colors.deepPurple),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                  Text(
                    description,
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _buildStepItem(int step, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: Colors.deepPurple,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(
                '$step',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    if (_isLoading) {
      return Scaffold(
        backgroundColor: const Color(0xFF121212),
        appBar: AppBar(
          title: Text(l.t('order_status_title')),
          backgroundColor: const Color(0xFF1A1A1A),
          foregroundColor: Colors.orange,
        ),
        body: const Center(child: CircularProgressIndicator(color: Color(0xFFFF6B6B))),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: const Color(0xFF121212),
        appBar: AppBar(
          title: Text(l.t('error')),
          backgroundColor: const Color(0xFF1A1A1A),
          foregroundColor: Colors.orange,
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                child: Text(l.t('back')),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: Text(_currentStatus == 'pending' ? l.t('order_status_pending_title') : l.t('order_status_title')),
        backgroundColor: const Color(0xFF1A1A1A),
        foregroundColor: Colors.orange,
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadOrderDetails,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildStatusCard(),
                const SizedBox(height: 10),
                _buildOrderDetailsCard(),
                const SizedBox(height: 10),
                if (_currentStatus == 'awaiting_confirmation') ...[
                  _buildReceiptCard(),
                  const SizedBox(height: 10),
                ],
                _buildTimelineCard(),
                const SizedBox(height: 10),
                _buildInfoCard(),
                const SizedBox(height: 16),
                if (_currentStatus == 'pending') ...[
                  // Ordem aguardando um Bro aceitar - só mostra botão cancelar
                  _buildCancelButton(),
                ],
                // Botão cancelar para confirmed e payment_received (aguardando Bro aceitar)
                if (_currentStatus == 'confirmed' || _currentStatus == 'payment_received') ...[
                  _buildCancelButton(),
                ],
                if (_currentStatus == 'awaiting_confirmation') ...[
                  _buildConfirmPaymentButton(),
                  const SizedBox(height: 10),
                  _buildDisputeButton(),
                ],
                // Botão de disputa também disponível para status 'accepted' (provedor aceitou mas não enviou comprovante)
                if (_currentStatus == 'accepted') ...[
                const SizedBox(height: 16),
                _buildDisputeButton(),
              ],
              // Status de disputa
              if (_currentStatus == 'disputed') ...[
                const SizedBox(height: 16),
                _buildDisputedCard(),
              ],
              // Card de resolução de disputa (para completed/cancelled/disputed com resolução)
              if (_disputeResolution != null) ...[
                const SizedBox(height: 16),
                _buildDisputeResolutionCard(),
              ],
              // v337: Botão de pagamento pós-resolução de disputa a favor do provedor
              if (_disputePaymentPending) ...[
                const SizedBox(height: 10),
                _buildDisputePaymentButton(),
              ],
              // Botão de saque para ordens canceladas
              if (_currentStatus == 'cancelled') ...[
                const SizedBox(height: 16),
                _buildWithdrawSatsButton(),
              ],
              // Espaço extra para navegação do sistema
              const SizedBox(height: 24),
            ],
          ),
        ),
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    final l = AppLocalizations.of(context)!;
    final statusInfo = _getStatusInfo(l);
    
    return Card(
      color: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: (statusInfo['color'] as Color).withOpacity(0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (statusInfo['color'] as Color).withOpacity(0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(
                statusInfo['icon'],
                size: 32,
                color: statusInfo['color'],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              statusInfo['title'],
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: statusInfo['color'],
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              statusInfo['subtitle'],
              style: const TextStyle(
                fontSize: 16,
                color: Colors.white70,
              ),
              textAlign: TextAlign.center,
            ),
            // Mostrar data de criação da ordem (importante para rastreamento)
            if (_orderDetails != null && _orderDetails!['createdAt'] != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.calendar_today, color: Colors.white, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      l.tp('order_created_at', {'date': _formatCreatedAt(_orderDetails!['createdAt'], l)}),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            // Mostrar ID da ordem (visível para usuário e Bro)
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.tag, color: Colors.white70, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    'ID: ${widget.orderId.substring(0, 8)}...',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w500,
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(width: 4),
                  GestureDetector(
                    onTap: () async {
                      await Clipboard.setData(ClipboardData(text: widget.orderId));
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(l.t('order_id_copied')), duration: const Duration(seconds: 1)),
                        );
                      }
                    },
                    child: const Icon(Icons.copy, color: Colors.white54, size: 14),
                  ),
                ],
              ),
            ),
            // Mostrar expiração SOMENTE quando estiver aguardando confirmação do usuário
            if (_currentStatus == 'awaiting_confirmation' && _expiresAt != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.timer, color: Colors.orange, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Confirme em: ${_orderService.formatTimeRemaining(_orderService.getTimeRemaining(_expiresAt!))}',
                      style: const TextStyle(
                        color: Colors.orange,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
  
  String _formatCreatedAt(dynamic createdAt, AppLocalizations l) {
    try {
      DateTime date;
      if (createdAt is DateTime) {
        date = createdAt;
      } else if (createdAt is String) {
        date = DateTime.parse(createdAt);
      } else {
        return l.t('order_unknown_date');
      }
      
      final now = DateTime.now();
      final diff = now.difference(date);
      
      if (diff.inMinutes < 1) {
        return l.t('order_now');
      } else if (diff.inMinutes < 60) {
        return l.tp('order_minutes_ago', {'min': diff.inMinutes.toString()});
      } else if (diff.inHours < 24) {
        return l.tp('order_hours_ago', {'hours': diff.inHours.toString()});
      } else {
        return '${date.day}/${date.month}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
      }
    } catch (e) {
      return l.t('order_unknown_date');
    }
  }

  Map<String, dynamic> _getStatusInfo(AppLocalizations l) {
    switch (_currentStatus) {
      case 'pending':
      case 'payment_received':
      case 'confirmed':
        return {
          'icon': Icons.hourglass_empty,
          'title': l.t('order_status_pending_title'),
          'subtitle': l.t('order_status_pending_subtitle'),
          'color': Colors.orange,
        };
      case 'accepted':
        return {
          'icon': Icons.check_circle_outline,
          'title': l.t('order_status_accepted_title'),
          'subtitle': l.t('order_status_accepted_subtitle'),
          'color': Colors.green,
        };
      case 'awaiting_confirmation':
      case 'payment_submitted':
        return {
          'icon': Icons.payment,
          'title': l.t('order_status_paid_title'),
          'subtitle': l.t('order_status_paid_subtitle'),
          'color': const Color(0xFFFF6B6B),
        };
      case 'completed':
        if (_disputeResolution != null) {
          return {
            'icon': Icons.gavel,
            'title': l.t('order_resolved_mediation'),
            'subtitle': _disputeResolution!['resolution'] == 'resolved_provider'
                ? l.t('order_mediator_decided_provider')
                : l.t('order_mediator_decided_completed'),
            'color': Colors.green,
          };
        }
        return {
          'icon': Icons.celebration,
          'title': l.t('order_completed_title'),
          'subtitle': l.t('order_completed_subtitle'),
          'color': Colors.green,
        };
      case 'liquidated':
        return {
          'icon': Icons.auto_fix_high,
          'title': l.t('order_liquidated_title'),
          'subtitle': l.t('order_liquidated_subtitle'),
          'color': Colors.purple,
        };
      case 'cancelled':
        if (_disputeResolution != null) {
          return {
            'icon': Icons.gavel,
            'title': l.t('order_resolved_mediation'),
            'subtitle': _disputeResolution!['resolution'] == 'resolved_user'
                ? l.t('order_mediator_decided_user_refund')
                : l.t('order_mediator_decided_cancelled'),
            'color': Colors.orange,
          };
        }
        return {
          'icon': Icons.cancel_outlined,
          'title': l.t('order_cancelled_title'),
          'subtitle': l.t('order_cancelled_subtitle'),
          'color': Colors.red,
        };
      case 'disputed':
        // v233: Se há resolução, mostrar como resolvida
        if (_disputeResolution != null) {
          final isUserFavor = _disputeResolution!['resolution'] == 'resolved_user';
          return {
            'icon': Icons.gavel,
            'title': l.t('order_resolved_mediation'),
            'subtitle': isUserFavor
                ? l.t('order_mediator_decided_user')
                : l.t('order_mediator_decided_provider'),
            'color': isUserFavor ? Colors.green : Colors.orange,
          };
        }
        return {
          'icon': Icons.gavel,
          'title': l.t('order_disputed_title'),
          'subtitle': l.t('order_disputed_subtitle'),
          'color': Colors.orange,
        };
      case 'completing':
        return {
          'icon': Icons.hourglass_top,
          'title': l.t('order_processing_title'),
          'subtitle': l.t('order_processing_subtitle'),
          'color': Colors.orange,
        };
      default:
        return {
          'icon': Icons.help_outline,
          'title': l.t('order_unknown_status'),
          'subtitle': _currentStatus,
          'color': Colors.grey,
        };
    }
  }

  Widget _buildOrderDetailsCard() {
    final l = AppLocalizations.of(context)!;
    return Card(
      color: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.orange.withOpacity(0.2)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.t('order_details_title'),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.orange,
              ),
            ),
            Divider(height: 20, color: Colors.grey.withOpacity(0.2)),
            _buildDetailRow(l.t('order_detail_id'), widget.orderId.substring(0, 8)),
            const SizedBox(height: 12),
            _buildDetailRow(l.t('order_detail_value'), 'R\$ ${widget.amountBrl.toStringAsFixed(2)}'),
            const SizedBox(height: 12),
            _buildDetailRow(l.t('order_detail_bitcoin'), '${widget.amountSats} sats'),
            const SizedBox(height: 12),
            _buildDetailRow(
              l.t('order_detail_payment_type'),
              _orderDetails?['billType'] == 'pix' ? 'PIX' : 'Boleto',
            ),
            if (_orderDetails?['provider_id'] != null) ...[
              const SizedBox(height: 12),
              _buildDetailRow(
                l.t('order_detail_provider'),
                _orderDetails!['provider_id'].substring(0, 8),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 13,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.w500,
            fontSize: 13,
            color: Colors.white,
          ),
        ),
      ],
    );
  }

  Widget _buildTimelineCard() {
    final l = AppLocalizations.of(context)!;
    return Card(
      color: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.orange.withOpacity(0.2)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.t('order_next_steps'),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.orange,
              ),
            ),
            Divider(height: 20, color: Colors.grey.withOpacity(0.2)),
            _buildTimelineStep(
              number: '1',
              title: l.t('order_step_created'),
              subtitle: l.t('order_step_created_sub'),
              isActive: false,
              isCompleted: true,
            ),
            _buildTimelineStep(
              number: '2',
              title: l.t('order_step_awaiting'),
              subtitle: l.t('order_step_awaiting_sub'),
              isActive: _currentStatus == 'pending' || _currentStatus == 'confirmed' || _currentStatus == 'payment_received',
              isCompleted: ['accepted', 'awaiting_confirmation', 'payment_submitted', 'completed'].contains(_currentStatus),
            ),
            _buildTimelineStep(
              number: '3',
              title: l.t('order_step_bro_pays'),
              subtitle: l.t('order_step_bro_pays_sub'),
              isActive: _currentStatus == 'accepted',
              isCompleted: ['awaiting_confirmation', 'payment_submitted', 'completed'].contains(_currentStatus),
            ),
            _buildTimelineStep(
              number: '4',
              title: l.t('order_step_completed'),
              subtitle: l.t('order_step_completed_sub'),
              isActive: _currentStatus == 'awaiting_confirmation' || _currentStatus == 'payment_submitted',
              isCompleted: _currentStatus == 'completed',
              isLast: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimelineStep({
    required String number,
    required String title,
    required String subtitle,
    required bool isActive,
    required bool isCompleted,
    bool isLast = false,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: isCompleted
                    ? Colors.green
                    : isActive
                        ? Colors.orange
                        : const Color(0xFF333333),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: isCompleted
                    ? const Icon(Icons.check, color: Colors.white, size: 14)
                    : Text(
                        number,
                        style: TextStyle(
                          color: isActive ? Colors.white : Colors.white60,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
              ),
            ),
            if (!isLast)
              Container(
                width: 2,
                height: 28,
                color: isCompleted ? Colors.green : const Color(0xFF333333),
              ),
          ],
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                  fontSize: 13,
                  color: isActive ? Colors.orange : Colors.white70,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.white54,
                ),
              ),
              if (!isLast) const SizedBox(height: 10),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInfoCard() {
    final l = AppLocalizations.of(context)!;
    return Card(
      color: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.blue.withOpacity(0.2)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline, color: Colors.blue[300], size: 18),
                const SizedBox(width: 8),
                Text(
                  l.t('order_info_title'),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.blue[300],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildInfoItem('⏰', l.t('order_info_36h')),
            const SizedBox(height: 12),
            _buildInfoItem('🔒', l.t('order_info_escrow')),
            const SizedBox(height: 12),
            _buildInfoItem('📱', l.t('order_info_notifications')),
            const SizedBox(height: 12),
            _buildInfoItem('🚫', l.t('order_info_can_cancel')),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoItem(String emoji, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(emoji, style: const TextStyle(fontSize: 14)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 12,
              color: Colors.white60,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildReceiptCard() {
    final l = AppLocalizations.of(context)!;
    // Tentar pegar metadata da ordem
    Map<String, dynamic>? metadata;
    
    if (_orderDetails != null && _orderDetails!['metadata'] != null) {
      metadata = _orderDetails!['metadata'] as Map<String, dynamic>;
    }
    
    // SEMPRE tentar buscar do OrderProvider também (não só em testMode)
    // porque o metadata pode ter sido atualizado após sincronização do Nostr
    if (metadata == null || metadata.isEmpty) {
      final orderProvider = context.read<OrderProvider>();
      final order = orderProvider.getOrderById(widget.orderId);
      if (order?.metadata != null) {
        metadata = order!.metadata;
        broLog('🔍 Metadata carregado do OrderProvider');
      }
    }

    broLog('🔍 _buildReceiptCard - metadata keys: ${metadata?.keys.toList()}');
    broLog('   proofImage existe: ${metadata?['proofImage'] != null}');
    broLog('   paymentProof existe: ${metadata?['paymentProof'] != null}');
    if (metadata?['proofImage'] != null) {
      final pi = metadata!['proofImage'] as String;
      broLog('   proofImage length: ${pi.length}');
      broLog('   proofImage preview: ${pi.substring(0, pi.length > 50 ? 50 : pi.length)}');
    }
    if (metadata?['paymentProof'] != null) {
      final pp = metadata!['paymentProof'] as String;
      broLog('   paymentProof length: ${pp.length}');
      broLog('   paymentProof preview: ${pp.substring(0, pp.length > 50 ? 50 : pp.length)}');
    }

    // Compatibilidade com TODOS os formatos de comprovante
    // Antigo: receipt_url, confirmation_code, receipt_submitted_at
    // Novo (via Nostr): proofImage, proofReceivedAt
    // Bro: paymentProof (usado pelo provider_order_detail_screen)
    String? receiptUrl = metadata?['receipt_url'] as String? 
        ?? metadata?['proofImage'] as String?
        ?? metadata?['paymentProof'] as String?;
    
    // Filtrar marcador de criptografia — não é uma imagem válida
    if (receiptUrl != null && receiptUrl.startsWith('[encrypted:')) {
      receiptUrl = null;
    }
    
    // Tentar re-descriptografar on-demand se temos dados NIP-44
    if (receiptUrl == null && metadata?['proofImage_nip44'] != null) {
      try {
        final orderProvider = Provider.of<OrderProvider>(context, listen: false);
        final privateKey = orderProvider.nostrPrivateKey;
        final senderPubkey = metadata?['proofImage_senderPubkey'] as String?;
        if (privateKey != null && senderPubkey != null) {
          final nip44 = Nip44Service();
          receiptUrl = nip44.decryptBetween(
            metadata!['proofImage_nip44'] as String,
            privateKey,
            senderPubkey,
          );
          broLog('🔓 proofImage re-descriptografado on-demand na UI');
        }
      } catch (e) {
        broLog('⚠️ Falha ao re-descriptografar proofImage na UI: $e');
      }
    }
    
    final confirmationCode = metadata?['confirmation_code'] as String?;
    final submittedAt = metadata?['receipt_submitted_at'] as String? ?? metadata?['proofReceivedAt'] as String?;

    return Card(
      color: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.orange.withOpacity(0.2)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.receipt_long, color: Colors.orange, size: 18),
                const SizedBox(width: 8),
                Text(
                  l.t('order_bro_proof'),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.orange,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            
            if (confirmationCode != null && confirmationCode.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.confirmation_number, color: Colors.orange, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          l.t('order_confirmation_code'),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      confirmationCode,
                      style: const TextStyle(
                        fontSize: 16,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        color: Colors.orange,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],

            if (receiptUrl != null && receiptUrl.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.image, color: Colors.blue[700]),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        l.t('order_proof_image_attached'),
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _showReceiptImage(receiptUrl!),
                      child: Text(l.t('order_view')),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],

            if (submittedAt != null) ...[
              Row(
                children: [
                  Icon(Icons.access_time, size: 16, color: Colors.grey[600]),
                  const SizedBox(width: 6),
                  Text(
                    l.tp('order_sent_at', {'date': _formatDateTime(submittedAt, l)}),
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ],

            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.green[700], size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l.t('order_verify_proof'),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDateTime(String isoString, AppLocalizations l) {
    try {
      final dt = DateTime.parse(isoString);
      final day = dt.day.toString().padLeft(2, '0');
      final month = dt.month.toString().padLeft(2, '0');
      final year = dt.year;
      final hour = dt.hour.toString().padLeft(2, '0');
      final minute = dt.minute.toString().padLeft(2, '0');
      return '$day/$month/$year ${l.t('order_date_at')} $hour:$minute';
    } catch (e) {
      return isoString;
    }
  }

  /// Exibe o Comprovante do Bro em tela cheia
  void _showReceiptImage(String imageUrl) {
    final l = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Imagem centralizada com zoom
            InteractiveViewer(
              panEnabled: true,
              minScale: 0.5,
              maxScale: 4.0,
              child: Center(
                child: _buildReceiptImageWidget(imageUrl),
              ),
            ),
            // Botão fechar
            Positioned(
              top: 40,
              right: 16,
              child: IconButton(
                icon: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Icon(Icons.close, color: Colors.white, size: 28),
                ),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            // Instruções
            Positioned(
              bottom: 40,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    l.t('order_pinch_to_zoom'),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReceiptImageWidget(String imageUrl) {
    final l = AppLocalizations.of(context)!;
    broLog('🖼️ _buildReceiptImageWidget chamado');
    broLog('   imageUrl length: ${imageUrl.length}');
    broLog('   imageUrl starts with: ${imageUrl.substring(0, imageUrl.length > 20 ? 20 : imageUrl.length)}');
    
    // Verificar se é base64 (vindo do Nostr proofImage)
    if (imageUrl.startsWith('data:image')) {
      // Data URI format: data:image/png;base64,xxxxx
      broLog('   Formato: data:image URI');
      try {
        final base64String = imageUrl.split(',').last;
        final bytes = base64Decode(base64String);
        return Image.memory(
          bytes,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => _buildImageError(l.tp('order_error_decode_base64', {'error': error.toString()})),
        );
      } catch (e) {
        return _buildImageError(l.tp('order_error_process_base64', {'error': e.toString()}));
      }
    } else if (_isBase64Image(imageUrl)) {
      // Base64 puro (sem prefixo data:) - pode ser JPEG (/9j/), PNG (iVBOR), etc
      broLog('   Formato: base64 puro detectado');
      try {
        final bytes = base64Decode(imageUrl);
        broLog('   Bytes decodificados: ${bytes.length}');
        return Image.memory(
          bytes,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => _buildImageError(l.tp('order_error_decode', {'error': error.toString()})),
        );
      } catch (e) {
        broLog('   Erro ao decodificar base64: $e');
        return _buildImageError(l.tp('order_error_process_image', {'error': e.toString()}));
      }
    } else if (imageUrl.startsWith('http://') || imageUrl.startsWith('https://')) {
      // URL HTTP/HTTPS
      return Image.network(
        imageUrl,
        fit: BoxFit.contain,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return Center(
            child: CircularProgressIndicator(
              value: loadingProgress.expectedTotalBytes != null
                  ? loadingProgress.cumulativeBytesLoaded / loadingProgress.expectedTotalBytes!
                  : null,
              color: const Color(0xFFFF6B6B),
            ),
          );
        },
        errorBuilder: (context, error, stackTrace) => _buildImageError(error.toString()),
      );
    } else {
      // Caminho local - carregar como arquivo
      final file = File(imageUrl);
      if (file.existsSync()) {
        return Image.file(
          file,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => _buildImageError(l.tp('order_error_load_file', {'error': error.toString()})),
        );
      } else {
        return _buildImageError(l.tp('order_error_file_not_found', {'path': imageUrl}));
      }
    }
  }

  /// Verifica se uma string parece ser base64 de imagem
  bool _isBase64Image(String str) {
    if (str.length < 100) return false;
    
    // Prefixos comuns de imagens em base64:
    // JPEG: /9j/
    // PNG: iVBOR
    // GIF: R0lGOD
    // WebP: UklGR
    final base64Prefixes = ['/9j/', 'iVBOR', 'R0lGOD', 'UklGR'];
    
    for (final prefix in base64Prefixes) {
      if (str.startsWith(prefix)) {
        return true;
      }
    }
    
    // Se tem mais de 1000 chars e é só caracteres base64 válidos, provavelmente é base64
    if (str.length > 1000) {
      final base64Regex = RegExp(r'^[A-Za-z0-9+/=]+$');
      // Testar só os primeiros 100 chars para performance
      return base64Regex.hasMatch(str.substring(0, 100));
    }
    
    return false;
  }

  Widget _buildImageError(String error) {
    final l = AppLocalizations.of(context)!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.broken_image, color: Colors.white54, size: 64),
        const SizedBox(height: 16),
        Text(
          l.t('order_error_load_receipt'),
          style: const TextStyle(color: Colors.white54, fontSize: 16),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            error,
            style: const TextStyle(color: Colors.white30, fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  /// Abre disputa para a ordem atual
  void _showDisputeDialog() {
    final l = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.gavel, color: Color(0xFFFF6B6B)),
            const SizedBox(width: 12),
            Text(l.t('order_open_dispute'), style: const TextStyle(color: Colors.white)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0x1AFF6B35),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.t('order_what_is_dispute'),
                      style: TextStyle(
                        color: Color(0xFFFF6B6B),
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      l.t('order_dispute_explanation'),
                      style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 13, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                l.t('order_dispute_common_reasons'),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
              ),
              const SizedBox(height: 8),
              _buildDisputeReason('💸', l.t('order_dispute_not_received')),
              _buildDisputeReason('📄', l.t('order_dispute_invalid_proof')),
              _buildDisputeReason('💰', l.t('order_dispute_wrong_amount')),
              _buildDisputeReason('🚫', l.t('order_dispute_no_proof')),
              _buildDisputeReason('❓', l.t('order_dispute_other_reason')),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0x1AFFC107),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0x33FFC107)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber, color: Color(0xFFFFC107), size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l.t('order_dispute_escrow_held'),
                        style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.t('cancel'), style: const TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _openDisputeForm();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF6B6B),
            ),
            child: Text(l.t('order_dispute_continue'), style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildDisputeReason(String emoji, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 16)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  void _openDisputeForm() {
    final l = AppLocalizations.of(context)!;
    final TextEditingController reasonController = TextEditingController();
    String? selectedReason;
    File? _evidencePhoto; // v236: foto de evidência
    String? _evidenceBase64; // v236: base64 da foto

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + MediaQuery.of(context).viewPadding.bottom + 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[600],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  l.t('order_dispute_form_title'),
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  l.tp('order_order_id_short', {'id': widget.orderId.substring(0, 8)}),
                  style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 14),
                ),
                const SizedBox(height: 20),
                Text(
                  l.t('order_dispute_reason_label'),
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                ...<String>[
                  l.t('order_dispute_opt_not_received'),
                  l.t('order_dispute_opt_invalid'),
                  l.t('order_dispute_opt_wrong_amount'),
                  l.t('order_dispute_opt_no_response'),
                  l.t('order_dispute_opt_other'),
                ].map((reason) => RadioListTile<String>(
                  title: Text(reason, style: const TextStyle(color: Colors.white)),
                  value: reason,
                  groupValue: selectedReason,
                  activeColor: const Color(0xFFFF6B6B),
                  onChanged: (value) {
                    setModalState(() => selectedReason = value);
                  },
                )),
                const SizedBox(height: 16),
                Text(
                  l.t('order_dispute_describe_label'),
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: reasonController,
                  maxLines: 4,
                  style: const TextStyle(color: Colors.white),
                  onChanged: (value) {
                    // Reconstruir o botão quando o texto mudar
                    setModalState(() {});
                  },
                  decoration: InputDecoration(
                    hintText: l.t('order_dispute_description_hint'),
                    hintStyle: const TextStyle(color: Color(0x66FFFFFF)),
                    filled: true,
                    fillColor: const Color(0x0DFFFFFF),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0x33FFFFFF)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0x33FFFFFF)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Color(0xFFFF6B6B)),
                    ),
                  ),
                ),
                // v236: Instruções de evidência
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.blue.withOpacity(0.2)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l.t('order_dispute_tips_title'),
                        style: const TextStyle(color: Colors.blue, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l.t('order_dispute_tip_check'),
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l.t('order_dispute_tip_registrato'),
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        l.t('order_dispute_tip_evidence'),
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  l.t('order_dispute_evidence_photo'),
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  l.t('order_dispute_evidence_hint'),
                  style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 12),
                ),
                const SizedBox(height: 8),
                if (_evidencePhoto != null) ...[                  
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(
                      children: [
                        Image.file(
                          _evidencePhoto!,
                          height: 150,
                          width: double.infinity,
                          fit: BoxFit.cover,
                        ),
                        Positioned(
                          top: 4,
                          right: 4,
                          child: GestureDetector(
                            onTap: () {
                              setModalState(() {
                                _evidencePhoto = null;
                                _evidenceBase64 = null;
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: const BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.close, color: Colors.white, size: 18),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ] else
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final picker = ImagePicker();
                            final picked = await picker.pickImage(
                              source: ImageSource.gallery,
                              maxWidth: 600,
                              maxHeight: 600,
                              imageQuality: 50,
                            );
                            if (picked != null) {
                              final file = File(picked.path);
                              final bytes = await file.readAsBytes();
                              setModalState(() {
                                _evidencePhoto = file;
                                _evidenceBase64 = base64Encode(bytes);
                              });
                            }
                          },
                          icon: const Icon(Icons.photo_library, size: 18),
                          label: Text(l.t('order_gallery')),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.orange,
                            side: const BorderSide(color: Colors.orange),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final picker = ImagePicker();
                            final picked = await picker.pickImage(
                              source: ImageSource.camera,
                              maxWidth: 600,
                              maxHeight: 600,
                              imageQuality: 50,
                            );
                            if (picked != null) {
                              final file = File(picked.path);
                              final bytes = await file.readAsBytes();
                              setModalState(() {
                                _evidencePhoto = file;
                                _evidenceBase64 = base64Encode(bytes);
                              });
                            }
                          },
                          icon: const Icon(Icons.camera_alt, size: 18),
                          label: Text(l.t('order_camera')),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.orange,
                            side: const BorderSide(color: Colors.orange),
                          ),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: selectedReason != null && reasonController.text.trim().isNotEmpty
                        ? () {
                            Navigator.pop(context);
                            _submitDispute(selectedReason!, reasonController.text.trim(), userEvidence: _evidenceBase64);
                          }
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF6B6B),
                      disabledBackgroundColor: Colors.grey[700],
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: Text(
                      l.t('order_submit_dispute'),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submitDispute(String reason, String description, {String? userEvidence}) async {
    final l = AppLocalizations.of(context)!;
    // Mostrar loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        content: Row(
          children: [
            const CircularProgressIndicator(color: Color(0xFFFF6B6B)),
            const SizedBox(width: 16),
            Text(l.t('order_sending_dispute'), style: const TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );

    try {
      // Criar disputa usando o serviço
      final disputeService = DisputeService();
      await disputeService.initialize();
      
      // Preparar detalhes da ordem para o suporte
      // v253: Incluir provider_id para que a disputa seja descoberta pelo provedor
      final existingOrder = context.read<OrderProvider>().getOrderById(widget.orderId);
      final orderDetails = {
        'amount_brl': widget.amountBrl,
        'amount_sats': widget.amountSats,
        'status': _currentStatus,
        'payment_type': _orderDetails?['payment_type'],
        'pix_key': _orderDetails?['pix_key'],
        'provider_id': existingOrder?.providerId ?? _orderDetails?['providerId'],
      };
      
      // Criar a disputa
      await disputeService.createDispute(
        orderId: widget.orderId,
        openedBy: 'user',
        reason: reason,
        description: description,
        orderDetails: orderDetails,
      );

      if (mounted) {
        Navigator.pop(context); // Fechar loading IMEDIATAMENTE
        
        // Atualizar status local para "em disputa"
        final orderProvider = context.read<OrderProvider>();
        await orderProvider.updateOrderStatus(orderId: widget.orderId, status: 'disputed');
        
        // Atualizar UI ANTES de publicar no Nostr (que é lento)
        setState(() {
          _currentStatus = 'disputed';
          _disputeReason = reason;
          _disputeDescription = description;
          _disputeCreatedAt = DateTime.now();
          _userEvidence = userEvidence;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.t('order_dispute_opened_success')),
            backgroundColor: const Color(0xFFFF6B6B),
            duration: const Duration(seconds: 4),
          ),
        );
        
        // Publicar notificação de disputa no Nostr (fire-and-forget)
        // Não bloqueia a UI — o admin será notificado em segundo plano
        try {
          final nostrOrderService = NostrOrderService();
          final privateKey = orderProvider.nostrPrivateKey;
          if (privateKey != null) {
            nostrOrderService.publishDisputeNotification(
              privateKey: privateKey,
              orderId: widget.orderId,
              reason: reason,
              description: description,
              openedBy: 'user',
              orderDetails: orderDetails,
              userEvidence: userEvidence,
            ).then((_) {
              broLog('📤 Disputa publicada no Nostr com sucesso');
            }).catchError((e) {
              broLog('⚠️ Erro ao publicar disputa no Nostr: $e');
            });
          }
        } catch (e) {
          broLog('⚠️ Erro ao publicar disputa no Nostr: $e');
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Fechar loading
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.tp('order_dispute_open_error', {'error': e.toString()})),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildDisputeButton() {
    final l = AppLocalizations.of(context)!;
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _showDisputeDialog,
        icon: const Icon(Icons.gavel),
        label: Text(l.t('order_open_dispute')),
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFFFF6B6B),
          side: const BorderSide(color: Color(0xFFFF6B6B)),
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
  }

  Widget _buildTalkToBroButton() {
    final l = AppLocalizations.of(context)!;
    final providerId = _orderDetails?['provider_id'] ?? '';
    final broName = providerId.isNotEmpty && providerId.length >= 8 ? providerId.substring(0, 8) : (providerId.isNotEmpty ? providerId : 'Bro');
    
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: () {
          if (providerId.isNotEmpty) {
            Navigator.pushNamed(
              context,
              '/nostr-messages',
              arguments: {'contactPubkey': providerId},
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(l.t('order_bro_id_unavailable')),
                backgroundColor: Colors.orange,
              ),
            );
          }
        },
        icon: const Icon(Icons.chat),
        label: Text(l.tp('order_chat_with_bro', {'name': broName})),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF9C27B0),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
  }

  Widget _buildPayButton() {
    final l = AppLocalizations.of(context)!;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _showPaymentMethodsSheet,
        icon: const Icon(Icons.currency_bitcoin),
        label: Text(l.t('order_pay_with_bitcoin')),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFFF6B6B),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
  }

  /// Mostra o bottom sheet com opções de pagamento (Lightning ou On-Chain)
  void _showPaymentMethodsSheet() {
    final l = AppLocalizations.of(context)!;
    broLog('🔵 _showPaymentMethodsSheet chamado');
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Indicador de arraste
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.grey[600],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Text(
                l.t('order_choose_payment'),
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'R\$ ${widget.amountBrl.toStringAsFixed(2)} ≈ ${widget.amountSats} sats',
                style: const TextStyle(
                  fontSize: 16,
                  color: Color(0x99FFFFFF),
                ),
              ),
              const SizedBox(height: 24),
              
              // Lightning Network (Recomendado)
              Card(
                color: const Color(0xFF2A2A2A),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: ListTile(
                  onTap: () {
                    Navigator.pop(context);
                    _createLightningInvoiceAndShow();
                  },
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  leading: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF6B6B),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.bolt, color: Colors.white, size: 24),
                  ),
                  title: Row(
                    children: [
                      const Flexible(
                        child: Text(
                          'Lightning',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.green,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          l.t('order_fast_badge'),
                          style: TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  subtitle: Text(
                    l.t('order_lightning_subtitle'),
                    style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 12),
                  ),
                  trailing: const Icon(Icons.arrow_forward_ios, color: Colors.white, size: 16),
                ),
              ),
              
              const SizedBox(height: 12),
              
              // Bitcoin On-Chain
              Card(
                color: const Color(0xFF2A2A2A),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: ListTile(
                  onTap: () {
                    Navigator.pop(context);
                    _showOnChainPaymentDialog();
                  },
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  leading: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF7931A),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.currency_bitcoin, color: Colors.white, size: 24),
                  ),
                  title: const Text(
                    'Bitcoin On-Chain',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  subtitle: Text(
                    l.t('order_onchain_subtitle'),
                    style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 12),
                  ),
                  trailing: const Icon(Icons.arrow_forward_ios, color: Colors.white, size: 16),
                ),
              ),
              
              const SizedBox(height: 20),
              
              // Botão cancelar
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  l.t('cancel'),
                  style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 16),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// Cria o invoice Lightning e mostra o dialog com QR Code
  Future<void> _createLightningInvoiceAndShow() async {
    final l = AppLocalizations.of(context)!;
    broLog('🔵 _createLightningInvoiceAndShow chamado');
    
    // Mostrar loading com feedback progressivo
    final stopwatch = Stopwatch()..start();
    final statusNotifier = ValueNotifier<String>('Conectando ao Spark...');
    Timer? feedbackTimer;
    
    feedbackTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      final elapsed = stopwatch.elapsed.inSeconds;
      if (elapsed >= 30) {
        statusNotifier.value = l.tp('order_trying_liquid', {'elapsed': elapsed.toString()});
      } else if (elapsed >= 15) {
        statusNotifier.value = l.tp('order_waiting_response', {'elapsed': elapsed.toString()});
      } else {
        statusNotifier.value = l.tp('order_connecting_spark', {'elapsed': elapsed.toString()});
      }
    });
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        content: ValueListenableBuilder<String>(
          valueListenable: statusNotifier,
          builder: (context, status, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Color(0xFFFF6B6B)),
              const SizedBox(height: 16),
              Text(
                l.t('order_generating_invoice'),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 8),
              Text(
                status,
                style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );

    // Usar LightningProvider com fallback automático Spark -> Liquid
    final lightningProvider = context.read<LightningProvider>();
    final breezProvider = context.read<BreezProvider>();
    
    try {
      broLog('🔵 Criando Lightning invoice para ${widget.amountSats} sats (com fallback)...');
      
      // LightningProvider tenta Spark primeiro, depois Liquid se Spark falhar
      final invoiceData = await lightningProvider.createInvoice(
        amountSats: widget.amountSats,
        description: 'Bro ${widget.orderId}',
      ).timeout(
        const Duration(seconds: 45), // Timeout maior para fallback
        onTimeout: () {
          broLog('⏰ Timeout ao criar invoice Lightning');
          return {'success': false, 'error': 'Timeout ao criar invoice'};
        },
      );

      // Fechar loading e limpar timer
      feedbackTimer?.cancel();
      stopwatch.stop();
      if (mounted) Navigator.pop(context);

      broLog('🔵 Invoice data recebido: $invoiceData');
      
      // Verificar se usou Liquid (para log)
      final isLiquid = invoiceData?['isLiquid'] == true;
      if (isLiquid) {
        final fees = invoiceData?['fees'] ?? 0;
        broLog('💧 Invoice criada via LIQUID (fallback). Taxas: $fees sats');
      }
      
      if (invoiceData != null && invoiceData['success'] == true) {
        final invoice = invoiceData['invoice'] as String;
        final paymentHash = invoiceData['paymentHash'] as String? ?? '';
        broLog('🔵 Invoice criada: ${invoice.substring(0, 50)}...');
        
        if (mounted) {
          _showLightningPaymentDialog(invoice, paymentHash, isLiquid: isLiquid);
        }
      } else {
        broLog('❌ Falha ao criar invoice: ${invoiceData?['error']}');
        _showError(l.tp('order_error_create_invoice', {'error': invoiceData?['error']?.toString() ?? 'Unknown'}));
      }
    } catch (e) {
      // Fechar loading e limpar timer
      feedbackTimer?.cancel();
      stopwatch.stop();
      if (mounted) Navigator.pop(context);
      broLog('❌ Erro ao criar invoice: $e');
      _showError(l.tp('order_error_create_invoice', {'error': e.toString()}));
    }
  }

  Future<void> _handlePayWithBitcoin() async {
    _showPaymentMethodsSheet();
  }

  void _showPaymentOptions(String invoice, String paymentHash) {
    // Método legado - redireciona para o novo fluxo
    _showLightningPaymentDialog(invoice, paymentHash, isLiquid: false);
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  void _showLightningPaymentDialog(String invoice, String paymentHash, {bool isLiquid = false}) {
    final l = AppLocalizations.of(context)!;
    // Registrar callback para pagamento recebido
    final breezProvider = context.read<BreezProvider>();
    breezProvider.onPaymentReceived = (paymentId, amountSats, pHash) {
      broLog('🎉 Callback de pagamento recebido! ID: $paymentId, Amount: $amountSats, Hash: $pHash');
      _onPaymentReceived();
    };
    
    // Se usando Liquid, registrar callback no LiquidProvider também
    if (isLiquid) {
      final lightningProvider = context.read<LightningProvider>();
      lightningProvider.liquidProvider.onPaymentReceived = (paymentId, amountSats, pHash) {
        broLog('🎉 Callback de pagamento Liquid recebido! ID: $paymentId, Amount: $amountSats');
        _onPaymentReceived();
      };
    }
    
    // Iniciar monitoramento de pagamento (backup via polling)
    _startPaymentMonitoring(paymentHash);
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.bolt, color: Color(0xFFFF6B6B), size: 28),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.t('order_pay_lightning'),
                  style: const TextStyle(color: Colors.white, fontSize: 18),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 300,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Status de aguardando
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.orange.withAlpha(40),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFFFF6B6B),
                          ),
                        ),
                      const SizedBox(width: 8),
                        Text(
                          l.t('order_waiting_payment'),
                          style: const TextStyle(color: Colors.orange, fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // QR Code - tamanho fixo para evitar LayoutBuilder error
                  Container(
                    width: 200,
                    height: 200,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: QrImageView(
                      data: invoice,
                      version: QrVersions.auto,
                      size: 180,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'R\$ ${widget.amountBrl.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    '${widget.amountSats} sats',
                    style: const TextStyle(
                      fontSize: 14,
                      color: Color(0x99FFFFFF),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Invoice (copiável)
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A2A2A),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            invoice.length > 40 
                                ? '${invoice.substring(0, 40)}...' 
                                : invoice,
                            style: const TextStyle(
                              color: Color(0x99FFFFFF),
                              fontSize: 11,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.copy, color: Color(0xFFFF6B6B), size: 20),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: invoice));
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(l.t('order_invoice_copied')),
                                backgroundColor: Colors.green,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l.t('order_qr_scan_instruction'),
                    style: const TextStyle(
                      color: Color(0x99FFFFFF),
                      fontSize: 13,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                _stopPaymentMonitoring();
                Navigator.pop(context);
              },
              child: Text(l.t('cancel'), style: const TextStyle(color: Colors.grey)),
            ),
          ],
        ),
      ),
    );
  }

  Timer? _paymentCheckTimer;
  
  void _startPaymentMonitoring(String paymentHash) {
    broLog('🔍 Iniciando monitoramento de pagamento: $paymentHash');
    
    _paymentCheckTimer?.cancel();
    _paymentCheckTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      try {
        final breezProvider = context.read<BreezProvider>();
        final status = await breezProvider.checkPaymentStatus(paymentHash);
        
        broLog('📊 Status do pagamento: $status');
        
        if (status != null && status['paid'] == true) {
          timer.cancel();
          _onPaymentReceived();
        }
      } catch (e) {
        broLog('❌ Erro ao verificar pagamento: $e');
      }
    });
  }
  
  void _stopPaymentMonitoring() {
    _paymentCheckTimer?.cancel();
    _paymentCheckTimer = null;
    
    // Limpar callback do BreezProvider
    try {
      final breezProvider = context.read<BreezProvider>();
      breezProvider.onPaymentReceived = null;
    } catch (e) {
      // Context pode não estar mais disponível
    }
  }
  
  void _onPaymentReceived() {
    final l = AppLocalizations.of(context)!;
    broLog('✅ PAGAMENTO RECEBIDO!');
    
    // Fechar dialog atual
    if (mounted) Navigator.of(context).pop();
    
    // IMPORTANTE: Atualizar status no OrderProvider para persistir
    final orderProvider = context.read<OrderProvider>();
    orderProvider.updateOrderStatus(
      orderId: widget.orderId,
      status: 'payment_received',
    ).then((_) {
      broLog('💾 Status da ordem ${widget.orderId} atualizado para payment_received');
    });
    
    // Mostrar dialog de sucesso
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.green.withAlpha(40),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_circle, color: Colors.green, size: 60),
            ),
            const SizedBox(height: 20),
            Text(
              l.t('order_payment_received'),
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'R\$ ${widget.amountBrl.toStringAsFixed(2)}',
              style: const TextStyle(
                fontSize: 18,
                color: Color(0xFFFF6B6B),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              l.t('order_payment_received_desc'),
              style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ],
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                // Atualizar status local também
                setState(() {
                  _currentStatus = 'payment_received';
                });
                // Já estamos na tela de detalhes, só recarregar
                _loadOrderDetails();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: Text(l.t('order_ok'), style: const TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }

  void _showOnChainPaymentDialog() async {
    final l = AppLocalizations.of(context)!;
    // Mostrar loading enquanto obtém o endereço
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: Color(0xFFFF6B6B)),
            const SizedBox(width: 16),
            Text(l.t('order_generating_address'), style: const TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );

    try {
      final breezProvider = context.read<BreezProvider>();
      final addressData = await breezProvider.createOnchainAddress();
      
      if (!mounted) return;
      Navigator.pop(context); // Fechar loading
      
      if (addressData != null && addressData['success'] == true) {
        final address = addressData['address'] as String;
        
        // Calcular valor em BTC (aproximado baseado nos sats)
        final btcAmount = widget.amountSats / 100000000;
        
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text(
              l.t('order_pay_bitcoin_title'),
              style: const TextStyle(color: Colors.white),
            ),
            content: SizedBox(
              width: 300,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // QR Code com endereço bitcoin: URI
                    Container(
                      width: 220,
                      height: 220,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: QrImageView(
                        data: 'bitcoin:$address?amount=$btcAmount',
                        version: QrVersions.auto,
                        size: 196,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'R\$ ${widget.amountBrl.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      '${widget.amountSats} sats ≈ ${btcAmount.toStringAsFixed(8)} BTC',
                      style: const TextStyle(
                        fontSize: 14,
                        color: Color(0x99FFFFFF),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // Endereço (copiável)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2A2A2A),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              address.length > 30
                                  ? '${address.substring(0, 15)}...${address.substring(address.length - 15)}'
                                  : address,
                              style: const TextStyle(
                                color: Color(0x99FFFFFF),
                                fontSize: 12,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy, color: Colors.white, size: 20),
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: address));
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(l.t('order_address_copied'))),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.orange.withOpacity(0.5)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.info_outline, color: Colors.orange, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              l.t('order_onchain_time_warning'),
                              style: const TextStyle(
                                color: Colors.orange,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(l.t('close')),
              ),
            ],
          ),
        );
      } else {
        _showError(l.t('order_address_gen_error'));
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Fechar loading
        _showError(l.tp('order_error_address', {'error': e.toString()}));
      }
    }
  }

  // REMOVIDO: _buildVerifyPaymentButton - não deve existir no fluxo Bro
  // O usuário não paga a ordem, ele RESERVA garantia. O Bro é quem paga a conta.

  Widget _buildCancelButton() {
    final l = AppLocalizations.of(context)!;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _handleCancelOrder,
        icon: const Icon(Icons.cancel),
        label: Text(l.t('order_cancel_order')),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.red,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
  }

  Widget _buildWithdrawSatsButton() {
    final l = AppLocalizations.of(context)!;
    return Column(
      children: [
        // Info card
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.blue.withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.blue.withOpacity(0.3)),
          ),
          child: Row(
            children: [
              const Icon(Icons.info_outline, color: Colors.blue, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l.tp('order_sats_in_wallet', {'sats': widget.amountSats.toString()}),
                  style: const TextStyle(
                    color: Colors.blue,
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Botão de saque
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () => _showWithdrawInstructions(),
            icon: const Icon(Icons.send),
            label: Text(l.t('order_withdraw_sats')),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
        ),
        const SizedBox(height: 16),
        // Histórico de saques desta ordem
        _buildWithdrawalHistory(),
      ],
    );
  }
  
  Widget _buildWithdrawalHistory() {
    final l = AppLocalizations.of(context)!;
    return FutureBuilder<List<Withdrawal>>(
      future: WithdrawalService().getWithdrawalsByOrder(
        orderId: widget.orderId,
        userPubkey: widget.userId ?? 'anonymous',
      ),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox.shrink();
        }
        
        final withdrawals = snapshot.data ?? [];
        if (withdrawals.isEmpty) {
          return const SizedBox.shrink();
        }
        
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.t('order_withdrawal_history'),
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            ...withdrawals.map((w) => _buildWithdrawalItem(w)).toList(),
          ],
        );
      },
    );
  }
  
  Widget _buildWithdrawalItem(Withdrawal withdrawal) {
    final l = AppLocalizations.of(context)!;
    final isSuccess = withdrawal.status == 'success';
    final statusColor = isSuccess ? Colors.green : Colors.red;
    final statusIcon = isSuccess ? Icons.check_circle : Icons.error;
    
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: statusColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: statusColor.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(statusIcon, color: statusColor, size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.tp('order_withdrawal_item', {'amount': withdrawal.amountSats.toString(), 'status': withdrawal.statusText}),
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l.tp('order_withdrawal_destination', {'dest': withdrawal.destinationShort}),
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 12,
                  ),
                ),
                Text(
                  _formatDateTime(withdrawal.createdAt.toIso8601String(), l),
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 11,
                  ),
                ),
                if (withdrawal.error != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    l.tp('order_withdrawal_error', {'error': withdrawal.error!}),
                    style: const TextStyle(
                      color: Colors.red,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConfirmPaymentButton() {
    final l = AppLocalizations.of(context)!;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _isConfirming ? null : _handleConfirmPayment,
        icon: _isConfirming 
            ? const SizedBox(
                width: 20, 
                height: 20, 
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)
              )
            : const Icon(Icons.check_circle),
        label: Text(_isConfirming ? l.t('order_processing') : l.t('order_confirm_payment_received')),
        style: ElevatedButton.styleFrom(
          backgroundColor: _isConfirming ? Colors.grey : Colors.green,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
  }

  bool _isConfirming = false; // Prevenir duplo clique
  
  Future<void> _handleConfirmPayment() async {
    if (_isConfirming) return;
    final l = AppLocalizations.of(context)!; // Prevenir duplo clique
    
    // Confirmar com o usuário
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.t('order_confirm_payment_title')),
        content: Text(
          l.t('order_confirm_payment_content'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.t('cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
            ),
            child: Text(l.t('confirm')),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    // FEEDBACK IMEDIATO: Mostrar loading e atualizar status visual
    setState(() {
      _isConfirming = true;
      _currentStatus = 'completing'; // Estado transitório visual
    });
    
    // Mostrar snackbar de feedback imediato
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Text(l.t('order_processing_confirmation')),
          ],
        ),
        backgroundColor: const Color(0xFFFF6B6B),
        duration: Duration(seconds: 10),
      ),
    );

    try {
      final orderProvider = context.read<OrderProvider>();
      
      // Buscar informações completas da ordem PRIMEIRO
      Map<String, dynamic>? orderDetails = _orderDetails;
      
      // Tentar obter do OrderProvider local primeiro
      var order = orderProvider.getOrderById(widget.orderId);
      if (order != null) {
        orderDetails = order.toJson();
      }
      
      // Verificar se já temos providerId localmente
      String? providerId = orderDetails?['providerId'] as String?;
      providerId ??= orderDetails?['provider_id'] as String?;
      providerId ??= order?.providerId;
      
      // Só fazer sync se NÃO temos providerId (sync com timeout de 10s para iOS)
      if (providerId == null || providerId.isEmpty) {
        broLog('🔄 Sincronizando ordem antes de confirmar (providerId não encontrado localmente)...');
        try {
          await orderProvider.syncOrdersFromNostr().timeout(
            const Duration(seconds: 10),  // iOS precisa de mais tempo
            onTimeout: () {
              broLog('⏱️ Timeout no sync (10s) - continuando com dados locais');
            },
          );
          // Recarregar ordem após sync
          order = orderProvider.getOrderById(widget.orderId);
          if (order != null) {
            orderDetails = order.toJson();
            providerId = order.providerId;
          }
        } catch (e) {
          broLog('⚠️ Erro no sync: $e - continuando com dados locais');
        }
      } else {
        broLog('✅ providerId já disponível localmente: ${providerId.substring(0, 16)}');
      }
      
      // Atualizar providerId de múltiplas fontes se ainda não temos
      if (providerId == null || providerId.isEmpty) {
        providerId = orderDetails?['provider_id'] as String?;
      }
      if (providerId == null || providerId.isEmpty) {
        providerId = order?.metadata?['providerId'] as String?;
        providerId ??= order?.metadata?['provider_id'] as String?;
      }
      
      // FALLBACK CRÍTICO: Se ainda não temos providerId, buscar diretamente do Nostr
      // Isso acontece quando o provedor aceitou mas o sync local não atualizou
      if (providerId == null || providerId.isEmpty) {
        broLog('🔍 providerId ainda é null, buscando diretamente do Nostr...');
        final nostrService = NostrOrderService();
        final nostrOrder = await nostrService.fetchOrderFromNostr(widget.orderId);
        if (nostrOrder != null) {
          providerId = nostrOrder['providerId'] as String?;
          providerId ??= nostrOrder['provider_id'] as String?;
          broLog('   Nostr retornou providerId: ${providerId?.substring(0, 16) ?? "NULL"}');
        }
      }
      
      broLog('📤 Confirmando ordem ${widget.orderId.substring(0, 8)}');
      broLog('   providerId: ${providerId?.substring(0, 16) ?? "NULL - PROBLEMA!"}');
      
      if (providerId == null || providerId.isEmpty) {
        broLog('⚠️ AVISO: providerId é null - o Bro pode não receber a notificação!');
        // NOVO: Mostrar aviso ao usuário mas continuar
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l.t('order_notification_warning')),
              backgroundColor: const Color(0xFFFF6B6B),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }

      // ========== ETAPA 1: PAGAR INVOICE DO PROVEDOR ANTES DE MARCAR COMPLETED ==========
      // CRÍTICO: Pagamento DEVE ocorrer ANTES de marcar como completed
      // Se o pagamento falhar, a ordem permanece em awaiting_confirmation
      String? providerInvoice;
      if (orderDetails != null) {
        providerInvoice = orderDetails['metadata']?['providerInvoice'] as String?;
        providerInvoice ??= orderDetails['providerInvoice'] as String?;
      }
      if (providerInvoice == null && order != null) {
        providerInvoice = order.metadata?['providerInvoice'] as String?;
      }
      
      // FALLBACK: Se não encontrou invoice no cache local, buscar do evento COMPLETE no Nostr
      if (providerInvoice == null || providerInvoice.isEmpty) {
        broLog('🔍 providerInvoice não encontrado no cache, buscando evento COMPLETE no Nostr...');
        try {
          final nostrService = NostrOrderService();
          final completeData = await nostrService.fetchOrderCompleteEvent(widget.orderId);
          if (completeData != null) {
            providerInvoice = completeData['providerInvoice'] as String?;
            if (providerInvoice != null && providerInvoice.isNotEmpty) {
              broLog('✅ Invoice encontrado no evento COMPLETE: ${providerInvoice.substring(0, 30)}...');
            }
          }
        } catch (e) {
          broLog('⚠️ Erro ao buscar invoice do Nostr: $e');
        }
      }
      
      // Se não tem invoice, BLOQUEAR a confirmação
      if (providerInvoice == null || providerInvoice.isEmpty) {
        broLog('🚨 BLOQUEANDO confirmação: Nenhum providerInvoice encontrado!');
        if (mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l.t('order_provider_invoice_not_found')),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 5),
            ),
          );
          setState(() {
            _isConfirming = false;
            _currentStatus = 'awaiting_confirmation';
          });
        }
        return;
      }
      
      // PAGAR O PROVEDOR
      broLog('⚡ Pagando invoice do provedor: ${providerInvoice.substring(0, 30)}...');
      bool paymentSuccess = false;
      String paymentError = '';
      
      try {
        final breezProvider = context.read<BreezProvider>();
        final liquidProvider = context.read<BreezLiquidProvider>();
        
        broLog('🔍 DEBUG PAY INVOICE:');
        broLog('   breezProvider.isInitialized: ${breezProvider.isInitialized}');
        broLog('   liquidProvider.isInitialized: ${liquidProvider.isInitialized}');
        
        if (!breezProvider.isInitialized && !liquidProvider.isInitialized) {
          paymentError = l.t('order_wallet_not_initialized');
        } else {
          // Retry: tentar até 3 vezes com intervalo de 2s
          for (int attempt = 1; attempt <= 3; attempt++) {
            try {
              Map<String, dynamic>? payResult;
              String usedBackend = 'none';
              
              if (breezProvider.isInitialized) {
                broLog('⚡ Tentativa $attempt/3: Pagando via Breez Spark...');
                payResult = await breezProvider.payInvoice(providerInvoice).timeout(
                  const Duration(seconds: 30),
                  onTimeout: () => {'success': false, 'error': 'timeout'},
                );
                usedBackend = 'Spark';
              } else if (liquidProvider.isInitialized) {
                broLog('⚡ Tentativa $attempt/3: Pagando via Liquid...');
                payResult = await liquidProvider.payInvoice(providerInvoice).timeout(
                  const Duration(seconds: 30),
                  onTimeout: () => {'success': false, 'error': 'timeout'},
                );
                usedBackend = 'Liquid';
              }
              
              if (payResult != null && payResult['success'] == true) {
                broLog('✅ Invoice do provedor pago com sucesso via $usedBackend na tentativa $attempt!');
                paymentSuccess = true;
                break;
              } else {
                paymentError = payResult?['error']?.toString() ?? l.t('order_unknown_failure');
                // Detectar invoice já pago — tratar como sucesso
                if (paymentError.toLowerCase().contains('already paid') ||
                    paymentError.toLowerCase().contains('already settled') ||
                    paymentError.toLowerCase().contains('invoice already') ||
                    paymentError.toLowerCase().contains('duplicate payment')) {
                  broLog('✅ Invoice já foi pago anteriormente — tratando como sucesso');
                  paymentSuccess = true;
                  break;
                }
                broLog('⚠️ Tentativa $attempt falhou: $paymentError');
              }
            } catch (e) {
              paymentError = e.toString();
              // Detectar invoice já pago em exceções
              if (paymentError.toLowerCase().contains('already paid') ||
                  paymentError.toLowerCase().contains('already settled') ||
                  paymentError.toLowerCase().contains('invoice already') ||
                  paymentError.toLowerCase().contains('duplicate payment')) {
                broLog('✅ Invoice já foi pago anteriormente (exception) — tratando como sucesso');
                paymentSuccess = true;
                break;
              }
              broLog('⚠️ Tentativa $attempt erro: $paymentError');
            }
            
            if (attempt < 3) {
              broLog('⏳ Aguardando 2s antes da próxima tentativa...');
              await Future.delayed(const Duration(seconds: 2));
            }
          }
        }
      } catch (e) {
        paymentError = e.toString();
        broLog('⚠️ Erro geral ao pagar invoice: $e');
      }
      
      // Se o pagamento falhou, NÃO marcar como completed
      if (!paymentSuccess) {
        broLog('❌ Pagamento ao provedor FALHOU após 3 tentativas: $paymentError');
        if (mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l.tp('order_payment_failure_detail', {'error': paymentError})),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 8),
            ),
          );
          setState(() {
            _isConfirming = false;
            _currentStatus = 'awaiting_confirmation';
          });
        }
        return; // CRÍTICO: Não finalizar sem pagamento
      }
      
      broLog('✅ Pagamento ao provedor confirmado! Agora marcando ordem como completed...');

      // ========== ETAPA 2: MARCAR COMO COMPLETED ==========
      // CRÍTICO: Salvar localmente PRIMEIRO para evitar desync se Nostr falhar
      // Se o pagamento Lightning já foi feito, a ordem DEVE ser completed localmente
      orderProvider.updateOrderStatusLocalOnly(
        orderId: widget.orderId,
        status: 'completed',
      );

      // Tentar publicar no Nostr (best-effort — pagamento já foi feito)
      final updateSuccess = await orderProvider.updateOrderStatus(
        orderId: widget.orderId,
        status: 'completed',
        providerId: providerId,
      );
      
      if (!updateSuccess) {
        broLog('⚠️ Pagamento feito mas falha ao publicar status no Nostr - tentando novamente...');
        await Future.delayed(const Duration(seconds: 2));
        final retrySuccess = await orderProvider.updateOrderStatus(
          orderId: widget.orderId,
          status: 'completed',
          providerId: providerId,
        );
        if (!retrySuccess) {
          broLog('⚠️ Segunda tentativa de publicar status falhou - pagamento foi feito, status atualizado localmente');
        }
      }
      
      broLog('✅ Ordem marcada como completed com sucesso');
      
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.t('order_payment_sent_to_bro')),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 3),
          ),
        );
      }

      // ========== PAGAR TAXA DA PLATAFORMA ==========
      // NOTA: O ganho do provedor NÃO é registrado aqui - isso acontece no dispositivo do PROVEDOR
      // quando o SDK Breez detecta o pagamento recebido via invoice Lightning
      {
        final platformBalanceProvider = context.read<PlatformBalanceProvider>();
        
        // Calcular taxas usando constantes centralizadas do AppConfig
        final totalSats = widget.amountSats.toDouble();
        
        // Taxa da plataforma: 2% do valor total (manutenção da plataforma)
        // Mínimo de 1 sat para garantir que a taxa sempre seja enviada
        final platformFeeRaw = totalSats * AppConfig.platformFeePercent;
        final platformFeeSats = platformFeeRaw.round() < 1 ? 1 : platformFeeRaw.round();
        final platformFee = platformFeeSats.toDouble();
        
        final orderDescription = 'Ordem ${widget.orderId.substring(0, 8)} - R\$ ${widget.amountBrl.toStringAsFixed(2)}';

        // ========== PAGAR TAXA DA PLATAFORMA VIA LIGHTNING ==========
        // Usar serviço centralizado que já tem fallback Spark/Liquid
        broLog('💼 Preparando envio de taxa da plataforma...');
        broLog('   platformLightningAddress: "${AppConfig.platformLightningAddress}"');
        broLog('   platformFeeSats: $platformFeeSats');
        broLog('   widget.amountSats: ${widget.amountSats}');
        
        if (AppConfig.platformLightningAddress.isNotEmpty && platformFeeSats > 0) {
          broLog('💼 Enviando taxa da plataforma via PlatformFeeService...');
          final feeSuccess = await PlatformFeeService.sendPlatformFee(
            orderId: widget.orderId,
            totalSats: widget.amountSats,
          );
          if (!feeSuccess) {
            broLog('⚠️ Falha ao enviar taxa da plataforma');
          } else {
            broLog('✅ Taxa da plataforma enviada com sucesso!');
          }
        } else {
          broLog('⚠️ Taxa da plataforma não enviada: address=${AppConfig.platformLightningAddress.isNotEmpty}, sats=$platformFeeSats');
        }

        // Registrar taxa da plataforma (para tracking local)
        await platformBalanceProvider.addPlatformFee(
          orderId: widget.orderId,
          amountSats: platformFee,
          orderDescription: orderDescription,
        );

        broLog('💼 Taxa de $platformFee sats registrada para a plataforma');
        broLog('ℹ️ Ganho do provedor será registrado no dispositivo do provedor via SDK Breez');
      }

      if (mounted) {
        // Esconder snackbar de loading
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.t('order_payment_confirmed')),
            backgroundColor: Colors.green,
          ),
        );

        // Atualizar status local
        setState(() {
          _currentStatus = 'completed';
          _isConfirming = false;
        });
      }
    } catch (e) {
      broLog('❌ ERRO na confirmação: $e');
      if (mounted) {
        // CRÍTICO: Reverter status visual para não travar a UI
        setState(() {
          _isConfirming = false;
          _currentStatus = 'awaiting_confirmation';
        });
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.tp('order_confirm_error', {'error': e.toString()})),
            backgroundColor: Colors.red,
          ),
        );
        setState(() {
          _isConfirming = false;
          _currentStatus = 'awaiting_confirmation'; // Reverter para status anterior
        });
      }
    }
  }

  /// v337: Botão para pagar o provedor após resolução de disputa a seu favor
  Widget _buildDisputePaymentButton() {
    final l = AppLocalizations.of(context)!;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _isPayingDisputeResolution ? null : _handleDisputePayment,
        icon: _isPayingDisputeResolution
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.bolt),
        label: Text(_isPayingDisputeResolution
            ? l.t('order_sending_payment')
            : l.t('order_pay_provider_mediation')),
        style: ElevatedButton.styleFrom(
          backgroundColor: _isPayingDisputeResolution ? Colors.grey : const Color(0xFFFF6B6B),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
  }

  /// v337: Paga o provedor após resolução de disputa a favor dele
  /// v338: autoMode=true pula diálogo de confirmação (auto-pay após resolução)
  Future<void> _handleDisputePayment({bool autoMode = false}) async {
    if (_isPayingDisputeResolution) return;
    final l = AppLocalizations.of(context)!;

    // Confirmar com o usuário antes de pagar (skip em autoMode)
    if (!autoMode) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l.t('order_mediation_payment_title')),
          content: Text(
            l.tp('order_mediation_payment_content', {'sats': widget.amountSats.toString()}),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.t('cancel')),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF6B6B)),
              child: Text(l.t('order_mediation_confirm')),
            ),
          ],
        ),
      );

      if (confirm != true || !mounted) return;
    } else {
      broLog('🤖 [AutoPay] Modo automático — pulando confirmação do usuário');
    }

    setState(() => _isPayingDisputeResolution = true);

    try {
      final orderProvider = context.read<OrderProvider>();
      final order = orderProvider.getOrderById(widget.orderId);
      final orderDetails = order?.toJson() ?? _orderDetails;

      // ========== VERIFICAR SE ADMIN JÁ PAGOU (reembolso) ==========
      String? invoiceToPay;
      String paymentTarget = 'provedor';
      
      final nostrService = NostrOrderService();
      
      // Primeiro: verificar se existe invoice de reembolso do admin
      try {
        final adminInvoice = await nostrService.fetchAdminReimbursementInvoice(widget.orderId);
        if (adminInvoice != null && adminInvoice.isNotEmpty) {
          broLog('🧾 [DisputePay] Admin já pagou o provedor — pagando reembolso ao admin');
          invoiceToPay = adminInvoice;
          paymentTarget = 'admin (reembolso)';
        }
      } catch (e) {
        broLog('⚠️ [DisputePay] Erro ao verificar reembolso admin: $e');
      }

      // Se não há reembolso do admin, buscar invoice do provedor normalmente
      if (invoiceToPay == null) {
        if (orderDetails != null) {
          invoiceToPay = orderDetails['metadata']?['providerInvoice'] as String?;
          invoiceToPay ??= orderDetails['providerInvoice'] as String?;
        }
        if (invoiceToPay == null && order != null) {
          invoiceToPay = order.metadata?['providerInvoice'] as String?;
        }

        // Fallback: buscar do evento COMPLETE no Nostr
        if (invoiceToPay == null || invoiceToPay.isEmpty) {
          broLog('🔍 [DisputePay] providerInvoice não encontrado no cache, buscando evento COMPLETE no Nostr...');
          try {
            final completeData = await nostrService.fetchOrderCompleteEvent(widget.orderId);
            if (completeData != null) {
              invoiceToPay = completeData['providerInvoice'] as String?;
              if (invoiceToPay != null && invoiceToPay.isNotEmpty) {
                broLog('✅ [DisputePay] Invoice encontrado no evento COMPLETE');
              }
            }
          } catch (e) {
            broLog('⚠️ [DisputePay] Erro ao buscar invoice do Nostr: $e');
          }
        }
      }

      // Snackbar com texto correto dependendo do alvo
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                const SizedBox(width: 12),
                Text(paymentTarget == 'provedor'
                  ? l.t('order_processing_provider_payment')
                  : l.t('order_processing_admin_refund')),
              ],
            ),
            backgroundColor: const Color(0xFFFF6B6B),
            duration: const Duration(seconds: 15),
          ),
        );
      }

      if (invoiceToPay == null || invoiceToPay.isEmpty) {
        broLog('🚨 [DisputePay] BLOQUEANDO: Nenhum providerInvoice encontrado!');
        if (mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l.t('order_provider_needs_new_invoice')),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 5),
            ),
          );
          setState(() => _isPayingDisputeResolution = false);
        }
        return;
      }

      // ========== PAGAR O INVOICE ==========
      if (!mounted) return;
      broLog('⚡ [DisputePay] Pagando invoice ($paymentTarget): ${invoiceToPay.substring(0, 30)}...');
      bool paymentSuccess = false;
      String paymentError = '';

      final breezProvider = context.read<BreezProvider>();
      final liquidProvider = context.read<BreezLiquidProvider>();

      if (!breezProvider.isInitialized && !liquidProvider.isInitialized) {
        paymentError = l.t('order_wallet_not_initialized');
      } else {
        for (int attempt = 1; attempt <= 3; attempt++) {
          try {
            Map<String, dynamic>? payResult;
            String usedBackend = 'none';

            if (breezProvider.isInitialized) {
              broLog('⚡ [DisputePay] Tentativa $attempt/3: Pagando via Breez Spark...');
              payResult = await breezProvider.payInvoice(invoiceToPay).timeout(
                const Duration(seconds: 30),
                onTimeout: () => {'success': false, 'error': 'timeout'},
              );
              usedBackend = 'Spark';
            } else if (liquidProvider.isInitialized) {
              broLog('⚡ [DisputePay] Tentativa $attempt/3: Pagando via Liquid...');
              payResult = await liquidProvider.payInvoice(invoiceToPay).timeout(
                const Duration(seconds: 30),
                onTimeout: () => {'success': false, 'error': 'timeout'},
              );
              usedBackend = 'Liquid';
            }

            if (payResult != null && payResult['success'] == true) {
              broLog('✅ [DisputePay] Invoice pago com sucesso via $usedBackend na tentativa $attempt!');
              paymentSuccess = true;
              break;
            } else {
              paymentError = payResult?['error']?.toString() ?? l.t('order_unknown_failure');
              broLog('⚠️ [DisputePay] Tentativa $attempt falhou: $paymentError');
            }
          } catch (e) {
            paymentError = e.toString();
            broLog('⚠️ [DisputePay] Tentativa $attempt erro: $paymentError');
          }

          if (attempt < 3) {
            await Future.delayed(const Duration(seconds: 2));
          }
        }
      }

      if (!paymentSuccess) {
        broLog('❌ [DisputePay] Pagamento FALHOU após 3 tentativas: $paymentError');
        if (mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l.tp('order_payment_failed_detail', {'error': paymentError})),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 8),
            ),
          );
          setState(() => _isPayingDisputeResolution = false);
        }
        return;
      }

      broLog('✅ [DisputePay] Pagamento confirmado! Alvo: $paymentTarget');

      // ========== MARCAR COMO PAGO NO METADATA ==========
      if (!mounted) return;
      if (order != null) {
        final updatedMetadata = {
          ...?order.metadata,
          'disputeProviderPaid': true,
          'disputeProviderPaidAt': DateTime.now().toIso8601String(),
        };
        orderProvider.updateOrderMetadataLocal(widget.orderId, updatedMetadata);
      }

      // ========== TAXA DA PLATAFORMA ==========
      final platformBalanceProvider = context.read<PlatformBalanceProvider>();
      final totalSats = widget.amountSats.toDouble();
      final platformFeeRaw = totalSats * AppConfig.platformFeePercent;
      final platformFeeSats = platformFeeRaw.round() < 1 ? 1 : platformFeeRaw.round();
      final orderDescription = 'Ordem ${widget.orderId.substring(0, 8)} - R\$ ${widget.amountBrl.toStringAsFixed(2)}';

      if (AppConfig.platformLightningAddress.isNotEmpty && platformFeeSats > 0) {
        broLog('💼 [DisputePay] Enviando taxa da plataforma...');
        final feeSuccess = await PlatformFeeService.sendPlatformFee(
          orderId: widget.orderId,
          totalSats: widget.amountSats,
        );
        if (!feeSuccess) {
          broLog('⚠️ [DisputePay] Falha ao enviar taxa da plataforma');
        }
      }

      await platformBalanceProvider.addPlatformFee(
        orderId: widget.orderId,
        amountSats: platformFeeSats.toDouble(),
        orderDescription: orderDescription,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(paymentTarget == 'provedor'
              ? l.t('order_payment_to_provider_success')
              : l.t('order_refund_admin_success')),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 4),
          ),
        );
        setState(() {
          _isPayingDisputeResolution = false;
          _disputePaymentPending = false;
        });
      }
    } catch (e) {
      broLog('❌ [DisputePay] ERRO: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.tp('order_error_pay_provider', {'error': e.toString()})),
            backgroundColor: Colors.red,
          ),
        );
        setState(() => _isPayingDisputeResolution = false);
      }
    }
  }

  /// Card mostrando resultado da resolução do mediador
  Widget _buildDisputeResolutionCard() {
    final l = AppLocalizations.of(context)!;
    final resolution = _disputeResolution!;
    final isUserFavor = resolution['resolution'] == 'resolved_user';
    final notes = resolution['notes'] as String? ?? '';
    final resolvedAt = resolution['resolvedAt'] as String? ?? '';
    
    String dateStr = '';
    try {
      final dt = DateTime.parse(resolvedAt);
      dateStr = '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      dateStr = resolvedAt;
    }
    
    return Card(
      color: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: isUserFavor ? Colors.blue.withOpacity(0.3) : Colors.green.withOpacity(0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: (isUserFavor ? Colors.blue : Colors.green).withOpacity(0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.gavel, color: isUserFavor ? Colors.blue : Colors.green, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l.t('order_mediator_decision'),
                        style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.bold,
                          color: isUserFavor ? Colors.blue : Colors.green,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isUserFavor
                            ? l.t('order_resolved_in_your_favor')
                            : _disputePaymentPending
                                ? l.t('order_resolved_provider_pending')
                                : l.t('order_resolved_provider_paid'),
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.t('order_mediator_message'), style: const TextStyle(color: Colors.white54, fontSize: 11)),
                    const SizedBox(height: 6),
                    Text(notes, style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.4)),
                  ],
                ),
              ),
            ],
            if (dateStr.isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: Text('📅 $dateStr', style: const TextStyle(color: Colors.white38, fontSize: 11)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDisputedCard() {
    final l = AppLocalizations.of(context)!;
    // Carregar dados da disputa se não tivermos
    final disputeService = DisputeService();
    final dispute = disputeService.getDisputeByOrderId(widget.orderId);
    final reason = _disputeReason ?? dispute?.reason ?? l.t('order_not_informed');
    final desc = _disputeDescription ?? dispute?.description ?? '';
    final createdAt = _disputeCreatedAt ?? dispute?.createdAt ?? DateTime.now();
    final providerId = _orderDetails?['providerId'] ?? _orderDetails?['provider_id'] ?? '';
    final proofImage = _orderDetails?['metadata']?['proofImage'] as String?;
    final userPubkey = _orderDetails?['userPubkey'] ?? widget.userId ?? '';
    
    final day = createdAt.day.toString().padLeft(2, '0');
    final month = createdAt.month.toString().padLeft(2, '0');
    final year = createdAt.year;
    final hour = createdAt.hour.toString().padLeft(2, '0');
    final minute = createdAt.minute.toString().padLeft(2, '0');
    final dateStr = '$day/$month/$year $hour:$minute';
    
    return Card(
      color: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.orange.withOpacity(0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.gavel, color: Colors.orange, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dispute?.status == 'in_review' ? l.t('order_dispute_in_review') : l.t('order_dispute_open'),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.orange,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        dispute?.status == 'in_review'
                            ? l.t('order_mediator_reviewing')
                            : l.t('order_awaiting_mediator'),
                        style: const TextStyle(fontSize: 14, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // Relatório detalhado da ordem
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF0D0D0D),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.withOpacity(0.2)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.t('order_dispute_report'),
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: Colors.orange,
                    ),
                  ),
                  const SizedBox(height: 12),
                  
                  // ID da Ordem
                  _disputeReportRow(l.t('order_dispute_order_label'), widget.orderId.length > 16 
                      ? '${widget.orderId.substring(0, 16)}...' 
                      : widget.orderId, isMonospace: true),
                  const SizedBox(height: 6),
                  
                  // Data e hora
                  _disputeReportRow(l.t('order_dispute_date_label'), dateStr),
                  const SizedBox(height: 6),
                  
                  // Valor
                  _disputeReportRow(l.t('order_dispute_value_label'), 'R\$ ${widget.amountBrl.toStringAsFixed(2)}'),
                  const SizedBox(height: 6),
                  _disputeReportRow(l.t('order_dispute_sats_label'), '${widget.amountSats}'),
                  const SizedBox(height: 6),
                  
                  // Usuários
                  if (userPubkey.isNotEmpty) ...[
                    _disputeReportRow(l.t('order_dispute_user_label'), '${userPubkey.toString().substring(0, 16)}...', isMonospace: true),
                    const SizedBox(height: 6),
                  ],
                  if (providerId.isNotEmpty) ...[
                    _disputeReportRow(l.t('order_dispute_provider_label'), '${providerId.toString().substring(0, 16)}...', isMonospace: true),
                    const SizedBox(height: 6),
                  ],
                  
                  const Divider(color: Colors.white24, height: 20),
                  
                  // Motivo
                  _disputeReportRow(l.t('order_dispute_motive_label'), reason),
                  const SizedBox(height: 6),
                  
                  // Descrição
                  if (desc.isNotEmpty) ...[
                    Text(l.t('order_dispute_description'), style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    const SizedBox(height: 4),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.black26,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        desc,
                        style: const TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                  
                  // Foto do comprovante (se disponível)
                  if (proofImage != null && proofImage.isNotEmpty) ...[
                    const Divider(color: Colors.white24, height: 20),
                    Text(
                      l.t('order_provider_receipt'),
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: proofImage.startsWith('http')
                          ? Image.network(
                              proofImage,
                              height: 200,
                              width: double.infinity,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                height: 100,
                                color: Colors.black26,
                                child: Center(
                                  child: Text(l.t('order_image_unavailable'), style: const TextStyle(color: Colors.white38)),
                                ),
                              ),
                            )
                          : Container(
                              height: 100,
                              color: Colors.black26,
                              child: Center(
                                child: Text(l.t('order_proof_attached'), style: const TextStyle(color: Colors.white38)),
                              ),
                            ),
                    ),
                  ],
                ],
              ),
            ),
            // v236: Evidência do usuário
            if (_userEvidence != null && _userEvidence!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D0D0D),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.blue.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.t('order_your_evidence_attached'),
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: Colors.blue,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(
                        base64Decode(_userEvidence!),
                        height: 150,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          height: 60,
                          color: Colors.black26,
                          child: Center(
                            child: Text(l.t('order_image_attached'), style: const TextStyle(color: Colors.blue)),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            
            // Tempo estimado
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.access_time, color: Colors.orange, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l.t('order_estimated_time'),
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Colors.white70),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            
            // v237: Mensagens do mediador
            if (_mediatorMessages.isNotEmpty) ...[            
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D0D0D),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.purple.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.message, color: Colors.purple, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          l.tp('order_mediator_messages', {'count': _mediatorMessages.length.toString()}),
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: Colors.purple,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ..._mediatorMessages.map((msg) {
                      final sentAt = msg['sentAt'] as String? ?? '';
                      String dateStr = '';
                      try {
                        final dt = DateTime.parse(sentAt);
                        dateStr = '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
                      } catch (_) {}
                      final message = msg['message'] as String? ?? '';
                      return Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.purple.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.purple.withOpacity(0.15)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.admin_panel_settings, color: Colors.purple, size: 14),
                                const SizedBox(width: 6),
                                Text(l.t('order_mediator'), style: const TextStyle(color: Colors.purple, fontSize: 11, fontWeight: FontWeight.bold)),
                                const Spacer(),
                                if (dateStr.isNotEmpty)
                                  Text(dateStr, style: const TextStyle(color: Colors.white38, fontSize: 10)),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              message,
                              style: const TextStyle(color: Colors.white70, fontSize: 13),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
              // v237: Botão para responder ao mediador
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _showSendEvidenceDialog('user'),
                  icon: const Icon(Icons.reply, size: 18),
                  label: Text(l.t('order_reply_to_mediator')),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.purple,
                    side: const BorderSide(color: Colors.purple),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ] else if (_loadingMediatorMessages) ...[            
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D0D0D),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.purple.withOpacity(0.2)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.purple)),
                    const SizedBox(width: 10),
                    Text(l.t('order_fetching_messages'), style: const TextStyle(color: Colors.white38, fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            
            // v236: Botão para enviar evidência adicional
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => _showSendEvidenceDialog('user'),
                icon: const Icon(Icons.add_photo_alternate, size: 20),
                label: Text(l.t('order_send_evidence')),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.blue,
                  side: const BorderSide(color: Colors.blue),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  Widget _disputeReportRow(String label, String value, {bool isMonospace = false}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontFamily: isMonospace ? 'monospace' : null,
            ),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }

  /// v236: Dialog para enviar evidência adicional na disputa
  void _showSendEvidenceDialog(String role) {
    final l = AppLocalizations.of(context)!;
    final descController = TextEditingController();
    File? evidencePhoto;
    String? evidenceBase64;
    bool sending = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + MediaQuery.of(context).viewPadding.bottom + 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(width: 40, height: 4,
                    decoration: BoxDecoration(color: Colors.grey[600], borderRadius: BorderRadius.circular(2))),
                ),
                const SizedBox(height: 20),
                Text(l.t('order_send_evidence_title'), style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(l.tp('order_order_id_short', {'id': widget.orderId.substring(0, 8)}), style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 14)),
                const SizedBox(height: 16),
                
                // Dicas
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.blue.withOpacity(0.2)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.t('order_accepted_evidence'), style: const TextStyle(color: Colors.blue, fontWeight: FontWeight.bold, fontSize: 13)),
                      const SizedBox(height: 6),
                      Text(l.t('order_evidence_tip_site'), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                      const SizedBox(height: 3),
                      Text(l.t('order_evidence_tip_registrato'), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                      const SizedBox(height: 3),
                      Text(l.t('order_evidence_tip_e2e'), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                      const SizedBox(height: 3),
                      Text(l.t('order_evidence_tip_any'), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                
                // Descrição
                Text(l.t('order_evidence_description'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                TextField(
                  controller: descController,
                  maxLines: 3,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: l.t('order_evidence_description_hint'),
                    hintStyle: const TextStyle(color: Color(0x66FFFFFF)),
                    filled: true, fillColor: const Color(0x0DFFFFFF),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0x33FFFFFF))),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0x33FFFFFF))),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.blue)),
                  ),
                ),
                const SizedBox(height: 16),
                
                // Foto
                Text(l.t('order_evidence_photo'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                if (evidencePhoto != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(
                      children: [
                        Image.file(evidencePhoto!, height: 150, width: double.infinity, fit: BoxFit.cover),
                        Positioned(
                          top: 4, right: 4,
                          child: GestureDetector(
                            onTap: () => setModalState(() { evidencePhoto = null; evidenceBase64 = null; }),
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                              child: const Icon(Icons.close, color: Colors.white, size: 18),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final picker = ImagePicker();
                            // v247: Reduzida resolução para caber nos relays Nostr (limite ~64KB)
                            final picked = await picker.pickImage(source: ImageSource.gallery, maxWidth: 600, maxHeight: 600, imageQuality: 40);
                            if (picked != null) {
                              final file = File(picked.path);
                              final bytes = await file.readAsBytes();
                              setModalState(() { evidencePhoto = file; evidenceBase64 = base64Encode(bytes); });
                            }
                          },
                          icon: const Icon(Icons.photo_library, size: 18),
                          label: Text(l.t('order_gallery')),
                          style: OutlinedButton.styleFrom(foregroundColor: Colors.blue, side: const BorderSide(color: Colors.blue)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final picker = ImagePicker();
                            // v247: Reduzida resolução para caber nos relays Nostr (limite ~64KB)
                            final picked = await picker.pickImage(source: ImageSource.camera, maxWidth: 600, maxHeight: 600, imageQuality: 40);
                            if (picked != null) {
                              final file = File(picked.path);
                              final bytes = await file.readAsBytes();
                              setModalState(() { evidencePhoto = file; evidenceBase64 = base64Encode(bytes); });
                            }
                          },
                          icon: const Icon(Icons.camera_alt, size: 18),
                          label: Text(l.t('order_camera')),
                          style: OutlinedButton.styleFrom(foregroundColor: Colors.blue, side: const BorderSide(color: Colors.blue)),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 20),
                
                // Botão enviar
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: ((evidenceBase64 == null && descController.text.trim().isEmpty) || sending) ? null : () async {
                      setModalState(() => sending = true);
                      try {
                        final orderProvider = context.read<OrderProvider>();
                        final privateKey = orderProvider.nostrPrivateKey;
                        if (privateKey == null) throw Exception('Chave não disponível');
                        
                        final nostrService = NostrOrderService();
                        final success = await nostrService.publishDisputeEvidence(
                          privateKey: privateKey,
                          orderId: widget.orderId,
                          senderRole: role,
                          imageBase64: evidenceBase64,
                          description: descController.text.trim(),
                        );
                        
                        if (mounted) {
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(success ? l.t('order_evidence_sent') : l.t('order_evidence_error')),
                            backgroundColor: success ? Colors.green : Colors.red,
                          ));
                        }
                      } catch (e) {
                        setModalState(() => sending = false);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.tp('order_error_generic', {'error': e.toString()})), backgroundColor: Colors.red));
                        }
                      }
                    },
                    icon: sending
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.send),
                    label: Text(sending ? l.t('order_evidence_sending') : (evidenceBase64 != null ? l.t('order_submit_evidence') : l.t('order_submit_message'))),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      disabledBackgroundColor: Colors.grey[700],
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
