import 'package:flutter/material.dart';

/// Card de transação no estilo Bro (dark + orange)
class TransactionCard extends StatelessWidget {
  final String title;
  final String amount;
  final String status;
  final String statusLabel;
  final String? orderId; // ID da ordem para controle administrativo
  final VoidCallback? onTap;

  const TransactionCard({
    Key? key,
    required this.title,
    required this.amount,
    required this.status,
    required this.statusLabel,
    this.orderId,
    this.onTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A), // Dark background Bro style
        border: Border.all(
          color: Colors.orange.withOpacity(0.2), // Orange accent
          width: 1,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                // Status Badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: _getStatusBackgroundColor(),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    statusLabel,
                    style: TextStyle(
                      color: _getStatusTextColor(),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                
                // Content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          // ID da ordem para controle
                          if (orderId != null && orderId!.isNotEmpty) ...[
                            Icon(Icons.tag, color: Colors.white38, size: 12),
                            const SizedBox(width: 4),
                            Text(
                              orderId!.length > 8 ? orderId!.substring(0, 8) : orderId!,
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 10,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        amount,
                        style: const TextStyle(
                          color: Colors.orange, // Bro orange
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                
                // Arrow
                Icon(
                  Icons.arrow_forward_ios,
                  color: Colors.orange.withOpacity(0.4),
                  size: 16,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _getStatusBackgroundColor() {
    switch (status.toLowerCase()) {
      case 'pending':
        return const Color(0x33FFC107); // rgba(255, 193, 7, 0.2)
      case 'completed':
      case 'paid':
        return const Color(0x334CAF50); // rgba(76, 175, 80, 0.2)
      case 'awaiting_confirmation':
      case 'payment_submitted':
      case 'processing':
        return const Color(0x33FF9800); // Orange para confirmar pagamento
      case 'cancelled':
      case 'failed':
        return const Color(0x33F44336); // rgba(244, 67, 54, 0.2)
      default:
        return const Color(0x339E9E9E); // rgba(158, 158, 158, 0.2)
    }
  }

  Color _getStatusTextColor() {
    switch (status.toLowerCase()) {
      case 'pending':
        return const Color(0xFFFFC107);
      case 'completed':
      case 'paid':
        return const Color(0xFF4CAF50);
      case 'awaiting_confirmation':
      case 'payment_submitted':
      case 'processing':
        return const Color(0xFFFF9800); // Orange para confirmar pagamento
      case 'cancelled':
      case 'failed':
        return const Color(0xFFF44336);
      default:
        return const Color(0xFF9E9E9E);
    }
  }
}

/// Empty State para lista vazia - estilo Bro
class EmptyTransactionState extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback? onAction;

  const EmptyTransactionState({
    Key? key,
    this.title = 'Nenhuma transação ainda',
    this.subtitle = 'Clique em "Nova Transação" para começar',
    this.onAction,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Empty Icon
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.inbox_outlined,
              size: 48,
              color: Colors.orange.withOpacity(0.5),
            ),
          ),
          const SizedBox(height: 20),
          
          // Title
          Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          
          // Subtitle
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 14,
              color: Colors.white.withOpacity(0.6),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
