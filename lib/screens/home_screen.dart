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
import 'new_trade_screen.dart';
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeBreezSdk();
      _loadData();
      _fetchBitcoinPrice();
      _startPricePolling();
    });
  }

  Future<void> _initializeBreezSdk() async {
    final breezProvider = context.read<BreezProvider>();

    if (!breezProvider.isInitialized) {
      debugPrint('Inicializando Breez SDK Spark...');

      try {
        final success = await breezProvider.initialize().timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            debugPrint('Timeout na inicializacao do Breez SDK');
            return false;
          },
        );

        if (!success && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Breez SDK nao inicializou completamente.'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 5),
            ),
          );
        }
      } catch (e) {
        debugPrint('Erro ao inicializar Breez SDK: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Erro ao inicializar carteira: $e'),
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
      final price = await ApiService().getBitcoinPrice();
      if (mounted) {
        setState(() {
          _btcPrice = price ?? _btcPrice;
        });
      }
    } catch (_) {
      // Mantem ultimo valor conhecido
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: _buildAppBar(),
      body: RefreshIndicator(
        onRefresh: () async {
          await _loadData();
          await _fetchBitcoinPrice();
        },
        backgroundColor: const Color(0xFF1A1A1A),
        color: const Color(0xFFFF6B6B),
        child: Consumer2<BreezProvider, OrderProvider>(
          builder: (context, breezProvider, orderProvider, child) {
            if (breezProvider.isLoading || orderProvider.isLoading) {
              return const Center(
                child: CircularProgressIndicator(
                  color: Color(0xFFFF6B6B),
                ),
              );
            }

            return _buildContent(breezProvider, orderProvider);
          },
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: const Color(0xF70A0A0A),
      elevation: 0,
      systemOverlayStyle: SystemUiOverlayStyle.light,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(
          color: const Color(0x33FF6B35),
          height: 1,
        ),
      ),
      title: Row(
        children: [
          // Logo Bro
          GestureDetector(
            onLongPress: () {
              Navigator.pushNamed(context, '/platform-balance');
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/images/bro-logo.png',
                height: 48,
                width: 48,
                fit: BoxFit.contain,
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Descricao
          const Expanded(
            child: Text(
              'Escambo digital via Nostr',
              style: TextStyle(
                fontSize: 12,
                color: Color(0xB3FFFFFF),
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.settings_outlined, color: Colors.white),
          onPressed: _showUserSettings,
          tooltip: 'Configuracoes',
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: TextButton.icon(
            onPressed: _logout,
            icon: const Icon(Icons.logout, color: Color(0xFFFF6B6B), size: 18),
            label: const Text(
              'Sair',
              style: TextStyle(
                color: Color(0xFFFF6B6B),
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
      padding: const EdgeInsets.all(12),
      children: [
        // Stats Row (4 cards)
        _buildStatsRow(breezProvider, orderProvider),
        const SizedBox(height: 12),

        // Action Buttons
        _buildActionButtons(),
        const SizedBox(height: 12),

        // Nostr Messages Button
        _buildNostrMessagesButton(),
        const SizedBox(height: 12),

        // My Orders Button
        _buildMyOrdersButton(),
        const SizedBox(height: 12),

        // Provider Mode Button
        _buildProviderModeButton(),
        const SizedBox(height: 12),

        // Transactions List
        _buildTransactionsList(orderProvider),

        // Footer
        const SizedBox(height: 12),
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
      childAspectRatio: 1.4,
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
          iconWidget: Image.asset(
            'assets/images/bitcoin-logo.png',
            height: 28,
            width: 28,
          ),
          value: btcPriceFormatted,
          label: 'Preco do Bitcoin',
        ),
      ],
    );
  }

  Widget _buildActionButtons() {
    return Row(
      children: [
        Expanded(
          child: GradientButton(
            text: 'Nova Troca',
            icon: Icons.swap_horiz,
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const NewTradeScreen()),
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
              foregroundColor: const Color(0xFFFF6B6B),
              side: const BorderSide(color: Color(0xFFFF6B6B)),
            ),
            onPressed: () async {
              await _loadData();
              await _fetchBitcoinPrice();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Dashboard atualizado!'),
                    backgroundColor: Color(0xFFFF6B6B),
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
        color: const Color(0x0DFFFFFF),
        border: Border.all(
          color: const Color(0x33FF6B35),
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
                colors: [Color(0xFFFF6B6B), Color(0xFFFF8A8A)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
              ),
            ),
            child: const Row(
              children: [
                Icon(Icons.receipt_long, color: Colors.white),
                SizedBox(width: 12),
                Text(
                  'Minhas Trocas',
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
                          _showOrderDetails(order);
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
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: const Column(
        children: [
          Text(
            '🔐 Privacidade first • Lightning fast',
            style: TextStyle(
              color: Color(0xFFFF6B6B),
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
    debugPrint('Navegando para detalhes da ordem: ${order.id}');

    if (!mounted) return;

    try {
      final amountSats = (order.btcAmount * 100000000).toInt();

      await Navigator.pushNamed(
        context,
        '/order-status',
        arguments: {
          'orderId': order.id,
          'userId': '',
          'amountBrl': order.amount,
          'amountSats': amountSats,
        },
      );
    } catch (e) {
      debugPrint('Erro ao navegar: $e');
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
        padding: const EdgeInsets.all(12),
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
        child: const Row(
          children: [
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
        final storage = StorageService();
        final userId = await storage.getUserId() ?? 'temp';

        Navigator.pushNamed(
          context,
          '/user-orders',
          arguments: {'userId': userId},
        );
      },
      child: Container(
        padding: const EdgeInsets.all(12),
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
        child: const Row(
          children: [
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
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Veja seu historico de trocas',
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

  Widget _buildProviderModeButton() {
    return GestureDetector(
      onTap: () {
        Navigator.pushNamed(context, '/provider-education');
      },
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF3DE98C), Color(0xFF00CC7A)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF3DE98C).withOpacity(0.3),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: const Row(
          children: [
            Icon(Icons.volunteer_activism, color: Colors.white, size: 28),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Seja um Bro',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Aceite trocas P2P',
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

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Sair da conta?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Voce sera desconectado e precisara fazer login novamente.',
          style: TextStyle(color: Color(0xB3FFFFFF)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar', style: TextStyle(color: Color(0xB3FFFFFF))),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF6B6B),
            ),
            child: const Text('Sair', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final orderProvider = context.read<OrderProvider>();
      await orderProvider.clearAllOrders();

      final storage = StorageService();
      await storage.logout();

      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const LoginScreen()),
          (route) => false,
        );
      }
    }
  }
}

class EmptyTransactionState extends StatelessWidget {
  const EmptyTransactionState({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(32),
      child: const Column(
        children: [
          Icon(
            Icons.receipt_long_outlined,
            size: 64,
            color: Color(0x4DFFFFFF),
          ),
          SizedBox(height: 16),
          Text(
            'Nenhuma troca ainda',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Color(0x99FFFFFF),
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Suas trocas aparecerao aqui',
            style: TextStyle(
              fontSize: 14,
              color: Color(0x66FFFFFF),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}


