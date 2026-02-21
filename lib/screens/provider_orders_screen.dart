import 'dart:async';
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
import '../services/bitcoin_price_service.dart';
import '../models/collateral_tier.dart';
import '../config.dart';
import 'provider_order_detail_screen.dart';

/// Helper para substring seguro - evita RangeError em strings curtas
String _safeSubstring(String? s, int start, int end) {
  if (s == null) return 'null';
  if (s.length <= start) return s;
  return s.substring(start, s.length < end ? s.length : end);
}

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
  final LocalCollateralService _collateralService = LocalCollateralService();
  
  late TabController _tabController;
  Timer? _ordersUpdateTimer; // Timer para atualizar ordens automaticamente
  
  List<Map<String, dynamic>> _availableOrders = [];
  List<Map<String, dynamic>> _myOrders = []; // Ordens aceitas por este provedor
  Set<String> _seenOrderIds = {};
  bool _isLoading = false;
  bool _isSyncingNostr = false;
  bool _hasCollateral = false;
  String? _error;
  int _lastOrderCount = 0;
  String? _currentPubkey;
  int _lastTabIndex = 0; // Para detectar mudança de aba
  
  // SEGURANÇA: Referência para cleanup no dispose
  OrderProvider? _orderProviderRef;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    
    // Adicionar listener para ressincronizar ao mudar de aba
    _tabController.addListener(_onTabChanged);
    
    
    // Salvar modo provedor com pubkey do usuário
    SecureStorageService.setProviderMode(true, userPubkey: widget.providerId);
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadOrders();
      _startOrdersPolling(); // Iniciar polling de ordens
    });
  }
  
  void _startOrdersPolling() {
    // CORREÇÃO: Intervalo aumentado para 45s para dar tempo da sincronização completa
    // A busca de ordens do provedor pode demorar até 60s devido às múltiplas consultas Nostr
    _ordersUpdateTimer = Timer.periodic(const Duration(seconds: 45), (_) async {
      // Verificar mounted ANTES de qualquer operação
      if (!mounted) {
        _ordersUpdateTimer?.cancel();
        return;
      }
      
      // Evitar polling durante loading ou sync
      if (_isLoading || _isSyncingNostr) {
        return;
      }
      
      try {
        final orderProvider = context.read<OrderProvider>();
        debugPrint('⏱️ Timer: chamando fetchOrders(forProvider: true)');
        await orderProvider.fetchOrders(forProvider: true);
        debugPrint('⏱️ Timer: fetchOrders completou, available=${orderProvider.availableOrdersForProvider.length}');
        
        // Verificar mounted novamente após operação async
        if (mounted) {
          _loadOrdersFromProvider();
        }
      } catch (e) {
        debugPrint('⏱️ Timer: erro - $e');
        // Não travar a UI - apenas logar o erro
      }
    });
  }
  
  void _loadOrdersFromProvider() {
    if (!mounted) return;
    final orderProvider = context.read<OrderProvider>();
    
    final accepted = orderProvider.myAcceptedOrders;
    final allAvailable = orderProvider.availableOrdersForProvider;
    
    // CORREÇÃO: Aplicar mesmo filtro de status que _loadOrders
    // Só mostrar ordens pending e payment_received (usuário já pagou)
    final filteredAvailable = allAvailable.where((o) {
      return o.status == 'pending' || o.status == 'payment_received';
    }).toList();
    
    debugPrint('📋 _loadOrdersFromProvider: ${allAvailable.length} total, ${filteredAvailable.length} filtradas, ${accepted.length} aceitas');
    
    setState(() {
      _availableOrders = filteredAvailable
          .map((o) {
            final orderMap = o.toJson();
            orderMap['amount'] = o.amount;
            orderMap['payment_type'] = o.billType;
            orderMap['created_at'] = o.createdAt.toIso8601String();
            orderMap['user_name'] = 'Usuário ${o.userPubkey?.substring(0, 6) ?? "anon"}';
            return orderMap;
          })
          .toList();
      _myOrders = accepted
          .map((o) {
            final orderMap = o.toJson();
            orderMap['amount'] = o.amount;
            orderMap['payment_type'] = o.billType;
            orderMap['created_at'] = o.createdAt.toIso8601String();
            orderMap['user_name'] = 'Usuário ${o.userPubkey?.substring(0, 6) ?? "anon"}';
            return orderMap;
          })
          .toList();
    });
  }
  
  /// Handler para mudança de aba - usa dados locais (sem resync Nostr)
  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    
    final newIndex = _tabController.index;
    if (newIndex != _lastTabIndex) {
      _lastTabIndex = newIndex;
      
      // Apenas recarregar dados locais (sem buscar no Nostr novamente)
      _loadOrdersFromProvider();
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _ordersUpdateTimer?.cancel(); // Cancelar timer de atualização
    
    // CRÍTICO: Limpar modo provedor E ordens de outros usuários
    // Isso é ESSENCIAL para evitar vazamento de dados!
    SecureStorageService.setProviderMode(false, userPubkey: widget.providerId);
    
    // SEGURANÇA: Chamar exitProviderMode usando a referência salva
    // Isso GARANTE que ordens de outros usuários sejam removidas da memória
    try {
      _orderProviderRef?.exitProviderMode();
    } catch (e) {
    }
    
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    
    // SEGURANÇA CRÍTICA: Capturar referência ao OrderProvider para uso no dispose
    // Isso garante que podemos limpar ordens mesmo quando o contexto está inválido
    _orderProviderRef = Provider.of<OrderProvider>(context, listen: false);
    
    if (AppConfig.testMode && mounted) {
      if (_orderProviderRef!.orders.length != _lastOrderCount) {
        _lastOrderCount = _orderProviderRef!.orders.length;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loadOrders();
        });
      }
    }
  }

  Future<void> _loadOrders({bool isRefresh = false}) async {
    if (!mounted) {
      return;
    }
    
    // CORREÇÃO: Não mostrar loading spinner no pull-to-refresh
    // Senão o RefreshIndicator é removido da tree e o usuário não vê o refresh
    if (!isRefresh) {
      setState(() {
        _isLoading = true;
        _isSyncingNostr = true;
        _error = null;
      });
    } else {
      setState(() {
        _isSyncingNostr = true;
        _error = null;
      });
    }

    try {
      // PERFORMANCE: Buscar prereqs e ordens EM PARALELO (não sequencial)
      final collateralService = LocalCollateralService();
      final breezProvider = context.read<BreezProvider>();
      final orderProvider = context.read<OrderProvider>();
      
      // Executar tudo em paralelo
      // Separar fetchOrders (void) dos que retornam valores
      final collateralFuture = collateralService.getCollateral();
      final balanceFuture = breezProvider.getBalance();
      final fetchOrdersFuture = orderProvider.fetchOrders(forProvider: true);
      
      await Future.wait([collateralFuture, balanceFuture, fetchOrdersFuture]);
      
      final localCollateral = await collateralFuture;
      _hasCollateral = localCollateral != null;
      
      final balanceInfo = await balanceFuture;
      final walletBalance = int.tryParse(balanceInfo['balance']?.toString() ?? '0') ?? 0;
      final committedSats = orderProvider.committedSats;
      
      final collateralProvider = context.read<CollateralProvider>();
      await collateralProvider.initialize(
        widget.providerId,
        walletBalance: walletBalance,
        committedSats: committedSats,
      );
      
      if (mounted) {
        setState(() {
          _isSyncingNostr = false;
        });
      }
      
      // Pegar pubkey do provedor
      final nostrService = NostrService();
      _currentPubkey = nostrService.publicKey;
      
      // CORREÇÃO VAZAMENTO: Separar ordens corretamente!
      // - myAcceptedOrders: Ordens que EU ACEITEI como Bro (providerId == minha pubkey)
      // - availableOrdersForProvider: Ordens de OUTROS disponíveis para aceitar
      // NUNCA usar 'orders' que inclui ordens criadas pelo usuário!
      final myOrdersFromProvider = orderProvider.myAcceptedOrders;
      final availableFromProvider = orderProvider.availableOrdersForProvider;
      List<Map<String, dynamic>> available = [];
      List<Map<String, dynamic>> myOrders = [];
      
      // Processar ordens que EU ACEITEI como provedor
      for (final order in myOrdersFromProvider) {
        final orderMap = order.toJson();
        orderMap['amount'] = order.amount;
        orderMap['payment_type'] = order.billType;
        orderMap['created_at'] = order.createdAt.toIso8601String();
        orderMap['user_name'] = 'Usuário ${order.userPubkey?.substring(0, 6) ?? "anon"}';
        myOrders.add(orderMap);
      }
      
      // Processar ordens disponíveis para aceitar (de outros usuários)
      // FILTRO: Mostrar ordens pending e payment_received (já pagaram via Lightning)
      for (final order in availableFromProvider) {
        // CORREÇÃO: Incluir payment_received — são ordens onde o usuário já pagou!
        if (order.status != 'pending' && order.status != 'payment_received') {
          continue;
        }
        
        final orderMap = order.toJson();
        orderMap['amount'] = order.amount;
        orderMap['payment_type'] = order.billType;
        orderMap['created_at'] = order.createdAt.toIso8601String();
        orderMap['user_name'] = 'Usuário ${order.userPubkey?.substring(0, 6) ?? "anon"}';
        available.add(orderMap);
      }
      
      // Notificar sobre novas ordens disponíveis
      for (final order in available) {
        final orderId = order['id'] as String? ?? '';
        if (orderId.isEmpty) continue; // Pular ordens sem ID
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
      
      // ========== REGISTRAR GANHOS DE ORDENS COMPLETADAS ==========
      // Verificar ordens completadas e registrar ganhos que ainda não foram registrados
      final providerBalanceProvider = context.read<ProviderBalanceProvider>();
      for (final order in myOrders) {
        final status = order['status'] as String?;
        if (status == 'completed') {
          final orderId = order['id'] as String? ?? '';
          if (orderId.isEmpty) continue; // Pular ordens sem ID
          final amount = (order['amount'] as num?)?.toDouble() ?? 0;
          final btcAmount = (order['btcAmount'] as num?)?.toDouble() ?? 0;
          
          // Calcular ganho: 3% do valor em sats
          final totalSats = (btcAmount * 100000000).round();
          var providerFeeSats = (totalSats * EscrowService.providerFeePercent / 100).round();
          if (providerFeeSats < 1 && totalSats > 0) providerFeeSats = 1;
          
          // Tentar registrar ganho (método verifica se já foi registrado para evitar duplicação)
          final registered = await providerBalanceProvider.addEarning(
            orderId: orderId,
            amountSats: providerFeeSats.toDouble(),
            orderDescription: 'Ordem ${orderId.substring(0, 8)} - R\$ ${amount.toStringAsFixed(2)}',
          );
          
          if (registered) {
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
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          // CRÍTICO: Limpar modo provedor ao sair
          SecureStorageService.setProviderMode(false, userPubkey: widget.providerId);
          try {
            final orderProvider = context.read<OrderProvider>();
            orderProvider.exitProviderMode();
          } catch (e) {
          }
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF121212),
        appBar: AppBar(
          backgroundColor: const Color(0xFF1E1E1E),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              // CRÍTICO: Limpar modo provedor ao sair
              SecureStorageService.setProviderMode(false, userPubkey: widget.providerId);
              try {
                final orderProvider = context.read<OrderProvider>();
                orderProvider.exitProviderMode();
              } catch (e) {
              }
              Navigator.pop(context);
            },
          ),
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Modo Bro'),
              const SizedBox(width: 8),
              _buildTierBadge(),
            ],
          ),
          actions: [
            // Botão para voltar ao Dashboard principal
            IconButton(
              icon: const Icon(Icons.home, color: Colors.white),
              onPressed: () {
                // Sair do modo Bro e voltar ao dashboard
                SecureStorageService.setProviderMode(false, userPubkey: widget.providerId);
                try {
                  final orderProvider = context.read<OrderProvider>();
                  orderProvider.exitProviderMode();
                } catch (e) {
                }
                // Navegar para o dashboard limpando toda a pilha de navegação
                Navigator.pushNamedAndRemoveUntil(context, '/home', (route) => false);
              },
              tooltip: 'Voltar ao Dashboard',
            ),
            // Botão da Carteira Lightning
            IconButton(
              icon: const Icon(Icons.account_balance_wallet, color: Colors.orange),
              onPressed: () => Navigator.pushNamed(context, '/wallet'),
              tooltip: 'Minha Carteira',
            ),
            // Removido botão refresh - pull-to-refresh já funciona
          ],
          bottom: TabBar(
            controller: _tabController,
            indicatorColor: const Color(0xFFFF6B6B),
            labelColor: const Color(0xFFFF6B6B),
            unselectedLabelColor: Colors.white60,
            labelPadding: const EdgeInsets.symmetric(horizontal: 4),
            tabs: [
              Tab(
                icon: const Icon(Icons.local_offer, size: 20),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('Disponíveis (${_availableOrders.length})', style: const TextStyle(fontSize: 12)),
                ),
              ),
              Tab(
                icon: const Icon(Icons.assignment_turned_in, size: 20),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('Minhas (${_myOrders.length})', style: const TextStyle(fontSize: 12)),
                ),
              ),
              const Tab(
                icon: Icon(Icons.bar_chart, size: 20),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('Estatísticas', style: TextStyle(fontSize: 12)),
                ),
            ),
          ],
        ),
      ),
      body: SafeArea(
        top: false, // AppBar já lida com safe area superior
        child: Consumer2<CollateralProvider, OrderProvider>(
          builder: (context, collateralProvider, orderProvider, child) {
            // Mostrar loading enquanto sincronizando
            if (_isLoading) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CircularProgressIndicator(color: Color(0xFFFF6B6B)),
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
    ),  // Fecha PopScope
    );
  }

  // ============================================
  // TAB 1: ORDENS DISPONÍVEIS
  // ============================================
  
  Widget _buildAvailableOrdersTab(CollateralProvider collateralProvider) {
    return RefreshIndicator(
      onRefresh: () => _loadOrders(isRefresh: true),
      color: const Color(0xFFFF6B6B),
      child: _availableOrders.isEmpty
        ? ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [_buildEmptyAvailableView()],
          )
        : ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            itemCount: _availableOrders.length + 1,
            itemBuilder: (context, index) {
              if (index == _availableOrders.length) {
                return const SizedBox(height: 80);
              }
              return _buildAvailableOrderCard(_availableOrders[index], collateralProvider);
            },
          ),
    );
  }

  Widget _buildEmptyAvailableView() {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.6,
      child: Center(
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
                onPressed: () => _loadOrders(isRefresh: true),
                icon: const Icon(Icons.refresh),
                label: const Text('Atualizar'),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF6B6B)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAvailableOrderCard(Map<String, dynamic> order, CollateralProvider collateralProvider) {
    final orderId = order['id'] as String? ?? '';
    if (orderId.isEmpty) return const SizedBox.shrink(); // Ordem inválida
    
    final amount = (order['amount'] as num?)?.toDouble() ?? 0;
    final paymentType = order['payment_type'] as String? ?? 'pix';
    final createdAtStr = order['created_at'] as String?;
    final createdAt = createdAtStr != null ? DateTime.tryParse(createdAtStr) ?? DateTime.now() : DateTime.now();
    final timeAgo = _getTimeAgo(createdAt);
    final userName = order['user_name'] as String? ?? 'Usuário';
    
    bool canAccept;
    String? rejectReason;
    
    if (AppConfig.providerTestMode) {
      canAccept = true;
    } else {
      // CRÍTICO: Usar APENAS collateralProvider.canAcceptOrderWithReason()
      // NÃO usar _tierAtRisk aqui porque pode estar desatualizado!
      // O collateralProvider sempre usa dados frescos do estado atual
      final (canAcceptResult, reason) = collateralProvider.canAcceptOrderWithReason(amount);
      canAccept = canAcceptResult;
      rejectReason = reason;
      
      // Debug para rastrear
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
                    const Icon(Icons.tag, color: Colors.white54, size: 14),
                    const SizedBox(width: 4),
                    Text('${_safeSubstring(orderId, 0, 8)}', style: const TextStyle(color: Colors.white54, fontSize: 11, fontFamily: 'monospace')),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
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
      return RefreshIndicator(
        onRefresh: () => _loadOrders(isRefresh: true),
        color: const Color(0xFFFF6B6B),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.6,
              child: Center(
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
              ),
            ),
          ],
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
      onRefresh: () => _loadOrders(isRefresh: true),
      color: const Color(0xFFFF6B6B),
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        itemCount: sortedOrders.length + 1,
        itemBuilder: (context, index) {
          if (index == sortedOrders.length) {
            return const SizedBox(height: 80);
          }
          return _buildMyOrderCard(sortedOrders[index]);
        },
      ),
    );
  }

  Widget _buildMyOrderCard(Map<String, dynamic> order) {
    final orderId = order['id'] as String? ?? '';
    if (orderId.isEmpty) return const SizedBox.shrink(); // Ordem inválida
    
    final amount = (order['amount'] as num?)?.toDouble() ?? 0;
    final paymentType = order['payment_type'] ?? order['billType'] ?? 'pix';
    final status = order['status'] as String? ?? 'unknown';
    final createdAtStr = order['created_at'] ?? order['createdAt'];
    final createdAt = createdAtStr != null ? DateTime.tryParse(createdAtStr.toString()) ?? DateTime.now() : DateTime.now();
    
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
                    // ID da ordem para controle
                    const Icon(Icons.tag, color: Colors.white38, size: 12),
                    const SizedBox(width: 4),
                    Text(
                      _safeSubstring(orderId, 0, 8),
                      style: const TextStyle(color: Colors.white38, fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(Icons.access_time, color: Colors.white54, size: 14),
                    const SizedBox(width: 4),
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
      onRefresh: () => _loadOrders(isRefresh: true),
      color: const Color(0xFFFF6B6B),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
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
          const SizedBox(height: 80),
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
            onPressed: () => Navigator.pushNamed(context, '/wallet'),
            icon: const Icon(Icons.account_balance_wallet, size: 18),
            label: const Text('Ver Carteira'),
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
    ).then((result) {
      _loadOrders();
      // Se enviou comprovante, ir para aba "Minhas Ordens"
      if (result is Map && result['goToMyOrders'] == true) {
        _tabController.animateTo(1); // Aba 1 = Minhas Ordens
      }
    });
  }

  void _openMyOrderDetail(Map<String, dynamic> order) {
    final orderId = order['id'] as String? ?? '';
    if (orderId.isEmpty) return; // Ordem inválida
    
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ProviderOrderDetailScreen(
          orderId: orderId,
          providerId: widget.providerId,
        ),
      ),
    ).then((result) {
      _loadOrders();
      // Se enviou comprovante, garantir que está na aba "Minhas Ordens"
      if (result is Map && result['goToMyOrders'] == true) {
        _tabController.animateTo(1); // Aba 1 = Minhas Ordens
      }
    });
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
      case 'pending':
        return {
          'label': 'PENDENTE',
          'icon': Icons.schedule,
          'color': Colors.amber,
          'description': 'Aguardando aceitação de um Bro',
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

  /// Badge compacto do tier - USA COLLATERAL PROVIDER DIRETAMENTE para evitar inconsistências
  Widget _buildTierBadge() {
    // CRÍTICO: Usar Consumer para reagir às mudanças do CollateralProvider
    return Consumer<CollateralProvider>(
      builder: (context, collateralProvider, _) {
        final localCollateral = collateralProvider.localCollateral;
        final hasCollateral = collateralProvider.hasCollateral;
        
        
        // Se não tem tier, mostra "Sem Tier"
        if (!hasCollateral || localCollateral == null) {
          return GestureDetector(
            onTap: () => Navigator.pushNamed(context, '/provider-collateral'),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.grey.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey, width: 1),
              ),
              child: const Text(
                'Sem Tier',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                ),
              ),
            ),
          );
        }
        
        // Verificar se pode aceitar pelo menos uma ordem de R$ 1 (teste mínimo)
        // Se não pode, tier está inativo por saldo insuficiente
        final (canAcceptTest, _) = collateralProvider.canAcceptOrderWithReason(1.0);
        final isActive = canAcceptTest;
        final statusText = isActive ? 'Tier Ativo' : 'Tier Inativo';
        final statusColor = isActive ? Colors.green : Colors.orange;
        
        return GestureDetector(
          onTap: () => _showTierStatusDialog(),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: statusColor.withOpacity(0.2),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: statusColor, width: 1.5),
            ),
            child: Text(
              statusText,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: statusColor,
              ),
            ),
          ),
        );
      },
    );
  }
  
  /// Dialog explicando status do tier - USA COLLATERAL PROVIDER
  void _showTierStatusDialog() {
    final collateralProvider = context.read<CollateralProvider>();
    final localCollateral = collateralProvider.localCollateral;
    final (canAccept, _) = collateralProvider.canAcceptOrderWithReason(1.0);
    final isActive = canAccept;
    final tierName = localCollateral?.tierName ?? 'Nenhum';
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(
              isActive ? Icons.check_circle : Icons.warning_amber,
              color: isActive ? Colors.green : Colors.orange,
              size: 28,
            ),
            const SizedBox(width: 12),
            Text(
              isActive ? 'Tier Ativo' : 'Tier Inativo',
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tier: $tierName',
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 12),
            if (!isActive) ...[
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
                      '⚠️ Saldo insuficiente',
                      style: TextStyle(
                        color: Colors.orange,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Seu saldo de ${collateralProvider.effectiveBalanceSats} sats está abaixo do requerido para o tier. Deposite mais Bitcoin para reativar.',
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ] else
              const Text(
                '✅ Seu tier está ativo e você pode aceitar ordens normalmente.',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fechar', style: TextStyle(color: Colors.white70)),
          ),
          if (!isActive)
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/provider-collateral');
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
              child: const Text('Depositar'),
            ),
        ],
      ),
    );
  }
}
