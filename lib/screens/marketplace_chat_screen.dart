import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:provider/provider.dart';
import '../services/chat_service.dart';
import '../services/storage_service.dart';
import '../services/platform_fee_service.dart';
import '../services/nostr_service.dart';
import '../services/nostr_order_service.dart';
import '../providers/breez_provider.dart';

/// Tela de Chat P2P via Nostr DMs (NIP-04)
/// Suporta pagamentos Lightning automáticos:
/// - Comprador: envia pedido de pagamento → detecta invoice → paga com 1 clique
/// - Vendedor: detecta pedido → gera invoice → envia automaticamente
class MarketplaceChatScreen extends StatefulWidget {
  final String sellerPubkey;
  final String? sellerName;
  final String? offerTitle;
  final String? offerId;
  final int? priceSats; // Preço para pagamento automático
  final bool autoPaymentRequest; // Enviar pedido automaticamente ao abrir

  const MarketplaceChatScreen({
    super.key,
    required this.sellerPubkey,
    this.sellerName,
    this.offerTitle,
    this.offerId,
    this.priceSats,
    this.autoPaymentRequest = false,
  });

  @override
  State<MarketplaceChatScreen> createState() => _MarketplaceChatScreenState();
}

class _MarketplaceChatScreenState extends State<MarketplaceChatScreen> {
  final _chatService = ChatService();
  final _storage = StorageService();
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  
  List<ChatMessage> _messages = [];
  StreamSubscription<ChatMessage>? _messageSubscription;
  bool _isLoading = true;
  bool _isSending = false;
  bool _isPayingInvoice = false;
  bool _isGeneratingInvoice = false;
  bool _autoRequestSent = false;
  String? _myPubkey;

  @override
  void initState() {
    super.initState();
    _initializeChat();
  }

  Future<void> _initializeChat() async {
    try {
      // Carregar chaves do usuário
      final privateKey = await _storage.getNostrPrivateKey();
      final publicKey = await _storage.getNostrPublicKey();
      
      if (privateKey == null || publicKey == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Chaves Nostr não encontradas. Configure sua carteira primeiro.'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
      
      _myPubkey = publicKey;
      
      // Inicializar serviço de chat
      await _chatService.initialize(privateKey, publicKey);
      
      // Carregar mensagens existentes
      _messages = _chatService.getMessages(widget.sellerPubkey);
      
      // Buscar mensagens do relay
      await _chatService.fetchMessagesFrom(widget.sellerPubkey);
      
      // Escutar novas mensagens
      _messageSubscription = _chatService
          .getMessageStream(widget.sellerPubkey)
          .listen(_onNewMessage);
      
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        _scrollToBottom();
        
        // Enviar pedido de pagamento automaticamente se solicitado
        if (widget.autoPaymentRequest && !_autoRequestSent && widget.priceSats != null) {
          _autoRequestSent = true;
          await Future.delayed(const Duration(milliseconds: 500));
          if (mounted) {
            await _sendPaymentRequest();
          }
        }
      }
    } catch (e) {
      broLog('❌ Erro ao inicializar chat: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _onNewMessage(ChatMessage message) {
    if (mounted) {
      setState(() {
        // Evitar duplicatas
        if (!_messages.any((m) => m.id == message.id)) {
          _messages.add(message);
          _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        }
      });
      _scrollToBottom();
      
      // v249: Quando receber confirmação de pagamento do comprador, atualizar sold count
      if (!message.isFromMe && message.content.contains('✅ PAGAMENTO CONFIRMADO')) {
        broLog('📦 Pagamento confirmado detectado — atualizando sold count');
        _updateOfferSoldCount();
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isSending) return;
    
    setState(() {
      _isSending = true;
    });
    
    try {
      final success = await _chatService.sendMessage(widget.sellerPubkey, text);
      
      if (success) {
        _messageController.clear();
        // Mensagem já foi adicionada pelo ChatService
        _messages = _chatService.getMessages(widget.sellerPubkey);
        setState(() {});
        _scrollToBottom();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Falha ao enviar mensagem. Tente novamente.'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  // ============================================
  // PAYMENT AUTOMATION
  // ============================================

  /// Prefixo para mensagens estruturadas de pagamento
  static const String _paymentRequestPrefix = '⚡ PEDIDO DE PAGAMENTO';
  static const String _invoicePrefix = '⚡ INVOICE LIGHTNING';

  /// Envia pedido de pagamento estruturado
  Future<void> _sendPaymentRequest() async {
    if (widget.priceSats == null || widget.priceSats! <= 0) return;
    
    final txCode = _generateTransactionCode();
    final message = '$_paymentRequestPrefix #$txCode\n'
        '━━━━━━━━━━━━━━━━━━━━\n'
        '📦 ${widget.offerTitle ?? "Produto"}\n'
        '💰 ${_formatSatsCompact(widget.priceSats!)} sats\n'
        '🔖 Pedido #$txCode\n'
        '━━━━━━━━━━━━━━━━━━━━\n'
        'Olá! Gostaria de comprar este item. '
        'Por favor, gere uma invoice Lightning de ${_formatSatsCompact(widget.priceSats!)} sats '
        'para eu efetuar o pagamento. Obrigado!';
    
    setState(() => _isSending = true);
    try {
      final success = await _chatService.sendMessage(widget.sellerPubkey, message);
      if (success) {
        _messages = _chatService.getMessages(widget.sellerPubkey);
        setState(() {});
        _scrollToBottom();
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  /// Gera invoice via BreezProvider e envia no chat
  Future<void> _generateAndSendInvoice(int amountSats) async {
    setState(() => _isGeneratingInvoice = true);
    
    try {
      final breezProvider = Provider.of<BreezProvider>(context, listen: false);
      final result = await breezProvider.createInvoice(
        amountSats: amountSats,
        description: 'Bro Marketplace: ${widget.offerTitle ?? "Produto"}',
      );
      
      if (result != null && result['success'] == true) {
        final bolt11 = result['bolt11'] as String? ?? '';
        if (bolt11.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('❌ Invoice vazia'), backgroundColor: Colors.red),
            );
          }
          return;
        }
        
        // Extrair código de transação da última mensagem de pedido
        String txCode = '';
        for (int i = _messages.length - 1; i >= 0; i--) {
          final match = RegExp(r'PEDIDO DE PAGAMENTO #(\d{6})').firstMatch(_messages[i].content);
          if (match != null) {
            txCode = match.group(1) ?? '';
            break;
          }
        }
        if (txCode.isEmpty) txCode = _generateTransactionCode();
        
        final message = '$_invoicePrefix\n'
            '━━━━━━━━━━━━━━━━━━━━\n'
            '💰 ${_formatSatsCompact(amountSats)} sats\n'
            '📦 ${widget.offerTitle ?? "Produto"}\n'
            '🔖 Pedido #$txCode\n'
            '━━━━━━━━━━━━━━━━━━━━\n'
            '$bolt11';
        
        final success = await _chatService.sendMessage(widget.sellerPubkey, message);
        if (success) {
          _messages = _chatService.getMessages(widget.sellerPubkey);
          setState(() {});
          _scrollToBottom();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('✅ Invoice enviada! Aguardando pagamento...'),
                backgroundColor: Colors.green,
              ),
            );
          }
          
          // v249: sold count movido para _onNewMessage (quando buyer confirma pagamento)
        }
      } else {
        final error = result?['error'] ?? 'Erro desconhecido';
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('❌ Falha ao gerar invoice: $error'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Erro: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isGeneratingInvoice = false);
    }
  }

  /// Paga uma invoice BOLT11 detectada no chat
  Future<void> _payInvoice(String bolt11) async {
    // Confirmar antes de pagar
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.bolt, color: Colors.amber, size: 24),
            SizedBox(width: 8),
            Text('Confirmar Pagamento', style: TextStyle(color: Colors.white, fontSize: 18)),
          ],
        ),
        content: const Text(
          'Deseja pagar esta invoice Lightning?\n\n'
          '⚠️ Pagamentos Lightning são irreversíveis.',
          style: TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.bolt, size: 18),
            label: const Text('Pagar'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
          ),
        ],
      ),
    );
    
    if (confirm != true || !mounted) return;
    
    setState(() => _isPayingInvoice = true);
    
    try {
      final breezProvider = Provider.of<BreezProvider>(context, listen: false);
      final result = await breezProvider.payInvoice(bolt11);
      
      if (result != null && result['success'] == true) {
        // Extrair código de transação da invoice ou pedido anterior
        String txCode = '';
        for (int i = _messages.length - 1; i >= 0; i--) {
          final match = RegExp(r'Pedido #(\d{6})').firstMatch(_messages[i].content);
          if (match != null) {
            txCode = match.group(1) ?? '';
            break;
          }
        }
        if (txCode.isEmpty) txCode = _generateTransactionCode();
        
        // Enviar confirmação no chat
        final confirmMsg = '✅ PAGAMENTO CONFIRMADO\n'
            '━━━━━━━━━━━━━━━━━━━━\n'
            '📦 ${widget.offerTitle ?? "Produto"}\n'
            '⚡ Pago com sucesso via Lightning!\n'
            '🔖 Pedido #$txCode\n'
            '━━━━━━━━━━━━━━━━━━━━\n'
            'Obrigado pela venda!';
        
        await _chatService.sendMessage(widget.sellerPubkey, confirmMsg);
        _messages = _chatService.getMessages(widget.sellerPubkey);
        setState(() {});
        _scrollToBottom();
        
        // v250: Enviar taxa de 2% da plataforma para Coinos (mínimo 1 sat)
        // ID único por transação para evitar bloqueio de dedup em compras repetidas
        if (widget.priceSats != null && widget.priceSats! > 0) {
          try {
            final feeOrderId = 'mkt_${txCode}_${DateTime.now().millisecondsSinceEpoch}';
            broLog('💼 Marketplace: Enviando taxa 2% de ${widget.priceSats} sats (orderId=$feeOrderId, min=1sat)');
            final feePaid = await PlatformFeeService.sendPlatformFee(
              orderId: feeOrderId,
              totalSats: widget.priceSats!,
            );
            broLog('💼 Marketplace taxa: ${feePaid ? "PAGA" : "FALHOU"}');
          } catch (e) {
            broLog('⚠️ Marketplace taxa erro (não-bloqueante): $e');
          }
        }
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ Pagamento realizado com sucesso!'),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 4),
            ),
          );
        }
      } else {
        final error = result?['error']?.toString() ?? 'Erro desconhecido';
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('❌ Falha no pagamento: $error'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 5),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Erro: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isPayingInvoice = false);
    }
  }

  /// Detecta se uma mensagem contém um pedido de pagamento
  int? _extractPaymentRequestAmount(String content) {
    if (!content.contains(_paymentRequestPrefix)) return null;
    // Extrair sats do formato "X.XXX sats" ou "XXXX sats"
    final match = RegExp(r'💰\s*([\d.,]+)\s*sats').firstMatch(content);
    if (match != null) {
      final numStr = match.group(1)!.replaceAll('.', '').replaceAll(',', '');
      return int.tryParse(numStr);
    }
    return null;
  }

  /// Detecta se uma mensagem contém uma invoice BOLT11
  String? _extractBolt11(String content) {
    // BOLT11 começa com lnbc (mainnet) ou lntb (testnet) seguido de dígitos
    final match = RegExp(r'(ln(?:bc|tb)\w{50,})', caseSensitive: false).firstMatch(content);
    return match?.group(1);
  }

  /// Gera ID curto de 6 dígitos a partir de uma string (mesmo algoritmo do marketplace_screen)
  String _generateShortId(String input) {
    if (input.isEmpty) return '000000';
    int hash = 0;
    for (int i = 0; i < input.length; i++) {
      hash = (hash * 31 + input.codeUnitAt(i)) & 0x7FFFFFFF;
    }
    return (hash % 999999 + 1).toString().padLeft(6, '0');
  }

  /// Gera um código único de transação para cada pedido de pagamento
  String _generateTransactionCode() {
    final now = DateTime.now().millisecondsSinceEpoch.toString();
    final offerId = widget.offerId ?? 'unknown';
    return _generateShortId('${offerId}_$now');
  }

  /// Formata sats com separador de milhar
  String _formatSatsCompact(int sats) {
    if (sats >= 1000) {
      final str = sats.toString();
      final buf = StringBuffer();
      for (int i = 0; i < str.length; i++) {
        if (i > 0 && (str.length - i) % 3 == 0) buf.write('.');
        buf.write(str[i]);
      }
      return buf.toString();
    }
    return sats.toString();
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.sellerName ?? 'Vendedor',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            if (widget.offerTitle != null)
              Text(
                widget.offerTitle!,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.normal,
                  color: Colors.orange,
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: _showChatInfo,
            tooltip: 'Informações',
          ),
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: _copyPubkey,
            tooltip: 'Copiar Pubkey',
          ),
        ],
      ),
      body: Column(
        children: [
          // Info banner
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.orange.withOpacity(0.15), Colors.deepOrange.withOpacity(0.05)],
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 16,
                  color: Colors.orange.shade400,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Chat criptografado via Nostr (NIP-04)',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.orange.shade300,
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          // Messages list
          Expanded(
            child: _isLoading
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(color: Color(0xFFFF6B6B)),
                        SizedBox(height: 16),
                        Text('Conectando aos relays...', style: TextStyle(color: Colors.white70)),
                      ],
                    ),
                  )
                : _messages.isEmpty
                    ? _buildEmptyState()
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(16),
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final message = _messages[index];
                          return _buildMessageBubble(message);
                        },
                      ),
          ),
          
          // Input area
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.chat_bubble_outline,
                size: 48,
                color: Colors.orange,
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Iniciar conversa',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Envie uma mensagem para ${widget.sellerName ?? 'o vendedor'} sobre a oferta.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                color: Colors.white54,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.security,
                    color: Colors.orange.shade700,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Nunca compartilhe seeds ou chaves privadas!',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.orange.shade800,
                      ),
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

  Widget _buildMessageBubble(ChatMessage message) {
    final isMe = message.isFromMe;
    final bolt11 = _extractBolt11(message.content);
    final paymentRequestAmount = _extractPaymentRequestAmount(message.content);
    final isInvoiceMsg = bolt11 != null && message.content.contains(_invoicePrefix);
    final isPaymentRequest = paymentRequestAmount != null;
    final isPaymentConfirmation = message.content.contains('✅ PAGAMENTO CONFIRMADO');
    
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          if (!isMe) ...[
            CircleAvatar(
              radius: 16,
              backgroundColor: Colors.orange,
              child: Text(
                (widget.sellerName ?? 'V')[0].toUpperCase(),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: isPaymentConfirmation
                    ? Colors.green.withOpacity(0.2)
                    : isInvoiceMsg
                        ? Colors.amber.withOpacity(0.15)
                        : isPaymentRequest
                            ? Colors.blue.withOpacity(0.15)
                            : isMe
                                ? Colors.orange
                                : const Color(0xFF2A2A2A),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isMe ? 16 : 4),
                  bottomRight: Radius.circular(isMe ? 4 : 16),
                ),
                border: isInvoiceMsg
                    ? Border.all(color: Colors.amber.withOpacity(0.4))
                    : isPaymentRequest
                        ? Border.all(color: Colors.blue.withOpacity(0.4))
                        : isPaymentConfirmation
                            ? Border.all(color: Colors.green.withOpacity(0.4))
                            : null,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 5,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Conteúdo da mensagem (sem o BOLT11 raw)
                  Text(
                    isInvoiceMsg
                        ? message.content.substring(0, message.content.indexOf(RegExp(r'ln(?:bc|tb)', caseSensitive: false))).trim()
                        : message.content,
                    style: TextStyle(
                      color: isMe && !isInvoiceMsg && !isPaymentRequest && !isPaymentConfirmation
                          ? Colors.white
                          : Colors.white.withOpacity(0.9),
                      fontSize: 14,
                    ),
                  ),
                  
                  // === Botão PAGAR (para o comprador, quando recebe invoice do vendedor) ===
                  if (isInvoiceMsg && !isMe && bolt11 != null) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _isPayingInvoice ? null : () => _payInvoice(bolt11),
                        icon: _isPayingInvoice
                            ? const SizedBox(
                                width: 16, height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.bolt, size: 18),
                        label: Text(_isPayingInvoice ? 'Pagando...' : '⚡ Pagar agora'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.amber,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                  ],
                  
                  // === Botão GERAR INVOICE (para o vendedor, quando recebe pedido do comprador) ===
                  if (isPaymentRequest && !isMe && paymentRequestAmount != null) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _isGeneratingInvoice
                            ? null
                            : () => _generateAndSendInvoice(paymentRequestAmount),
                        icon: _isGeneratingInvoice
                            ? const SizedBox(
                                width: 16, height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.receipt_long, size: 18),
                        label: Text(_isGeneratingInvoice
                            ? 'Gerando invoice...'
                            : 'Gerar Invoice (${_formatSatsCompact(paymentRequestAmount)} sats)'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                  ],
                  
                  // === Botão Copiar Invoice (fallback) ===
                  if (isInvoiceMsg && bolt11 != null) ...[
                    const SizedBox(height: 6),
                    GestureDetector(
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: bolt11));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Invoice copiada!'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.copy, size: 12, color: Colors.white.withOpacity(0.5)),
                          const SizedBox(width: 4),
                          Text(
                            'Copiar invoice',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.white.withOpacity(0.5),
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _formatTime(message.timestamp),
                        style: TextStyle(
                          color: isMe && !isInvoiceMsg && !isPaymentRequest && !isPaymentConfirmation
                              ? Colors.white60
                              : Colors.white38,
                          fontSize: 11,
                        ),
                      ),
                      if (isMe) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.done_all,
                          size: 14,
                          color: isMe && !isInvoiceMsg && !isPaymentRequest && !isPaymentConfirmation
                              ? Colors.white60
                              : Colors.white38,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (isMe) ...[
            const SizedBox(width: 8),
            const CircleAvatar(
              radius: 16,
              backgroundColor: Colors.green,
              child: Icon(
                Icons.person,
                color: Colors.white,
                size: 16,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.only(
          left: 16,
          right: 16,
          top: 8,
          bottom: 8,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 10,
              offset: const Offset(0, -2),
            ),
          ],
        ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF2A2A2A),
                borderRadius: BorderRadius.circular(24),
              ),
              child: TextField(
                controller: _messageController,
                maxLines: null,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Digite sua mensagem...',
                  hintStyle: TextStyle(color: Colors.white38),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                ),
                onSubmitted: (_) => _sendMessage(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            decoration: const BoxDecoration(
              color: Colors.orange,
              shape: BoxShape.circle,
            ),
            child: IconButton(
              onPressed: _isSending ? null : _sendMessage,
              icon: _isSending
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(Colors.white),
                      ),
                    )
                  : const Icon(Icons.send, color: Colors.white),
            ),
          ),
        ],
      ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    
    if (diff.inDays > 0) {
      return '${time.day}/${time.month} ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    }
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  void _showChatInfo() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.only(
              left: 24,
              right: 24,
              top: 24,
              bottom: MediaQuery.of(context).viewInsets.bottom + 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.info_outline,
                        color: Colors.orange,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Text(
                      'Sobre este chat',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _buildInfoItem(
                  Icons.lock,
                  'Criptografia NIP-04',
                  'Suas mensagens são criptografadas de ponta a ponta usando o protocolo Nostr.',
                ),
                _buildInfoItem(
                  Icons.cloud_sync,
                  'Descentralizado',
                  'As mensagens são enviadas através de relays Nostr distribuídos.',
                ),
                _buildInfoItem(
                  Icons.verified_user,
                  'Privacidade',
                  'Apenas você e o destinatário podem ler as mensagens.',
                ),
                _buildInfoItem(
                  Icons.warning_amber,
                  'Segurança',
                  'Nunca compartilhe seeds, chaves privadas ou informações sensíveis.',
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text(
                      'Entendi',
                      style: TextStyle(color: Colors.white),
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

  Widget _buildInfoItem(IconData icon, String title, String description) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: Colors.orange),
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
                    color: Colors.white,
                  ),
                ),
                Text(
                  description,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Colors.white54,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _copyPubkey() {
    Clipboard.setData(ClipboardData(text: widget.sellerPubkey));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Pubkey copiado!'),
        backgroundColor: Colors.orange,
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// v249: Atualiza sold count da oferta no Nostr quando comprador confirma pagamento
  Future<void> _updateOfferSoldCount() async {
    final offerId = widget.offerId;
    if (offerId == null || offerId.isEmpty) {
      broLog('⚠️ _updateOfferSoldCount: offerId é null/vazio');
      return;
    }
    
    try {
      final nostrService = NostrService();
      final nostrOrderService = NostrOrderService();
      final privateKey = nostrService.privateKey;
      if (privateKey == null) {
        broLog('⚠️ _updateOfferSoldCount: privateKey é null');
        return;
      }
      
      broLog('📦 _updateOfferSoldCount: buscando oferta $offerId...');
      
      // Buscar oferta atual para pegar dados + sold count
      final offers = await nostrOrderService.fetchMarketplaceOffers();
      final myOffer = offers.where((o) => o['id'] == offerId).toList();
      
      if (myOffer.isEmpty) {
        broLog('⚠️ Oferta $offerId não encontrada para atualizar sold (${offers.length} ofertas totais)');
        return;
      }
      
      final offer = myOffer.first;
      final currentSold = offer['sold'] as int? ?? 0;
      final quantity = offer['quantity'] as int? ?? 0;
      final newSold = currentSold + 1;
      
      broLog('📦 Atualizando sold: $currentSold → $newSold (quantity=$quantity, offerId=${offerId.substring(0, 8)})');
      
      List<String> photos = [];
      if (offer['photos'] is List) {
        photos = (offer['photos'] as List).cast<String>();
      }
      
      final success = await nostrOrderService.updateMarketplaceOfferSold(
        privateKey: privateKey,
        offerId: offerId,
        title: offer['title'] ?? '',
        description: offer['description'] ?? '',
        priceSats: offer['priceSats'] ?? 0,
        category: offer['category'] ?? 'outro',
        siteUrl: offer['siteUrl'],
        city: offer['city'],
        photos: photos.isNotEmpty ? photos : null,
        quantity: quantity,
        newSold: newSold,
      );
      broLog('📦 updateMarketplaceOfferSold resultado: $success');
    } catch (e) {
      broLog('⚠️ Erro ao atualizar sold count: $e');
    }
  }
}
