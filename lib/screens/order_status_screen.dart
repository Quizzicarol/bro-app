import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../services/order_service.dart';
import '../services/dispute_service.dart';
import '../services/lnaddress_service.dart';
import '../services/withdrawal_service.dart';
import '../models/withdrawal.dart';
import '../providers/breez_provider_export.dart';
import '../providers/order_provider.dart';
import '../providers/provider_balance_provider.dart';
import '../providers/platform_balance_provider.dart';
import '../config.dart';
import '../services/notification_service.dart';
import 'package:qr_flutter/qr_flutter.dart';
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
  
  Map<String, dynamic>? _orderDetails;
  String _currentStatus = 'pending';
  bool _isLoading = true;
  String? _error;
  DateTime? _expiresAt;

  @override
  void initState() {
    super.initState();
    _loadOrderDetails();
    _startStatusPolling();
  }

  @override
  void dispose() {
    _statusCheckTimer?.cancel();
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
        debugPrint('⚠️ OrderService falhou: $serviceError');
        // Continua para tentar o OrderProvider
      }
      
      // Se não encontrou, tenta buscar pelo OrderProvider (que tem as ordens em memória)
      if (order == null && mounted) {
        debugPrint('⚠️ Ordem não encontrada no OrderService, tentando OrderProvider...');
        try {
          final orderProvider = Provider.of<OrderProvider>(context, listen: false);
          final orderFromProvider = orderProvider.orders.firstWhere(
            (o) => o.id == widget.orderId,
            orElse: () => throw Exception('Ordem não encontrada no OrderProvider'),
          );
          // Converter Order para Map
          order = orderFromProvider.toJson();
          debugPrint('✅ Ordem encontrada no OrderProvider: ${widget.orderId}');
        } catch (providerError) {
          debugPrint('⚠️ OrderProvider também falhou: $providerError');
        }
      }
      
      if (order != null) {
        if (!mounted) return;
        setState(() {
          _orderDetails = order;
          _currentStatus = order!['status'] ?? 'pending';
          // Verificar se expires_at existe antes de parsear
          if (order['expires_at'] != null) {
            _expiresAt = DateTime.parse(order['expires_at']);
          } else {
            // Default: 24 horas a partir de agora
            _expiresAt = DateTime.now().add(const Duration(hours: 24));
          }
          _isLoading = false;
        });
      } else {
        if (!mounted) return;
        setState(() {
          _error = 'Ordem não encontrada';
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('❌ Erro ao carregar ordem: $e');
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
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
        break;
      case 'disputed':
        _notificationService.notifyDisputeOpened(orderId: widget.orderId);
        break;
    }
  }

  void _startStatusPolling() {
    // Verificar status a cada 10 segundos (usando OrderProvider em vez de API)
    _statusCheckTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
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
        debugPrint('⚠️ Erro ao sincronizar Nostr no polling: $e');
      }
      
      if (!mounted) return;
      
      final order = orderProvider.getOrderById(widget.orderId);
      final status = order?.status ?? _currentStatus;
      
      // Atualizar orderDetails com dados mais recentes (incluindo metadata/proofImage)
      if (order != null && mounted) {
        setState(() {
          _orderDetails = order.toJson();
        });
      }
      
      if (status != _currentStatus) {
        // Notificar sobre mudanca de status
        _handleStatusChange(status);
        if (!mounted) return;
        setState(() {
          _currentStatus = status;
        });

        // Se ordem foi aceita ou completada, parar polling
        if (status == 'accepted' || status == 'completed' || status == 'cancelled') {
          timer.cancel();
        }
      }

      // REMOVIDO: Ordens em 'pending' NÃO expiram
      // Só expiram após Bro aceitar e usuário demorar 24h para confirmar
      // A expiração só deve ocorrer no status 'awaiting_confirmation'
      if (!mounted) return;
      if (_currentStatus == 'awaiting_confirmation' && _expiresAt != null && _orderService.isOrderExpired(_expiresAt!)) {
        timer.cancel();
        _showExpiredDialog();
      }
    });
  }

  void _showExpiredDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('⏰ Tempo Esgotado'),
        content: const Text(
          'Nenhum Bro aceitou sua ordem em 24 horas.\n\n'
          'Você pode:\n'
          '• Aguardar mais tempo\n'
          '• Cancelar e criar uma nova ordem\n'
          '• Seus fundos estão seguros no escrow',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Aguardar'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _handleCancelOrder();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('Cancelar Ordem'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleCancelOrder() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancelar Ordem?'),
        content: const Text(
          'Tem certeza que deseja cancelar esta ordem?\n\n'
          'Seus sats permanecerão na sua carteira do app.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Não'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('Sim, Cancelar'),
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
        debugPrint('✅ Ordem ${widget.orderId} cancelada localmente');
      } catch (e) {
        debugPrint('⚠️ Erro ao cancelar ordem local: $e');
      }
      
      // Se não está em modo teste, também tentar notificar backend (com timeout)
      if (!AppConfig.testMode && !success) {
        try {
          success = await _orderService.cancelOrder(
            orderId: widget.orderId,
            userId: widget.userId ?? '',
            reason: 'Cancelado pelo usuário',
          ).timeout(
            const Duration(seconds: 5),
            onTimeout: () {
              debugPrint('⚠️ Timeout ao cancelar no backend, usando cancelamento local');
              return false;
            },
          );
          
          // Se backend falhou mas temos acesso local, cancelar local mesmo assim
          if (!success) {
            final orderProvider = Provider.of<OrderProvider>(context, listen: false);
            await orderProvider.updateOrderStatusLocal(widget.orderId, 'cancelled');
            success = true;
            debugPrint('✅ Ordem ${widget.orderId} cancelada localmente (fallback)');
          }
        } catch (e) {
          debugPrint('⚠️ Erro ao cancelar no backend: $e');
          // Tentar cancelar local como fallback
          try {
            final orderProvider = Provider.of<OrderProvider>(context, listen: false);
            await orderProvider.updateOrderStatusLocal(widget.orderId, 'cancelled');
            success = true;
            debugPrint('✅ Ordem ${widget.orderId} cancelada localmente (fallback)');
          } catch (e2) {
            debugPrint('❌ Erro ao cancelar ordem local (fallback): $e2');
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
          const SnackBar(
            content: Text('✅ Ordem cancelada com sucesso'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('❌ Erro ao cancelar ordem'),
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
                            const Text(
                              'Sacar Sats',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'Saldo na carteira: $realBalance sats',
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
                  const Text(
                    'Valor a sacar (sats)',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: amountController,
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                    keyboardType: TextInputType.number,
                    enabled: !isSending && !isResolvingLnAddress,
                    decoration: InputDecoration(
                      hintText: 'Ex: 1000',
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
                        'MAX ($realBalance)',
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
                  const Text(
                    'Destino (Invoice ou Lightning Address)',
                    style: TextStyle(color: Colors.white70, fontSize: 14),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: destinationController,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                    maxLines: 3,
                    enabled: !isSending && !isResolvingLnAddress,
                    decoration: InputDecoration(
                      hintText: 'lnbc... ou usuario@wallet.com',
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
                          label: const Text('Colar'),
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
                          label: const Text('Escanear'),
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
                          setModalState(() => errorMessage = 'Digite um valor válido');
                          return;
                        }
                        
                        if (amount > realBalance) {
                          setModalState(() => errorMessage = 'Saldo insuficiente! Você tem $realBalance sats na carteira');
                          return;
                        }
                        
                        // Validar destino
                        if (destination.isEmpty) {
                          setModalState(() => errorMessage = 'Cole ou escaneie um destino');
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
                            infoMessage = 'Verificando limites do destino...';
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
                              errorMessage = resolved['error'] ?? 'Erro ao resolver destino';
                            });
                            return;
                          }
                          
                          minSats = resolved['minSats'] as int?;
                          maxSats = resolved['maxSats'] as int?;
                          
                          // Verificar se o valor está nos limites
                          if (minSats != null && amount < minSats!) {
                            setModalState(() {
                              isResolvingLnAddress = false;
                              infoMessage = 'Destino aceita: mín $minSats sats, máx $maxSats sats';
                              errorMessage = 'Valor mínimo do destino: $minSats sats. Seu valor: $amount sats';
                            });
                            return;
                          }
                          
                          if (maxSats != null && amount > maxSats!) {
                            setModalState(() {
                              isResolvingLnAddress = false;
                              infoMessage = 'Destino aceita: mín $minSats sats, máx $maxSats sats';
                              errorMessage = 'Valor máximo do destino: $maxSats sats. Seu valor: $amount sats';
                            });
                            return;
                          }
                          
                          setModalState(() {
                            infoMessage = 'Obtendo invoice para $amount sats...';
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
                              errorMessage = result['error'] ?? 'Erro ao obter invoice';
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
                          setModalState(() => errorMessage = 'Destino inválido. Use invoice (lnbc...), LNURL ou user@wallet.com');
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
                          infoMessage = 'Enviando $amount sats...';
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
                                  content: Text('✅ Saque de $amount sats enviado com sucesso!'),
                                  backgroundColor: Colors.green,
                                ),
                              );
                              // Recarregar a tela para mostrar o saque registrado
                              setState(() {});
                            }
                          } else {
                            final errMsg = result?['error'] ?? 'Falha ao enviar pagamento';
                            
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
                            errorMessage = 'Erro: $e';
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
                            ? 'Resolvendo endereço...' 
                            : (isSending ? 'Enviando...' : 'Enviar Sats'),
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
                      child: const Text(
                        'Criar nova ordem com esses sats',
                        style: TextStyle(color: Colors.white54),
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
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Escanear Destino',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'Invoice Lightning ou Lightning Address',
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
                  debugPrint('📷 QR Scanner detectou ${barcodes.length} códigos');
                  
                  for (final barcode in barcodes) {
                    final code = barcode.rawValue;
                    debugPrint('📷 Código raw: $code');
                    
                    if (code != null && code.isNotEmpty) {
                      String cleaned = code.trim();
                      debugPrint('📷 Código limpo: $cleaned');
                      
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
                      
                      debugPrint('📷 Código após limpeza: $cleaned');
                      
                      // BOLT11 Invoice - aceitar qualquer coisa que comece com ln
                      if (cleaned.toLowerCase().startsWith('lnbc') || 
                          cleaned.toLowerCase().startsWith('lntb') ||
                          cleaned.toLowerCase().startsWith('lnurl')) {
                        scannedCode = cleaned;
                        debugPrint('✅ Invoice detectada: $scannedCode');
                        Navigator.pop(ctx);
                        return;
                      }
                      
                      // Lightning Address (user@domain.com)
                      if (cleaned.contains('@') && cleaned.contains('.')) {
                        // Limpar e validar
                        final cleanedAddress = LnAddressService.cleanAddress(cleaned);
                        if (LnAddressService.isLightningAddress(cleanedAddress)) {
                          scannedCode = cleanedAddress;
                          debugPrint('✅ LN Address detectado: $scannedCode');
                          Navigator.pop(ctx);
                          return;
                        }
                      }
                      
                      // Se não reconheceu, mas tem conteúdo, aceitar mesmo assim
                      // O usuário pode ter escaneado algo que o app não conhece
                      if (cleaned.length > 10) {
                        scannedCode = cleaned;
                        debugPrint('⚠️ Código não reconhecido, aceitando: $scannedCode');
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
              child: const Column(
                children: [
                  Icon(Icons.lightbulb_outline, color: Colors.amber, size: 24),
                  SizedBox(height: 8),
                  Text(
                    'Escaneie uma invoice Lightning (lnbc...) ou Lightning Address (user@wallet.com)',
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
    if (_isLoading) {
      return Scaffold(
        backgroundColor: const Color(0xFF121212),
        appBar: AppBar(
          title: const Text('Status da Ordem'),
          backgroundColor: const Color(0xFF1A1A1A),
          foregroundColor: Colors.orange,
        ),
        body: const Center(child: CircularProgressIndicator(color: Colors.orange)),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: const Color(0xFF121212),
        appBar: AppBar(
          title: const Text('Erro'),
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
                child: const Text('Voltar'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: Text(_currentStatus == 'pending' ? 'Aguardando Bro' : 'Status da Ordem'),
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
    final statusInfo = _getStatusInfo();
    
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
                      'Criada em: ${_formatCreatedAt(_orderDetails!['createdAt'])}',
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
                          const SnackBar(content: Text('ID copiado!'), duration: Duration(seconds: 1)),
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
  
  String _formatCreatedAt(dynamic createdAt) {
    try {
      DateTime date;
      if (createdAt is DateTime) {
        date = createdAt;
      } else if (createdAt is String) {
        date = DateTime.parse(createdAt);
      } else {
        return 'Data desconhecida';
      }
      
      final now = DateTime.now();
      final diff = now.difference(date);
      
      if (diff.inMinutes < 1) {
        return 'agora';
      } else if (diff.inMinutes < 60) {
        return 'há ${diff.inMinutes} min';
      } else if (diff.inHours < 24) {
        return 'há ${diff.inHours}h';
      } else {
        return '${date.day}/${date.month}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
      }
    } catch (e) {
      return 'Data desconhecida';
    }
  }

  Map<String, dynamic> _getStatusInfo() {
    switch (_currentStatus) {
      case 'pending':
      case 'payment_received':
      case 'confirmed':
        return {
          'icon': Icons.hourglass_empty,
          'title': 'Aguardando Bro',
          'subtitle': 'Sua ordem está disponível para Bros',
          'color': Colors.orange,
        };
      case 'accepted':
        return {
          'icon': Icons.check_circle_outline,
          'title': 'Bro Encontrado!',
          'subtitle': 'Um Bro aceitou sua ordem',
          'color': Colors.green,
        };
      case 'awaiting_confirmation':
      case 'payment_submitted':
        return {
          'icon': Icons.payment,
          'title': 'Bro Pagou!',
          'subtitle': 'O Bro já pagou sua conta, confirme o recebimento',
          'color': const Color(0xFFFF6B6B),
        };
      case 'completed':
        return {
          'icon': Icons.celebration,
          'title': 'Concluída!',
          'subtitle': 'Sua conta foi paga com sucesso',
          'color': Colors.green,
        };
      case 'cancelled':
        return {
          'icon': Icons.cancel_outlined,
          'title': 'Cancelada',
          'subtitle': 'Seus sats permanecem na sua carteira',
          'color': Colors.red,
        };
      case 'disputed':
        return {
          'icon': Icons.gavel,
          'title': 'Em Disputa',
          'subtitle': 'Aguardando mediação',
          'color': Colors.orange,
        };
      default:
        return {
          'icon': Icons.help_outline,
          'title': 'Status Desconhecido',
          'subtitle': _currentStatus,
          'color': Colors.grey,
        };
    }
  }

  Widget _buildOrderDetailsCard() {
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
            const Text(
              'Detalhes da Ordem',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.orange,
              ),
            ),
            Divider(height: 20, color: Colors.grey.withOpacity(0.2)),
            _buildDetailRow('ID da Ordem', widget.orderId.substring(0, 8)),
            const SizedBox(height: 12),
            _buildDetailRow('Valor', 'R\$ ${widget.amountBrl.toStringAsFixed(2)}'),
            const SizedBox(height: 12),
            _buildDetailRow('Bitcoin', '${widget.amountSats} sats'),
            const SizedBox(height: 12),
            _buildDetailRow(
              'Tipo de Pagamento',
              _orderDetails?['billType'] == 'pix' ? 'PIX' : 'Boleto',
            ),
            if (_orderDetails?['provider_id'] != null) ...[
              const SizedBox(height: 12),
              _buildDetailRow(
                'Provedor',
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
            const Text(
              'Próximos Passos',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.orange,
              ),
            ),
            Divider(height: 20, color: Colors.grey.withOpacity(0.2)),
            _buildTimelineStep(
              number: '1',
              title: 'Ordem Criada',
              subtitle: 'Sua ordem está pronta',
              isActive: false,
              isCompleted: true,
            ),
            _buildTimelineStep(
              number: '2',
              title: 'Aguardando Bro',
              subtitle: 'Um Bro irá aceitar sua ordem',
              isActive: _currentStatus == 'pending' || _currentStatus == 'confirmed' || _currentStatus == 'payment_received',
              isCompleted: ['accepted', 'awaiting_confirmation', 'payment_submitted', 'completed'].contains(_currentStatus),
            ),
            _buildTimelineStep(
              number: '3',
              title: 'Bro Paga a Conta',
              subtitle: 'O Bro paga sua conta com PIX/Boleto',
              isActive: _currentStatus == 'accepted',
              isCompleted: ['awaiting_confirmation', 'payment_submitted', 'completed'].contains(_currentStatus),
            ),
            _buildTimelineStep(
              number: '4',
              title: 'Concluído',
              subtitle: 'Conta paga com sucesso!',
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
                  'Informações',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.blue[300],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildInfoItem('⏰', 'O Bro tem até 24 horas para aceitar e pagar sua conta'),
            const SizedBox(height: 12),
            _buildInfoItem('🔒', 'Seus Bitcoin estão seguros no escrow até a conclusão'),
            const SizedBox(height: 12),
            _buildInfoItem('📱', 'Você receberá notificações sobre o andamento'),
            const SizedBox(height: 12),
            _buildInfoItem('🚫', 'Você pode cancelar a ordem se nenhum Bro aceitar'),
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
    // Tentar pegar metadata da ordem
    Map<String, dynamic>? metadata;
    
    if (_orderDetails != null && _orderDetails!['metadata'] != null) {
      metadata = _orderDetails!['metadata'] as Map<String, dynamic>;
    } else if (AppConfig.testMode) {
      // Em modo teste, buscar do OrderProvider
      final orderProvider = context.read<OrderProvider>();
      final order = orderProvider.getOrderById(widget.orderId);
      metadata = order?.metadata;
    }

    debugPrint('🔍 _buildReceiptCard - metadata keys: ${metadata?.keys.toList()}');
    debugPrint('   proofImage existe: ${metadata?['proofImage'] != null}');
    debugPrint('   paymentProof existe: ${metadata?['paymentProof'] != null}');
    if (metadata?['proofImage'] != null) {
      final pi = metadata!['proofImage'] as String;
      debugPrint('   proofImage length: ${pi.length}');
      debugPrint('   proofImage preview: ${pi.substring(0, pi.length > 50 ? 50 : pi.length)}');
    }
    if (metadata?['paymentProof'] != null) {
      final pp = metadata!['paymentProof'] as String;
      debugPrint('   paymentProof length: ${pp.length}');
      debugPrint('   paymentProof preview: ${pp.substring(0, pp.length > 50 ? 50 : pp.length)}');
    }

    // Compatibilidade com TODOS os formatos de comprovante
    // Antigo: receipt_url, confirmation_code, receipt_submitted_at
    // Novo (via Nostr): proofImage, proofReceivedAt
    // Bro: paymentProof (usado pelo provider_order_detail_screen)
    final receiptUrl = metadata?['receipt_url'] as String? 
        ?? metadata?['proofImage'] as String?
        ?? metadata?['paymentProof'] as String?;
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
                const Text(
                  'Comprovante do Bro',
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
                        const Icon(Icons.confirmation_number, color: Colors.orange, size: 20),
                        const SizedBox(width: 8),
                        const Text(
                          'Código de Confirmação:',
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
                    const Expanded(
                      child: Text(
                        'Comprovante em imagem anexado',
                        style: TextStyle(fontSize: 14),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _showReceiptImage(receiptUrl),
                      child: const Text('Ver'),
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
                    'Enviado em: ${_formatDateTime(submittedAt)}',
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
                  const Expanded(
                    child: Text(
                      'Verifique o comprovante e confirme se o pagamento foi recebido corretamente.',
                      style: TextStyle(fontSize: 13),
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

  String _formatDateTime(String isoString) {
    try {
      final dt = DateTime.parse(isoString);
      final day = dt.day.toString().padLeft(2, '0');
      final month = dt.month.toString().padLeft(2, '0');
      final year = dt.year;
      final hour = dt.hour.toString().padLeft(2, '0');
      final minute = dt.minute.toString().padLeft(2, '0');
      return '$day/$month/$year às $hour:$minute';
    } catch (e) {
      return isoString;
    }
  }

  /// Exibe o Comprovante do Bro em tela cheia
  void _showReceiptImage(String imageUrl) {
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
                  child: const Text(
                    'Pinça para zoom • Arraste para mover',
                    style: TextStyle(color: Colors.white, fontSize: 13),
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
    debugPrint('🖼️ _buildReceiptImageWidget chamado');
    debugPrint('   imageUrl length: ${imageUrl.length}');
    debugPrint('   imageUrl starts with: ${imageUrl.substring(0, imageUrl.length > 20 ? 20 : imageUrl.length)}');
    
    // Verificar se é base64 (vindo do Nostr proofImage)
    if (imageUrl.startsWith('data:image')) {
      // Data URI format: data:image/png;base64,xxxxx
      debugPrint('   Formato: data:image URI');
      try {
        final base64String = imageUrl.split(',').last;
        final bytes = base64Decode(base64String);
        return Image.memory(
          bytes,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => _buildImageError('Erro ao decodificar base64: $error'),
        );
      } catch (e) {
        return _buildImageError('Erro ao processar imagem base64: $e');
      }
    } else if (_isBase64Image(imageUrl)) {
      // Base64 puro (sem prefixo data:) - pode ser JPEG (/9j/), PNG (iVBOR), etc
      debugPrint('   Formato: base64 puro detectado');
      try {
        final bytes = base64Decode(imageUrl);
        debugPrint('   Bytes decodificados: ${bytes.length}');
        return Image.memory(
          bytes,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => _buildImageError('Erro ao decodificar: $error'),
        );
      } catch (e) {
        debugPrint('   Erro ao decodificar base64: $e');
        return _buildImageError('Erro ao processar imagem: $e');
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
          errorBuilder: (context, error, stackTrace) => _buildImageError('Erro ao carregar arquivo: $error'),
        );
      } else {
        return _buildImageError('Arquivo não encontrado: $imageUrl');
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.broken_image, color: Colors.white54, size: 64),
        const SizedBox(height: 16),
        const Text(
          'Erro ao carregar comprovante',
          style: TextStyle(color: Colors.white54, fontSize: 16),
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
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.gavel, color: Color(0xFFFF6B6B)),
            SizedBox(width: 12),
            Text('Abrir Disputa', style: TextStyle(color: Colors.white)),
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
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '⚖️ O que é uma disputa?',
                      style: TextStyle(
                        color: Color(0xFFFF6B6B),
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Uma disputa é aberta quando há um desacordo entre você e o provedor sobre o pagamento. '
                      'Um mediador irá analisar as evidências de ambas as partes para resolver o problema.',
                      style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 13, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Motivos comuns para disputa:',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
              ),
              const SizedBox(height: 8),
              _buildDisputeReason('💸', 'Pagamento não recebido pelo provedor'),
              _buildDisputeReason('📄', 'Comprovante inválido ou falsificado'),
              _buildDisputeReason('💰', 'Valor pago diferente do combinado'),
              _buildDisputeReason('🚫', 'Provedor não enviou o comprovante'),
              _buildDisputeReason('❓', 'Outro motivo'),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0x1AFFC107),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0x33FFC107)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning_amber, color: Color(0xFFFFC107), size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Os Bitcoin ficam retidos no escrow até a resolução da disputa.',
                        style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 12),
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
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _openDisputeForm();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF6B6B),
            ),
            child: const Text('Continuar', style: TextStyle(color: Colors.white)),
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
    final TextEditingController reasonController = TextEditingController();
    String? selectedReason;

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
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
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
                const Text(
                  '📋 Formulário de Disputa',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Ordem: ${widget.orderId.substring(0, 8)}...',
                  style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 14),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Motivo da disputa *',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                ...[
                  'Pagamento não recebido',
                  'Comprovante inválido',
                  'Valor incorreto',
                  'Provedor não respondeu',
                  'Outro'
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
                const Text(
                  'Descreva o problema *',
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
                    hintText: 'Explique com detalhes o que aconteceu...',
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
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: selectedReason != null && reasonController.text.trim().isNotEmpty
                        ? () {
                            Navigator.pop(context);
                            _submitDispute(selectedReason!, reasonController.text.trim());
                          }
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF6B6B),
                      disabledBackgroundColor: Colors.grey[700],
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: const Text(
                      'Enviar Disputa',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
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

  Future<void> _submitDispute(String reason, String description) async {
    // Mostrar loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        backgroundColor: Color(0xFF1A1A1A),
        content: Row(
          children: [
            CircularProgressIndicator(color: Color(0xFFFF6B6B)),
            SizedBox(width: 16),
            Text('Enviando disputa...', style: TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );

    try {
      // Criar disputa usando o serviço
      final disputeService = DisputeService();
      await disputeService.initialize();
      
      // Preparar detalhes da ordem para o suporte
      final orderDetails = {
        'amount_brl': widget.amountBrl,
        'amount_sats': widget.amountSats,
        'status': _currentStatus,
        'payment_type': _orderDetails?['payment_type'],
        'pix_key': _orderDetails?['pix_key'],
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
        Navigator.pop(context); // Fechar loading
        
        // Atualizar status local para "em disputa"
        final orderProvider = context.read<OrderProvider>();
        await orderProvider.updateOrderStatus(orderId: widget.orderId, status: 'disputed');
        setState(() {
          _currentStatus = 'disputed';
        });

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⚖️ Disputa aberta com sucesso! O suporte foi notificado e irá analisar o caso.'),
            backgroundColor: Color(0xFFFF6B6B),
            duration: Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Fechar loading
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erro ao abrir disputa: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildDisputeButton() {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _showDisputeDialog,
        icon: const Icon(Icons.gavel),
        label: const Text('Abrir Disputa'),
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFFFF6B6B),
          side: const BorderSide(color: Color(0xFFFF6B6B)),
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
  }

  Widget _buildTalkToBroButton() {
    final providerId = _orderDetails?['provider_id'] ?? '';
    final broName = providerId.isNotEmpty ? providerId.substring(0, 8) : 'Bro';
    
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
              const SnackBar(
                content: Text('ID do Bro não disponível'),
                backgroundColor: Colors.orange,
              ),
            );
          }
        },
        icon: const Icon(Icons.chat),
        label: Text('Falar com $broName'),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF9C27B0),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
  }

  Widget _buildPayButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _showPaymentMethodsSheet,
        icon: const Icon(Icons.currency_bitcoin),
        label: const Text('Pagar com Bitcoin'),
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
    debugPrint('🔵 _showPaymentMethodsSheet chamado');
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
              const Text(
                'Escolha o método de pagamento',
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
                        child: const Text(
                          '⚡ Rápido',
                          style: TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  subtitle: const Text(
                    'Instantâneo • Taxas baixas',
                    style: TextStyle(color: Color(0x99FFFFFF), fontSize: 12),
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
                  subtitle: const Text(
                    '~10 min • Blockchain',
                    style: TextStyle(color: Color(0x99FFFFFF), fontSize: 12),
                  ),
                  trailing: const Icon(Icons.arrow_forward_ios, color: Colors.white, size: 16),
                ),
              ),
              
              const SizedBox(height: 20),
              
              // Botão cancelar
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text(
                  'Cancelar',
                  style: TextStyle(color: Color(0x99FFFFFF), fontSize: 16),
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
    debugPrint('🔵 _createLightningInvoiceAndShow chamado');
    
    // Mostrar loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        backgroundColor: Color(0xFF1E1E1E),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFFFF6B6B)),
            SizedBox(height: 16),
            Text(
              'Gerando Invoice Lightning...',
              style: TextStyle(color: Colors.white),
            ),
          ],
        ),
      ),
    );

    final breezProvider = context.read<BreezProvider>();
    
    try {
      debugPrint('🔵 Criando Lightning invoice para ${widget.amountSats} sats...');
      final invoiceData = await breezProvider.createInvoice(
        amountSats: widget.amountSats,
        description: 'Bro ${widget.orderId}',
      ).timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          debugPrint('⏰ Timeout ao criar invoice Lightning');
          return {'success': false, 'error': 'Timeout ao criar invoice'};
        },
      );

      // Fechar loading
      if (mounted) Navigator.pop(context);

      debugPrint('🔵 Invoice data recebido: $invoiceData');
      
      if (invoiceData != null && invoiceData['success'] == true) {
        final invoice = invoiceData['invoice'] as String;
        final paymentHash = invoiceData['paymentHash'] as String? ?? '';
        debugPrint('🔵 Invoice criada: ${invoice.substring(0, 50)}...');
        
        if (mounted) {
          _showLightningPaymentDialog(invoice, paymentHash);
        }
      } else {
        debugPrint('❌ Falha ao criar invoice: ${invoiceData?['error']}');
        _showError('Erro ao criar invoice: ${invoiceData?['error'] ?? 'Desconhecido'}');
      }
    } catch (e) {
      // Fechar loading
      if (mounted) Navigator.pop(context);
      debugPrint('❌ Erro ao criar invoice: $e');
      _showError('Erro ao criar invoice: $e');
    }
  }

  Future<void> _handlePayWithBitcoin() async {
    _showPaymentMethodsSheet();
  }

  void _showPaymentOptions(String invoice, String paymentHash) {
    // Método legado - redireciona para o novo fluxo
    _showLightningPaymentDialog(invoice, paymentHash);
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  void _showLightningPaymentDialog(String invoice, String paymentHash) {
    // Registrar callback para pagamento recebido
    final breezProvider = context.read<BreezProvider>();
    breezProvider.onPaymentReceived = (paymentId, amountSats, pHash) {
      debugPrint('🎉 Callback de pagamento recebido! ID: $paymentId, Amount: $amountSats, Hash: $pHash');
      _onPaymentReceived();
    };
    
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
              const Expanded(
                child: Text(
                  'Pagar com Lightning',
                  style: TextStyle(color: Colors.white, fontSize: 18),
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
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.orange,
                          ),
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Aguardando pagamento...',
                          style: TextStyle(color: Colors.orange, fontSize: 13, fontWeight: FontWeight.w500),
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
                              const SnackBar(
                                content: Text('✅ Invoice copiado!'),
                                backgroundColor: Colors.green,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Escaneie o QR Code com sua\ncarteira Lightning para pagar',
                    style: TextStyle(
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
              child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
            ),
          ],
        ),
      ),
    );
  }

  Timer? _paymentCheckTimer;
  
  void _startPaymentMonitoring(String paymentHash) {
    debugPrint('🔍 Iniciando monitoramento de pagamento: $paymentHash');
    
    _paymentCheckTimer?.cancel();
    _paymentCheckTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      try {
        final breezProvider = context.read<BreezProvider>();
        final status = await breezProvider.checkPaymentStatus(paymentHash);
        
        debugPrint('📊 Status do pagamento: $status');
        
        if (status != null && status['paid'] == true) {
          timer.cancel();
          _onPaymentReceived();
        }
      } catch (e) {
        debugPrint('❌ Erro ao verificar pagamento: $e');
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
    debugPrint('✅ PAGAMENTO RECEBIDO!');
    
    // Fechar dialog atual
    if (mounted) Navigator.of(context).pop();
    
    // IMPORTANTE: Atualizar status no OrderProvider para persistir
    final orderProvider = context.read<OrderProvider>();
    orderProvider.updateOrderStatus(
      orderId: widget.orderId,
      status: 'payment_received',
    ).then((_) {
      debugPrint('💾 Status da ordem ${widget.orderId} atualizado para payment_received');
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
            const Text(
              'Pagamento Recebido!',
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
            const Text(
              'Seu pagamento via Lightning foi\nconfirmado com sucesso!\n\nAguardando um Bro aceitar sua ordem.',
              style: TextStyle(color: Color(0x99FFFFFF), fontSize: 14),
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
              child: const Text('OK', style: TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }

  void _showOnChainPaymentDialog() async {
    // Mostrar loading enquanto obtém o endereço
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        backgroundColor: Color(0xFF1E1E1E),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFFFF6B6B)),
            SizedBox(width: 16),
            Text('Gerando endereço...', style: TextStyle(color: Colors.white)),
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
            title: const Text(
              'Pagar com Bitcoin',
              style: TextStyle(color: Colors.white),
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
                                const SnackBar(content: Text('Endereço copiado!')),
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
                      child: const Row(
                        children: [
                          Icon(Icons.info_outline, color: Colors.orange, size: 20),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Transações on-chain podem levar ~10-60 minutos para confirmar.',
                              style: TextStyle(
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
                child: const Text('Fechar'),
              ),
            ],
          ),
        );
      } else {
        _showError('Erro ao gerar endereço Bitcoin');
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Fechar loading
        _showError('Erro ao gerar endereço: $e');
      }
    }
  }

  // REMOVIDO: _buildVerifyPaymentButton - não deve existir no fluxo Bro
  // O usuário não paga a ordem, ele RESERVA garantia. O Bro é quem paga a conta.

  Widget _buildCancelButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _handleCancelOrder,
        icon: const Icon(Icons.cancel),
        label: const Text('Cancelar Ordem'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.red,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
  }

  Widget _buildWithdrawSatsButton() {
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
                  'Seus ${widget.amountSats} sats ainda estão na sua carteira. Você pode sacar para outra carteira Lightning.',
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
            label: const Text('Sacar Sats'),
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
            const Text(
              'Histórico de Saques desta Ordem',
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
                  '${withdrawal.amountSats} sats - ${withdrawal.statusText}',
                  style: TextStyle(
                    color: statusColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Destino: ${withdrawal.destinationShort}',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 12,
                  ),
                ),
                Text(
                  _formatDateTime(withdrawal.createdAt.toIso8601String()),
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.5),
                    fontSize: 11,
                  ),
                ),
                if (withdrawal.error != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Erro: ${withdrawal.error}',
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
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _handleConfirmPayment,
        icon: const Icon(Icons.check_circle),
        label: const Text('Confirmar Pagamento Recebido'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.green,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
      ),
    );
  }

  Future<void> _handleConfirmPayment() async {
    // Confirmar com o usuário
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirmar Pagamento'),
        content: const Text(
          'Você confirma que recebeu o pagamento conforme o comprovante enviado pelo provedor?\n\n'
          'Ao confirmar, o valor será liberado para o provedor.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
            ),
            child: const Text('Confirmar'),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    try {
      // Buscar informações completas da ordem
      Map<String, dynamic>? orderDetails = _orderDetails;
      
      if (orderDetails == null) {
        final orderProvider = context.read<OrderProvider>();
        final order = orderProvider.getOrderById(widget.orderId);
        if (order != null) {
          orderDetails = order.toJson();
        }
      }

      // Atualizar status para 'completed' - SEMPRE usar OrderProvider que publica no Nostr
      final orderProvider = context.read<OrderProvider>();
      final updateSuccess = await orderProvider.updateOrderStatus(
        orderId: widget.orderId,
        status: 'completed',
      );
      
      if (!updateSuccess) {
        debugPrint('⚠️ Falha ao atualizar status para completed');
      } else {
        debugPrint('✅ Status atualizado para completed e publicado no Nostr');
      }

      // Adicionar ganho ao saldo do provedor E taxa da plataforma
      if (orderDetails != null) {
        final providerBalanceProvider = context.read<ProviderBalanceProvider>();
        final platformBalanceProvider = context.read<PlatformBalanceProvider>();
        
        // Calcular taxas baseado no valor total em sats
        final totalSats = widget.amountSats.toDouble();
        
        // Taxa do provedor: 5% do valor total
        final providerFee = totalSats * 0.05;
        
        // Taxa da plataforma: 2% do valor total
        final platformFee = totalSats * 0.02;
        
        final orderDescription = 'Ordem ${widget.orderId.substring(0, 8)} - R\$ ${widget.amountBrl.toStringAsFixed(2)}';
        
        // Adicionar ganho do provedor
        await providerBalanceProvider.addEarning(
          orderId: widget.orderId,
          amountSats: providerFee,
          orderDescription: orderDescription,
        );

        // Adicionar taxa da plataforma
        await platformBalanceProvider.addPlatformFee(
          orderId: widget.orderId,
          amountSats: platformFee,
          orderDescription: orderDescription,
        );

        debugPrint('💰 Ganho de $providerFee sats adicionado ao saldo do provedor');
        debugPrint('💼 Taxa de $platformFee sats adicionada ao saldo da plataforma');
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Pagamento confirmado!'),
            backgroundColor: Colors.green,
          ),
        );

        // Atualizar status local
        setState(() {
          _currentStatus = 'completed';
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erro ao confirmar: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildDisputedCard() {
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
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Disputa em Análise',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.orange,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Um mediador está analisando seu caso',
                        style: TextStyle(fontSize: 14, color: Colors.black87),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.orange.withOpacity(0.3)),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '📋 O que acontece agora?',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  SizedBox(height: 8),
                  Text(
                    '1. Um mediador irá revisar todas as evidências\n'
                    '2. Ambas as partes podem ser contactadas para esclarecimentos\n'
                    '3. A decisão será comunicada via notificação\n'
                    '4. Os Bitcoin permanecerão no escrow até resolução',
                    style: TextStyle(fontSize: 13, height: 1.5),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                children: [
                  Icon(Icons.access_time, color: Colors.orange, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Tempo estimado: 24-72 horas',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
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
}
