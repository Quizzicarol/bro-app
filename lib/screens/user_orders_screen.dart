import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/order_service.dart';
import '../providers/order_provider.dart';
import '../config.dart';
import 'user_order_detail_screen.dart';

/// Tela para visualizar todas as ordens do usuário
class UserOrdersScreen extends StatefulWidget {
  final String userId;

  const UserOrdersScreen({
    Key? key,
    required this.userId,
  }) : super(key: key);

  @override
  State<UserOrdersScreen> createState() => _UserOrdersScreenState();
}

class _UserOrdersScreenState extends State<UserOrdersScreen> {
  final OrderService _orderService = OrderService();
  List<Map<String, dynamic>> _orders = [];
  bool _isLoading = true;
  String? _error;
  String _filterStatus = 'all'; // 'all', 'active', 'completed'

  @override
  void initState() {
    super.initState();
    // Aguardar o primeiro frame antes de acessar o Provider
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadOrders();
    });
  }

  Future<void> _loadOrders() async {
    if (!mounted) return;
    
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      // Se estiver em modo teste, usar OrderProvider (memória local)
      if (AppConfig.testMode) {
        final orderProvider = Provider.of<OrderProvider>(context, listen: false);
        debugPrint('📱 OrderProvider tem ${orderProvider.orders.length} ordens no total');
        
        // Mostrar TODAS as ordens (exceto canceladas)
        final localOrders = orderProvider.orders
          .where((order) {
            debugPrint('   - Ordem ${order.id.substring(0, 8)}: status=${order.status}, providerId=${order.providerId ?? "null"}');
            return order.status != 'cancelled';
          })
          .map((order) => {
            'id': order.id,
            'status': order.status,
            'amount_brl': order.amount,
            'amount_sats': (order.btcAmount * 100000000).toInt(),
            'created_at': order.createdAt.toIso8601String(),
            'expires_at': order.createdAt.add(const Duration(hours: 24)).toIso8601String(),
            'payment_type': order.billType == 'electricity' || order.billType == 'water' || order.billType == 'internet' 
              ? order.billType 
              : 'pix',
            'provider_id': order.providerId,
          }).toList();
        
        if (mounted) {
          setState(() {
            _orders = localOrders;
            _isLoading = false;
          });
        }
        debugPrint('📱 Modo teste: ${_orders.length} ordens carregadas (todas menos canceladas)');
        return;
      }
      
      // Produção: buscar do backend
      final orders = await _orderService.getUserOrders(widget.userId);
      if (mounted) {
        setState(() {
          _orders = orders;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('❌ Erro ao carregar ordens: $e');
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  List<Map<String, dynamic>> _getFilteredOrders() {
    if (_filterStatus == 'all') {
      return _orders;
    } else if (_filterStatus == 'active') {
      // Ativas: pending, payment_received, confirmed, accepted, awaiting_confirmation
      return _orders.where((order) {
        final status = order['status'] as String;
        return ['pending', 'payment_received', 'confirmed', 'accepted', 'awaiting_confirmation'].contains(status);
      }).toList();
    } else if (_filterStatus == 'completed') {
      // Completadas
      return _orders.where((order) => order['status'] == 'completed').toList();
    }
    return _orders;
  }

  Future<void> _handleCancelOrder(String orderId) async {
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
      bool success = false;
      
      // Se estiver em modo teste, cancelar localmente no OrderProvider
      if (AppConfig.testMode) {
        try {
          final orderProvider = Provider.of<OrderProvider>(context, listen: false);
          await orderProvider.updateOrderStatusLocal(orderId, 'cancelled');
          success = true;
          debugPrint('✅ Ordem $orderId cancelada localmente');
        } catch (e) {
          debugPrint('❌ Erro ao cancelar ordem local: $e');
        }
      } else {
        // Produção: cancelar no backend
        success = await _orderService.cancelOrder(
          orderId: orderId,
          userId: widget.userId,
          reason: 'Cancelado pelo usuário',
        );
      }

      if (success) {
        _loadOrders(); // Recarregar lista
        // Mostrar modal com instruções de saque
        _showWithdrawInstructions();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('❌ Erro ao cancelar ordem'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showWithdrawInstructions() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green, size: 28),
            const SizedBox(width: 10),
            const Text('Ordem Cancelada'),
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
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.blue.withOpacity(0.3)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.blue),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Seus sats continuam seguros na sua carteira!',
                        style: TextStyle(
                          color: Colors.blue,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'O que deseja fazer com seus sats?',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 16),
              _buildOptionCard(
                icon: Icons.refresh,
                title: 'Criar nova ordem',
                description: 'Usar os sats para pagar outra conta',
                onTap: () {
                  Navigator.pop(context);
                  Navigator.pushNamed(context, '/');
                },
              ),
              const SizedBox(height: 12),
              _buildOptionCard(
                icon: Icons.send,
                title: 'Sacar para outra carteira',
                description: 'Enviar sats via Lightning',
                onTap: () {
                  Navigator.pop(context);
                  Navigator.pushNamed(context, '/wallet');
                },
              ),
              const SizedBox(height: 12),
              _buildOptionCard(
                icon: Icons.account_balance_wallet,
                title: 'Manter na carteira',
                description: 'Guardar para usar depois',
                onTap: () => Navigator.pop(context),
              ),
            ],
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
  }

  Widget _buildOptionCard({
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

  @override
  Widget build(BuildContext context) {
    final filteredOrders = _getFilteredOrders();
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Minhas Ordens'),
        backgroundColor: Colors.blue,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadOrders,
            tooltip: 'Atualizar',
          ),
        ],
      ),
      body: Column(
        children: [
          // Filtros
          Container(
            padding: const EdgeInsets.all(16),
            color: const Color(0xFF1E1E1E),
            child: Row(
              children: [
                Expanded(
                  child: _buildFilterChip('Todas', 'all', _orders.length),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildFilterChip(
                    'Ativas',
                    'active',
                    _orders.where((o) => ['pending', 'payment_received', 'confirmed', 'accepted', 'awaiting_confirmation'].contains(o['status'])).length,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildFilterChip(
                    'Finalizadas',
                    'completed',
                    _orders.where((o) => o['status'] == 'completed').length,
                  ),
                ),
              ],
            ),
          ),
          // Lista de ordens
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.error_outline, size: 64, color: Colors.red),
                            const SizedBox(height: 16),
                            Text(_error!, textAlign: TextAlign.center),
                            const SizedBox(height: 24),
                            ElevatedButton(
                              onPressed: _loadOrders,
                              child: const Text('Tentar Novamente'),
                            ),
                          ],
                        ),
                      )
                    : filteredOrders.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.inbox, size: 64, color: Colors.grey[400]),
                                const SizedBox(height: 16),
                                Text(
                                  _getEmptyMessage(),
                                  style: TextStyle(color: Colors.grey[600]),
                                ),
                              ],
                            ),
                          )
                        : RefreshIndicator(
                            onRefresh: _loadOrders,
                            child: ListView.builder(
                              padding: const EdgeInsets.all(16),
                              itemCount: filteredOrders.length,
                              itemBuilder: (context, index) {
                                return _buildOrderCard(filteredOrders[index]);
                              },
                            ),
                          ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, String value, int count) {
    final isSelected = _filterStatus == value;
    return InkWell(
      onTap: () {
        setState(() {
          _filterStatus = value;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? Colors.blue : Colors.white24,
          ),
        ),
        child: Column(
          children: [
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.white70,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              count.toString(),
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.white54,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getEmptyMessage() {
    switch (_filterStatus) {
      case 'active':
        return 'Nenhuma ordem ativa';
      case 'completed':
        return 'Nenhuma ordem finalizada';
      default:
        return 'Você ainda não criou nenhuma ordem';
    }
  }

  Widget _buildOrderCard(Map<String, dynamic> order) {
    final orderId = order['id'] as String;
    final status = order['status'] as String? ?? 'unknown';
    final amount = order['amount_brl'] as double;
    final createdAt = DateTime.parse(order['created_at'] as String);
    final expiresAt = DateTime.parse(order['expires_at'] as String);
    final paymentType = order['payment_type'] as String? ?? 'pix';

    final statusInfo = _getStatusInfo(status);
    final canCancel = status == 'pending';

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: InkWell(
        onTap: () {
          // Se ordem está completada, mostrar detalhes. Senão, mostrar status
          if (status == 'completed') {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => UserOrderDetailScreen(orderId: orderId),
              ),
            );
          } else {
            // Navegar para tela de status/acompanhamento
            Navigator.pushNamed(
              context,
              '/order-status',
              arguments: {
                'orderId': orderId,
                'userId': widget.userId,
                'amountBrl': amount,
                'amountSats': order['amount_sats'] ?? 0,
              },
            );
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'R\$ ${amount.toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          paymentType.toUpperCase(),
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: statusInfo['color'],
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      statusInfo['label'],
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              const Divider(height: 24),
              Row(
                children: [
                  Icon(Icons.calendar_today, size: 16, color: Colors.grey[600]),
                  const SizedBox(width: 8),
                  Text(
                    _formatDate(createdAt),
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
              if (canCancel) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.timer, size: 16, color: Colors.orange[700]),
                    const SizedBox(width: 8),
                    Text(
                      'Expira em: ${_orderService.formatTimeRemaining(_orderService.getTimeRemaining(expiresAt))}',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.orange[700],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
              if (canCancel) ...[
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _handleCancelOrder(orderId),
                    icon: const Icon(Icons.cancel, size: 18),
                    label: const Text('Cancelar Ordem'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      side: const BorderSide(color: Colors.red),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Map<String, dynamic> _getStatusInfo(String status) {
    switch (status) {
      case 'pending':
        return {
          'label': 'Aguardando Pagamento',
          'color': Colors.orange,
        };
      case 'payment_received':
        return {
          'label': 'Pagamento Recebido',
          'color': Colors.teal,
        };
      case 'confirmed':
        return {
          'label': 'Aguardando Bro',
          'color': Colors.blue,
        };
      case 'accepted':
        return {
          'label': 'Bro Encontrado',
          'color': Colors.amber,
        };
      case 'awaiting_confirmation':
        return {
          'label': 'Aguardando Confirmação',
          'color': Colors.purple,
        };
      case 'payment_submitted':
        return {
          'label': 'Em Validação',
          'color': Colors.purple,
        };
      case 'completed':
        return {
          'label': 'Concluído',
          'color': Colors.green,
        };
      case 'cancelled':
        return {
          'label': 'Cancelado',
          'color': Colors.red,
        };
      case 'disputed':
        return {
          'label': 'Em Disputa',
          'color': Colors.deepOrange,
        };
      default:
        return {
          'label': status.toUpperCase(),
          'color': Colors.grey,
        };
    }
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays == 0) {
      return 'Hoje às ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    } else if (difference.inDays == 1) {
      return 'Ontem';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} dias atrás';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }
}
