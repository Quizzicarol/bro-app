import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import '../providers/order_provider.dart';
import '../providers/collateral_provider.dart';
import '../providers/breez_provider_export.dart';
import '../providers/breez_liquid_provider.dart';
import '../providers/lightning_provider.dart';
import '../services/escrow_service.dart';
import '../services/dispute_service.dart';
import '../services/notification_service.dart';
import '../services/nostr_order_service.dart';
import '../config.dart';

/// Tela de detalhes da ordem para o provedor
/// Mostra dados de pagamento (PIX/boleto) e permite aceitar e enviar comprovante
class ProviderOrderDetailScreen extends StatefulWidget {
  final String orderId;
  final String providerId;

  const ProviderOrderDetailScreen({
    super.key,
    required this.orderId,
    required this.providerId,
  });

  @override
  State<ProviderOrderDetailScreen> createState() => _ProviderOrderDetailScreenState();
}

class _ProviderOrderDetailScreenState extends State<ProviderOrderDetailScreen> {
  final EscrowService _escrowService = EscrowService();
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _confirmationCodeController = TextEditingController();
  final TextEditingController _e2eIdController = TextEditingController(); // v236: E2E ID do PIX
  
  Map<String, dynamic>? _orderDetails;
  bool _isLoading = false;
  bool _isAccepting = false;
  bool _isUploading = false;
  String? _error;
  File? _receiptImage;
  bool _orderAccepted = false;
  
  // Dados de resolução de disputa (vindo do mediador)
  Map<String, dynamic>? _disputeResolution;
  
  // v237: Mensagens do mediador para o provedor
  List<Map<String, dynamic>> _providerMediatorMessages = [];
  bool _loadingProviderMediatorMessages = false;
  
  // Timer de 36h para auto-liquidação
  Duration? _timeRemaining;
  DateTime? _receiptSubmittedAt;
  
  // Timer para polling automático de updates de status
  Timer? _statusPollingTimer;

  @override
  void initState() {
    super.initState();
    // Aguardar o frame completo antes de acessar o Provider
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadOrderDetails(forceSync: true);
      _startStatusPolling();
      _fetchResolutionIfNeeded();
      _fetchProviderMediatorMessages();
    });
  }

  @override
  void dispose() {
    _statusPollingTimer?.cancel();
    _confirmationCodeController.dispose();
    _e2eIdController.dispose();
    super.dispose();
  }
  
  /// Busca resolução de disputa do Nostr
  Future<void> _fetchResolutionIfNeeded() async {
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;
    
    try {
      final nostrService = NostrOrderService();
      final resolution = await nostrService.fetchDisputeResolution(widget.orderId);
      if (resolution != null && mounted) {
        setState(() => _disputeResolution = resolution);
        debugPrint('✅ Provider: resolução encontrada para ${widget.orderId.substring(0, 8)}');
      }
    } catch (e) {
      debugPrint('⚠️ Provider: erro ao buscar resolução: $e');
    }
  }
  
  /// v237: Busca mensagens do mediador direcionadas a este provedor para esta ordem
  Future<void> _fetchProviderMediatorMessages() async {
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    
    setState(() => _loadingProviderMediatorMessages = true);
    
    try {
      final orderProvider = context.read<OrderProvider>();
      final providerPubkey = orderProvider.currentUserPubkey;
      if (providerPubkey == null || providerPubkey.isEmpty) {
        if (mounted) setState(() => _loadingProviderMediatorMessages = false);
        return;
      }
      
      final nostrService = NostrOrderService();
      final messages = await nostrService.fetchMediatorMessages(
        providerPubkey,
        orderId: widget.orderId,
      );
      
      if (mounted) {
        setState(() {
          _providerMediatorMessages = messages;
          _loadingProviderMediatorMessages = false;
        });
        if (messages.isNotEmpty) {
          debugPrint('📨 Provider: ${messages.length} mensagens do mediador para ordem ${widget.orderId.substring(0, 8)}');
        }
      }
    } catch (e) {
      debugPrint('⚠️ Provider: erro ao buscar mensagens do mediador: $e');
      if (mounted) setState(() => _loadingProviderMediatorMessages = false);
    }
  }
  
  /// Inicia polling automático para verificar updates de status
  /// Isso permite que o Bro veja quando o usuário confirma o pagamento
  void _startStatusPolling() {
    // Polling a cada 10 segundos quando em awaiting_confirmation
    _statusPollingTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      final currentStatus = _orderDetails?['status'] ?? '';
      
      // Só fazer polling se estiver aguardando confirmação
      if (currentStatus == 'awaiting_confirmation' && mounted) {
        debugPrint('🔄 [POLLING] Verificando status da ordem ${widget.orderId.substring(0, 8)}...');
        await _loadOrderDetails();
        
        // CORREÇÃO v234: Recalcular _timeRemaining a cada tick pra manter o countdown atualizado
        if (_receiptSubmittedAt != null && mounted) {
          final deadline = _receiptSubmittedAt!.add(const Duration(hours: 36));
          setState(() {
            _timeRemaining = deadline.difference(DateTime.now());
          });
        }
        
        // Se mudou para completed ou liquidated, parar o polling
        final newStatus = _orderDetails?['status'] ?? '';
        if (newStatus == 'completed' || newStatus == 'liquidated') {
          debugPrint('🎉 [POLLING] Ordem ${newStatus}! Parando polling.');
          timer.cancel();
          
          // Mostrar notificação ao Bro
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(newStatus == 'completed' 
                    ? '🎉 Pagamento confirmado pelo usuário!' 
                    : '⚡ Ordem liquidada automaticamente!'),
                backgroundColor: Colors.green,
                duration: const Duration(seconds: 5),
              ),
            );
          }
        }
      }
    });
  }

  Future<void> _loadOrderDetails({bool forceSync = false}) async {
    if (!mounted) return;
    
    debugPrint('🔵 [LOAD] _loadOrderDetails INICIADO (forceSync=$forceSync, _orderDetails=${_orderDetails != null ? "set" : "null"})');
    
    // Não mostrar loading se for polling (forceSync = false mantido do caller)
    if (_orderDetails == null) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }

    try {
      final orderProvider = context.read<OrderProvider>();
      
      // IMPORTANTE: Fazer sync com Nostr para buscar updates de status
      // Isso permite que o Bro veja quando o usuário confirmou
      final currentStatus = _orderDetails?['status'] ?? '';
      if (currentStatus == 'awaiting_confirmation' || forceSync) {
        debugPrint('🔄 [SYNC] Sincronizando com Nostr para buscar updates...');
        await orderProvider.syncOrdersFromNostr().timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            debugPrint('⏱️ [SYNC] Timeout - continuando com dados locais');
          },
        );
      }
      
      debugPrint('🔵 [LOAD] Chamando getOrder(${widget.orderId.substring(0, 8)})...');
      final order = await orderProvider.getOrder(widget.orderId);
      
      debugPrint('🔍 _loadOrderDetails: ordem carregada = ${order != null ? "OK (status=${order['status']})" : "NULL"}');
      debugPrint('🔍 _loadOrderDetails: billCode = ${order?['billCode'] != null && (order!['billCode'] as String).isNotEmpty ? "present (${(order['billCode'] as String).length} chars)" : "EMPTY"}');

      if (mounted) {
        setState(() {
          _orderDetails = order;
          // Verificar se ordem já foi aceita (por qualquer provedor ou este provedor)
          final orderProviderId = order?['providerId'] ?? order?['provider_id'];
          final orderStatus = order?['status'] ?? 'pending';
          
          // CORREÇÃO CRÍTICA: Ordem foi aceita se:
          // 1. Status indica aceitação (accepted/awaiting_confirmation/completed/liquidated)
          // 2. OU tem providerId definido (mesmo se status vier errado do Nostr)
          final hasValidProviderId = orderProviderId != null && 
                                     orderProviderId.isNotEmpty && 
                                     orderProviderId != 'provider_test_001';
          final hasAdvancedStatus = orderStatus == 'accepted' || 
                                    orderStatus == 'awaiting_confirmation' || 
                                    orderStatus == 'completed' ||
                                    orderStatus == 'liquidated';
          
          // Se tem providerId válido, a ordem FOI aceita - independente do status
          _orderAccepted = hasAdvancedStatus || hasValidProviderId;
          
          debugPrint('🔍 _orderAccepted calc: hasAdvancedStatus=$hasAdvancedStatus, hasValidProviderId=$hasValidProviderId, result=$_orderAccepted');
          
          // Calcular tempo restante se comprovante foi enviado
          final metadata = order?['metadata'] as Map<String, dynamic>?;
          // CORREÇÃO: Verificar TODOS os campos possíveis de timestamp
          final submittedAtStr = metadata?['receipt_submitted_at'] as String? ?? 
                                 metadata?['proofReceivedAt'] as String? ??
                                 metadata?['proofSentAt'] as String? ??
                                 metadata?['completedAt'] as String?;
          if (submittedAtStr != null) {
            _receiptSubmittedAt = DateTime.tryParse(submittedAtStr);
            if (_receiptSubmittedAt != null) {
              final deadline = _receiptSubmittedAt!.add(const Duration(hours: 36));
              _timeRemaining = deadline.difference(DateTime.now());
              debugPrint('⏱️ Timer 36h: prazo=${deadline.toIso8601String()}, restante=${_timeRemaining?.inHours ?? 0}h ${(_timeRemaining?.inMinutes.abs() ?? 0) % 60}m');
            }
          } else {
            debugPrint('⚠️ Nenhum timestamp de comprovante encontrado');
          }
          
          debugPrint('🔍 Ordem ${widget.orderId.substring(0, 8)}: status=$orderStatus, providerId=$orderProviderId, _orderAccepted=$_orderAccepted');
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _acceptOrder() async {
    if (!mounted) return;
    
    debugPrint('🔵 [ACCEPT] _acceptOrder INICIADO para ordem ${widget.orderId.substring(0, 8)}');
    
    // PROTEÇÃO CRÍTICA: Verificar se ordem já foi aceita
    final currentStatus = _orderDetails?['status'] ?? 'pending';
    final currentProviderId = _orderDetails?['providerId'] ?? _orderDetails?['provider_id'];
    
    debugPrint('🔵 [ACCEPT] Status atual: $currentStatus, providerId: $currentProviderId, _orderAccepted: $_orderAccepted');
    
    if (currentStatus != 'pending' && currentStatus != 'payment_received') {
      debugPrint('🚫 BLOQUEIO DE SEGURANÇA: Tentativa de aceitar ordem com status=$currentStatus');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Esta ordem já está em status "$currentStatus" e não pode ser aceita novamente'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    
    if (_orderAccepted) {
      debugPrint('🚫 BLOQUEIO DE SEGURANÇA: Ordem já marcada como aceita localmente');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('❌ Esta ordem já foi aceita'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    
    if (currentProviderId != null && currentProviderId.isNotEmpty) {
      debugPrint('🚫 BLOQUEIO DE SEGURANÇA: Ordem já tem providerId=$currentProviderId');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('❌ Esta ordem já foi aceita por outro provedor'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    
    final orderAmount = (_orderDetails!['amount'] as num).toDouble();
    
    // VALIDAÇÃO: Verificar se ordem não é muito antiga (PIX pode ter expirado)
    final createdAtStr = _orderDetails!['createdAt'] as String?;
    if (createdAtStr != null) {
      final createdAt = DateTime.tryParse(createdAtStr);
      if (createdAt != null) {
        final orderAge = DateTime.now().difference(createdAt);
        if (orderAge.inHours >= 12) {
          // Mostrar aviso mas permitir aceitar
          final shouldContinue = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF1A1A1A),
              title: Row(
                children: const [
                  Icon(Icons.warning_amber, color: Colors.orange),
                  SizedBox(width: 8),
                  Text('Ordem Antiga', style: TextStyle(color: Colors.white)),
                ],
              ),
              content: Text(
                'Esta ordem foi criada há ${orderAge.inHours} horas. O código PIX pode ter expirado.\n\nDeseja continuar mesmo assim?',
                style: const TextStyle(color: Colors.white70),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancelar'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                  child: const Text('Aceitar Mesmo Assim'),
                ),
              ],
            ),
          );
          
          if (shouldContinue != true) return;
        }
      }
    }

    // Em modo teste, pular verificação de garantia
    if (!AppConfig.providerTestMode) {
      final collateralProvider = context.read<CollateralProvider>();
      
      // Verificar se pode aceitar
      if (!collateralProvider.canAcceptOrder(orderAmount)) {
        _showError('Garantia insuficiente para aceitar esta ordem');
        return;
      }
    }

    if (!mounted) return;
    setState(() {
      _isAccepting = true;
    });

    try {
      // TIMEOUT GLOBAL: Toda operação de aceitar deve completar em 45s
      // Inclui retry automático se falhar na primeira tentativa
      await _doAcceptOrder(orderAmount).timeout(
        const Duration(seconds: 45),
        onTimeout: () {
          debugPrint('⏱️ [ACCEPT] TIMEOUT GLOBAL de 45s atingido!');
          throw TimeoutException('Tempo esgotado ao aceitar ordem (45s)');
        },
      );
    } catch (e) {
      debugPrint('❌ [ACCEPT] ERRO: $e');
      _showError('Erro ao aceitar ordem: $e');
    } finally {
      // GARANTIA: _isAccepting SEMPRE é resetado
      if (mounted && _isAccepting) {
        debugPrint('🔵 [ACCEPT] Resetando _isAccepting no finally');
        setState(() {
          _isAccepting = false;
        });
      }
    }
  }

  /// Execução interna do aceitar — separada para permitir timeout global
  Future<void> _doAcceptOrder(double orderAmount) async {
    // Em modo produção, bloquear garantia
    if (!AppConfig.providerTestMode) {
      final collateralProvider = context.read<CollateralProvider>();
      final currentTier = collateralProvider.getCurrentTier();
      
      if (currentTier != null) {
        debugPrint('🔵 [ACCEPT] Bloqueando garantia (tier=${currentTier.id})...');
        await _escrowService.lockCollateral(
          providerId: widget.providerId,
          orderId: widget.orderId,
          lockedSats: (orderAmount * 1000).round(),
        );
        debugPrint('🔵 [ACCEPT] Garantia bloqueada OK');
      } else {
        debugPrint('⚠️ [ACCEPT] Sem tier ativo — pulando lockCollateral');
      }
    }

    // Publicar aceitação no Nostr E atualizar localmente
    // Retry automático: até 2 tentativas se falhar
    debugPrint('🔵 [ACCEPT] Publicando aceitação no Nostr...');
    final orderProvider = context.read<OrderProvider>();
    
    bool success = false;
    for (int attempt = 1; attempt <= 2; attempt++) {
      debugPrint('🔵 [ACCEPT] Tentativa $attempt/2...');
      success = await orderProvider.acceptOrderAsProvider(widget.orderId);
      if (success) break;
      if (attempt < 2) {
        debugPrint('⚠️ [ACCEPT] Tentativa $attempt falhou, retentando em 2s...');
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    
    debugPrint('🔵 [ACCEPT] Resultado final: success=$success');
    
    if (!success) {
      _showError('Falha ao publicar aceitação no Nostr');
      return;
    }

    if (mounted) {
      setState(() {
        _orderAccepted = true;
        _isAccepting = false;
      });
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Ordem aceita! Pague a conta e envie o comprovante.'),
          backgroundColor: Colors.green,
        ),
      );
    }

    debugPrint('🔵 [ACCEPT] Recarregando detalhes da ordem...');
    await _loadOrderDetails();
    debugPrint('🔵 [ACCEPT] Ordem aceita e detalhes carregados com sucesso!');
  }

  Future<void> _pickReceipt() async {
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (image != null) {
        setState(() {
          _receiptImage = File(image.path);
        });
      }
    } catch (e) {
      _showError('Erro ao selecionar imagem: $e');
    }
  }

  Future<void> _takePhoto() async {
    try {
      final XFile? image = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (image != null) {
        setState(() {
          _receiptImage = File(image.path);
        });
      }
    } catch (e) {
      _showError('Erro ao tirar foto: $e');
    }
  }

  Future<void> _uploadReceipt() async {
    // Verificar se tem imagem OU código
    if (_receiptImage == null && _confirmationCodeController.text.trim().isEmpty) {
      _showError('Selecione um comprovante ou digite um código de confirmação');
      return;
    }

    setState(() {
      _isUploading = true;
    });

    try {
      // Timeout global de 90s para toda a operação de upload
      await _doUploadReceipt().timeout(
        const Duration(seconds: 90),
        onTimeout: () {
          throw TimeoutException('Tempo esgotado ao enviar comprovante (90s)');
        },
      );
    } catch (e) {
      setState(() {
        _isUploading = false;
      });
      _showError('Erro ao enviar comprovante: $e');
    }
  }

  Future<void> _doUploadReceipt() async {
    try {
      String proofImageBase64 = '';
      String confirmationCode = _confirmationCodeController.text.trim();
      String e2eId = _e2eIdController.text.trim(); // v236
      
      if (_receiptImage != null) {
        // Converter imagem para base64 para publicar no Nostr
        final bytes = await _receiptImage!.readAsBytes();
        proofImageBase64 = base64Encode(bytes);
      }

      // ========== GERAR INVOICE AUTOMATICAMENTE ==========
      // CORRIGIDO: O provedor recebe o VALOR TOTAL menos a taxa da plataforma
      // Modelo: Usuário paga sats -> Provedor paga PIX -> Provedor recebe sats
      final amount = (_orderDetails!['amount'] as num).toDouble();
      final btcAmount = (_orderDetails!['btcAmount'] as num?)?.toDouble() ?? 0;
      
      // Converter btcAmount para sats (btcAmount está em BTC, * 100_000_000 = sats)
      final totalSats = (btcAmount * 100000000).round();
      
      // CORRIGIDO: Provedor recebe valor total MENOS taxa da plataforma (2%)
      // A taxa da plataforma é paga separadamente pelo usuário
      var providerReceiveSats = totalSats;
      
      // Taxa mínima de 1 sat para ordens muito pequenas
      if (providerReceiveSats < 1 && totalSats > 0) {
        providerReceiveSats = 1;
      }
      
      debugPrint('💰 Ordem: R\$ ${amount.toStringAsFixed(2)} = $totalSats sats');
      debugPrint('💰 Provedor vai receber: $providerReceiveSats sats (valor total da ordem)');
      
      String? generatedInvoice;
      
      // Gerar invoice Lightning para receber o pagamento (apenas se taxa > 0)
      // IMPORTANTE: Usar BreezProvider direto pois é o que está inicializado pelo login
      final breezProvider = context.read<BreezProvider>();
      final liquidProvider = context.read<BreezLiquidProvider>();
      
      // DEBUG: Verificar estado das carteiras
      debugPrint('🔍 DEBUG INVOICE GENERATION:');
      debugPrint('   breezProvider.isInitialized: ${breezProvider.isInitialized}');
      debugPrint('   liquidProvider.isInitialized: ${liquidProvider.isInitialized}');
      debugPrint('   providerReceiveSats: $providerReceiveSats');
      
      // Só gerar invoice se o valor for maior que 0
      if (providerReceiveSats > 0 && breezProvider.isInitialized) {
        debugPrint('⚡ Gerando invoice de $providerReceiveSats sats via Breez Spark...');
        
        try {
          final result = await breezProvider.createInvoice(
            amountSats: providerReceiveSats,
            description: 'Bro - Ordem ${widget.orderId.substring(0, 8)}',
          ).timeout(const Duration(seconds: 30));
          
          if (result != null && result['bolt11'] != null) {
            generatedInvoice = result['bolt11'] as String;
            debugPrint('✅ Invoice gerado via Spark: ${generatedInvoice.substring(0, 30)}...');
          } else {
            debugPrint('⚠️ Falha ao gerar invoice via Spark: $result');
          }
        } catch (e) {
          debugPrint('⚠️ Erro/timeout ao gerar invoice Spark: $e — continuando sem invoice');
        }
      } else if (providerReceiveSats > 0 && liquidProvider.isInitialized) {
        debugPrint('⚡ Gerando invoice de $providerReceiveSats sats via Liquid (fallback)...');
        
        try {
          final result = await liquidProvider.createInvoice(
            amountSats: providerReceiveSats,
            description: 'Bro - Ordem ${widget.orderId.substring(0, 8)}',
          ).timeout(const Duration(seconds: 30));
          
          if (result != null && result['bolt11'] != null) {
            generatedInvoice = result['bolt11'] as String;
            debugPrint('✅ Invoice gerado via Liquid: ${generatedInvoice.substring(0, 30)}...');
          } else {
            debugPrint('⚠️ Falha ao gerar invoice via Liquid: $result');
          }
        } catch (e) {
          debugPrint('⚠️ Erro/timeout ao gerar invoice Liquid: $e — continuando sem invoice');
        }
      } else if (providerReceiveSats <= 0) {
        debugPrint('ℹ️ providerReceiveSats=$providerReceiveSats (muito baixo), não gerando invoice');
      } else {
        debugPrint('🚨 NENHUMA CARTEIRA INICIALIZADA! breez=${breezProvider.isInitialized}, liquid=${liquidProvider.isInitialized}');
      }

      debugPrint('📋 Resumo: providerReceiveSats=$providerReceiveSats, hasInvoice=${generatedInvoice != null}');
      if (generatedInvoice != null) {
        debugPrint('   Invoice: ${generatedInvoice.substring(0, 50)}...');
      }

      // CRÍTICO: Se não gerou invoice e há sats a receber, bloquear
      if (generatedInvoice == null && providerReceiveSats > 0) {
        debugPrint('🚨 BLOQUEANDO: Sem invoice gerado para receber $providerReceiveSats sats!');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('❌ Carteira não conectada. Conecte sua carteira para receber pagamento.'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 5),
            ),
          );
          setState(() => _isUploading = false);
        }
        return;
      }

      // Publicar comprovante + invoice no Nostr E atualizar localmente
      // Retry automático: até 2 tentativas se falhar
      final orderProvider = context.read<OrderProvider>();
      bool success = false;
      for (int attempt = 1; attempt <= 2; attempt++) {
        debugPrint('📤 [UPLOAD] Tentativa $attempt/2 de publicar comprovante...');
        success = await orderProvider.completeOrderAsProvider(
          widget.orderId, 
          proofImageBase64.isNotEmpty ? proofImageBase64 : confirmationCode,
          providerInvoice: generatedInvoice,
          e2eId: e2eId.isNotEmpty ? e2eId : null, // v236
        );
        if (success) break;
        if (attempt < 2) {
          debugPrint('⚠️ [UPLOAD] Tentativa $attempt falhou, retentando em 3s...');
          await Future.delayed(const Duration(seconds: 3));
        }
      }
      
      if (!success) {
        _showError('Falha ao publicar comprovante no Nostr');
        setState(() {
          _isUploading = false;
        });
        return;
      }

      setState(() {
        _isUploading = false;
      });

      if (mounted) {
        if (generatedInvoice != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✅ Comprovante enviado! Você receberá $providerReceiveSats sats quando o usuário confirmar.'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 4),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⚠️ Comprovante enviado mas carteira não conectada! Configure sua carteira para receber sats automaticamente.'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 6),
            ),
          );
        }
        // Voltar para a tela de ordens com resultado indicando para ir para aba "Minhas"
        Navigator.pop(context, {'goToMyOrders': true});
      }
    } catch (e) {
      setState(() {
        _isUploading = false;
      });
      _showError('Erro ao enviar comprovante: $e');
    }
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Detalhes da Ordem'),
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator(color: Color(0xFFFF6B6B)))
            : _error != null
                ? _buildErrorView()
                : _orderDetails == null
                    ? const Center(child: Text('Ordem não encontrada', style: TextStyle(color: Colors.white70)))
                    : RefreshIndicator(
                        onRefresh: _loadOrderDetails,
                        color: Colors.orange,
                        child: _buildContent(),
                      ),
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              _error!,
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _loadOrderDetails,
              child: const Text('Tentar Novamente'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    final amount = (_orderDetails!['amount'] as num).toDouble();
    final status = _orderDetails!['status'] as String? ?? 'pending';
    // Usar billType e billCode diretamente do modelo Order
    final billType = _orderDetails!['billType'] as String? ?? 
                     _orderDetails!['bill_type'] as String? ?? 
                     _orderDetails!['payment_type'] as String? ?? 'pix';
    final billCode = _orderDetails!['billCode'] as String? ?? 
                     _orderDetails!['bill_code'] as String? ?? '';
    
    // DEBUG: Log para verificar se billCode está presente
    debugPrint('🔍 _buildContent: billType=$billType, status=$status, billCode=${billCode.isNotEmpty ? "${billCode.substring(0, billCode.length > 20 ? 20 : billCode.length)}..." : "EMPTY"}');
    
    // SEMPRE construir payment_data a partir do billCode se existir
    Map<String, dynamic>? paymentData;
    if (billCode.isNotEmpty) {
      // Criar payment_data baseado no tipo de conta
      if (billType.toLowerCase() == 'pix' || billCode.length > 30) {
        paymentData = {
          'pix_code': billCode,
          'pix_key': _extractPixKey(billCode),
        };
      } else {
        paymentData = {
          'barcode': billCode,
        };
      }
      debugPrint('✅ paymentData criado: ${paymentData.keys}');
    } else {
      // Fallback: tentar usar payment_data existente
      paymentData = _orderDetails!['payment_data'] as Map<String, dynamic>?;
      debugPrint('⚠️ billCode vazio, usando payment_data existente: $paymentData');
    }
    
    final providerFee = amount * EscrowService.providerFeePercent / 100;
    
    // Verificar se ordem está concluída ou aguardando confirmação
    final isCompleted = status == 'completed' || status == 'liquidated';
    final isAwaitingConfirmation = status == 'awaiting_confirmation';
    final isAccepted = status == 'accepted';
    final isPending = status == 'pending' || status == 'payment_received';

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ========== ORDEM CONCLUÍDA - Tela de Resumo ==========
          if (isCompleted) ...[
            _buildCompletedOrderView(amount, providerFee, billType),
            // Card de resolução (se ordem foi resolvida via mediação)
            if (_disputeResolution != null) ...[
              const SizedBox(height: 16),
              _buildDisputeResolutionCard(),
            ],
          ]
          // ========== AGUARDANDO CONFIRMAÇÃO DO USUÁRIO ==========
          else if (isAwaitingConfirmation) ...[
            _buildAmountCard(amount, providerFee),
            const SizedBox(height: 16),
            _buildStatusCard(),
            const SizedBox(height: 16),
            _buildAwaitingConfirmationSection(),
            const SizedBox(height: 16),
          ]
          // ========== BRO ACEITOU - PRECISA PAGAR A CONTA ==========
          else if (isAccepted) ...[
            _buildAmountCard(amount, providerFee),
            const SizedBox(height: 16),
            _buildStatusCard(),
            const SizedBox(height: 16),
            // Mostrar código de pagamento APENAS quando Bro precisa pagar
            if (paymentData != null && paymentData.isNotEmpty) ...[
              _buildPaymentDataCard(billType, paymentData),
              const SizedBox(height: 16),
            ],
            _buildReceiptSection(),
          ]
          // ========== ORDEM DISPONÍVEL - PODE ACEITAR ==========
          else if (isPending) ...[
            _buildAmountCard(amount, providerFee),
            const SizedBox(height: 16),
            _buildStatusCard(),
            const SizedBox(height: 16),
            // SEGURANÇA: NÃO mostrar código PIX/boleto antes de aceitar
            // Evita que dois Bros paguem a mesma conta simultaneamente
            // O código só será revelado APÓS o Bro aceitar a ordem
            _buildAcceptButton(),
          ]
          // ========== OUTROS STATUS ==========
          else ...[
            _buildAmountCard(amount, providerFee),
            const SizedBox(height: 16),
            _buildStatusCard(),
            // Card de resolução de disputa (se houver)
            if (_disputeResolution != null) ...[
              const SizedBox(height: 16),
              _buildDisputeResolutionCard(),
            ],
            // v236: Botão enviar evidência quando em disputa
            if (status == 'disputed' && _disputeResolution == null) ...[
              // v237: Mensagens do mediador para o provedor
              if (_providerMediatorMessages.isNotEmpty) ...[
                const SizedBox(height: 16),
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
                            'Mensagens do Mediador (${_providerMediatorMessages.length})',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: Colors.purple,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      ..._providerMediatorMessages.map((msg) {
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
                                  const Text('Mediador', style: TextStyle(color: Colors.purple, fontSize: 11, fontWeight: FontWeight.bold)),
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
              ] else if (_loadingProviderMediatorMessages) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D0D0D),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.purple.withOpacity(0.2)),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.purple)),
                      SizedBox(width: 10),
                      Text('Buscando mensagens do mediador...', style: TextStyle(color: Colors.white38, fontSize: 12)),
                    ],
                  ),
                ),
              ],
              // v237: Botão para responder ao mediador (se houver mensagens)
              if (_providerMediatorMessages.isNotEmpty) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _showSendEvidenceDialog(),
                    icon: const Icon(Icons.reply, size: 18),
                    label: const Text('Responder ao Mediador'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.purple,
                      side: const BorderSide(color: Colors.purple),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _showSendEvidenceDialog(),
                  icon: const Icon(Icons.add_photo_alternate, size: 20),
                  label: const Text('Enviar Evidência / Comprovante'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.blue,
                    side: const BorderSide(color: Colors.blue),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ],
          ],
          
          // Padding extra para não ficar sob a barra de navegação
          const SizedBox(height: 32),
        ],
      ),
    );
  }
  
  /// Tela de resumo para ordem concluída - mostra ganho, timeline, sucesso
  Widget _buildCompletedOrderView(double amount, double providerFee, String billType) {
    final totalGanho = providerFee;
    final metadata = _orderDetails?['metadata'] as Map<String, dynamic>?;
    final proofImage = metadata?['paymentProof'] as String?;
    final createdAt = _orderDetails?['createdAt'] != null 
        ? DateTime.tryParse(_orderDetails!['createdAt'].toString())
        : null;
    final status = _orderDetails?['status'] as String? ?? '';
    final isLiquidated = status == 'liquidated';
    final cardColor = isLiquidated ? Colors.purple : Colors.green;
    
    return Column(
      children: [
        // Card de Sucesso / Liquidação
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [cardColor.withOpacity(0.2), cardColor.withOpacity(0.05)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: cardColor.withOpacity(0.5)),
          ),
          child: Column(
            children: [
              Icon(
                isLiquidated ? Icons.electric_bolt : Icons.check_circle, 
                color: cardColor, 
                size: 64,
              ),
              const SizedBox(height: 16),
              Text(
                isLiquidated ? '⚡ Liquidada Automaticamente' : '🎉 Ordem Concluída!',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                isLiquidated 
                    ? 'Usuário não confirmou em 36h. Valores liberados para você.'
                    : 'O usuário confirmou o recebimento',
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 24),
              
              // ID da Ordem
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.tag, color: Colors.white38, size: 16),
                  const SizedBox(width: 6),
                  Text(
                    'Ordem #${widget.orderId.length > 8 ? widget.orderId.substring(0, 8) : widget.orderId}',
                    style: const TextStyle(color: Colors.white54, fontSize: 13, fontFamily: 'monospace'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        
        // Resumo Financeiro
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.orange.withOpacity(0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '💰 Resumo Financeiro',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              _buildFinancialRow('Valor da conta', 'R\$ ${amount.toStringAsFixed(2)}', Colors.white70),
              const SizedBox(height: 8),
              _buildFinancialRow('Tipo', billType.toUpperCase(), Colors.orange),
              const SizedBox(height: 8),
              const Divider(color: Colors.white24),
              const SizedBox(height: 8),
              _buildFinancialRow(
                'Seu Ganho (${EscrowService.providerFeePercent}%)', 
                '+ R\$ ${totalGanho.toStringAsFixed(2)}', 
                Colors.green,
                bold: true,
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        
        // Timeline de etapas
        _buildCompletedTimeline(createdAt),
        const SizedBox(height: 20),
        
        // Ver comprovante (se existir)
        if (proofImage != null && proofImage != 'image_base64_stored') ...[
          _buildViewProofButton(proofImage),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
  
  Widget _buildFinancialRow(String label, String value, Color valueColor, {bool bold = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: Colors.white60, fontSize: 14)),
        Text(
          value,
          style: TextStyle(
            color: valueColor,
            fontSize: bold ? 18 : 14,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    );
  }
  
  Widget _buildCompletedTimeline(DateTime? createdAt) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '📋 Etapas Concluídas',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          _buildTimelineStep('Ordem criada pelo usuário', true, isFirst: true),
          _buildTimelineStep('Você aceitou a ordem', true),
          _buildTimelineStep('Conta paga por você', true),
          _buildTimelineStep('Comprovante enviado', true),
          _buildTimelineStep('Usuário confirmou recebimento', true, isLast: true),
        ],
      ),
    );
  }
  
  Widget _buildTimelineStep(String label, bool completed, {bool isFirst = false, bool isLast = false}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: completed ? Colors.green : Colors.grey,
                shape: BoxShape.circle,
              ),
              child: Icon(
                completed ? Icons.check : Icons.circle,
                size: 16,
                color: Colors.white,
              ),
            ),
            if (!isLast)
              Container(
                width: 2,
                height: 30,
                color: completed ? Colors.green.withOpacity(0.5) : Colors.grey.withOpacity(0.3),
              ),
          ],
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: isLast ? 0 : 20),
            child: Text(
              label,
              style: TextStyle(
                color: completed ? Colors.white : Colors.white54,
                fontSize: 14,
              ),
            ),
          ),
        ),
      ],
    );
  }
  
  Widget _buildViewProofButton(String proofImage) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () => _showProofImage(proofImage),
        icon: const Icon(Icons.receipt_long),
        label: const Text('Ver Comprovante Enviado'),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.orange,
          side: const BorderSide(color: Colors.orange),
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }
  
  void _showProofImage(String base64Image) {
    try {
      final imageBytes = base64Decode(base64Image);
      showDialog(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: const Color(0xFF1A1A1A),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppBar(
                backgroundColor: Colors.transparent,
                title: const Text('Comprovante Enviado'),
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(
                    imageBytes,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Center(
                      child: Text('Não foi possível carregar a imagem',
                          style: TextStyle(color: Colors.white70)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Erro ao carregar comprovante')),
      );
    }
  }

  Widget _buildAmountCard(double amount, double fee) {
    // Obter btcAmount da ordem para mostrar em sats
    final btcAmount = (_orderDetails?['btcAmount'] as num?)?.toDouble() ?? 0;
    final satsAmount = (btcAmount * 100000000).toInt();
    // Calcular sats que o provedor vai receber (proporcional à taxa)
    final satsToReceive = ((amount + fee) / amount * satsAmount).round();
    
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.orange.withOpacity(0.2), Colors.orange.withOpacity(0.05)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.orange.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ID da ordem no topo do card
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Valor da Conta',
                style: TextStyle(color: Colors.white60, fontSize: 14),
              ),
              Row(
                children: [
                  const Icon(Icons.tag, color: Colors.white38, size: 14),
                  const SizedBox(width: 4),
                  Text(
                    widget.orderId.length > 8 ? widget.orderId.substring(0, 8) : widget.orderId,
                    style: const TextStyle(color: Colors.white38, fontSize: 12, fontFamily: 'monospace'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'R\$ ${amount.toStringAsFixed(2)}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 36,
              fontWeight: FontWeight.bold,
            ),
          ),
          // Mostrar valor em sats
          if (satsAmount > 0) ...[
            const SizedBox(height: 4),
            Text(
              '≈ $satsAmount sats',
              style: TextStyle(
                color: Colors.orange.withOpacity(0.8),
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          const SizedBox(height: 16),
          const Divider(color: Colors.white12),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Sua Taxa (3%)',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'R\$ ${fee.toStringAsFixed(2)}',
                    style: const TextStyle(
                      color: Colors.green,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text(
                    'Você Recebe',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  if (satsToReceive > 0)
                    Text(
                      '$satsToReceive sats',
                      style: const TextStyle(
                        color: Colors.orange,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    )
                  else
                    Text(
                      'R\$ ${(amount + fee).toStringAsFixed(2)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    final status = _orderDetails!['status'] as String? ?? 'pending';
    final statusInfo = _getStatusInfo(status);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: statusInfo['color'].withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusInfo['color'].withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(statusInfo['icon'], color: statusInfo['color'], size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  statusInfo['title'],
                  style: TextStyle(
                    color: statusInfo['color'],
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                Text(
                  statusInfo['description'],
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Extrai a chave PIX de um código PIX (se possível)
  String _extractPixKey(String pixCode) {
    // Se for um código PIX copia-e-cola longo, tentar extrair a chave
    if (pixCode.startsWith('00020126')) {
      // Código PIX EMV - retornar "Ver código abaixo"
      return 'Ver código abaixo';
    }
    // Se for curto, provavelmente é a própria chave
    if (pixCode.length < 50) {
      return pixCode;
    }
    return 'Ver código abaixo';
  }

  /// Card mostrando resultado da resolução do mediador
  Widget _buildDisputeResolutionCard() {
    final resolution = _disputeResolution!;
    final isProviderFavor = resolution['resolution'] == 'resolved_provider';
    final notes = resolution['notes'] as String? ?? '';
    final resolvedAt = resolution['resolvedAt'] as String? ?? '';
    
    String dateStr = '';
    try {
      final dt = DateTime.parse(resolvedAt);
      dateStr = '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      dateStr = resolvedAt;
    }
    
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: (isProviderFavor ? Colors.green : Colors.orange).withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: (isProviderFavor ? Colors.green : Colors.orange).withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.gavel, color: isProviderFavor ? Colors.green : Colors.orange, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '⚖️ Decisão do Mediador',
                      style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold,
                        color: isProviderFavor ? Colors.green : Colors.orange,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isProviderFavor
                          ? 'Resolvida a seu favor — pagamento mantido'
                          : 'Resolvida a favor do usuário — ordem cancelada',
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
                  const Text('Mensagem do mediador:', style: TextStyle(color: Colors.white54, fontSize: 11)),
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
    );
  }

  Map<String, dynamic> _getStatusInfo(String status) {
    switch (status) {
      case 'pending':
        return {
          'title': 'Aguardando Aceitação',
          'description': 'Ordem disponível para aceitar',
          'icon': Icons.pending_outlined,
          'color': Colors.orange,
        };
      case 'accepted':
        return {
          'title': 'Ordem Aceita',
          'description': 'Pague a conta e envie o comprovante',
          'icon': Icons.check_circle_outline,
          'color': Colors.blue,
        };
      case 'payment_submitted':
      case 'awaiting_confirmation':
        return {
          'title': 'Comprovante Enviado',
          'description': 'Aguardando confirmação do usuário',
          'icon': Icons.hourglass_empty,
          'color': Colors.purple,
        };
      case 'disputed':
        // v233: Se há resolução, mostrar como resolvida mesmo que status ainda seja 'disputed'
        if (_disputeResolution != null) {
          final isProviderFavor = _disputeResolution!['resolution'] == 'resolved_provider';
          return {
            'title': 'Resolvida por Mediação',
            'description': isProviderFavor
                ? 'Mediador decidiu a seu favor — pagamento mantido'
                : 'Mediador decidiu a favor do usuário',
            'icon': Icons.gavel,
            'color': isProviderFavor ? Colors.green : Colors.orange,
          };
        }
        return {
          'title': 'Em Disputa',
          'description': 'Aguardando mediação',
          'icon': Icons.gavel,
          'color': Colors.orange,
        };
      case 'liquidated':
        return {
          'title': 'Liquidada Automaticamente ⚡',
          'description': 'Usuário não confirmou em 36h. Valores liberados para você.',
          'icon': Icons.electric_bolt,
          'color': Colors.purple,
        };
      case 'confirmed':
      case 'completed':
        if (_disputeResolution != null) {
          final isProviderFavor = _disputeResolution!['resolution'] == 'resolved_provider';
          return {
            'title': 'Resolvida por Mediação',
            'description': isProviderFavor
                ? 'Mediador decidiu a seu favor — pagamento mantido'
                : 'Mediador decidiu a favor do usuário',
            'icon': Icons.gavel,
            'color': isProviderFavor ? Colors.green : Colors.orange,
          };
        }
        return {
          'title': 'Confirmado',
          'description': 'Pagamento recebido!',
          'icon': Icons.check_circle,
          'color': Colors.green,
        };
      default:
        return {
          'title': status,
          'description': '',
          'icon': Icons.info_outline,
          'color': Colors.grey,
        };
    }
  }

  Widget _buildPaymentDataCard(String type, Map<String, dynamic> data) {
    final isPix = type.toLowerCase() == 'pix' || 
                  data['pix_code'] != null || 
                  (data['barcode'] == null && data['pix_key'] != null);
    
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withOpacity(0.5), width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_getPaymentIcon(type), color: Colors.orange, size: 24),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '⚡ PAGAR ESTA CONTA',
                  style: const TextStyle(
                    color: Colors.orange,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            isPix ? 'Copie o código PIX abaixo e pague no seu banco' 
                  : 'Copie o código de barras abaixo e pague',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 16),
          const Divider(color: Colors.white12),
          const SizedBox(height: 16),
          
          if (isPix) ...[
            // Mostrar chave PIX se não for "Ver código abaixo"
            if (data['pix_key'] != null && data['pix_key'] != 'Ver código abaixo')
              _buildPaymentField('Chave PIX', data['pix_key'] as String),
            if (data['pix_name'] != null)
              _buildPaymentField('Nome', data['pix_name'] as String),
            // SEMPRE mostrar o código PIX se existir
            if (data['pix_code'] != null) ...[
              const SizedBox(height: 12),
              _buildCopyableField('📋 Código PIX (Copia e Cola)', data['pix_code'] as String),
            ],
          ] else ...[
            // Boleto
            if (data['bank'] != null)
              _buildPaymentField('Banco', data['bank'] as String),
            // SEMPRE mostrar o código de barras se existir
            if (data['barcode'] != null) ...[
              const SizedBox(height: 12),
              _buildCopyableField('📋 Código de Barras', data['barcode'] as String),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildPaymentField(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildCopyableField(String label, String value) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontFamily: 'monospace',
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, color: Colors.orange),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: value));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('📋 Copiado!')),
                  );
                },
                tooltip: 'Copiar',
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildAcceptButton() {
    // PROTEÇÃO CRÍTICA: Não mostrar botão se ordem já foi aceita
    if (_orderAccepted) {
      debugPrint('🚫 _buildAcceptButton: Botão oculto porque _orderAccepted=true');
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.orange.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.orange.withOpacity(0.3)),
        ),
        child: Row(
          children: const [
            Icon(Icons.check_circle, color: Colors.orange),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Esta ordem já foi aceita',
                style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      );
    }
    
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _isAccepting ? null : _acceptOrder,
        icon: _isAccepting
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.check_circle),
        label: Text(_isAccepting ? 'Aceitando...' : 'Aceitar Ordem'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.orange,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }

  /// Seção exibida quando provedor enviou comprovante e aguarda confirmação
  Widget _buildAwaitingConfirmationSection() {
    final amount = (_orderDetails!['amount'] as num).toDouble();
    final providerFee = amount * EscrowService.providerFeePercent / 100;
    final hoursRemaining = _timeRemaining?.inHours ?? 24;
    final minutesRemaining = (_timeRemaining?.inMinutes ?? 0) % 60;
    final isExpiringSoon = hoursRemaining < 4;
    final isExpired = _timeRemaining != null && _timeRemaining!.isNegative;
    final metadata = _orderDetails?['metadata'] as Map<String, dynamic>?;
    final proofImage = metadata?['paymentProof'] as String?;
    
    // Se o prazo expirou, executar auto-liquidação
    if (isExpired && !_isProcessingAutoLiquidation) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _executeAutoLiquidation();
      });
    }
    
    return Column(
      children: [
        // Card de Status - Esperando Usuário
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: isExpiringSoon 
                  ? [Colors.red.withOpacity(0.2), Colors.red.withOpacity(0.05)]
                  : [Colors.purple.withOpacity(0.2), Colors.purple.withOpacity(0.05)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isExpiringSoon 
                  ? Colors.red.withOpacity(0.5) 
                  : Colors.purple.withOpacity(0.5),
            ),
          ),
          child: Column(
            children: [
              Icon(
                Icons.hourglass_empty, 
                color: isExpiringSoon ? Colors.red : Colors.purple,
                size: 48,
              ),
              const SizedBox(height: 12),
              Text(
                '⏳ Aguardando Usuário',
                style: TextStyle(
                  color: isExpiringSoon ? Colors.red : Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'O usuário precisa confirmar que recebeu o pagamento para liberar seus ganhos',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 16),
              
              // ID da Ordem
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.tag, color: Colors.white38, size: 16),
                  const SizedBox(width: 6),
                  Text(
                    'Ordem #${widget.orderId.length > 8 ? widget.orderId.substring(0, 8) : widget.orderId}',
                    style: const TextStyle(color: Colors.white54, fontSize: 13, fontFamily: 'monospace'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        
        // Resumo do que você vai ganhar
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.green.withOpacity(0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '💰 Você vai receber',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Valor da conta', style: TextStyle(color: Colors.white60, fontSize: 14)),
                  Text('R\$ ${amount.toStringAsFixed(2)}', style: const TextStyle(color: Colors.white70, fontSize: 14)),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Seu ganho (${EscrowService.providerFeePercent}%)', style: const TextStyle(color: Colors.white60, fontSize: 14)),
                  Text(
                    '+ R\$ ${providerFee.toStringAsFixed(2)}',
                    style: const TextStyle(color: Colors.green, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        
        // Timer
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.timer, color: isExpiringSoon ? Colors.red : Colors.orange),
              const SizedBox(width: 8),
              Text(
                isExpired
                    ? '🔄 Auto-liquidação em andamento...'
                    : 'Tempo restante: ${hoursRemaining}h ${minutesRemaining}min',
                style: TextStyle(
                  color: isExpiringSoon ? Colors.red : Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        
        // Ver comprovante enviado
        if (proofImage != null && proofImage != 'image_base64_stored') ...[
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _showProofImage(proofImage),
              icon: const Icon(Icons.receipt_long),
              label: const Text('Ver Comprovante Enviado'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.orange,
                side: const BorderSide(color: Colors.orange),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        
        // Informação sobre auto-liquidação
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0x1A4CAF50),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0x334CAF50)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Icon(Icons.info_outline, color: Color(0xFF4CAF50), size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '💡 Se o usuário não confirmar em 36 horas, a auto-liquidação libera seu pagamento automaticamente.',
                  style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        
        // Botão de disputa
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _showProviderDisputeDialog,
            icon: const Icon(Icons.gavel),
            label: const Text('Abrir Disputa'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFFF6B6B),
              side: const BorderSide(color: Color(0xFFFF6B6B)),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
      ],
    );
  }
  
  bool _isProcessingAutoLiquidation = false;
  
  /// Executa auto-liquidação quando prazo de 36h expira
  Future<void> _executeAutoLiquidation() async {
    if (_isProcessingAutoLiquidation) return;
    
    setState(() {
      _isProcessingAutoLiquidation = true;
    });
    
    try {
      debugPrint('🔄 Executando auto-liquidação para ordem ${widget.orderId}');
      
      final orderProvider = Provider.of<OrderProvider>(context, listen: false);
      
      // Usar o proof existente ou um placeholder para auto-liquidação
      final metadata = _orderDetails?['metadata'] as Map<String, dynamic>?;
      final existingProof = metadata?['paymentProof'] as String? ?? 'AUTO_LIQUIDATED';
      final amount = (_orderDetails?['amount'] as num?)?.toDouble() ?? 0.0;
      
      // Atualizar status para 'liquidated' (auto-liquidação) em vez de 'completed'
      final success = await orderProvider.autoLiquidateOrder(widget.orderId, existingProof);
      
      if (mounted) {
        if (success) {
          // Notificar o usuário sobre a auto-liquidação
          final notificationService = NotificationService();
          await notificationService.notifyOrderAutoLiquidated(
            orderId: widget.orderId,
            amountBrl: amount,
          );
          
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ Auto-liquidação concluída! Seus ganhos foram liberados.'),
              backgroundColor: Colors.green,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⚠️ Erro ao processar auto-liquidação'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        
        // Recarregar detalhes
        await _loadOrderDetails();
      }
    } catch (e) {
      debugPrint('❌ Erro na auto-liquidação: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro na auto-liquidação: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessingAutoLiquidation = false;
        });
      }
    }
  }

  void _showProviderDisputeDialog() {
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
                      '⚖️ Quando abrir uma disputa?',
                      style: TextStyle(
                        color: Color(0xFFFF6B6B),
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Você pode abrir uma disputa se:\n\n'
                      '• O usuário não confirma mesmo após receber\n'
                      '• Houve algum problema com o pagamento\n'
                      '• O usuário alega não ter recebido\n'
                      '• Precisa de mediação para resolver o caso',
                      style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 13, height: 1.4),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0x1A4CAF50),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0x334CAF50)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, color: Color(0xFF4CAF50), size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Lembre-se: após 36h sem confirmação, a auto-liquidação ocorre automaticamente.',
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
              _openProviderDisputeForm();
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

  void _openProviderDisputeForm() {
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
                const Text(
                  '📋 Formulário de Disputa (Provedor)',
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
                  'Usuário não confirma o recebimento',
                  'Usuário alega não ter recebido',
                  'Problema com o pagamento',
                  'Usuário não responde',
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
                            _submitProviderDispute(selectedReason!, reasonController.text.trim());
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

  Future<void> _submitProviderDispute(String reason, String description) async {
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
        'amount_brl': _orderDetails?['amount_brl'],
        'amount_sats': _orderDetails?['amount_sats'],
        'status': _orderDetails?['status'],
        'payment_type': _orderDetails?['payment_type'],
        'pix_key': _orderDetails?['pix_key'],
        'provider_id': widget.providerId,
      };
      
      // Criar a disputa
      await disputeService.createDispute(
        orderId: widget.orderId,
        openedBy: 'provider',
        reason: reason,
        description: description,
        orderDetails: orderDetails,
      );

      // Atualizar status local para "em disputa"
      final orderProvider = context.read<OrderProvider>();
      await orderProvider.updateOrderStatus(orderId: widget.orderId, status: 'disputed');

      // Publicar notificação de disputa no Nostr (kind 1 com tag bro-disputa)
      try {
        final nostrOrderService = NostrOrderService();
        final privateKey = orderProvider.nostrPrivateKey;
        if (privateKey != null) {
          await nostrOrderService.publishDisputeNotification(
            privateKey: privateKey,
            orderId: widget.orderId,
            reason: reason,
            description: description,
            openedBy: 'provider',
            orderDetails: orderDetails,
          );
          debugPrint('📤 Disputa do provedor publicada no Nostr');
        }
      } catch (e) {
        debugPrint('⚠️ Erro ao publicar disputa no Nostr: $e');
      }

      if (mounted) {
        Navigator.pop(context); // Fechar loading
        
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⚖️ Disputa aberta com sucesso! O suporte foi notificado e irá analisar o caso.'),
            backgroundColor: Color(0xFFFF6B6B),
            duration: Duration(seconds: 4),
          ),
        );
        
        // Recarregar detalhes
        await _loadOrderDetails();
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

  Widget _buildReceiptSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Enviar Comprovante',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Após pagar a conta, envie foto/arquivo do comprovante OU digite o código de confirmação.',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 16),
          
          // Campo de código de confirmação
          TextField(
            controller: _confirmationCodeController,
            decoration: InputDecoration(
              labelText: 'Código de Confirmação',
              hintText: 'Ex: 123456789 ou ID da transação',
              prefixIcon: const Icon(Icons.confirmation_number, color: Colors.orange),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Colors.white24),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Colors.orange, width: 2),
              ),
            ),
            style: const TextStyle(color: Colors.white),
            keyboardType: TextInputType.text,
          ),
          const SizedBox(height: 12),
          
          // v236: Campo E2E ID do PIX
          TextField(
            controller: _e2eIdController,
            decoration: InputDecoration(
              labelText: 'Código E2E do PIX (opcional)',
              hintText: 'Ex: E09089356202602251806...',
              helperText: 'Encontre nos detalhes do comprovante no app do banco',
              helperStyle: const TextStyle(color: Colors.white38, fontSize: 11),
              prefixIcon: const Icon(Icons.fingerprint, color: Colors.cyan),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Colors.white24),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Colors.cyan, width: 2),
              ),
            ),
            style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 13),
            keyboardType: TextInputType.text,
          ),
          const SizedBox(height: 16),
          
          const Divider(color: Colors.white12),
          const SizedBox(height: 16),
          
          // Seção de imagem
          if (_receiptImage != null) ...[
            const Text(
              'Comprovante Anexado:',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(
                _receiptImage!,
                height: 200,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickReceipt,
                    icon: const Icon(Icons.image, color: Colors.orange),
                    label: const Text('Trocar Foto'),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.orange),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      setState(() {
                        _receiptImage = null;
                      });
                    },
                    icon: const Icon(Icons.delete, color: Colors.red),
                    label: const Text('Remover'),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.red),
                    ),
                  ),
                ),
              ],
            ),
          ] else ...[
            // AVISO DE PRIVACIDADE
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.orange.withOpacity(0.3)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Icon(Icons.privacy_tip, color: Colors.orange, size: 20),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '⚠️ ATENÇÃO: Oculte dados sensíveis (CPF, nome completo) na imagem do comprovante. Esta imagem é apenas para comprovar o pagamento ao usuário. Criptografia NIP-17 em breve.',
                    style: TextStyle(color: Colors.orange, fontSize: 12, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          
          const Text(
              'Anexar Comprovante:',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickReceipt,
                    icon: const Icon(Icons.photo_library, color: Colors.orange),
                    label: const Text('Galeria'),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.orange),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _takePhoto,
                    icon: const Icon(Icons.camera_alt, color: Colors.orange),
                    label: const Text('Câmera'),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.orange),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ],
          
          const SizedBox(height: 16),
          
          // Botão de enviar
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isUploading ? null : _uploadReceipt,
              icon: _isUploading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.send),
              label: Text(_isUploading ? 'Enviando...' : 'Enviar Comprovante'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  IconData _getPaymentIcon(String type) {
    switch (type.toLowerCase()) {
      case 'pix':
        return Icons.pix;
      case 'boleto':
        return Icons.receipt_long;
      default:
        return Icons.payment;
    }
  }

  /// v236: Dialog para provedor enviar evidência na disputa
  void _showSendEvidenceDialog() {
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
                const Text('📎 Enviar Evidência', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text('Ordem: ${widget.orderId.substring(0, 8)}...', style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 14)),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.green.withOpacity(0.2)),
                  ),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('💡 Evidências aceitas:', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 13)),
                      SizedBox(height: 6),
                      Text('• Comprovante completo do PIX com código E2E (endToEndId)', style: TextStyle(color: Colors.white70, fontSize: 12)),
                      SizedBox(height: 3),
                      Text('• Print do Registrato (registrato.bcb.gov.br) mostrando PIX enviados', style: TextStyle(color: Colors.white70, fontSize: 12)),
                      SizedBox(height: 3),
                      Text('• Print do site do beneficiário mostrando conta paga', style: TextStyle(color: Colors.white70, fontSize: 12)),
                      SizedBox(height: 3),
                      Text('• Qualquer documento que comprove o pagamento', style: TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Descrição (opcional)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                TextField(
                  controller: descController,
                  maxLines: 3,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Explique o que esta evidência comprova...',
                    hintStyle: const TextStyle(color: Color(0x66FFFFFF)),
                    filled: true, fillColor: const Color(0x0DFFFFFF),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0x33FFFFFF))),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0x33FFFFFF))),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.green)),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('📸 Foto / Print (opcional)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
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
                            final picked = await picker.pickImage(source: ImageSource.gallery, maxWidth: 1024, maxHeight: 1024, imageQuality: 70);
                            if (picked != null) {
                              final file = File(picked.path);
                              final bytes = await file.readAsBytes();
                              setModalState(() { evidencePhoto = file; evidenceBase64 = base64Encode(bytes); });
                            }
                          },
                          icon: const Icon(Icons.photo_library, size: 18),
                          label: const Text('Galeria'),
                          style: OutlinedButton.styleFrom(foregroundColor: Colors.green, side: const BorderSide(color: Colors.green)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final picker = ImagePicker();
                            final picked = await picker.pickImage(source: ImageSource.camera, maxWidth: 1024, maxHeight: 1024, imageQuality: 70);
                            if (picked != null) {
                              final file = File(picked.path);
                              final bytes = await file.readAsBytes();
                              setModalState(() { evidencePhoto = file; evidenceBase64 = base64Encode(bytes); });
                            }
                          },
                          icon: const Icon(Icons.camera_alt, size: 18),
                          label: const Text('Câmera'),
                          style: OutlinedButton.styleFrom(foregroundColor: Colors.green, side: const BorderSide(color: Colors.green)),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 20),
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
                          senderRole: 'provider',
                          imageBase64: evidenceBase64,
                          description: descController.text.trim(),
                        );
                        
                        if (mounted) {
                          Navigator.pop(context);
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(success ? '✅ Evidência enviada! O mediador irá analisar.' : '❌ Erro ao enviar'),
                            backgroundColor: success ? Colors.green : Colors.red,
                          ));
                        }
                      } catch (e) {
                        setModalState(() => sending = false);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erro: $e'), backgroundColor: Colors.red));
                        }
                      }
                    },
                    icon: sending
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.send),
                    label: Text(sending ? 'Enviando...' : (evidenceBase64 != null ? 'Enviar Evidência' : 'Enviar Mensagem')),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
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
