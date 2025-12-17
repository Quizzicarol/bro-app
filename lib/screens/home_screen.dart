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
import 'new_trade_screen.dart';
import 'login_screen.dart';
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
      _checkAndShowBackupReminder();
    });
  }
  
  /// Mostra aviso de backup da seed para novos usuários
  Future<void> _checkAndShowBackupReminder() async {
    final storage = StorageService();
    await storage.init();
    
    // Verificar se já mostrou o aviso de backup
    final hasShownBackupReminder = await storage.getData('has_shown_backup_reminder');
    if (hasShownBackupReminder == 'true') return;
    
    // Aguardar um pouco para não atrapalhar a inicialização
    await Future.delayed(const Duration(seconds: 2));
    
    if (!mounted) return;
    
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.key, color: Colors.orange, size: 28),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Proteja seus Sats!',
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
            ),
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
                  color: Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withOpacity(0.3)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning, color: Colors.red, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Sem backup = sem acesso aos fundos!',
                        style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                '🔑 Sua Seed (12 palavras) é a chave da sua carteira Lightning.',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              const SizedBox(height: 12),
              const Text(
                '• Anote em papel e guarde em local seguro\n'
                '• NUNCA compartilhe com ninguém\n'
                '• Se perder o celular, só a seed recupera seus sats',
                style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 13),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green.withOpacity(0.3)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.green, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Faça backup agora em Configurações > Backup',
                        style: TextStyle(color: Colors.green, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'later'),
            child: const Text('Depois', style: TextStyle(color: Color(0x99FFFFFF))),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(context, 'backup'),
            icon: const Icon(Icons.key, size: 18),
            label: const Text('Ver minha Seed'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
    
    // Marcar como já mostrado
    await storage.saveData('has_shown_backup_reminder', 'true');
    
    if (result == 'backup' && mounted) {
      Navigator.pushNamed(context, '/settings');
    }
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
      if (mounted) {
        _fetchBitcoinPrice();
      }
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
      padding: const EdgeInsets.all(16),
      children: [
        // Grade de Botões de Ação (3 botões)
        _buildActionButtonsGrid(),
        const SizedBox(height: 14),

        // Métricas em linha horizontal
        _buildMetricsRow(orderProvider),
        const SizedBox(height: 16),

        // Lista de Ordens
        _buildTransactionsList(orderProvider),

        // Footer
        const SizedBox(height: 12),
        _buildFooter(),
        
        // Extra space
        const SizedBox(height: 80),
      ],
    );
  }

  Widget _buildActionButtonsGrid() {
    return Column(
      children: [
        // Primeira linha: Nova Troca + Preço Bitcoin
        Row(
          children: [
            // Nova Troca
            Expanded(
              child: _buildGridButton(
                icon: Icons.swap_horiz,
                label: 'Nova Troca',
                gradient: const [Color(0xFFFF6B6B), Color(0xFFFF8A8A)],
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const NewTradeScreen()),
                  );
                },
              ),
            ),
            const SizedBox(width: 12),
            // Preço do Bitcoin
            Expanded(
              child: _buildBitcoinPriceButton(),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Segunda linha: Minhas Ordens + Seja um Bro
        Row(
          children: [
            // Minhas Ordens
            Expanded(
              child: _buildGridButton(
                icon: Icons.receipt_long,
                label: 'Minhas Ordens',
                gradient: const [Color(0xFF4A90E2), Color(0xFF5BA3F5)],
                onTap: () async {
                  final storage = StorageService();
                  final userId = await storage.getUserId() ?? 'temp';
                  Navigator.pushNamed(
                    context,
                    '/user-orders',
                    arguments: {'userId': userId},
                  );
                },
              ),
            ),
            const SizedBox(width: 12),
            // Modo Bro
            Expanded(
              child: _buildGridButton(
                icon: Icons.volunteer_activism,
                label: 'Modo Bro',
                gradient: const [Color(0xFF3DE98C), Color(0xFF00CC7A)],
                onTap: () {
                  Navigator.pushNamed(context, '/provider-education');
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildGridButton({
    required IconData icon,
    required String label,
    required List<Color> gradient,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 90,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: gradient,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: gradient[0].withOpacity(0.3),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 28),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBitcoinPriceButton() {
    // Só mostrar preço se tiver valor real da API
    final btcPriceFormatted = _btcPrice > 0 
        ? _currencyFormat.format(_btcPrice) 
        : 'Carregando...';

    return Container(
      height: 90,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFFF7931A).withOpacity(0.3),
            const Color(0xFFF7931A).withOpacity(0.15),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFF7931A).withOpacity(0.4),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Image.asset(
            'assets/images/bitcoin-logo.png',
            height: 24,
            width: 24,
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                btcPriceFormatted,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricsRow(OrderProvider orderProvider) {
    final totalBills = orderProvider.orders.length;
    final pendingBills = orderProvider.orders.where((o) => o.status == 'pending').length;
    final completedOrders = orderProvider.orders
        .where((o) => o.status == 'completed')
        .length;

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF333333)),
      ),
      child: Row(
        children: [
          _buildMetricItem('📋', '$totalBills', 'Criadas'),
          _buildMetricDivider(),
          _buildMetricItem('⏳', '$pendingBills', 'Pendentes'),
          _buildMetricDivider(),
          _buildMetricItem('✅', '$completedOrders', 'Finalizadas'),
        ],
      ),
    );
  }

  Widget _buildMetricItem(String emoji, String value, String label) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.6),
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetricDivider() {
    return Container(
      width: 1,
      height: 40,
      color: const Color(0xFF333333),
    );
  }

  Widget _buildBtcMetricItem(String value) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset(
            'assets/images/bitcoin-logo.png',
            height: 18,
            width: 18,
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Text(
            'BTC',
            style: TextStyle(
              color: Colors.white.withOpacity(0.6),
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsRow(BreezProvider breezProvider, OrderProvider orderProvider) {
    final totalBills = orderProvider.orders.length;
    final pendingBills = orderProvider.orders.where((o) => o.status == 'pending').length;
    final completedToday = orderProvider.orders
        .where((o) =>
          o.status == 'completed' &&
          o.createdAt != null &&
          _isToday(o.createdAt)
        )
        .length;

    final btcPriceFormatted = _currencyFormat.format(_btcPrice);

    return GridView.count(
      crossAxisCount: 4,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      childAspectRatio: 0.9,
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
    return SizedBox(
      width: double.infinity,
      height: 60,
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
        return 'Aguardando Pagamento';
      case 'payment_received':
        return 'Pagamento Recebido';
      case 'confirmed':
        return 'Aguardando Bro';
      case 'accepted':
        return 'Bro Encontrado';
      case 'awaiting_confirmation':
        return 'Aguardando Confirmação';
      case 'payment_submitted':
        return 'Em Validação';
      case 'processing':
        return 'Processando';
      case 'completed':
      case 'paid':
        return 'Concluído';
      case 'cancelled':
        return 'Cancelado';
      case 'disputed':
        return 'Em Disputa';
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
                    'Modo Bro',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Ganhe sats pagando contas',
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
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.warning_amber, color: Colors.orange, size: 28),
            const SizedBox(width: 12),
            const Expanded(
              child: Text('Antes de sair...', style: TextStyle(color: Colors.white, fontSize: 18)),
            ),
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
                  color: Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withOpacity(0.3)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning, color: Colors.red, size: 24),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Você tem sats na carteira?',
                        style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                '🔑 Salve sua Seed (12 palavras)',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
              ),
              const SizedBox(height: 4),
              const Text(
                'Sua seed é a ÚNICA forma de recuperar seus sats. Sem ela, você perde acesso aos fundos para sempre.',
                style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 13),
              ),
              const SizedBox(height: 12),
              const Text(
                '💸 Ou saque seus sats',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
              ),
              const SizedBox(height: 4),
              const Text(
                'Transfira seus sats para outra carteira Lightning antes de sair.',
                style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 13),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withOpacity(0.3)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.history, color: Colors.orange, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'O histórico de ordens será perdido (salvo apenas neste dispositivo).',
                        style: TextStyle(color: Colors.orange, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actionsAlignment: MainAxisAlignment.spaceBetween,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('Cancelar', style: TextStyle(color: Color(0x99FFFFFF))),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton.icon(
                onPressed: () => Navigator.pop(context, 'backup'),
                icon: const Icon(Icons.key, color: Colors.green, size: 18),
                label: const Text('Ver Seed', style: TextStyle(color: Colors.green)),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, 'logout'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF6B6B),
                ),
                child: const Text('Sair', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ],
      ),
    );

    if (result == 'backup' && mounted) {
      // Ir para tela de backup
      Navigator.pushNamed(context, '/settings');
      return;
    }
    
    if (result == 'logout' && mounted) {
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
      width: double.infinity,
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
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
            textAlign: TextAlign.center,
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


