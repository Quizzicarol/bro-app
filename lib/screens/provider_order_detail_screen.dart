import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:bro_app/services/log_utils.dart';
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
import '../l10n/app_localizations.dart';

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
  
  // v338: Regeneração de invoice pós-disputa
  bool _isRegeneratingInvoice = false;
  
  // v237: Mensagens do mediador para o provedor
  List<Map<String, dynamic>> _providerMediatorMessages = [];
  bool _loadingProviderMediatorMessages = false;
  
  // Timer de 36h para auto-liquidação
  Duration? _timeRemaining;
  DateTime? _receiptSubmittedAt;
  
  // Comprovante buscado do Nostr (descriptografado)
  String? _providerProofImage;
  
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
      _fetchProviderProofImage();
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
        broLog('✅ Provider: resolução encontrada para ${widget.orderId.substring(0, 8)}');
      }
    } catch (e) {
      broLog('⚠️ Provider: erro ao buscar resolução: $e');
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
          broLog('📨 Provider: ${messages.length} mensagens do mediador para ordem ${widget.orderId.substring(0, 8)}');
        }
      }
    } catch (e) {
      broLog('⚠️ Provider: erro ao buscar mensagens do mediador: $e');
      if (mounted) setState(() => _loadingProviderMediatorMessages = false);
    }
  }
  
  /// Busca comprovante do provedor via Nostr para exibição local
  Future<void> _fetchProviderProofImage() async {
    try {
      final orderProvider = context.read<OrderProvider>();
      final providerPrivKey = orderProvider.nostrPrivateKey;
      if (providerPrivKey == null || providerPrivKey.isEmpty) return;
      
      final nostrService = NostrOrderService();
      final result = await nostrService.fetchProofForOrder(
        widget.orderId,
        providerPubkey: widget.providerId.isNotEmpty ? widget.providerId : null,
        privateKey: providerPrivKey,
      );
      
      final proof = result['proofImage'] as String?;
      final encrypted = result['encrypted'] as bool? ?? false;
      
      if (mounted && proof != null && proof.isNotEmpty && !encrypted) {
        setState(() => _providerProofImage = proof);
        broLog('✅ Comprovante do provedor obtido do Nostr para exibição');
      }
    } catch (e) {
      broLog('⚠️ Erro ao buscar comprovante do provedor: $e');
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
        broLog('🔄 [POLLING] Verificando status da ordem ${widget.orderId.substring(0, 8)}...');
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
          broLog('🎉 [POLLING] Ordem ${newStatus}! Parando polling.');
          timer.cancel();
          
          // Mostrar notificação ao Bro
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(newStatus == 'completed' 
                    ? AppLocalizations.of(context)!.t('prov_det_user_confirmed') 
                    : AppLocalizations.of(context)!.t('prov_det_auto_settled')),
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
    
    broLog('🔵 [LOAD] _loadOrderDetails INICIADO (forceSync=$forceSync, _orderDetails=${_orderDetails != null ? "set" : "null"})');
    
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
        broLog('🔄 [SYNC] Sincronizando com Nostr para buscar updates...');
        await orderProvider.syncOrdersFromNostr().timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            broLog('⏱️ [SYNC] Timeout - continuando com dados locais');
          },
        );
      }
      
      broLog('🔵 [LOAD] Chamando getOrder(${widget.orderId.substring(0, 8)})...');
      final order = await orderProvider.getOrder(widget.orderId);
      
      broLog('🔍 _loadOrderDetails: ordem carregada = ${order != null ? "OK (status=${order['status']})" : "NULL"}');
      broLog('🔍 _loadOrderDetails: billCode = ${order?['billCode'] != null && (order!['billCode'] as String).isNotEmpty ? "present (${(order['billCode'] as String).length} chars)" : "EMPTY"}');

      // FIX: Se billCode está vazio/encrypted e a ordem foi aceita,
      // buscar do Nostr onde o evento republished tem billCode_nip44_provider
      if (order != null) {
        final currentBillCode = order['billCode'] as String? ?? '';
        final currentStatus = order['status'] as String? ?? 'pending';
        if ((currentBillCode.isEmpty || currentBillCode == '[encrypted]') &&
            currentStatus != 'pending') {
          broLog('🔄 billCode vazio/encrypted — buscando do Nostr para descriptografia...');
          try {
            final nostrService = NostrOrderService();
            final nostrOrder = await nostrService.fetchOrderFromNostr(widget.orderId).timeout(
              const Duration(seconds: 10),
              onTimeout: () => null,
            );
            if (nostrOrder != null) {
              final nostrBillCode = nostrOrder['billCode'] as String? ?? '';
              if (nostrBillCode.isNotEmpty && nostrBillCode != '[encrypted]') {
                order['billCode'] = nostrBillCode;
                broLog('✅ billCode obtido do Nostr: ${nostrBillCode.length} chars');
              }
            }
          } catch (e) {
            broLog('⚠️ Falha ao buscar billCode do Nostr: $e');
          }
        }
      }

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
          
          broLog('🔍 _orderAccepted calc: hasAdvancedStatus=$hasAdvancedStatus, hasValidProviderId=$hasValidProviderId, result=$_orderAccepted');
          
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
              broLog('⏱️ Timer 36h: prazo=${deadline.toIso8601String()}, restante=${_timeRemaining?.inHours ?? 0}h ${(_timeRemaining?.inMinutes.abs() ?? 0) % 60}m');
            }
          } else {
            broLog('⚠️ Nenhum timestamp de comprovante encontrado');
          }
          
          broLog('🔍 Ordem ${widget.orderId.substring(0, 8)}: status=$orderStatus, providerId=$orderProviderId, _orderAccepted=$_orderAccepted');
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
    
    broLog('🔵 [ACCEPT] _acceptOrder INICIADO para ordem ${widget.orderId.substring(0, 8)}');
    
    // PROTEÇÃO CRÍTICA: Verificar se ordem já foi aceita
    final currentStatus = _orderDetails?['status'] ?? 'pending';
    final currentProviderId = _orderDetails?['providerId'] ?? _orderDetails?['provider_id'];
    
    broLog('🔵 [ACCEPT] Status atual: $currentStatus, providerId: $currentProviderId, _orderAccepted: $_orderAccepted');
    
    if (currentStatus != 'pending' && currentStatus != 'payment_received') {
      broLog('🚫 BLOQUEIO DE SEGURANÇA: Tentativa de aceitar ordem com status=$currentStatus');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.tp('prov_det_already_status', {'status': currentStatus})),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    
    if (_orderAccepted) {
      broLog('🚫 BLOQUEIO DE SEGURANÇA: Ordem já marcada como aceita localmente');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.t('prov_det_already_accepted')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    
    if (currentProviderId != null && currentProviderId.isNotEmpty) {
      broLog('🚫 BLOQUEIO DE SEGURANÇA: Ordem já tem providerId=$currentProviderId');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.t('prov_det_accepted_other')),
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
                children: [
                  const Icon(Icons.warning_amber, color: Colors.orange),
                  const SizedBox(width: 8),
                  Text(AppLocalizations.of(context)!.t('prov_det_old_order'), style: TextStyle(color: Colors.white)),
                ],
              ),
              content: Text(
                AppLocalizations.of(context)!.tp('prov_det_old_order_msg', {'hours': orderAge.inHours.toString()}),
                style: const TextStyle(color: Colors.white70),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(AppLocalizations.of(context)!.t('cancel')),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
                  child: Text(AppLocalizations.of(context)!.t('prov_det_accept_anyway')),
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
        _showError(AppLocalizations.of(context)!.t('prov_det_insufficient_collateral'));
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
          broLog('⏱️ [ACCEPT] TIMEOUT GLOBAL de 45s atingido!');
          throw TimeoutException('Tempo esgotado ao aceitar ordem (45s)');
        },
      );
    } catch (e) {
      broLog('❌ [ACCEPT] ERRO: $e');
      _showError('Erro ao aceitar ordem: $e');
    } finally {
      // GARANTIA: _isAccepting SEMPRE é resetado
      if (mounted && _isAccepting) {
        broLog('🔵 [ACCEPT] Resetando _isAccepting no finally');
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
        broLog('🔵 [ACCEPT] Bloqueando garantia (tier=${currentTier.id})...');
        await _escrowService.lockCollateral(
          providerId: widget.providerId,
          orderId: widget.orderId,
          lockedSats: (orderAmount * 1000).round(),
        );
        broLog('🔵 [ACCEPT] Garantia bloqueada OK');
      } else {
        broLog('⚠️ [ACCEPT] Sem tier ativo — pulando lockCollateral');
      }
    }

    // Publicar aceitação no Nostr E atualizar localmente
    // Retry automático: até 2 tentativas se falhar
    broLog('🔵 [ACCEPT] Publicando aceitação no Nostr...');
    final orderProvider = context.read<OrderProvider>();
    
    bool success = false;
    for (int attempt = 1; attempt <= 2; attempt++) {
      broLog('🔵 [ACCEPT] Tentativa $attempt/2...');
      success = await orderProvider.acceptOrderAsProvider(widget.orderId);
      if (success) break;
      if (attempt < 2) {
        broLog('⚠️ [ACCEPT] Tentativa $attempt falhou, retentando em 2s...');
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    
    broLog('🔵 [ACCEPT] Resultado final: success=$success');
    
    if (!success) {
      _showError(AppLocalizations.of(context)!.t('prov_det_publish_fail'));
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
        SnackBar(
          content: Text(AppLocalizations.of(context)!.t('prov_det_accepted_pay')),
          backgroundColor: Colors.green,
        ),
      );
    }

    broLog('🔵 [ACCEPT] Recarregando detalhes da ordem...');
    await _loadOrderDetails();
    broLog('🔵 [ACCEPT] Ordem aceita e detalhes carregados com sucesso!');
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
      _showError(AppLocalizations.of(context)!.tp('prov_det_error_select_image', {'error': e.toString()}));
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
      _showError(AppLocalizations.of(context)!.tp('prov_det_error_take_photo', {'error': e.toString()}));
    }
  }

  Future<void> _uploadReceipt() async {
    // Verificar se tem imagem OU código
    if (_receiptImage == null && _confirmationCodeController.text.trim().isEmpty) {
      _showError(AppLocalizations.of(context)!.t('prov_det_select_receipt'));
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
      _showError(AppLocalizations.of(context)!.tp('prov_det_error_send_receipt', {'error': e.toString()}));
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
      
      broLog('💰 Ordem: R\$ ${amount.toStringAsFixed(2)} = $totalSats sats');
      broLog('💰 Provedor vai receber: $providerReceiveSats sats (valor total da ordem)');
      
      String? generatedInvoice;
      
      // Gerar invoice Lightning para receber o pagamento (apenas se taxa > 0)
      // IMPORTANTE: Usar BreezProvider direto pois é o que está inicializado pelo login
      final breezProvider = context.read<BreezProvider>();
      final liquidProvider = context.read<BreezLiquidProvider>();
      
      // DEBUG: Verificar estado das carteiras
      broLog('🔍 DEBUG INVOICE GENERATION:');
      broLog('   breezProvider.isInitialized: ${breezProvider.isInitialized}');
      broLog('   liquidProvider.isInitialized: ${liquidProvider.isInitialized}');
      broLog('   providerReceiveSats: $providerReceiveSats');
      
      // Só gerar invoice se o valor for maior que 0
      if (providerReceiveSats > 0 && breezProvider.isInitialized) {
        broLog('⚡ Gerando invoice de $providerReceiveSats sats via Breez Spark...');
        
        try {
          final result = await breezProvider.createInvoice(
            amountSats: providerReceiveSats,
            description: 'Bro - Ordem ${widget.orderId.substring(0, 8)}',
          ).timeout(const Duration(seconds: 30));
          
          if (result != null && result['bolt11'] != null) {
            generatedInvoice = result['bolt11'] as String;
            broLog('✅ Invoice gerado via Spark: ${generatedInvoice.substring(0, 30)}...');
          } else {
            broLog('⚠️ Falha ao gerar invoice via Spark: $result');
          }
        } catch (e) {
          broLog('⚠️ Erro/timeout ao gerar invoice Spark: $e — continuando sem invoice');
        }
      } else if (providerReceiveSats > 0 && liquidProvider.isInitialized) {
        broLog('⚡ Gerando invoice de $providerReceiveSats sats via Liquid (fallback)...');
        
        try {
          final result = await liquidProvider.createInvoice(
            amountSats: providerReceiveSats,
            description: 'Bro - Ordem ${widget.orderId.substring(0, 8)}',
          ).timeout(const Duration(seconds: 30));
          
          if (result != null && result['bolt11'] != null) {
            generatedInvoice = result['bolt11'] as String;
            broLog('✅ Invoice gerado via Liquid: ${generatedInvoice.substring(0, 30)}...');
          } else {
            broLog('⚠️ Falha ao gerar invoice via Liquid: $result');
          }
        } catch (e) {
          broLog('⚠️ Erro/timeout ao gerar invoice Liquid: $e — continuando sem invoice');
        }
      } else if (providerReceiveSats <= 0) {
        broLog('ℹ️ providerReceiveSats=$providerReceiveSats (muito baixo), não gerando invoice');
      } else {
        broLog('🚨 NENHUMA CARTEIRA INICIALIZADA! breez=${breezProvider.isInitialized}, liquid=${liquidProvider.isInitialized}');
      }

      broLog('📋 Resumo: providerReceiveSats=$providerReceiveSats, hasInvoice=${generatedInvoice != null}');
      if (generatedInvoice != null) {
        broLog('   Invoice: ${generatedInvoice.substring(0, 50)}...');
      }

      // CRÍTICO: Se não gerou invoice e há sats a receber, bloquear
      if (generatedInvoice == null && providerReceiveSats > 0) {
        broLog('🚨 BLOQUEANDO: Sem invoice gerado para receber $providerReceiveSats sats!');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context)!.t('prov_det_wallet_not_connected')),
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
        broLog('📤 [UPLOAD] Tentativa $attempt/2 de publicar comprovante...');
        success = await orderProvider.completeOrderAsProvider(
          widget.orderId, 
          proofImageBase64.isNotEmpty ? proofImageBase64 : confirmationCode,
          providerInvoice: generatedInvoice,
          e2eId: e2eId.isNotEmpty ? e2eId : null, // v236
        );
        if (success) break;
        if (attempt < 2) {
          broLog('⚠️ [UPLOAD] Tentativa $attempt falhou, retentando em 3s...');
          await Future.delayed(const Duration(seconds: 3));
        }
      }
      
      if (!success) {
        _showError(AppLocalizations.of(context)!.t('prov_det_publish_receipt_fail'));
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
              content: Text(AppLocalizations.of(context)!.tp('prov_det_receipt_sent_sats', {'sats': providerReceiveSats.toString()})),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 4),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context)!.t('prov_det_receipt_no_wallet')),
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
      _showError(AppLocalizations.of(context)!.tp('prov_det_error_send_receipt', {'error': e.toString()}));
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
        title: Text(AppLocalizations.of(context)!.t('prov_det_title')),
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator(color: Color(0xFFFF6B6B)))
            : _error != null
                ? _buildErrorView()
                : _orderDetails == null
                    ? Center(child: Text(AppLocalizations.of(context)!.t('prov_det_order_not_found'), style: const TextStyle(color: Colors.white70)))
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
              child: Text(AppLocalizations.of(context)!.t('prov_det_try_again')),
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
    broLog('🔍 _buildContent: billType=$billType, status=$status, billCode=${billCode.isNotEmpty ? "${billCode.substring(0, billCode.length > 20 ? 20 : billCode.length)}..." : "EMPTY"}');
    
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
      broLog('✅ paymentData criado: ${paymentData.keys}');
    } else {
      // Fallback: tentar usar payment_data existente
      paymentData = _orderDetails!['payment_data'] as Map<String, dynamic>?;
      broLog('⚠️ billCode vazio, usando payment_data existente: $paymentData');
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
              // v338: Botão para regenerar invoice se disputa foi a favor do provedor
              if (_disputeResolution!['resolution'] == 'resolved_provider') ...[
                const SizedBox(height: 10),
                _buildRegenerateInvoiceButton(),
              ],
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
              // v338: Botão para regenerar invoice se disputa foi a favor do provedor
              if (_disputeResolution!['resolution'] == 'resolved_provider') ...[
                const SizedBox(height: 10),
                _buildRegenerateInvoiceButton(),
              ],
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
                            AppLocalizations.of(context)!.tp('prov_det_mediator_msgs', {'count': _providerMediatorMessages.length.toString()}),
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
                                  Text(AppLocalizations.of(context)!.t('prov_det_mediator'), style: const TextStyle(color: Colors.purple, fontSize: 11, fontWeight: FontWeight.bold)),
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
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.purple)),
                      const SizedBox(width: 10),
                      Text(AppLocalizations.of(context)!.t('prov_det_fetching_msgs'), style: TextStyle(color: Colors.white38, fontSize: 12)),
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
                    label: Text(AppLocalizations.of(context)!.t('prov_det_reply_mediator')),
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
                  label: Text(AppLocalizations.of(context)!.t('prov_det_send_evidence')),
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
    final proofImage = _providerProofImage ?? metadata?['paymentProof'] as String?;
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
                isLiquidated ? AppLocalizations.of(context)!.t('prov_det_auto_settled_title') : AppLocalizations.of(context)!.t('prov_det_completed_title'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                isLiquidated 
                    ? AppLocalizations.of(context)!.t('prov_det_no_confirm_36h')
                    : AppLocalizations.of(context)!.t('prov_det_user_confirmed_msg'),
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
                    AppLocalizations.of(context)!.tp('prov_det_order_id', {'id': widget.orderId.length > 8 ? widget.orderId.substring(0, 8) : widget.orderId}),
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
              Text(
                AppLocalizations.of(context)!.t('prov_det_financial_summary'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              _buildFinancialRow(AppLocalizations.of(context)!.t('prov_det_bill_value'), 'R\$ ${amount.toStringAsFixed(2)}', Colors.white70),
              const SizedBox(height: 8),
              _buildFinancialRow(AppLocalizations.of(context)!.t('prov_det_type'), billType.toUpperCase(), Colors.orange),
              const SizedBox(height: 8),
              const Divider(color: Colors.white24),
              const SizedBox(height: 8),
              _buildFinancialRow(
                AppLocalizations.of(context)!.tp('prov_det_your_earning', {'percent': EscrowService.providerFeePercent.toString()}), 
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
          Text(
            AppLocalizations.of(context)!.t('prov_det_steps_completed'),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          _buildTimelineStep(AppLocalizations.of(context)!.t('prov_det_step_created'), true, isFirst: true),
          _buildTimelineStep(AppLocalizations.of(context)!.t('prov_det_step_accepted'), true),
          _buildTimelineStep(AppLocalizations.of(context)!.t('prov_det_step_paid'), true),
          _buildTimelineStep(AppLocalizations.of(context)!.t('prov_det_step_receipt'), true),
          _buildTimelineStep(AppLocalizations.of(context)!.t('prov_det_step_confirmed'), true, isLast: true),
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
        label: Text(AppLocalizations.of(context)!.t('prov_det_view_receipt')),
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
      final screenHeight = MediaQuery.of(context).size.height;
      showDialog(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: const Color(0xFF1A1A1A),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: screenHeight * 0.85),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppBar(
                  backgroundColor: Colors.transparent,
                  title: Text(AppLocalizations.of(context)!.t('prov_det_receipt_title')),
                  leading: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(
                        imageBytes,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => Center(
                          child: Text(AppLocalizations.of(context)!.t('prov_det_image_error'),
                              style: TextStyle(color: Colors.white70)),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context)!.t('prov_det_error_load_receipt'))),
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
              Text(
                AppLocalizations.of(context)!.t('prov_det_bill_value2'),
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
                  Text(
                    AppLocalizations.of(context)!.t('prov_det_your_fee'),
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
                  Text(
                    AppLocalizations.of(context)!.t('prov_det_you_receive'),
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
      return AppLocalizations.of(context)!.t('prov_det_see_code_below');
    }
    // Se for curto, provavelmente é a própria chave
    if (pixCode.length < 50) {
      return pixCode;
    }
    return AppLocalizations.of(context)!.t('prov_det_see_code_below');
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
                      AppLocalizations.of(context)!.t('prov_det_mediator_decision'),
                      style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold,
                        color: isProviderFavor ? Colors.green : Colors.orange,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isProviderFavor
                          ? AppLocalizations.of(context)!.t('prov_det_resolved_your_favor')
                          : AppLocalizations.of(context)!.t('prov_det_resolved_user_favor'),
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
                  Text(AppLocalizations.of(context)!.t('prov_det_mediator_msg'), style: TextStyle(color: Colors.white54, fontSize: 11)),
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

  /// v338: Botão para o provedor regenerar invoice quando o original expirou
  Widget _buildRegenerateInvoiceButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _isRegeneratingInvoice ? null : _handleRegenerateInvoice,
        icon: _isRegeneratingInvoice
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.refresh),
        label: Text(_isRegeneratingInvoice ? AppLocalizations.of(context)!.t('prov_det_generating_invoice') : AppLocalizations.of(context)!.t('prov_det_generate_invoice')),
        style: ElevatedButton.styleFrom(
          backgroundColor: _isRegeneratingInvoice ? Colors.grey : Colors.green,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  /// v338: Gera novo invoice Lightning e publica no Nostr para substituir o expirado
  Future<void> _handleRegenerateInvoice() async {
    if (_isRegeneratingInvoice) return;
    setState(() => _isRegeneratingInvoice = true);

    try {
      final breezProvider = context.read<BreezProvider>();
      final liquidProvider = context.read<BreezLiquidProvider>();
      final orderProvider = context.read<OrderProvider>();

      // Calcular valor em sats
      final order = orderProvider.getOrderById(widget.orderId);
      final totalSats = order?.btcAmount.round() ?? 0;

      if (totalSats <= 0) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context)!.t('prov_det_invalid_amount')), backgroundColor: Colors.red),
          );
        }
        setState(() => _isRegeneratingInvoice = false);
        return;
      }

      String? newInvoice;

      if (breezProvider.isInitialized) {
        broLog('⚡ [RegenInvoice] Gerando invoice de $totalSats sats via Spark...');
        final result = await breezProvider.createInvoice(
          amountSats: totalSats,
          description: 'Bro - Ordem ${widget.orderId.substring(0, 8)} (novo)',
        ).timeout(const Duration(seconds: 30));
        if (result != null && result['bolt11'] != null) {
          newInvoice = result['bolt11'] as String;
        }
      } else if (liquidProvider.isInitialized) {
        broLog('⚡ [RegenInvoice] Gerando invoice de $totalSats sats via Liquid...');
        final result = await liquidProvider.createInvoice(
          amountSats: totalSats,
          description: 'Bro - Ordem ${widget.orderId.substring(0, 8)} (novo)',
        ).timeout(const Duration(seconds: 30));
        if (result != null && result['bolt11'] != null) {
          newInvoice = result['bolt11'] as String;
        }
      }

      if (newInvoice == null || newInvoice.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(AppLocalizations.of(context)!.t('prov_det_wallet_not_connected2')), backgroundColor: Colors.red),
          );
        }
        setState(() => _isRegeneratingInvoice = false);
        return;
      }

      broLog('✅ [RegenInvoice] Novo invoice gerado: ${newInvoice.substring(0, 30)}...');

      // Publicar novo evento COMPLETE no Nostr com o invoice atualizado
      final success = await orderProvider.completeOrderAsProvider(
        widget.orderId,
        'invoice_regenerated', // proof placeholder — não é um novo comprovante
        providerInvoice: newInvoice,
      );

      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.t('prov_det_new_invoice_published')),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 5),
          ),
        );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.t('prov_det_invoice_publish_fail')), backgroundColor: Colors.orange),
        );
      }
    } catch (e) {
      broLog('❌ [RegenInvoice] Erro: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.tp('prov_det_error_generic', {'error': e.toString()})), backgroundColor: Colors.red),
        );
      }
    }

    if (mounted) setState(() => _isRegeneratingInvoice = false);
  }

  Map<String, dynamic> _getStatusInfo(String status) {
    switch (status) {
      case 'pending':
        return {
          'title': AppLocalizations.of(context)!.t('prov_det_status_waiting'),
          'description': AppLocalizations.of(context)!.t('prov_det_status_waiting_desc'),
          'icon': Icons.pending_outlined,
          'color': Colors.orange,
        };
      case 'accepted':
        return {
          'title': AppLocalizations.of(context)!.t('prov_det_status_accepted'),
          'description': AppLocalizations.of(context)!.t('prov_det_status_accepted_desc'),
          'icon': Icons.check_circle_outline,
          'color': Colors.blue,
        };
      case 'payment_submitted':
      case 'awaiting_confirmation':
        return {
          'title': AppLocalizations.of(context)!.t('prov_det_status_receipt_sent'),
          'description': AppLocalizations.of(context)!.t('prov_det_status_receipt_desc'),
          'icon': Icons.hourglass_empty,
          'color': Colors.purple,
        };
      case 'disputed':
        // v233: Se há resolução, mostrar como resolvida mesmo que status ainda seja 'disputed'
        if (_disputeResolution != null) {
          final isProviderFavor = _disputeResolution!['resolution'] == 'resolved_provider';
          return {
            'title': AppLocalizations.of(context)!.t('prov_det_status_mediated'),
            'description': isProviderFavor
                ? AppLocalizations.of(context)!.t('prov_det_status_mediated_favor')
                : AppLocalizations.of(context)!.t('prov_det_status_mediated_user'),
            'icon': Icons.gavel,
            'color': isProviderFavor ? Colors.green : Colors.orange,
          };
        }
        return {
          'title': AppLocalizations.of(context)!.t('prov_det_status_dispute'),
          'description': AppLocalizations.of(context)!.t('prov_det_status_dispute_desc'),
          'icon': Icons.gavel,
          'color': Colors.orange,
        };
      case 'liquidated':
        return {
          'title': AppLocalizations.of(context)!.t('prov_det_status_settled'),
          'description': AppLocalizations.of(context)!.t('prov_det_status_settled_desc'),
          'icon': Icons.electric_bolt,
          'color': Colors.purple,
        };
      case 'confirmed':
      case 'completed':
        if (_disputeResolution != null) {
          final isProviderFavor = _disputeResolution!['resolution'] == 'resolved_provider';
          return {
            'title': AppLocalizations.of(context)!.t('prov_det_status_mediated'),
            'description': isProviderFavor
                ? AppLocalizations.of(context)!.t('prov_det_status_mediated_favor')
                : AppLocalizations.of(context)!.t('prov_det_status_mediated_user'),
            'icon': Icons.gavel,
            'color': isProviderFavor ? Colors.green : Colors.orange,
          };
        }
        return {
          'title': AppLocalizations.of(context)!.t('prov_det_status_confirmed'),
          'description': AppLocalizations.of(context)!.t('prov_det_status_confirmed_desc'),
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
                  AppLocalizations.of(context)!.t('prov_det_pay_bill'),
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
            isPix ? AppLocalizations.of(context)!.t('prov_det_copy_pix') 
                  : AppLocalizations.of(context)!.t('prov_det_copy_barcode'),
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 16),
          const Divider(color: Colors.white12),
          const SizedBox(height: 16),
          
          if (isPix) ...[
            // Mostrar chave PIX se não for "Ver código abaixo"
            if (data['pix_key'] != null && data['pix_key'] != 'Ver código abaixo')
              _buildPaymentField(AppLocalizations.of(context)!.t('prov_det_pix_key'), data['pix_key'] as String),
            if (data['pix_name'] != null)
              _buildPaymentField(AppLocalizations.of(context)!.t('prov_det_name'), data['pix_name'] as String),
            // SEMPRE mostrar o código PIX se existir
            if (data['pix_code'] != null) ...[
              const SizedBox(height: 12),
              _buildCopyableField(AppLocalizations.of(context)!.t('prov_det_pix_code'), data['pix_code'] as String),
            ],
          ] else ...[
            // Boleto
            if (data['bank'] != null)
              _buildPaymentField(AppLocalizations.of(context)!.t('prov_det_bank'), data['bank'] as String),
            // SEMPRE mostrar o código de barras se existir
            if (data['barcode'] != null) ...[
              const SizedBox(height: 12),
              _buildCopyableField(AppLocalizations.of(context)!.t('prov_det_barcode'), data['barcode'] as String),
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
                    SnackBar(content: Text(AppLocalizations.of(context)!.t('prov_det_copied'))),
                  );
                },
                tooltip: AppLocalizations.of(context)!.t('prov_det_copy'),
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
      broLog('🚫 _buildAcceptButton: Botão oculto porque _orderAccepted=true');
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.orange.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.orange.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.orange),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                AppLocalizations.of(context)!.t('prov_det_already_accepted_msg'),
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
        label: Text(_isAccepting ? AppLocalizations.of(context)!.t('prov_det_accepting') : AppLocalizations.of(context)!.t('prov_det_accept_order')),
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
    final proofImage = _providerProofImage ?? metadata?['paymentProof'] as String?;
    
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
                AppLocalizations.of(context)!.t('prov_det_waiting_user'),
                style: TextStyle(
                  color: isExpiringSoon ? Colors.red : Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                AppLocalizations.of(context)!.t('prov_det_user_confirm_msg'),
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
                    AppLocalizations.of(context)!.tp('prov_det_order_id', {'id': widget.orderId.length > 8 ? widget.orderId.substring(0, 8) : widget.orderId}),
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
              Text(
                AppLocalizations.of(context)!.t('prov_det_you_will_receive'),
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
                  Text(AppLocalizations.of(context)!.t('prov_det_bill_value'), style: const TextStyle(color: Colors.white60, fontSize: 14)),
                  Text('R\$ ${amount.toStringAsFixed(2)}', style: const TextStyle(color: Colors.white70, fontSize: 14)),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(AppLocalizations.of(context)!.tp('prov_det_your_earning2', {'percent': EscrowService.providerFeePercent.toString()}), style: const TextStyle(color: Colors.white60, fontSize: 14)),
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
                    ? AppLocalizations.of(context)!.t('prov_det_auto_settling')
                    : AppLocalizations.of(context)!.tp('prov_det_time_remaining', {'hours': hoursRemaining.toString(), 'minutes': minutesRemaining.toString()}),
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
              label: Text(AppLocalizations.of(context)!.t('prov_det_view_receipt')),
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
            children: [
              const Icon(Icons.info_outline, color: Color(0xFF4CAF50), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  AppLocalizations.of(context)!.t('prov_det_auto_settle_tip'),
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
            label: Text(AppLocalizations.of(context)!.t('prov_det_open_dispute')),
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
      broLog('🔄 Executando auto-liquidação para ordem ${widget.orderId}');
      
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
            SnackBar(
              content: Text(AppLocalizations.of(context)!.t('prov_det_auto_settle_done')),
              backgroundColor: Colors.green,
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context)!.t('prov_det_auto_settle_error')),
              backgroundColor: Colors.orange,
            ),
          );
        }
        
        // Recarregar detalhes
        await _loadOrderDetails();
      }
    } catch (e) {
      broLog('❌ Erro na auto-liquidação: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context)!.tp('prov_det_auto_settle_error2', {'error': e.toString()}))),
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
        title: Row(
          children: [
            const Icon(Icons.gavel, color: Color(0xFFFF6B6B)),
            const SizedBox(width: 12),
            Text(AppLocalizations.of(context)!.t('prov_det_open_dispute'), style: TextStyle(color: Colors.white)),
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
                      AppLocalizations.of(context)!.t('prov_det_when_dispute'),
                      style: TextStyle(
                        color: Color(0xFFFF6B6B),
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      AppLocalizations.of(context)!.t('prov_det_dispute_reasons'),
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
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, color: Color(0xFF4CAF50), size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        AppLocalizations.of(context)!.t('prov_det_auto_settle_reminder'),
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
            child: Text(AppLocalizations.of(context)!.t('cancel'), style: const TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _openProviderDisputeForm();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF6B6B),
            ),
            child: Text(AppLocalizations.of(context)!.t('prov_det_continue'), style: const TextStyle(color: Colors.white)),
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
                Text(
                  AppLocalizations.of(context)!.t('prov_det_dispute_form'),
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  AppLocalizations.of(context)!.tp('prov_det_order_label', {'id': widget.orderId.substring(0, 8)}),
                  style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 14),
                ),
                const SizedBox(height: 20),
                Text(
                  AppLocalizations.of(context)!.t('prov_det_dispute_reason'),
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                ...[
                  AppLocalizations.of(context)!.t('prov_det_reason_no_confirm'),
                  AppLocalizations.of(context)!.t('prov_det_reason_not_received'),
                  AppLocalizations.of(context)!.t('prov_det_reason_payment_issue'),
                  AppLocalizations.of(context)!.t('prov_det_reason_no_response'),
                  AppLocalizations.of(context)!.t('prov_det_reason_other')
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
                  AppLocalizations.of(context)!.t('prov_det_describe_problem'),
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
                    hintText: AppLocalizations.of(context)!.t('prov_det_explain_detail'),
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
                    child: Text(
                      AppLocalizations.of(context)!.t('prov_det_send_dispute'),
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
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        content: Row(
          children: [
            const CircularProgressIndicator(color: Color(0xFFFF6B6B)),
            const SizedBox(width: 16),
            Text(AppLocalizations.of(context)!.t('prov_det_sending_dispute'), style: const TextStyle(color: Colors.white)),
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
          broLog('📤 Disputa do provedor publicada no Nostr');
        }
      } catch (e) {
        broLog('⚠️ Erro ao publicar disputa no Nostr: $e');
      }

      if (mounted) {
        Navigator.pop(context); // Fechar loading
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.t('prov_det_dispute_opened')),
            backgroundColor: const Color(0xFFFF6B6B),
            duration: const Duration(seconds: 4),
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
            content: Text(AppLocalizations.of(context)!.tp('prov_det_error_open_dispute', {'error': e.toString()})),
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
          Text(
            AppLocalizations.of(context)!.t('prov_det_send_receipt_title'),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            AppLocalizations.of(context)!.t('prov_det_receipt_instructions'),
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 16),
          
          // Campo de código de confirmação
          TextField(
            controller: _confirmationCodeController,
            decoration: InputDecoration(
              labelText: AppLocalizations.of(context)!.t('prov_det_confirm_code'),
              hintText: AppLocalizations.of(context)!.t('prov_det_confirm_code_hint'),
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
              labelText: AppLocalizations.of(context)!.t('prov_det_e2e_code'),
              hintText: AppLocalizations.of(context)!.t('prov_det_e2e_hint'),
              helperText: AppLocalizations.of(context)!.t('prov_det_e2e_helper'),
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
            Text(
              AppLocalizations.of(context)!.t('prov_det_receipt_attached'),
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
                    label: Text(AppLocalizations.of(context)!.t('prov_det_change_photo')),
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
                    label: Text(AppLocalizations.of(context)!.t('prov_det_remove')),
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
              children: [
                const Icon(Icons.privacy_tip, color: Colors.orange, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    AppLocalizations.of(context)!.t('prov_det_privacy_warning'),
                    style: TextStyle(color: Colors.orange, fontSize: 12, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          
          Text(
              AppLocalizations.of(context)!.t('prov_det_attach_receipt'),
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickReceipt,
                    icon: const Icon(Icons.photo_library, color: Colors.orange),
                    label: Text(AppLocalizations.of(context)!.t('prov_det_gallery')),
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
                    label: Text(AppLocalizations.of(context)!.t('prov_det_camera')),
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
              label: Text(_isUploading ? AppLocalizations.of(context)!.t('prov_det_sending') : AppLocalizations.of(context)!.t('prov_det_send_receipt')),
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
                Text(AppLocalizations.of(context)!.t('prov_det_evidence_title'), style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(AppLocalizations.of(context)!.tp('prov_det_order_label', {'id': widget.orderId.substring(0, 8)}), style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 14)),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.green.withOpacity(0.2)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(AppLocalizations.of(context)!.t('prov_det_accepted_evidence'), style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 13)),
                      SizedBox(height: 6),
                      Text(AppLocalizations.of(context)!.t('prov_det_evidence_e2e'), style: TextStyle(color: Colors.white70, fontSize: 12)),
                      SizedBox(height: 3),
                      Text(AppLocalizations.of(context)!.t('prov_det_evidence_registrato'), style: TextStyle(color: Colors.white70, fontSize: 12)),
                      SizedBox(height: 3),
                      Text(AppLocalizations.of(context)!.t('prov_det_evidence_site'), style: TextStyle(color: Colors.white70, fontSize: 12)),
                      SizedBox(height: 3),
                      Text(AppLocalizations.of(context)!.t('prov_det_evidence_any'), style: TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(AppLocalizations.of(context)!.t('prov_det_evidence_desc'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                TextField(
                  controller: descController,
                  maxLines: 3,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: AppLocalizations.of(context)!.t('prov_det_explain_evidence'),
                    hintStyle: const TextStyle(color: Color(0x66FFFFFF)),
                    filled: true, fillColor: const Color(0x0DFFFFFF),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0x33FFFFFF))),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0x33FFFFFF))),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.green)),
                  ),
                ),
                const SizedBox(height: 16),
                Text(AppLocalizations.of(context)!.t('prov_det_evidence_photo'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
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
                          label: Text(AppLocalizations.of(context)!.t('prov_det_gallery')),
                          style: OutlinedButton.styleFrom(foregroundColor: Colors.green, side: const BorderSide(color: Colors.green)),
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
                          label: Text(AppLocalizations.of(context)!.t('prov_det_camera')),
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
                            content: Text(success ? AppLocalizations.of(context)!.t('prov_det_evidence_sent') : AppLocalizations.of(context)!.t('prov_det_evidence_error')),
                            backgroundColor: success ? Colors.green : Colors.red,
                          ));
                        }
                      } catch (e) {
                        setModalState(() => sending = false);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppLocalizations.of(context)!.tp('prov_det_error_generic', {'error': e.toString()})), backgroundColor: Colors.red));
                        }
                      }
                    },
                    icon: sending
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.send),
                    label: Text(sending ? AppLocalizations.of(context)!.t('prov_det_sending') : (evidenceBase64 != null ? AppLocalizations.of(context)!.t('prov_det_send_evidence_btn') : AppLocalizations.of(context)!.t('prov_det_send_message'))),
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
