import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../providers/breez_provider_export.dart';
import '../providers/order_provider.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../widgets/stat_card.dart';
import '../widgets/gradient_button.dart';
import '../widgets/transaction_card.dart';
import '../widgets/first_time_seed_dialog.dart';
import 'payment_screen.dart';
import 'login_screen.dart';
import 'provider_dashboard_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _currencyFormat = NumberFormat.currency(locale: 'pt_BR', symbol: 'R\$');
  double _btcPrice = 0.0;
  Timer? _priceUpdateTimer;

  @override
  void initState() {
    super.initState();
    // Evita notifyListeners durante o build inicial
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // NÃO await - deixa rodar em paralelo para não travar
      // Comentado temporariamente para debug do travamento
      // _initializeBreezSdk();
      _loadData();
      _fetchBitcoinPrice();
      _startPricePolling();
    });
  }

  /// Inicializa Breez SDK automaticamente
  Future<void> _initializeBreezSdk() async {
    final breezProvider = context.read<BreezProvider>();
    
    if (!breezProvider.isInitialized) {
      debugPrint('🚀 Inicializando Breez SDK Spark...');
      
      try {
        // Timeout de 30 segundos para evitar travamento eterno
        final success = await breezProvider.initialize().timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            debugPrint('⏰ Timeout na inicialização do Breez SDK');
            return false;
          },
        );
        
        if (success && breezProvider.mnemonic != null && mounted) {
          // Aguardar 1 segundo para UI estar completamente pronta
          await Future.delayed(const Duration(seconds: 1));
          if (mounted) {
            // Mostrar seed apenas na primeira vez (agora com await para garantir contexto)
            await FirstTimeSeedDialog.showIfNeeded(context, breezProvider.mnemonic);
          }
        } else if (!success && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⚠️ Breez SDK não inicializou completamente. Algumas funcionalidades podem estar limitadas.'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 5),
            ),
          );
        }
      } catch (e) {
        debugPrint('❌ Erro ao inicializar Breez SDK: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('❌ Erro ao inicializar carteira: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  @override
  void dispose() {
    _priceUpdateTimer?.cancel();
    super.dispose();
  }

  /// Inicia polling automático do preço BTC a cada 30 segundos
  void _startPricePolling() {
    _priceUpdateTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _fetchBitcoinPrice();
    });
  }

  Future<void> _loadData() async {
  final breezProvider = context.read<BreezProvider>();
    final orderProvider = context.read<OrderProvider>();
    
    await Future.wait([
      breezProvider.refresh(),
      orderProvider.fetchOrders(),
    ]);
  }

  Future<void> _fetchBitcoinPrice() async {
    try {
      final api = context.read<OrderProvider>();
      // Usa ApiService através do provider para manter mesma instância/config
      final price = await ApiService().getBitcoinPrice();
      if (mounted) {
        setState(() {
          _btcPrice = price ?? _btcPrice;
        });
      }
    } catch (_) {
      // Mantém último valor conhecido
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A), // --dark-bg
      appBar: _buildAppBar(),
      body: RefreshIndicator(
        onRefresh: () async {
          await _loadData();
          await _fetchBitcoinPrice();
        },
        backgroundColor: const Color(0xFF1A1A1A),
        color: const Color(0xFFFF6B35),
  child: Consumer2<BreezProvider, OrderProvider>(
          builder: (context, breezProvider, orderProvider, child) {
            if (breezProvider.isLoading || orderProvider.isLoading) {
              return const Center(
                child: CircularProgressIndicator(
                  color: Color(0xFFFF6B35),
                ),
              );
            }

            return _buildContent(breezProvider, orderProvider);
          },
        ),
      ),
      // floatingActionButton removido (Lightning Test)
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xF70A0A0A), // rgba(10, 10, 10, 0.98)
      elevation: 0,
      systemOverlayStyle: SystemUiOverlayStyle.light,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(
          color: const Color(0x33FF6B35), // rgba(255, 107, 53, 0.2)
          height: 1,
        ),
      ),
      title: Row(
        children: [
          GestureDetector(
            onLongPress: () {
              Navigator.pushNamed(context, '/platform-balance');
            },
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFFF6B35), Color(0xFFFF8F65)],
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.currency_bitcoin, size: 24, color: Colors.white),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Paga Conta P2P',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  'Escambo digital via nostr',
                  style: TextStyle(
                    fontSize: 10,
                    color: Color(0xB3FFFFFF),
                    fontWeight: FontWeight.w400,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.settings_outlined, color: Colors.white),
          onPressed: _showUserSettings,
          tooltip: 'Configurações',
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: TextButton.icon(
            onPressed: _logout,
            icon: const Icon(Icons.logout, color: Color(0xFFFF6B35), size: 18),
            label: const Text(
              'Sair',
              style: TextStyle(
                color: Color(0xFFFF6B35),
                fontWeight: FontWeight.w600,
              ),
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildContent(BreezProvider breezProvider, OrderProvider orderProvider) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Stats Row (4 cards)
        _buildStatsRow(breezProvider, orderProvider),
        const SizedBox(height: 24),

        // Action Buttons
        _buildActionButtons(),
        const SizedBox(height: 16),

        // Nostr Messages Button
        _buildNostrMessagesButton(),
        const SizedBox(height: 16),

        // My Orders Button
        _buildMyOrdersButton(),
        const SizedBox(height: 16),

        // Provider Mode Button
        _buildProviderModeButton(),
        const SizedBox(height: 24),

        // Transactions List
        _buildTransactionsList(orderProvider),
        
        // Footer
        const SizedBox(height: 24),
        _buildFooter(),
      ],
    );
  }

  Widget _buildStatsRow(BreezProvider breezProvider, OrderProvider orderProvider) {
    final totalBills = orderProvider.orders.length;
    final pendingBills = orderProvider.orders.where((o) => o.status == 'pending').length;
    final completedToday = orderProvider.orders
        .where((o) => 
          o.status == 'completed' && 
          o.createdAt != null &&
          _isToday(o.createdAt!)
        )
        .length;
    
    final btcPriceFormatted = _currencyFormat.format(_btcPrice);

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 12,
      mainAxisSpacing: 12,
      childAspectRatio: 1.1,
      children: [
        StatCard(
          emoji: '📋',
          value: '$totalBills',
          label: 'Ordens Criadas',
        ),
        StatCard(
          emoji: '⏳',
          value: '$pendingBills',
          label: 'Aguardando Pagamento',
        ),
        StatCard(
          emoji: '✅',
          value: '$completedToday',
          label: 'Finalizadas Hoje',
        ),
        StatCard(
          emoji: '₿',
          value: btcPriceFormatted,
          label: 'Preço do Bitcoin',
        ),
      ],
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        Expanded(
          child: GradientButton(
            text: 'Pagar Nova Conta',
            icon: Icons.payment,
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PaymentScreen()),
              );
            },
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Atualizar'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFFF6B35),
              side: const BorderSide(color: Color(0xFFFF6B35)),
            ),
            onPressed: () async {
              await _loadData();
              await _fetchBitcoinPrice();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Dashboard atualizado!'),
                    backgroundColor: Color(0xFFFF6B35),
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTransactionsList(OrderProvider orderProvider) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF), // rgba(255, 255, 255, 0.05)
        border: Border.all(
          color: const Color(0x33FF6B35), // rgba(255, 107, 53, 0.2)
          width: 1,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(20),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFFFF6B35), Color(0xFFFF8F65)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
              ),
            ),
            child: Row(
              children: const [
                Icon(Icons.receipt_long, color: Colors.white),
                SizedBox(width: 12),
                Text(
                  'Minhas Transações',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          
          // Body
          Container(
            padding: const EdgeInsets.all(20),
            child: orderProvider.orders.isEmpty
                ? const EmptyTransactionState()
                : Column(
                    children: orderProvider.orders.map((order) {
                      return TransactionCard(
                        title: order.billType == 'pix' ? 'PIX' : 'Boleto',
                        amount: _currencyFormat.format(order.amount),
                        status: order.status,
                        statusLabel: _getStatusLabel(order.status),
                        onTap: () {
                          debugPrint('🔍 Card clicado - ID: ${order.id}, Status: ${order.status}');
                          
                          // Garantir que estamos no contexto correto
                          if (!mounted) {
                            debugPrint('⚠️ Widget não montado');
                            return;
                          }
                          
                          try {
                            _showOrderDetails(order);
                          } catch (e) {
                            debugPrint('❌ Erro ao abrir detalhes: $e');
                          }
                        },
                      );
                    }).toList(),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: const Column(
        children: [
          Text(
            '🔐 Privacidade first • Lightning fast',
            style: TextStyle(
              color: Color(0xFFFF6B35),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  String _getStatusLabel(String status) {
    switch (status.toLowerCase()) {
      case 'pending':
        return 'Pendente';
      case 'processing':
        return 'Processando';
      case 'completed':
      case 'paid':
        return 'Pago';
      case 'cancelled':
        return 'Cancelado';
      case 'failed':
        return 'Falhou';
      default:
        return status;
    }
  }

  bool _isToday(DateTime date) {
    final now = DateTime.now();
    return date.year == now.year &&
           date.month == now.month &&
           date.day == now.day;
  }

  void _showOrderDetails(dynamic order) async {
    debugPrint('🔍 Navegando para detalhes da ordem: ${order.id}, Status: ${order.status}');
    
    if (!mounted) {
      debugPrint('⚠️ Widget não montado');
      return;
    }
    
    try {
      // Todas as ordens vão para a mesma tela de status
      // (tanto ativas quanto completas)100,000,000 sats)
      final amountSats = (order.btcAmount * 100000000).toInt();
      
      await Navigator.pushNamed(
        context,
        '/order-status',
        arguments: {
          'orderId': order.id,
          'userId': '', // Order não tem userId, passar vazio
          'amountBrl': order.amount,
          'amountSats': amountSats,
        },
      );
      
      debugPrint('✅ Navegação concluída');
    } catch (e) {
      debugPrint('❌ Erro ao navegar: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erro ao abrir ordem: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Color(0x99FFFFFF),
              fontSize: 14,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  void _showUserSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const SettingsScreen()),
    );
  }

  Widget _buildNostrMessagesButton() {
    return GestureDetector(
      onTap: () {
        Navigator.pushNamed(context, '/nostr-messages');
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF9C27B0), Color(0xFFBA68C8)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF9C27B0).withOpacity(0.3),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: const [
            Icon(Icons.chat_bubble_outline, color: Colors.white, size: 28),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Mensagens Nostr',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Chat privado P2P criptografado',
                    style: TextStyle(
                      fontSize: 13,
                      color: Color(0xCCFFFFFF),
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios, color: Colors.white70, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _buildMyOrdersButton() {
    return GestureDetector(
      onTap: () async {
        // Obter userId do storage
        final storage = StorageService();
        final userId = await storage.getUserId() ?? 'temp';
        
        Navigator.pushNamed(
          context,
          '/user-orders',
          arguments: {'userId': userId},
        );
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF4A90E2), Color(0xFF5BA3F5)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF4A90E2).withOpacity(0.3),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: const [
            Icon(Icons.receipt_long, color: Colors.white, size: 28),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Minhas Ordens',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Acompanhe status de negociações',
                    style: TextStyle(
                      fontSize: 13,
                      color: Color(0xE6FFFFFF),
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios, color: Colors.white, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildProviderModeButton() {
    return GestureDetector(
      onTap: () {
        // Navegue para tela educacional primeiro
        Navigator.pushNamed(context, '/provider-education');
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF4CAF50), Color(0xFF66BB6A)], // VERDE
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF4CAF50).withOpacity(0.3),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: const [
            Icon(Icons.monetization_on, color: Colors.white, size: 28),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Modo Provedor',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Aceite ordens P2P',
                    style: TextStyle(
                      fontSize: 13,
                      color: Color(0xE6FFFFFF),
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios, color: Colors.white, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildPlatformBalanceButton() {
    return GestureDetector(
      onTap: () {
        Navigator.pushNamed(context, '/platform-balance');
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF6C63FF), Color(0xFF5A52D5)], // ROXO
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF6C63FF).withOpacity(0.3),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: const [
            Icon(Icons.account_balance, color: Colors.white, size: 28),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '💼 Saldo da Plataforma',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Visualize taxas acumuladas (Gestora)',
                    style: TextStyle(
                      fontSize: 13,
                      color: Color(0xE6FFFFFF),
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.arrow_forward_ios, color: Colors.white, size: 20),
          ],
        ),
      ),
    );
  }

  void _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Sair', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Deseja realmente sair?',
          style: TextStyle(color: Color(0x99FFFFFF)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar', style: TextStyle(color: Color(0x99FFFFFF))),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sair', style: TextStyle(color: Color(0xFFFF6B35))),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      // Limpar ordens (histórico da conta)
      final orderProvider = context.read<OrderProvider>();
      await orderProvider.clearAllOrders();
      
      // Limpar dados de login
      final storage = StorageService();
      await storage.logout();
      
      debugPrint('🚪 Logout realizado - dados de login e ordens limpos');
      
      // Navegar para LoginScreen
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    }
  }
}
