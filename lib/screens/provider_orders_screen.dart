import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/collateral_provider.dart';
import '../providers/order_provider.dart';
import '../providers/breez_provider_export.dart';
import '../providers/provider_balance_provider.dart';
import '../services/escrow_service.dart';
import '../services/nostr_service.dart';
import '../services/secure_storage_service.dart';
import '../services/local_collateral_service.dart';
import '../services/notification_service.dart';
import '../config.dart';
import 'provider_order_detail_screen.dart';

/// Tela de ordens do provedor com abas: Disponíveis, Minhas Ordens, Estatísticas
class ProviderOrdersScreen extends StatefulWidget {
  final String providerId;

  const ProviderOrdersScreen({
    super.key,
    required this.providerId,
  });

  @override
  State<ProviderOrdersScreen> createState() => _ProviderOrdersScreenState();
}

class _ProviderOrdersScreenState extends State<ProviderOrdersScreen> with SingleTickerProviderStateMixin {
  final EscrowService _escrowService = EscrowService();
  final NotificationService _notificationService = NotificationService();
  
  late TabController _tabController;
  
  List<Map<String, dynamic>> _availableOrders = [];
  List<Map<String, dynamic>> _myOrders = []; // Ordens aceitas por este provedor
  Set<String> _seenOrderIds = {};
  bool _isLoading = false;
  bool _isSyncingNostr = false;
  bool _hasCollateral = false;
  String? _error;
  int _lastOrderCount = 0;
  String? _currentPubkey;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    
    debugPrint('🟢 ProviderOrdersScreen initState iniciado');
    debugPrint('   providerId: ${widget.providerId}');
    
    SecureStorageService.setProviderMode(true);
    debugPrint('✅ Modo provedor salvo como ativo');
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadOrders();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppConfig.testMode && mounted) {
      final orderProvider = Provider.of<OrderProvider>(context, listen: false);
      if (orderProvider.orders.length != _lastOrderCount) {
        debugPrint('🔄 Ordens mudaram, recarregando lista do provedor...');
        _lastOrderCount = orderProvider.orders.length;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loadOrders();
        });
      }
    }
  }

  Future<void> _loadOrders() async {
    debugPrint('🔵 _loadOrders iniciado');
    if (!mounted) return;
    
    setState(() {
      _isLoading = true;
      _isSyncingNostr = true;
      _error = null;
    });

    try {
      final collateralService = LocalCollateralService();
      final localCollateral = await collateralService.getCollateral();
      _hasCollateral = localCollateral != null;
      debugPrint('✅ Verificação de garantia: hasCollateral=$_hasCollateral');
      
      // Buscar saldo da carteira
      int walletBalance = 0;
      int committedSats = 0;
      try {
        final breezProvider = context.read<BreezProvider>();
        final balanceInfo = await breezProvider.getBalance();
        walletBalance = int.tryParse(balanceInfo['balance']?.toString() ?? '0') ?? 0;
        
        final orderProvider = context.read<OrderProvider>();
        committedSats = orderProvider.committedSats;
      } catch (e) {
        debugPrint('⚠️ Erro ao buscar saldo: $e');
      }
      
      final collateralProvider = context.read<CollateralProvider>();
      await collateralProvider.initialize(
        widget.providerId,
        walletBalance: walletBalance,
        committedSats: committedSats,
      );
      
      // Buscar ordens do Nostr
      final orderProvider = context.read<OrderProvider>();
      await orderProvider.fetchOrders(forProvider: true);
      
      if (mounted) {
        setState(() {
          _isSyncingNostr = false;
        });
      }
      
      // Pegar pubkey do provedor
      final nostrService = NostrService();
      _currentPubkey = nostrService.publicKey;
      debugPrint('👤 Pubkey do provedor: ${_currentPubkey?.substring(0, 8) ?? "null"}...');
      
      // Separar ordens disponíveis e minhas ordens
      final allOrders = orderProvider.orders;
      List<Map<String, dynamic>> available = [];
      List<Map<String, dynamic>> myOrders = [];
      
      for (final order in allOrders) {
        final orderMap = order.toJson();
        orderMap['amount'] = order.amount;
        orderMap['payment_type'] = order.billType;
        orderMap['created_at'] = order.createdAt.toIso8601String();
        orderMap['user_name'] = 'Usuário ${order.userPubkey?.substring(0, 6) ?? "anon"}';
        
        // Verificar se é ordem deste provedor
        final isMyOrder = order.providerId == _currentPubkey || 
                          order.providerId == widget.providerId;
        
        if (isMyOrder) {
          // Minhas ordens (aceitas por mim)
          myOrders.add(orderMap);
        } else if (order.status == 'pending' || order.status == 'payment_received') {
          // Ordens disponíveis (não aceitas ainda)
          // TESTE: Permitir ver próprias ordens para facilitar testes
          available.add(orderMap);
        }
      }
      
      // Notificar sobre novas ordens disponíveis
      for (final order in available) {
        final orderId = order['id'] as String;
        if (!_seenOrderIds.contains(orderId)) {
          _seenOrderIds.add(orderId);
          if (_lastOrderCount > 0) {
            _notificationService.notifyNewOrderAvailable(
              orderId: orderId,
              amount: (order['amount'] as num).toDouble(),
              paymentType: order['payment_type'] as String? ?? 'pix',
            );
          }
        }
      }

      if (mounted) {
        setState(() {
          _availableOrders = available;
          _myOrders = myOrders;
          _isLoading = false;
        });
        _lastOrderCount = available.length;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Modo Bro'),
        actions: [
          IconButton(
            icon: const Icon(Icons.account_balance_wallet),
            onPressed: () => Navigator.pushNamed(context, '/wallet'),
            tooltip: 'Minha Carteira',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadOrders,
            tooltip: 'Atualizar',
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.orange,
          labelColor: Colors.orange,
          unselectedLabelColor: Colors.white60,
          tabs: [
            Tab(
              icon: const Icon(Icons.local_offer, size: 20),
              child: Text('Disponíveis (${_availableOrders.length})', style: const TextStyle(fontSize: 11)),
            ),
            Tab(
              icon: const Icon(Icons.assignment_turned_in, size: 20),
              child: Text('Minhas (${_myOrders.length})', style: const TextStyle(fontSize: 11)),
            ),
            const Tab(
              icon: Icon(Icons.bar_chart, size: 20),
              child: Text('Estatísticas', style: TextStyle(fontSize: 11)),
            ),
          ],
        ),
      ),
      body: SafeArea(
        top: false, // AppBar já lida com safe area superior
        child: Consumer2<CollateralProvider, OrderProvider>(
          builder: (context, collateralProvider, orderProvider, child) {
            if (_isLoading) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(color: Colors.orange),
                    const SizedBox(height: 16),
                    Text(
                      _isSyncingNostr 
                          ? '🔄 Sincronizando com Nostr...'
                          : 'Carregando ordens...',
                      style: const TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                    if (_isSyncingNostr)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'Buscando ordens de todos os usuários',
                          style: TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                      ),
                  ],
                ),
              );
            }
            
            if (!AppConfig.providerTestMode && !_hasCollateral && !collateralProvider.hasCollateral) {
              return _buildNoCollateralView();
            }

            if (_error != null) {
              return _buildErrorView();
            }

            return TabBarView(
              controller: _tabController,
              children: [
                // Tab 1: Ordens Disponíveis
                _buildAvailableOrdersTab(collateralProvider),
                // Tab 2: Minhas Ordens
                _buildMyOrdersTab(),
                // Tab 3: Estatísticas
                _buildStatisticsTab(collateralProvider),
              ],
            );
          },
        ),
      ),
    );
  }

  // ============================================
  // TAB 1: ORDENS DISPONÍVEIS
  // ============================================
  
  Widget _buildAvailableOrdersTab(CollateralProvider collateralProvider) {
    if (_availableOrders.isEmpty) {
      return _buildEmptyAvailableView();
    }
    
    return RefreshIndicator(
      onRefresh: _loadOrders,
      color: Colors.orange,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ..._availableOrders.map((order) => _buildAvailableOrderCard(order, collateralProvider)),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildEmptyAvailableView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inbox_outlined, size: 80, color: Colors.grey[600]),
            const SizedBox(height: 16),
            const Text(
              'Nenhuma ordem disponível',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Novas ordens aparecerão aqui quando usuários criarem pedidos.',
              style: TextStyle(color: Colors.white70, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _loadOrders,
              icon: const Icon(Icons.refresh),
              label: const Text('Atualizar'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvailableOrderCard(Map<String, dynamic> order, CollateralProvider collateralProvider) {
    final orderId = order['id'] as String;
    final amount = (order['amount'] as num).toDouble();
    final paymentType = order['payment_type'] as String? ?? 'pix';
    final createdAt = DateTime.parse(order['created_at'] as String);
    final timeAgo = _getTimeAgo(createdAt);
    final userName = order['user_name'] as String? ?? 'Usuário';
    
    bool canAccept;
    String? rejectReason;
    
    if (AppConfig.providerTestMode) {
      canAccept = true;
    } else {
      final (canAcceptResult, reason) = collateralProvider.canAcceptOrderWithReason(amount);
      canAccept = canAcceptResult;
      rejectReason = reason;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: canAccept ? Colors.green.withOpacity(0.3) : Colors.red.withOpacity(0.3),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: canAccept ? () => _openOrderDetail(orderId) : null,
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
                        Icon(_getPaymentIcon(paymentType), color: Colors.orange, size: 24),
                        const SizedBox(width: 8),
                        Text(
                          paymentType.toUpperCase(),
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
                        color: canAccept ? Colors.green.withOpacity(0.2) : Colors.red.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: canAccept ? Colors.green : Colors.red),
                      ),
                      child: Text(
                        canAccept ? 'DISPONÍVEL' : 'BLOQUEADA',
                        style: TextStyle(
                          color: canAccept ? Colors.green : Colors.red,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'R\$ ${amount.toStringAsFixed(2)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Ganho: R\$ ${(amount * EscrowService.providerFeePercent / 100).toStringAsFixed(2)} (${EscrowService.providerFeePercent}%)',
                  style: const TextStyle(color: Colors.green, fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.person_outline, color: Colors.white54, size: 16),
                    const SizedBox(width: 6),
                    Text(userName, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                    const Spacer(),
                    const Icon(Icons.access_time, color: Colors.white54, size: 16),
                    const SizedBox(width: 6),
                    Text(timeAgo, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  ],
                ),
                if (!canAccept && rejectReason != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber, color: Colors.red, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(rejectReason, style: const TextStyle(color: Colors.red, fontSize: 11)),
                        ),
                      ],
                    ),
                  ),
                ],
                if (canAccept) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => _openOrderDetail(orderId),
                      icon: const Icon(Icons.touch_app),
                      label: const Text('Ver Detalhes e Aceitar'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ============================================
  // TAB 2: MINHAS ORDENS
  // ============================================
  
  Widget _buildMyOrdersTab() {
    if (_myOrders.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.assignment_outlined, size: 80, color: Colors.grey[600]),
              const SizedBox(height: 16),
              const Text(
                'Nenhuma ordem ainda',
                style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Aceite ordens na aba "Disponíveis" para começar a ganhar sats!',
                style: TextStyle(color: Colors.white70, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    
    // Ordenar por data (mais recente primeiro)
    final sortedOrders = List<Map<String, dynamic>>.from(_myOrders)
      ..sort((a, b) {
        final dateA = DateTime.parse(a['created_at'] ?? a['createdAt'] ?? DateTime.now().toIso8601String());
        final dateB = DateTime.parse(b['created_at'] ?? b['createdAt'] ?? DateTime.now().toIso8601String());
        return dateB.compareTo(dateA);
      });
    
    return RefreshIndicator(
      onRefresh: _loadOrders,
      color: Colors.orange,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ...sortedOrders.map((order) => _buildMyOrderCard(order)),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildMyOrderCard(Map<String, dynamic> order) {
    final orderId = order['id'] as String;
    final amount = (order['amount'] as num).toDouble();
    final paymentType = order['payment_type'] ?? order['billType'] ?? 'pix';
    final status = order['status'] as String? ?? 'unknown';
    final createdAt = DateTime.parse(order['created_at'] ?? order['createdAt'] ?? DateTime.now().toIso8601String());
    
    final statusInfo = _getStatusInfo(status);
    final earning = amount * EscrowService.providerFeePercent / 100;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusInfo['color'].withOpacity(0.3)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _openMyOrderDetail(order),
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
                        Icon(_getPaymentIcon(paymentType), color: Colors.orange, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          'R\$ ${amount.toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: statusInfo['color'].withOpacity(0.2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: statusInfo['color']),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(statusInfo['icon'], color: statusInfo['color'], size: 14),
                          const SizedBox(width: 4),
                          Text(
                            statusInfo['label'],
                            style: TextStyle(
                              color: statusInfo['color'],
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      'Ganho: R\$ ${earning.toStringAsFixed(2)}',
                      style: TextStyle(
                        color: status == 'completed' ? Colors.green : Colors.white54,
                        fontSize: 13,
                        fontWeight: status == 'completed' ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _formatDate(createdAt),
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  statusInfo['description'],
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ============================================
  // TAB 3: ESTATÍSTICAS
  // ============================================
  
  Widget _buildStatisticsTab(CollateralProvider collateralProvider) {
    return RefreshIndicator(
      onRefresh: _loadOrders,
      color: Colors.orange,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Card do Tier
          _buildTierStatusCard(collateralProvider),
          const SizedBox(height: 16),
          
          // Card de Estatísticas
          _buildStatsCard(),
          const SizedBox(height: 16),
          
          // Card de Ganhos
          _buildEarningsCard(),
          const SizedBox(height: 16),
          
          // Ações
          _buildActionsCard(),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildTierStatusCard(CollateralProvider collateralProvider) {
    final currentTier = collateralProvider.getCurrentTier();
    final maxOrder = collateralProvider.getMaxOrderValue();
    
    final tierName = AppConfig.providerTestMode ? 'Trial (Teste)' : (currentTier?.name ?? 'Nenhum');
    final tierMax = AppConfig.providerTestMode ? 'R\$ 10,00' : 'R\$ ${maxOrder.toStringAsFixed(0)}';
    
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.deepPurple.shade800, Colors.deepPurple.shade600],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.verified, color: Colors.white, size: 32),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Tier: $tierName',
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  'Aceita ordens até $tierMax',
                  style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 14),
                ),
              ],
            ),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pushNamed(context, '/provider-collateral'),
            icon: const Icon(Icons.upgrade, size: 18),
            label: const Text('Upgrade'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsCard() {
    final completedOrders = _myOrders.where((o) => o['status'] == 'completed').length;
    final pendingOrders = _myOrders.where((o) => o['status'] != 'completed' && o['status'] != 'cancelled').length;
    final totalOrders = _myOrders.length;
    
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.analytics, color: Colors.blue),
              SizedBox(width: 8),
              Text(
                'Estatísticas',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _buildStatItem('Total', totalOrders.toString(), Colors.white),
              _buildStatItem('Concluídas', completedOrders.toString(), Colors.green),
              _buildStatItem('Em Andamento', pendingOrders.toString(), Colors.orange),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(String label, String value, Color color) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(color: color, fontSize: 28, fontWeight: FontWeight.bold),
          ),
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildEarningsCard() {
    final completedOrders = _myOrders.where((o) => o['status'] == 'completed');
    double totalEarnings = 0;
    for (final order in completedOrders) {
      final amount = (order['amount'] as num).toDouble();
      totalEarnings += amount * EscrowService.providerFeePercent / 100;
    }
    
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.monetization_on, color: Colors.green),
              SizedBox(width: 8),
              Text(
                'Ganhos',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'R\$ ${totalEarnings.toStringAsFixed(2)}',
            style: const TextStyle(color: Colors.green, fontSize: 32, fontWeight: FontWeight.bold),
          ),
          const Text(
            'Total de comissões ganhas',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: () => Navigator.pushNamed(context, '/provider-balance'),
            icon: const Icon(Icons.account_balance_wallet, size: 18),
            label: const Text('Ver Carteira do Bro'),
            style: TextButton.styleFrom(foregroundColor: Colors.orange),
          ),
        ],
      ),
    );
  }

  Widget _buildActionsCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.settings, color: Colors.grey),
              SizedBox(width: 8),
              Text(
                'Ações',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ListTile(
            leading: const Icon(Icons.upgrade, color: Colors.orange),
            title: const Text('Upgrade de Tier', style: TextStyle(color: Colors.white)),
            subtitle: const Text('Aumente seu limite de ordens', style: TextStyle(color: Colors.white54)),
            trailing: const Icon(Icons.chevron_right, color: Colors.white54),
            onTap: () => Navigator.pushNamed(context, '/provider-collateral'),
          ),
          const Divider(color: Colors.white12),
          ListTile(
            leading: const Icon(Icons.school, color: Colors.blue),
            title: const Text('Como Funciona', style: TextStyle(color: Colors.white)),
            subtitle: const Text('Aprenda sobre o modo Bro', style: TextStyle(color: Colors.white54)),
            trailing: const Icon(Icons.chevron_right, color: Colors.white54),
            onTap: () => Navigator.pushNamed(context, '/provider-education'),
          ),
        ],
      ),
    );
  }

  // ============================================
  // HELPERS
  // ============================================

  void _openOrderDetail(String orderId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ProviderOrderDetailScreen(
          orderId: orderId,
          providerId: widget.providerId,
        ),
      ),
    ).then((_) => _loadOrders());
  }

  void _openMyOrderDetail(Map<String, dynamic> order) {
    final orderId = order['id'] as String;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ProviderOrderDetailScreen(
          orderId: orderId,
          providerId: widget.providerId,
        ),
      ),
    ).then((_) => _loadOrders());
  }

  Widget _buildNoCollateralView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.lock_outline, size: 64, color: Colors.orange),
            const SizedBox(height: 16),
            const Text(
              'Garantia Necessária',
              style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Você precisa depositar uma garantia em Bitcoin para aceitar ordens.',
              style: TextStyle(color: Colors.white70, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pushNamed(context, '/provider-collateral', arguments: widget.providerId);
              },
              icon: const Icon(Icons.account_balance_wallet),
              label: const Text('Depositar Garantia'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
          ],
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
            Text('Erro: $_error', style: const TextStyle(color: Colors.white70), textAlign: TextAlign.center),
            const SizedBox(height: 24),
            ElevatedButton(onPressed: _loadOrders, child: const Text('Tentar Novamente')),
          ],
        ),
      ),
    );
  }

  Map<String, dynamic> _getStatusInfo(String status) {
    switch (status) {
      case 'completed':
        return {
          'label': 'CONCLUÍDA',
          'icon': Icons.check_circle,
          'color': Colors.green,
          'description': 'Pagamento confirmado pelo usuário',
        };
      case 'awaiting_confirmation':
        return {
          'label': 'AGUARDANDO',
          'icon': Icons.hourglass_empty,
          'color': Colors.orange,
          'description': 'Aguardando confirmação do usuário',
        };
      case 'accepted':
        return {
          'label': 'ACEITA',
          'icon': Icons.assignment_turned_in,
          'color': Colors.blue,
          'description': 'Você aceitou, agora pague a conta',
        };
      case 'cancelled':
        return {
          'label': 'CANCELADA',
          'icon': Icons.cancel,
          'color': Colors.red,
          'description': 'Ordem foi cancelada',
        };
      case 'disputed':
        return {
          'label': 'EM DISPUTA',
          'icon': Icons.gavel,
          'color': Colors.purple,
          'description': 'Disputa aberta',
        };
      default:
        return {
          'label': status.toUpperCase(),
          'icon': Icons.help_outline,
          'color': Colors.grey,
          'description': 'Status: $status',
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

  String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
}
