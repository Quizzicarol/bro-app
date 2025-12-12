import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'dart:io';
import '../services/order_service.dart';
import '../services/dispute_service.dart';
import '../providers/breez_provider_export.dart';
import '../providers/order_provider.dart';
import '../providers/provider_balance_provider.dart';
import '../providers/platform_balance_provider.dart';
import '../config.dart';
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
    super.dispose();
  }

  Future<void> _loadOrderDetails() async {
    try {
      final order = await _orderService.getOrder(widget.orderId);
      
      if (order != null) {
        setState(() {
          _orderDetails = order;
          _currentStatus = order['status'] ?? 'pending';
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
        setState(() {
          _error = 'Ordem não encontrada';
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('❌ Erro ao carregar ordem: $e');
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _startStatusPolling() {
    // Verificar status a cada 10 segundos
    _statusCheckTimer = Timer.periodic(const Duration(seconds: 10), (timer) async {
      final status = await _orderService.checkOrderStatus(widget.orderId);
      
      if (status != _currentStatus) {
        setState(() {
          _currentStatus = status;
        });

        // Se ordem foi aceita ou completada, parar polling
        if (status == 'accepted' || status == 'completed' || status == 'cancelled') {
          timer.cancel();
        }
      }

      // Verificar expiração
      if (_expiresAt != null && _orderService.isOrderExpired(_expiresAt!)) {
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
          'Nenhum provedor aceitou sua ordem em 24 horas.\n\n'
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
          'Seus Bitcoin serão devolvidos automaticamente.',
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
      
      final success = await _orderService.cancelOrder(
        orderId: widget.orderId,
        userId: widget.userId ?? '',
        reason: 'Cancelado pelo usuário',
      );

      if (success) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('✅ Ordem cancelada! Seus fundos serão devolvidos.'),
              backgroundColor: Colors.green,
            ),
          );
          Navigator.pop(context); // Voltar para home
        }
      } else {
        setState(() => _isLoading = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('❌ Erro ao cancelar ordem'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Status da Ordem')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Erro')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Voltar'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_currentStatus == 'pending' ? 'Aguardando Pagamento' : 'Status da Ordem'),
        backgroundColor: _currentStatus == 'pending' ? Colors.orange : Colors.blue,
      ),
      body: RefreshIndicator(
        onRefresh: _loadOrderDetails,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildStatusCard(),
              const SizedBox(height: 16),
              _buildOrderDetailsCard(),
              const SizedBox(height: 16),
              if (_currentStatus == 'awaiting_confirmation') ...[
                _buildReceiptCard(),
                const SizedBox(height: 16),
              ],
              _buildTimelineCard(),
              const SizedBox(height: 16),
              _buildInfoCard(),
              const SizedBox(height: 24),
              if (_currentStatus == 'pending') ...[
                _buildPayButton(),
                const SizedBox(height: 12),
                _buildCancelButton(),
              ],
              if (_currentStatus == 'awaiting_confirmation') ...[
                _buildConfirmPaymentButton(),
                const SizedBox(height: 12),
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    final statusInfo = _getStatusInfo();
    
    return Card(
      color: statusInfo['color'],
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(
              statusInfo['icon'],
              size: 64,
              color: Colors.white,
            ),
            const SizedBox(height: 16),
            Text(
              statusInfo['title'],
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Colors.white,
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
            if (_currentStatus == 'pending' && _expiresAt != null) ...[
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
                    const Icon(Icons.timer, color: Colors.white, size: 20),
                    const SizedBox(width: 8),
                    Text(
                      'Expira em: ${_orderService.formatTimeRemaining(_orderService.getTimeRemaining(_expiresAt!))}',
                      style: const TextStyle(
                        color: Colors.white,
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

  Map<String, dynamic> _getStatusInfo() {
    switch (_currentStatus) {
      case 'pending':
        return {
          'icon': Icons.payment,
          'title': 'Aguardando Pagamento',
          'subtitle': 'Pague com Bitcoin para prosseguir',
          'color': Colors.orange,
        };
      case 'confirmed':
        return {
          'icon': Icons.hourglass_empty,
          'title': 'Aguardando Provedor',
          'subtitle': 'Sua ordem está disponível para provedores',
          'color': Colors.blue,
        };
      case 'accepted':
        return {
          'icon': Icons.check_circle_outline,
          'title': 'Provedor Encontrado!',
          'subtitle': 'Um provedor aceitou sua ordem',
          'color': Colors.green,
        };
      case 'awaiting_confirmation':
        return {
          'icon': Icons.receipt_long,
          'title': 'Comprovante Enviado',
          'subtitle': 'Verifique o comprovante e confirme o pagamento',
          'color': Colors.purple,
        };
      case 'payment_submitted':
        return {
          'icon': Icons.receipt_long,
          'title': 'Comprovante Enviado',
          'subtitle': 'Aguardando validação do pagamento',
          'color': Colors.purple,
        };
      case 'completed':
        return {
          'icon': Icons.celebration,
          'title': 'Pagamento Concluído!',
          'subtitle': 'Sua conta foi paga com sucesso',
          'color': Colors.green,
        };
      case 'cancelled':
        return {
          'icon': Icons.cancel_outlined,
          'title': 'Ordem Cancelada',
          'subtitle': 'Seus fundos foram devolvidos',
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
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Detalhes da Ordem',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Divider(height: 24),
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
            color: Colors.grey,
            fontSize: 14,
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
          ),
        ),
      ],
    );
  }

  Widget _buildTimelineCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Próximos Passos',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Divider(height: 24),
            _buildTimelineStep(
              number: '1',
              title: 'Aguardando Pagamento',
              subtitle: 'Pague com Bitcoin para prosseguir',
              isActive: _currentStatus == 'pending',
              isCompleted: _currentStatus != 'pending',
            ),
            _buildTimelineStep(
              number: '2',
              title: 'Aguardando Provedor',
              subtitle: 'Um provedor irá aceitar sua ordem',
              isActive: _currentStatus == 'confirmed',
              isCompleted: _currentStatus == 'accepted' || _currentStatus == 'payment_submitted' || _currentStatus == 'completed',
            ),
            _buildTimelineStep(
              number: '3',
              title: 'Provedor Realiza Pagamento',
              subtitle: 'O provedor paga a conta com PIX/Boleto',
              isActive: _currentStatus == 'accepted',
              isCompleted: _currentStatus == 'payment_submitted' || _currentStatus == 'completed',
            ),
            _buildTimelineStep(
              number: '4',
              title: 'Comprovante Validado',
              subtitle: 'Sistema valida o pagamento',
              isActive: _currentStatus == 'payment_submitted',
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
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: isCompleted
                    ? Colors.green
                    : isActive
                        ? Colors.orange
                        : Colors.grey[300],
                shape: BoxShape.circle,
              ),
              child: Center(
                child: isCompleted
                    ? const Icon(Icons.check, color: Colors.white, size: 20)
                    : Text(
                        number,
                        style: TextStyle(
                          color: isActive ? Colors.white : Colors.grey[600],
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ),
            if (!isLast)
              Container(
                width: 2,
                height: 40,
                color: isCompleted ? Colors.green : Colors.grey[300],
              ),
          ],
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                  color: isActive ? Colors.black : Colors.grey[600],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[600],
                ),
              ),
              if (!isLast) const SizedBox(height: 16),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildInfoCard() {
    return Card(
      color: Colors.blue[50],
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline, color: Colors.blue[700]),
                const SizedBox(width: 8),
                Text(
                  'Informações Importantes',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue[900],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildInfoItem('⏰', 'O provedor tem até 24 horas para aceitar e pagar sua conta'),
            const SizedBox(height: 12),
            _buildInfoItem('🔒', 'Seus Bitcoin estão seguros no escrow até a conclusão'),
            const SizedBox(height: 12),
            _buildInfoItem('📱', 'Você receberá notificações sobre o andamento'),
            const SizedBox(height: 12),
            _buildInfoItem('🚫', 'Você pode cancelar a ordem se nenhum provedor aceitar'),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoItem(String emoji, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(emoji, style: const TextStyle(fontSize: 20)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 14,
              color: Colors.blue[900],
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

    final receiptUrl = metadata?['receipt_url'] as String?;
    final confirmationCode = metadata?['confirmation_code'] as String?;
    final submittedAt = metadata?['receipt_submitted_at'] as String?;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.receipt_long, color: Colors.orange[700]),
                const SizedBox(width: 12),
                const Text(
                  'Comprovante do Provedor',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
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
                        Icon(Icons.confirmation_number, color: Colors.orange[700], size: 20),
                        const SizedBox(width: 8),
                        const Text(
                          'Código de Confirmação:',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
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

  /// Exibe o comprovante do provedor em tela cheia
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
    // Verificar se é uma URL ou caminho local
    if (imageUrl.startsWith('http://') || imageUrl.startsWith('https://')) {
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
              color: const Color(0xFFFF6B35),
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
            Icon(Icons.gavel, color: Color(0xFFFF6B35)),
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
                        color: Color(0xFFFF6B35),
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
              backgroundColor: const Color(0xFFFF6B35),
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
                  activeColor: const Color(0xFFFF6B35),
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
                      borderSide: const BorderSide(color: Color(0xFFFF6B35)),
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
                      backgroundColor: const Color(0xFFFF6B35),
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
            CircularProgressIndicator(color: Color(0xFFFF6B35)),
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
            backgroundColor: Color(0xFFFF6B35),
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
          foregroundColor: const Color(0xFFFF6B35),
          side: const BorderSide(color: Color(0xFFFF6B35)),
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
          backgroundColor: const Color(0xFFFF6B35),
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
                      color: const Color(0xFFFF6B35),
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
            CircularProgressIndicator(color: Color(0xFFFF6B35)),
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
        description: 'Paga Conta ${widget.orderId}',
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
    breezProvider.onPaymentReceived = (paymentId, amountSats) {
      debugPrint('🎉 Callback de pagamento recebido! ID: $paymentId, Amount: $amountSats');
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
              const Icon(Icons.bolt, color: Color(0xFFFF6B35), size: 28),
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
                          icon: const Icon(Icons.copy, color: Color(0xFFFF6B35), size: 20),
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
                color: Color(0xFFFF6B35),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Seu pagamento via Lightning foi\nconfirmado com sucesso!\n\nAguardando provedor aceitar sua ordem.',
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
                // Navegar para Minhas Ordens
                Navigator.of(context).pushNamedAndRemoveUntil(
                  '/user-orders',
                  (route) => route.isFirst,
                  arguments: {'userId': widget.userId ?? 'user_test_001'},
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('Ver Minhas Ordens', style: TextStyle(color: Colors.white, fontSize: 16)),
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
            CircularProgressIndicator(color: Color(0xFFFF6B35)),
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
      
      if (AppConfig.testMode && orderDetails == null) {
        final orderProvider = context.read<OrderProvider>();
        final order = orderProvider.getOrderById(widget.orderId);
        if (order != null) {
          orderDetails = order.toJson();
        }
      }

      // Atualizar status para 'completed'
      if (AppConfig.testMode) {
        final orderProvider = context.read<OrderProvider>();
        await orderProvider.updateOrderStatus(orderId: widget.orderId, status: 'completed');
      } else {
        // TODO: Implementar update via API
        debugPrint('⚠️ Update de status não implementado para produção');
      }

      // Adicionar ganho ao saldo do provedor E taxa da plataforma (apenas em test mode)
      if (AppConfig.testMode && orderDetails != null) {
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
      color: const Color(0xFFFFF3E0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.gavel, color: Colors.orange, size: 28),
                ),
                const SizedBox(width: 12),
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
