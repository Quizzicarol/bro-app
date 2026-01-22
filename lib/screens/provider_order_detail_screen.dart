import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'dart:convert';
import '../providers/order_provider.dart';
import '../providers/collateral_provider.dart';
import '../services/escrow_service.dart';
import '../services/dispute_service.dart';
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
  
  Map<String, dynamic>? _orderDetails;
  bool _isLoading = false;
  bool _isAccepting = false;
  bool _isUploading = false;
  String? _error;
  File? _receiptImage;
  bool _orderAccepted = false;
  
  // Timer de 24h para auto-liquidação
  Duration? _timeRemaining;
  DateTime? _receiptSubmittedAt;

  @override
  void initState() {
    super.initState();
    // Aguardar o frame completo antes de acessar o Provider
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadOrderDetails();
    });
  }

  @override
  void dispose() {
    _confirmationCodeController.dispose();
    super.dispose();
  }

  Future<void> _loadOrderDetails() async {
    if (!mounted) return;
    
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final orderProvider = context.read<OrderProvider>();
      final order = await orderProvider.getOrder(widget.orderId);
      
      debugPrint('🔍 _loadOrderDetails: ordem carregada = $order');
      debugPrint('🔍 _loadOrderDetails: billCode = ${order?['billCode']}');

      if (mounted) {
        setState(() {
          _orderDetails = order;
          // Verificar se ordem já foi aceita (por qualquer provedor ou este provedor)
          final orderProviderId = order?['providerId'] ?? order?['provider_id'];
          final orderStatus = order?['status'] ?? 'pending';
          
          // Ordem foi aceita se status é accepted/awaiting_confirmation e tem providerId
          // Não importa se é exatamente widget.providerId porque em modo teste usamos pubkey Nostr
          _orderAccepted = (orderStatus == 'accepted' || orderStatus == 'awaiting_confirmation' || orderStatus == 'completed') && 
                          (orderProviderId != null && orderProviderId.isNotEmpty);
          
          // Calcular tempo restante se comprovante foi enviado
          final metadata = order?['metadata'] as Map<String, dynamic>?;
          if (metadata != null && metadata['receipt_submitted_at'] != null) {
            _receiptSubmittedAt = DateTime.parse(metadata['receipt_submitted_at']);
            final deadline = _receiptSubmittedAt!.add(const Duration(hours: 24));
            _timeRemaining = deadline.difference(DateTime.now());
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
    
    final orderAmount = (_orderDetails!['amount'] as num).toDouble();

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
      // Em modo produção, bloquear garantia
      if (!AppConfig.providerTestMode) {
        final collateralProvider = context.read<CollateralProvider>();
        final tierId = collateralProvider.getCurrentTier()!.id;
        
        await _escrowService.lockCollateral(
          providerId: widget.providerId,
          orderId: widget.orderId,
          lockedSats: (orderAmount * 1000).round(),
        );
      }

      // Publicar aceitação no Nostr E atualizar localmente
      final orderProvider = context.read<OrderProvider>();
      final success = await orderProvider.acceptOrderAsProvider(widget.orderId);
      
      if (!success) {
        _showError('Falha ao publicar aceitação no Nostr');
        if (mounted) {
          setState(() {
            _isAccepting = false;
          });
        }
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

      await _loadOrderDetails();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isAccepting = false;
        });
      }
      _showError('Erro ao aceitar ordem: $e');
    }
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
      String proofImageBase64 = '';
      String confirmationCode = _confirmationCodeController.text.trim();
      
      if (_receiptImage != null) {
        // Converter imagem para base64 para publicar no Nostr
        final bytes = await _receiptImage!.readAsBytes();
        proofImageBase64 = base64Encode(bytes);
      }

      // Publicar comprovante no Nostr E atualizar localmente
      final orderProvider = context.read<OrderProvider>();
      final success = await orderProvider.completeOrderAsProvider(
        widget.orderId, 
        proofImageBase64.isNotEmpty ? proofImageBase64 : confirmationCode,
      );
      
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Comprovante enviado! Aguardando confirmação do usuário.'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
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
            ? const Center(child: CircularProgressIndicator(color: Colors.orange))
            : _error != null
                ? _buildErrorView()
                : _orderDetails == null
                    ? const Center(child: Text('Ordem não encontrada', style: TextStyle(color: Colors.white70)))
                    : _buildContent(),
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
    // Usar billType e billCode diretamente do modelo Order
    final billType = _orderDetails!['billType'] as String? ?? 
                     _orderDetails!['bill_type'] as String? ?? 
                     _orderDetails!['payment_type'] as String? ?? 'pix';
    final billCode = _orderDetails!['billCode'] as String? ?? 
                     _orderDetails!['bill_code'] as String? ?? '';
    
    // DEBUG: Log para verificar se billCode está presente
    debugPrint('🔍 _buildContent: billType=$billType, billCode=${billCode.isNotEmpty ? "${billCode.substring(0, billCode.length > 20 ? 20 : billCode.length)}..." : "EMPTY"}');
    
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

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Valor da ordem
          _buildAmountCard(amount, providerFee),
          const SizedBox(height: 16),

          // Status
          _buildStatusCard(),
          const SizedBox(height: 16),

          // Dados de pagamento - SEMPRE mostrar se tiver billCode
          if (paymentData != null && paymentData.isNotEmpty) ...[
            _buildPaymentDataCard(billType, paymentData),
            const SizedBox(height: 16),
          ],

          // Botão de aceitar (se ainda não aceitou)
          if (!_orderAccepted) ...[
            _buildAcceptButton(),
            const SizedBox(height: 16),
          ],

          // Seção de timer e disputa (se aguardando confirmação)
          if (_orderDetails!['status'] == 'awaiting_confirmation') ...[  
            _buildAwaitingConfirmationSection(),
            const SizedBox(height: 16),
          ],
          
          // Upload de comprovante (se já aceitou)
          if (_orderAccepted && _orderDetails!['status'] != 'awaiting_confirmation') ...[
            _buildReceiptSection(),
          ],
          
          // Padding extra para não ficar sob a barra de navegação
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildAmountCard(double amount, double fee) {
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
          const Text(
            'Valor da Conta',
            style: TextStyle(color: Colors.white60, fontSize: 14),
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
                    style: TextStyle(color: Colors.white54, fontSize: 15),
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
                    'Total a Receber',
                    style: TextStyle(color: Colors.white54, fontSize: 15),
                  ),
                  const SizedBox(height: 4),
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
                  style: const TextStyle(color: Colors.white70, fontSize: 15),
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
        return {
          'title': 'Em Disputa',
          'description': 'Aguardando mediação',
          'icon': Icons.gavel,
          'color': Colors.orange,
        };
      case 'confirmed':
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
            style: TextStyle(color: Colors.white70, fontSize: 16),
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
            style: const TextStyle(color: Colors.white54, fontSize: 15),
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
            style: const TextStyle(color: Colors.white54, fontSize: 15),
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
    final hoursRemaining = _timeRemaining?.inHours ?? 24;
    final minutesRemaining = (_timeRemaining?.inMinutes ?? 0) % 60;
    final isExpiringSoon = hoursRemaining < 4;
    
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isExpiringSoon 
            ? Colors.red.withOpacity(0.1)
            : Colors.purple.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isExpiringSoon 
              ? Colors.red.withOpacity(0.3) 
              : Colors.purple.withOpacity(0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.hourglass_empty, 
                color: isExpiringSoon ? Colors.red : Colors.purple,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Aguardando Confirmação do Usuário',
                  style: TextStyle(
                    color: isExpiringSoon ? Colors.red : Colors.purple,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          
          // Timer
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.timer, color: isExpiringSoon ? Colors.red : Colors.white70),
                const SizedBox(width: 8),
                Text(
                  _timeRemaining != null && !_timeRemaining!.isNegative
                      ? 'Tempo restante: ${hoursRemaining}h ${minutesRemaining}min'
                      : 'Prazo expirado - Auto-liquidação em andamento',
                  style: TextStyle(
                    color: isExpiringSoon ? Colors.red : Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          
          // Informação sobre auto-liquidação
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0x1AFF6B35),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  '💡 Auto-liquidação após 24h',
                  style: TextStyle(
                    color: Color(0xFFFF6B6B),
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'Se o usuário não confirmar o recebimento em 24 horas, '
                  'os Bitcoin em escrow serão automaticamente liquidados para:\n\n'
                  '• Pagar você pelo serviço realizado\n'
                  '• Cobrir as taxas da plataforma\n\n'
                  'Você pode abrir uma disputa se houver algum problema.',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 16,
                    height: 1.4,
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
      ),
    );
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
                      style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 16, height: 1.4),
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
                        'Lembre-se: após 24h sem confirmação, a auto-liquidação ocorre automaticamente.',
                        style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 15),
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
            style: TextStyle(color: Colors.white70, fontSize: 16),
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
          const SizedBox(height: 16),
          
          const Divider(color: Colors.white12),
          const SizedBox(height: 16),
          
          // Seção de imagem
          if (_receiptImage != null) ...[
            const Text(
              'Comprovante Anexado:',
              style: TextStyle(color: Colors.white70, fontSize: 15),
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
            const Text(
              'Anexar Comprovante:',
              style: TextStyle(color: Colors.white70, fontSize: 15),
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
}
