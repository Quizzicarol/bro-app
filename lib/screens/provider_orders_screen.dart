import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/collateral_provider.dart';
import '../providers/order_provider.dart';
import '../providers/breez_provider_export.dart';
import '../services/escrow_service.dart';
import '../services/nostr_service.dart';
import '../services/secure_storage_service.dart';
import '../services/local_collateral_service.dart';
import '../config.dart';
import 'provider_order_detail_screen.dart';

/// Tela de ordens disponíveis para o provedor aceitar
class ProviderOrdersScreen extends StatefulWidget {
  final String providerId;

  const ProviderOrdersScreen({
    super.key,
    required this.providerId,
  });

  @override
  State<ProviderOrdersScreen> createState() => _ProviderOrdersScreenState();
}

class _ProviderOrdersScreenState extends State<ProviderOrdersScreen> {
  final EscrowService _escrowService = EscrowService();
  List<Map<String, dynamic>> _availableOrders = [];
  bool _isLoading = false;
  bool _hasCollateral = false; // Verificação local de garantia
  String? _error;
  int _lastOrderCount = 0;

  @override
  void initState() {
    super.initState();
    debugPrint('🟢 ProviderOrdersScreen initState iniciado');
    debugPrint('   providerId: ${widget.providerId}');
    
    // Salvar que está em modo provedor (garantir persistência)
    SecureStorageService.setProviderMode(true);
    debugPrint('✅ Modo provedor salvo como ativo (na tela de ordens)');
    
    // Aguardar o frame completo antes de acessar o Provider
    WidgetsBinding.instance.addPostFrameCallback((_) {
      debugPrint('🟢 addPostFrameCallback executado, chamando _loadOrders');
      _loadOrders();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Recarregar quando voltar para a tela (ex: depois de criar ordem)
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
    if (!mounted) {
      debugPrint('⚠️ Widget não montado, abortando _loadOrders');
      return;
    }
    
    setState(() {
      _isLoading = true;
      _error = null;
    });
    debugPrint('🔵 setState chamado: _isLoading = true');

    try {
      // NÃO limpar cache - pode ter acabado de ser setado pelo TierDepositScreen!
      // Se precisar forçar refresh, o usuário pode fazer pull-to-refresh
      
      // IMPORTANTE: Verificar garantia DIRETAMENTE do LocalCollateralService
      final collateralService = LocalCollateralService();
      final localCollateral = await collateralService.getCollateral();
      _hasCollateral = localCollateral != null;
      debugPrint('✅ Verificação direta de garantia: hasCollateral=$_hasCollateral');
      if (localCollateral != null) {
        debugPrint('   Tier: ${localCollateral.tierName} (${localCollateral.requiredSats} sats)');
      }
      
      // IMPORTANTE: Buscar saldo atual da carteira para verificação de tier
      int walletBalance = 0;
      int committedSats = 0;
      try {
        final breezProvider = context.read<BreezProvider>();
        final balanceInfo = await breezProvider.getBalance();
        walletBalance = int.tryParse(balanceInfo['balance']?.toString() ?? '0') ?? 0;
        debugPrint('💰 Saldo da carteira para verificação de tier: $walletBalance sats');
        
        // Pegar sats comprometidos com ordens pendentes (como cliente)
        final orderProvider = context.read<OrderProvider>();
        committedSats = orderProvider.committedSats;
        debugPrint('🔒 Sats comprometidos: $committedSats sats');
      } catch (e) {
        debugPrint('⚠️ Erro ao buscar saldo da carteira: $e');
      }
      
      // Também atualizar o CollateralProvider para manter consistência
      // IMPORTANTE: Passar saldo da carteira para verificação correta
      final collateralProvider = context.read<CollateralProvider>();
      await collateralProvider.initialize(
        widget.providerId,
        walletBalance: walletBalance,
        committedSats: committedSats,
      );
      debugPrint('✅ CollateralProvider inicializado com saldo=$walletBalance, hasCollateral: ${collateralProvider.hasCollateral}');
      
      List<Map<String, dynamic>> orders;
      
      // SEMPRE buscar ordens do OrderProvider (modo P2P via Nostr)
      debugPrint('📦 Buscando ordens do OrderProvider (modo PROVEDOR)...');
      final orderProvider = context.read<OrderProvider>();
      
      // Sincronizar com Nostr - modo PROVEDOR busca TODAS as ordens pendentes
      await orderProvider.fetchOrders(forProvider: true);
      
      debugPrint('📦 OrderProvider tem ${orderProvider.orders.length} ordens');
      
      // Log detalhado de TODAS as ordens
      for (var i = 0; i < orderProvider.orders.length; i++) {
        final order = orderProvider.orders[i];
        debugPrint('   [$i] Ordem ${order.id.substring(0, 8)}: status="${order.status}", amount=${order.amount}, pubkey=${order.userPubkey?.substring(0, 8) ?? "null"}');
      }
      
      // Pegar o pubkey do provedor atual para excluir suas próprias ordens
      final nostrService = NostrService();
      final currentPubkey = nostrService.publicKey;
      debugPrint('👤 Pubkey do provedor atual: ${currentPubkey?.substring(0, 8) ?? "null"}...');
      
      orders = await _escrowService.getAvailableOrdersForProvider(
        providerId: widget.providerId,
        orders: orderProvider.orders,
        currentUserPubkey: currentPubkey,
      );
      debugPrint('📦 ${orders.length} ordens disponíveis para provedor');

      if (mounted) {
        debugPrint('🔵 Atualizando estado com ${orders.length} ordens');
        setState(() {
          _availableOrders = orders;
          _isLoading = false;
        });
        debugPrint('✅ Estado atualizado com sucesso');
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
        title: const Text('Ordens Disponíveis'),
        actions: [
          IconButton(
            icon: const Icon(Icons.assignment),
            onPressed: () {
              Navigator.pushNamed(
                context,
                '/provider-my-orders',
                arguments: widget.providerId,
              );
            },
            tooltip: 'Minhas Ordens',
          ),
          IconButton(
            icon: const Icon(Icons.account_balance_wallet),
            onPressed: () {
              // Ir para carteira principal (unificada)
              Navigator.pushNamed(context, '/wallet');
            },
            tooltip: 'Minha Carteira',
          ),
          // Menu com mais opções
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              switch (value) {
                case 'tier':
                  Navigator.pushNamed(context, '/provider-collateral');
                  break;
                case 'education':
                  Navigator.pushNamed(context, '/provider-education');
                  break;
                case 'refresh':
                  _loadOrders();
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'tier',
                child: Row(
                  children: [
                    Icon(Icons.upgrade, color: Colors.orange),
                    SizedBox(width: 12),
                    Text('Upgrade de Tier'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'education',
                child: Row(
                  children: [
                    Icon(Icons.school, color: Colors.blue),
                    SizedBox(width: 12),
                    Text('Como Funciona'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'refresh',
                child: Row(
                  children: [
                    Icon(Icons.refresh, color: Colors.green),
                    SizedBox(width: 12),
                    Text('Atualizar Ordens'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Consumer2<CollateralProvider, OrderProvider>(
        builder: (context, collateralProvider, orderProvider, child) {
          // Mostrar loading primeiro
          if (_isLoading) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.orange),
            );
          }
          
          // Verificar garantia local
          if (!AppConfig.providerTestMode && !_hasCollateral && !collateralProvider.hasCollateral) {
            return _buildNoCollateralView();
          }

          if (_error != null) {
            return _buildErrorView();
          }

          if (_availableOrders.isEmpty) {
            return _buildEmptyView();
          }

          return RefreshIndicator(
            onRefresh: _loadOrders,
            color: Colors.orange,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Card de status do tier
                _buildTierStatusCard(collateralProvider),
                const SizedBox(height: 16),
                // Lista de ordens
                ..._availableOrders.map((order) => _buildOrderCard(order, collateralProvider)),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Card mostrando o tier atual e opção de upgrade
  Widget _buildTierStatusCard(CollateralProvider collateralProvider) {
    final currentTier = collateralProvider.getCurrentTier();
    final maxOrder = collateralProvider.getMaxOrderValue();
    
    // Em modo teste, mostrar tier Trial
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
        boxShadow: [
          BoxShadow(
            color: Colors.deepPurple.withOpacity(0.3),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.verified,
              color: Colors.white,
              size: 32,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Tier: $tierName',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Aceita ordens até $tierMax',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.8),
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.pushNamed(context, '/provider-collateral');
            },
            icon: const Icon(Icons.upgrade, size: 18),
            label: const Text('Upgrade'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ],
      ),
    );
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
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
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
                Navigator.pushNamed(
                  context,
                  '/provider-collateral',
                  arguments: widget.providerId,
                );
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
            Text(
              'Erro: $_error',
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _loadOrders,
              child: const Text('Tentar Novamente'),
            ),
          ],
        ),
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
              'Nenhuma ordem disponível',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Novas ordens aparecerão aqui quando usuários criarem pedidos compatíveis com seu nível de garantia.',
              style: TextStyle(color: Colors.white70, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _loadOrders,
              icon: const Icon(Icons.refresh),
              label: const Text('Atualizar'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderCard(Map<String, dynamic> order, CollateralProvider collateralProvider) {
    final orderId = order['id'] as String;
    final amount = (order['amount'] as num).toDouble();
    final paymentType = order['payment_type'] as String? ?? 'pix';
    final createdAt = DateTime.parse(order['created_at'] as String);
    final timeAgo = _getTimeAgo(createdAt);
    final userName = order['user_name'] as String? ?? 'Usuário';
    
    // Verificar se pode aceitar e obter razão se não puder
    bool canAccept;
    String? rejectReason;
    
    if (AppConfig.providerTestMode) {
      canAccept = true;
      rejectReason = null;
    } else {
      final (canAcceptResult, reason) = collateralProvider.canAcceptOrderWithReason(amount);
      canAccept = canAcceptResult;
      rejectReason = reason;
    }
    
    final requiredTier = AppConfig.providerTestMode ? null : collateralProvider.getRequiredTier(amount);

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
          onTap: canAccept
              ? () {
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
              : null,
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
                          _getPaymentIcon(paymentType),
                          color: Colors.orange,
                          size: 24,
                        ),
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
                        border: Border.all(
                          color: canAccept ? Colors.green : Colors.red,
                        ),
                      ),
                      child: Text(
                        canAccept ? 'DISPONÍVEL' : 'REQUER ${requiredTier?.name.toUpperCase() ?? "TIER SUPERIOR"}',
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
                  'Taxa: R\$ ${(amount * EscrowService.providerFeePercent / 100).toStringAsFixed(2)} (${EscrowService.providerFeePercent}%)',
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
                    const Icon(Icons.person_outline, color: Colors.white54, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      userName,
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const Spacer(),
                    const Icon(Icons.access_time, color: Colors.white54, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      timeAgo,
                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                  ],
                ),
                if (!canAccept) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber, color: Colors.red, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            rejectReason ?? 'Você precisa do tier ${requiredTier?.name ?? "superior"} para aceitar esta ordem',
                            style: const TextStyle(color: Colors.red, fontSize: 11),
                          ),
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
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ProviderOrderDetailScreen(
                              orderId: orderId,
                              providerId: widget.providerId,
                            ),
                          ),
                        ).then((_) => _loadOrders());
                      },
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
