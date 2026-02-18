import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class OrderCard extends StatefulWidget {
  final Map<String, dynamic> order;
  final VoidCallback? onAccept;
  final VoidCallback? onReject;
  final VoidCallback? onUploadProof;
  final bool showActions;
  final bool isMyOrder;

  const OrderCard({
    Key? key,
    required this.order,
    this.onAccept,
    this.onReject,
    this.onUploadProof,
    this.showActions = true,
    this.isMyOrder = false,
  }) : super(key: key);

  @override
  State<OrderCard> createState() => _OrderCardState();
}

class _OrderCardState extends State<OrderCard> {
  bool _isExpanded = false;

  String _formatCurrency(double value) {
    final formatter = NumberFormat.currency(locale: 'pt_BR', symbol: 'R\$');
    return formatter.format(value);
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null) return 'N/A';
    try {
      final date = DateTime.parse(dateStr);
      return DateFormat('dd/MM/yyyy').format(date);
    } catch (e) {
      return dateStr;
    }
  }

  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'pending':
        return Colors.orange;
      case 'accepted':
        return Colors.blue;
      case 'paid':
        return Colors.green;
      case 'completed':
        return Colors.green.shade700;
      case 'rejected':
        return Colors.red;
      case 'cancelled':
        return Colors.grey;
      default:
        return Colors.grey;
    }
  }

  String _getStatusText(String status) {
    switch (status.toLowerCase()) {
      case 'pending':
        return 'Pendente';
      case 'accepted':
        return 'Aceita';
      case 'paid':
        return 'Paga';
      case 'completed':
        return 'Conclu�da';
      case 'rejected':
        return 'Rejeitada';
      case 'cancelled':
        return 'Cancelada';
      default:
        return status;
    }
  }

  @override
  Widget build(BuildContext context) {
    final billType = widget.order['billType'] ?? 'N/A';
    final amount = (widget.order['amount'] ?? 0.0).toDouble();
    final status = widget.order['status'] ?? 'pending';
    final dueDate = widget.order['dueDate'];
    final estimatedEarnings = amount * 0.07; // 7% de ganho
    final orderId = widget.order['_id'] ?? widget.order['id'] ?? 'N/A';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: _getStatusColor(status).withOpacity(0.3),
          width: 1,
        ),
      ),
      child: InkWell(
        onTap: () {
          setState(() {
            _isExpanded = !_isExpanded;
          });
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  // �cone do tipo de conta
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: billType.toUpperCase() == 'PIX'
                          ? Colors.teal.shade50
                          : Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      billType.toUpperCase() == 'PIX'
                          ? Icons.pix
                          : Icons.receipt_long,
                      color: billType.toUpperCase() == 'PIX'
                          ? Colors.teal
                          : Colors.orange,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Tipo e valor
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          billType.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _formatCurrency(amount),
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Status badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: _getStatusColor(status).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: _getStatusColor(status),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      _getStatusText(status),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _getStatusColor(status),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              
              // Informa��es principais
              Row(
                children: [
                  if (dueDate != null) ...[
                    Icon(Icons.calendar_today, size: 16, color: Colors.grey[600]),
                    const SizedBox(width: 4),
                    Text(
                      'Venc: ${_formatDate(dueDate)}',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[700],
                      ),
                    ),
                    const SizedBox(width: 16),
                  ],
                  Icon(Icons.account_balance_wallet, size: 16, color: Colors.green[600]),
                  const SizedBox(width: 4),
                  Text(
                    'Ganho: ${_formatCurrency(estimatedEarnings)}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.green[700],
                    ),
                  ),
                ],
              ),

              // Detalhes expandidos
              if (_isExpanded) ...[
                const Divider(height: 24),
                _buildDetailRow('ID da Ordem', orderId.substring(0, 8) + '...'),
                if (widget.order['billCode'] != null)
                  _buildDetailRow('C�digo', widget.order['billCode'].substring(0, 20) + '...'),
                if (widget.order['btcAmount'] != null)
                  _buildDetailRow('BTC', '${widget.order['btcAmount']} sats'),
                if (widget.order['createdAt'] != null)
                  _buildDetailRow('Criado em', _formatDate(widget.order['createdAt'])),
              ],

              // Bot�es de a��o
              if (widget.showActions) ...[
                const SizedBox(height: 16),
                if (!widget.isMyOrder && status.toLowerCase() == 'pending')
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: widget.onAccept,
                          icon: const Icon(Icons.check_circle),
                          label: const Text('Aceitar'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: widget.onReject,
                          icon: const Icon(Icons.cancel),
                          label: const Text('Rejeitar'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            side: const BorderSide(color: Colors.red),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                if (widget.isMyOrder && status.toLowerCase() == 'accepted' && widget.onUploadProof != null)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: widget.onUploadProof,
                      icon: const Icon(Icons.upload_file),
                      label: const Text('Enviar Comprovante'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
              ],

              // Indicador de expans�o
              Center(
                child: Icon(
                  _isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                  color: Colors.grey,
                  size: 20,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              color: Colors.grey,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
