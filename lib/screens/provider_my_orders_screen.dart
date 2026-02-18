import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/order_provider.dart';
import '../services/nostr_service.dart';
import '../models/order.dart';
import 'provider_order_detail_screen.dart';

/// Helper para substring seguro - evita RangeError em strings curtas
String _safeSubstring(String? s, int start, int end) {
  if (s == null) return 'null';
  if (s.length <= start) return s;
  return s.substring(start, s.length < end ? s.length : end);
}

/// Tela de ordens aceitas pelo provedor
/// Mostra ordens com status 'accepted' e 'awaiting_confirmation'
class ProviderMyOrdersScreen extends StatefulWidget {
  final String providerId;

  const ProviderMyOrdersScreen({
    super.key,
    required this.providerId,
  });

  @override
  State<ProviderMyOrdersScreen> createState() => _ProviderMyOrdersScreenState();
}

class _ProviderMyOrdersScreenState extends State<ProviderMyOrdersScreen> {
  final NostrService _nostrService = NostrService();
  
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshOrders();
    });
  }

  Future<void> _refreshOrders() async {
    // Recarregar ordens do provider
    if (mounted) {
      setState(() {});
    }
  }

  List<Order> _getMyOrders(OrderProvider orderProvider) {
    // Obter pubkey Nostr do usuário logado (para comparar com providerId real)
    final nostrPubkey = _nostrService.publicKey;
    
    // Filtrar ordens que este provedor aceitou e ainda não completou
    return orderProvider.orders.where((order) {
      // Aceitar tanto o providerId passado quanto a pubkey Nostr real
      final isMyOrder = order.providerId == widget.providerId || 
                        (nostrPubkey != null && order.providerId == nostrPubkey);
      final isActiveStatus = order.status == 'accepted' || 
                            order.status == 'awaiting_confirmation';
      
      debugPrint('🔍 Ordem ${_safeSubstring(order.id, 0, 8)}: providerId=${order.providerId}, myId=${widget.providerId}, nostrPubkey=${_safeSubstring(nostrPubkey, 0, 8)}, isMyOrder=$isMyOrder, isActive=$isActiveStatus');
      
      return isMyOrder && isActiveStatus;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Minhas Ordens'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: () {
              Navigator.pushNamed(
                context,
                '/provider-history',
                arguments: widget.providerId,
              );
            },
            tooltip: 'Histórico',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshOrders,
            tooltip: 'Atualizar',
          ),
        ],
      ),
      body: Consumer<OrderProvider>(
        builder: (context, orderProvider, child) {
          final myOrders = _getMyOrders(orderProvider);
          
          debugPrint('📦 Total de ordens aceitas: ${myOrders.length}');

          if (myOrders.isEmpty) {
            return _buildEmptyView();
          }

          return RefreshIndicator(
            onRefresh: _refreshOrders,
            color: Colors.orange,
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: myOrders.length,
              itemBuilder: (context, index) {
                final order = myOrders[index];
                return _buildOrderCard(order);
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildEmptyView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.inbox_outlined, size: 64, color: Colors.white38),
            const SizedBox(height: 16),
            const Text(
              'Nenhuma ordem em andamento',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Ordens aceitas aparecerão aqui até você enviar o comprovante e o usuário confirmar.',
              style: TextStyle(color: Colors.white70, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pushReplacementNamed(
                  context,
                  '/provider-orders',
                  arguments: {'providerId': widget.providerId},
                );
              },
              icon: const Icon(Icons.search),
              label: const Text('Ver Ordens Disponíveis'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderCard(Order order) {
    final statusInfo = _getStatusInfo(order.status);
    final timeAgo = _getTimeAgo(order.createdAt);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: statusInfo['color'].withOpacity(0.3),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => ProviderOrderDetailScreen(
                  orderId: order.id,
                  providerId: widget.providerId,
                ),
              ),
            ).then((result) {
              _refreshOrders();
              // Resultado é tratado aqui, mas já estamos na tela de "Minhas"
            });
          },
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _getPaymentIcon(order.billType),
                          color: Colors.orange,
                          size: 24,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          order.billType.toUpperCase(),
                          style: const TextStyle(
                            color: Colors.orange,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: statusInfo['color'].withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: statusInfo['color'],
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            statusInfo['icon'],
                            color: statusInfo['color'],
                            size: 12,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            statusInfo['label'],
                            style: TextStyle(
                              color: statusInfo['color'],
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'R\$ ${order.amount.toStringAsFixed(2)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Sua taxa: R\$ ${(order.amount * 0.03).toStringAsFixed(2)}',
                  style: const TextStyle(
                    color: Colors.green,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(color: Colors.white12),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.access_time, color: Colors.white54, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      'Aceita $timeAgo',
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: statusInfo['color'].withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: statusInfo['color'].withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(statusInfo['icon'], color: statusInfo['color'], size: 20),
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
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              statusInfo['description'],
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right, color: statusInfo['color']),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Map<String, dynamic> _getStatusInfo(String status) {
    switch (status) {
      case 'accepted':
        return {
          'label': 'EM ANDAMENTO',
          'title': 'Pagar e Enviar Comprovante',
          'description': 'Pague a conta e envie o comprovante de pagamento',
          'icon': Icons.upload_file,
          'color': Colors.blue,
        };
      case 'awaiting_confirmation':
        return {
          'label': 'AGUARDANDO',
          'title': 'Comprovante Enviado',
          'description': 'Aguardando usuário confirmar o pagamento',
          'icon': Icons.hourglass_empty,
          'color': Colors.purple,
        };
      default:
        return {
          'label': status.toUpperCase(),
          'title': status,
          'description': '',
          'icon': Icons.info_outline,
          'color': Colors.grey,
        };
    }
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

  String _getTimeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inDays > 0) {
      return '${difference.inDays}d atrás';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h atrás';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}min atrás';
    } else {
      return 'Agora';
    }
  }
}
