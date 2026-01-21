import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:convert';
import '../providers/order_provider.dart';
import '../models/order.dart';

/// Tela de detalhes de uma ordem completada (histórico do usuário)
class UserOrderDetailScreen extends StatefulWidget {
  final String orderId;

  const UserOrderDetailScreen({
    super.key,
    required this.orderId,
  });

  @override
  State<UserOrderDetailScreen> createState() => _UserOrderDetailScreenState();
}

class _UserOrderDetailScreenState extends State<UserOrderDetailScreen> {
  Order? _order;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadOrder();
    });
  }

  Future<void> _loadOrder() async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final orderProvider = context.read<OrderProvider>();
      
      // Forçar sincronização com Nostr para pegar dados mais recentes
      try {
        await orderProvider.syncOrdersFromNostr();
      } catch (e) {
        debugPrint('⚠️ Erro ao sincronizar Nostr: $e');
      }
      
      // Buscar ordem do provider
      final order = orderProvider.getOrderById(widget.orderId);
      
      if (mounted) {
        setState(() {
          _order = order;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('❌ Erro ao carregar ordem: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Detalhes da Ordem'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.blue))
          : _order == null
              ? _buildNotFound()
              : _buildContent(),
    );
  }

  Widget _buildNotFound() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 64, color: Colors.red),
          const SizedBox(height: 16),
          const Text(
            'Ordem não encontrada',
            style: TextStyle(color: Colors.white, fontSize: 18),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Voltar'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    // Debug: verificar se metadata está presente
    debugPrint('📋 UserOrderDetailScreen: ordem ${_order!.id.substring(0, 8)}');
    debugPrint('   status: ${_order!.status}');
    debugPrint('   metadata: ${_order!.metadata}');
    if (_order!.metadata != null) {
      debugPrint('   metadata keys: ${_order!.metadata!.keys}');
      debugPrint('   proofImage: ${_order!.metadata!['proofImage'] != null ? "existe (${(_order!.metadata!['proofImage'] as String).length} chars)" : "null"}');
      debugPrint('   receipt_url: ${_order!.metadata!['receipt_url'] ?? "null"}');
    }
    
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildStatusBadge(),
          const SizedBox(height: 16),
          _buildAmountCard(),
          const SizedBox(height: 16),
          _buildDetailsCard(),
          const SizedBox(height: 16),
          if (_order!.metadata != null) _buildReceiptCard(),
          // Padding extra para navegação
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildStatusBadge() {
    final statusInfo = _getStatusInfo(_order!.status);
    
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: statusInfo['color'].withOpacity(0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusInfo['color']),
      ),
      child: Row(
        children: [
          Icon(statusInfo['icon'], color: statusInfo['color'], size: 32),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  statusInfo['title'],
                  style: TextStyle(
                    color: statusInfo['color'],
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  statusInfo['subtitle'],
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Map<String, dynamic> _getStatusInfo(String status) {
    switch (status) {
      case 'completed':
        return {
          'title': 'Pagamento Concluído',
          'subtitle': 'Conta paga com sucesso',
          'icon': Icons.check_circle,
          'color': Colors.green,
        };
      case 'awaiting_confirmation':
        return {
          'title': 'Aguardando Confirmação',
          'subtitle': 'Verifique o comprovante',
          'icon': Icons.hourglass_empty,
          'color': Colors.orange,
        };
      case 'accepted':
        return {
          'title': 'Em Andamento',
          'subtitle': 'Provedor processando',
          'icon': Icons.sync,
          'color': Colors.blue,
        };
      default:
        return {
          'title': status,
          'subtitle': '',
          'icon': Icons.info_outline,
          'color': Colors.grey,
        };
    }
  }

  Widget _buildAmountCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.blue.withOpacity(0.2), Colors.blue.withOpacity(0.05)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.blue.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Valor da Conta',
            style: TextStyle(color: Colors.white54, fontSize: 14),
          ),
          const SizedBox(height: 8),
          Text(
            'R\$ ${_order!.amount.toStringAsFixed(2)}',
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
              _buildFeeItem('Taxa Provedor (3%)', _order!.providerFee),
              _buildFeeItem('Taxa Plataforma (2%)', _order!.platformFee),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: Colors.white12),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Total Pago em BTC:',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              Text(
                '${(_order!.btcAmount * 100000000).toInt()} sats',
                style: const TextStyle(
                  color: Colors.orange,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFeeItem(String label, double value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 11),
        ),
        const SizedBox(height: 4),
        Text(
          'R\$ ${value.toStringAsFixed(2)}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildDetailsCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Informações',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          _buildDetailRow('Tipo de Pagamento', _order!.billTypeText),
          const SizedBox(height: 12),
          _buildDetailRow('ID da Ordem', _order!.id.substring(0, 16) + '...'),
          const SizedBox(height: 12),
          _buildDetailRow('Data de Criação', _formatDate(_order!.createdAt)),
          const SizedBox(height: 12),
          if (_order!.completedAt != null)
            _buildDetailRow('Data de Conclusão', _formatDate(_order!.completedAt!)),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
      ],
    );
  }

  Widget _buildReceiptCard() {
    final metadata = _order!.metadata!;
    // Compatibilidade com ambos formatos de comprovante
    final receiptUrl = metadata['receipt_url'] as String? ?? metadata['proofImage'] as String?;
    final confirmationCode = metadata['confirmation_code'] as String?;
    final submittedAt = metadata['receipt_submitted_at'] as String? ?? metadata['proofReceivedAt'] as String?;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.receipt_long, color: Colors.orange),
              const SizedBox(width: 12),
              const Text(
                'Comprovante',
                style: TextStyle(
                  color: Colors.white,
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
                  const Text(
                    'Código de Confirmação:',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    confirmationCode,
                    style: const TextStyle(
                      color: Colors.white,
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.image, color: Colors.blue),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          'Comprovante em imagem',
                          style: TextStyle(color: Colors.white70, fontSize: 14),
                        ),
                      ),
                      TextButton(
                        onPressed: () => _showReceiptImage(receiptUrl),
                        child: const Text('Ver'),
                      ),
                    ],
                  ),
                  // Mostrar preview da imagem se for base64
                  if (receiptUrl.startsWith('data:image') || receiptUrl.length > 100) ...[
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: _buildReceiptImageWidget(receiptUrl),
                    ),
                  ],
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
                  'Enviado em: ${_formatDate(DateTime.parse(submittedAt))}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildReceiptImageWidget(String receiptUrl) {
    try {
      String base64Data = receiptUrl;
      
      // Se for data URI, extrair apenas a parte base64
      if (receiptUrl.contains(',')) {
        base64Data = receiptUrl.split(',').last;
      }
      
      final bytes = base64Decode(base64Data);
      
      return ConstrainedBox(
        constraints: const BoxConstraints(
          maxHeight: 200,
        ),
        child: Image.memory(
          bytes,
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) {
            debugPrint('❌ Erro ao exibir imagem: $error');
            return Container(
              padding: const EdgeInsets.all(16),
              color: Colors.red.withOpacity(0.2),
              child: const Row(
                children: [
                  Icon(Icons.error_outline, color: Colors.red),
                  SizedBox(width: 8),
                  Text(
                    'Erro ao carregar imagem',
                    style: TextStyle(color: Colors.red),
                  ),
                ],
              ),
            );
          },
        ),
      );
    } catch (e) {
      debugPrint('❌ Erro ao decodificar base64: $e');
      return Container(
        padding: const EdgeInsets.all(16),
        color: Colors.orange.withOpacity(0.2),
        child: const Row(
          children: [
            Icon(Icons.warning_amber, color: Colors.orange),
            SizedBox(width: 8),
            Text(
              'Formato de imagem inválido',
              style: TextStyle(color: Colors.orange),
            ),
          ],
        ),
      );
    }
  }

  void _showReceiptImage(String receiptUrl) {
    try {
      String base64Data = receiptUrl;
      
      // Se for data URI, extrair apenas a parte base64
      if (receiptUrl.contains(',')) {
        base64Data = receiptUrl.split(',').last;
      }
      
      final bytes = base64Decode(base64Data);
      
      showDialog(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: Colors.black,
          insetPadding: const EdgeInsets.all(16),
          child: Stack(
            children: [
              InteractiveViewer(
                minScale: 0.5,
                maxScale: 4.0,
                child: Center(
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      debugPrint('❌ Erro ao mostrar imagem fullscreen: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Erro ao abrir imagem'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  String _formatDate(DateTime dateTime) {
    final day = dateTime.day.toString().padLeft(2, '0');
    final month = dateTime.month.toString().padLeft(2, '0');
    final year = dateTime.year;
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    
    return '$day/$month/$year às $hour:$minute';
  }
}
