import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../providers/breez_provider_export.dart';
import '../providers/order_provider.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';
import '../services/secure_storage_service.dart';
import '../services/local_collateral_service.dart';
import '../services/platform_fee_service.dart';
import '../services/version_check_service.dart';
import '../services/brix_relay_service.dart';
import '../widgets/stat_card.dart';
import '../widgets/gradient_button.dart';
import '../widgets/transaction_card.dart';
import 'payment_screen.dart';
import 'login_screen.dart';
import 'settings_screen.dart';
import 'nostr_conversations_screen.dart';
import 'order_status_screen.dart';
import '../models/order.dart';
import '../services/chat_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final _currencyFormat = NumberFormat.currency(locale: 'pt_BR', symbol: 'R\$');
  double _btcPrice = 0.0;
  Timer? _priceUpdateTimer;
  Timer? _ordersUpdateTimer; // Timer para atualizar ordens automaticamente
  String? _currentUserPubkey; // Para filtro extra de segurança
  int _unreadMessages = 0;
  StreamSubscription<int>? _unreadSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadCurrentUserPubkey();
      _initializeBreezSdk();
      _loadData();
      _listenUnreadMessages();
      _fetchBitcoinPrice();
      _startPricePolling();
      _startOrdersPolling(); // Iniciar polling de ordens
      _checkSeedRecoveryStatus();
      _checkAndShowBackupReminder();
      _checkForAppUpdate();
      // Start BRIX invoice relay service (global, any screen)
      BrixRelayService().start(context);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Restart relay service when app comes back to foreground
      BrixRelayService().restart(context);
    }
  }
  
  /// Carrega a pubkey do usuário atual para filtro extra de segurança
  Future<void> _loadCurrentUserPubkey() async {
    final pubkey = await StorageService().getNostrPublicKey();
    if (mounted) {
      setState(() {
        _currentUserPubkey = pubkey;
      });
      broLog('🔑 [HOME] Pubkey carregada: ${pubkey?.substring(0, 16) ?? "null"}');
    }
  }

  /// Verifica se precisa recuperar seed perdida (situação crítica!)
  Future<void> _checkSeedRecoveryStatus() async {
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    
    final breezProvider = Provider.of<BreezProvider>(context, listen: false);
    
    if (breezProvider.seedRecoveryNeeded) {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          backgroundColor: Colors.red.shade900,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.error, color: Colors.white, size: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  AppLocalizations.of(context).t('home_recovery_needed'),
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                AppLocalizations.of(context).t('home_recovery_message'),
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
          ),
          actions: [
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/settings');
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.white),
              child: Text(AppLocalizations.of(context).t('home_go_to_settings'), style: const TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );
    }
  }

  /// v239: Verificar se há atualização disponível
  Future<void> _checkForAppUpdate() async {
    // Atraso para não competir com outros dialogs de inicialização
    await Future.delayed(const Duration(seconds: 4));
    if (!mounted) return;
    
    final versionService = VersionCheckService();
    final hasUpdate = await versionService.checkForUpdate();
    
    if (hasUpdate && mounted) {
      await versionService.showUpdateDialog(context);
    }
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
            Expanded(
              child: Text(
                AppLocalizations.of(context).t('home_protect_sats'),
                style: const TextStyle(color: Colors.white, fontSize: 18),
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
                child: Row(
                  children: [
                    const Icon(Icons.warning, color: Colors.red, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        AppLocalizations.of(context).t('home_no_backup_no_funds'),
                        style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                AppLocalizations.of(context).t('home_seed_is_key'),
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              const SizedBox(height: 12),
              Text(
                AppLocalizations.of(context).t('home_seed_instructions'),
                style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 13),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle, color: Colors.green, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        AppLocalizations.of(context).t('home_backup_now_hint'),
                        style: const TextStyle(color: Colors.green, fontSize: 13),
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
            child: Text(AppLocalizations.of(context).t('later'), style: const TextStyle(color: Color(0x99FFFFFF))),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(context, 'backup'),
            icon: const Icon(Icons.key, size: 18),
            label: Text(AppLocalizations.of(context).t('home_view_my_seed')),
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
      broLog('Inicializando Breez SDK Spark...');

      try {
        final success = await breezProvider.initialize().timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            broLog('Timeout na inicializacao do Breez SDK');
            return false;
          },
        );

        if (success) {
          // CRÍTICO: Configurar callback do PlatformFeeService para envio de taxas
          PlatformFeeService.setPaymentCallback(
            (String invoice) => breezProvider.payInvoice(invoice),
            'Spark',
          );
          broLog('💼 PlatformFeeService callback configurado com BreezProvider');
        }

        if (!success && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Breez SDK did not fully initialize.'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 5),
            ),
          );
        }
      } catch (e) {
        broLog('Erro ao inicializar Breez SDK: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context).tp('home_wallet_init_error', {'error': e})),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _priceUpdateTimer?.cancel();
    _ordersUpdateTimer?.cancel();
    _unreadSub?.cancel();
    super.dispose();
  }

  void _startPricePolling() {
    _priceUpdateTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) {
        _fetchBitcoinPrice();
      }
    });
  }

  void _listenUnreadMessages() {
    final chatService = ChatService();
    _unreadMessages = chatService.totalUnread;
    _unreadSub = chatService.unreadStream.listen((count) {
      if (mounted) {
        setState(() => _unreadMessages = count);
      }
    });
  }
  
  void _startOrdersPolling() {
    // v269: Reduzido de 30s para 15s para sincronia com order_status_screen
    // O syncOrdersFromNostr já tem throttle interno de 15s
    _ordersUpdateTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (mounted) {
        final orderProvider = context.read<OrderProvider>();
        // PERFORMANCE v226: Pular sync de user quando provider mode está ativo
        // O provider sync (ProviderOrdersScreen) já busca tudo que precisamos
        // Isso elimina ~42 WebSocket conexões/min de redundância
        if (orderProvider.isProviderMode) {
          broLog('⚡ HomeScreen timer: provider mode ativo, pulando syncOrdersFromNostr');
          return;
        }
        try {
          await orderProvider.syncOrdersFromNostr();
        } catch (e) {
          broLog('⚠️ Erro no polling de ordens: $e');
        }
      }
    });
  }

  Future<void> _loadData({bool force = false}) async {
    try {
      final breezProvider = context.read<BreezProvider>();
      final orderProvider = context.read<OrderProvider>();

      // SEGURANÇA CRÍTICA: Garantir que NÃO estamos em modo provedor na home
      if (orderProvider.isProviderMode) {
        broLog('⚠️ [HOME] Detectado modo provedor ativo! Forçando reset...');
        orderProvider.exitProviderMode();
      }

      // Mostrar mensagem de progresso
      _showSyncSnackbar(AppLocalizations.of(context).t('home_connecting_nostr'));
      
      await Future.wait([
        breezProvider.refresh(),
        // PERFORMANCE: Na inicialização, não forçar sync — o initialize() já faz
        // Forçar apenas em pull-to-refresh (force=true)
        if (force) orderProvider.fetchOrders(),
        if (!force) orderProvider.syncOrdersFromNostr(), // usa throttle interno
      ]);

      // Mostrar conclusão
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        _showSyncSnackbar(AppLocalizations.of(context).t('home_data_updated'), duration: const Duration(seconds: 3));
      }
    } catch (e) {
      broLog('❌ Erro no _loadData: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        _showSyncSnackbar(AppLocalizations.of(context).t('home_data_update_failed'), duration: const Duration(seconds: 2));
      }
    }
  }
  
  void _showSyncSnackbar(String message, {Duration duration = const Duration(seconds: 30)}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            if (!message.startsWith('✅'))
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
            if (!message.startsWith('✅')) const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
        duration: duration,
        backgroundColor: const Color(0xFF2A2A2A),
        behavior: SnackBarBehavior.floating,
      ),
    );
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
          await _loadData(force: true);
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
      backgroundColor: const Color(0xFF121212),
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
          Expanded(
            child: Text(
              AppLocalizations.of(context).t('home_digital_barter'),
              style: const TextStyle(
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
        // Carteira Lightning
        IconButton(
          icon: const Icon(Icons.account_balance_wallet, color: Colors.orange),
          onPressed: () => Navigator.pushNamed(context, '/wallet'),
          tooltip: AppLocalizations.of(context).t('home_my_wallet'),
        ),
        IconButton(
          icon: const Icon(Icons.settings_outlined, color: Colors.white),
          onPressed: _showUserSettings,
          tooltip: AppLocalizations.of(context).t('home_settings'),
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
        const SizedBox(height: 8),

        // Preço do Bitcoin compacto
        _buildBtcPriceTicker(),
        const SizedBox(height: 16),

        // Lista de Ordens
        _buildTransactionsList(orderProvider),
        const SizedBox(height: 16),
        
        // v246: Atividade do Marketplace
        _buildMarketplaceActivity(breezProvider),
        
        // Extra space
        const SizedBox(height: 80),
      ],
    );
  }

  Widget _buildActionButtonsGrid() {
    return Column(
      children: [
        // Primeira linha: Pagar Conta + BRIX
        Row(
          children: [
            // Pagar Conta
            Expanded(
              child: _buildGridButton(
                icon: Icons.receipt_long,
                label: AppLocalizations.of(context).t('home_pay_bill'),
                gradient: const [Color(0xFFFF6B6B), Color(0xFFFF8A8A)],
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const PaymentScreen()),
                  );
                },
              ),
            ),
            const SizedBox(width: 12),
            // BRIX
            Expanded(
              child: _buildGridButton(
                icon: Icons.flash_on,
                label: 'BRIX',
                gradient: const [Color(0xFFF7931A), Color(0xFFFFAB40)],
                onTap: () => Navigator.pushNamed(context, '/brix'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Segunda linha: Marketplace + Modo Bro
        Row(
          children: [
            // Marketplace
            Expanded(
              child: _buildMarketplaceButton(),
            ),
            const SizedBox(width: 12),
            // Modo Bro
            Expanded(
              child: _buildGridButton(
                icon: Icons.volunteer_activism,
                label: AppLocalizations.of(context).t('home_bro_mode'),
                gradient: const [Color(0xFF3DE98C), Color(0xFF00CC7A)],
                onTap: () async {
                  final pubkey = await StorageService().getNostrPublicKey();
                  final collateralService = LocalCollateralService();
                  final hasActiveTier = await collateralService.hasCollateral(userPubkey: pubkey);
                  
                  if (hasActiveTier) {
                    final providerId = pubkey ?? 'unknown';
                    Navigator.pushNamed(context, '/provider-orders', arguments: {
                      'providerId': providerId,
                    });
                  } else {
                    Navigator.pushNamed(context, '/provider-education');
                  }
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
        : AppLocalizations.of(context).t('loading');

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

  /// Ticker compacto do preço Bitcoin (inline, abaixo dos botões)
  Widget _buildBtcPriceTicker() {
    final btcPriceFormatted = _btcPrice > 0 
        ? _currencyFormat.format(_btcPrice) 
        : AppLocalizations.of(context).t('loading');
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xFFF7931A).withOpacity(0.3),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Image.asset(
            'assets/images/bitcoin-logo.png',
            height: 16,
            width: 16,
          ),
          const SizedBox(width: 8),
          Text(
            'Bitcoin',
            style: TextStyle(
              color: Colors.white.withOpacity(0.6),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            btcPriceFormatted,
            style: const TextStyle(
              color: Color(0xFFF7931A),
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  /// Botão Marketplace com estilo laranja transparente (como preço Bitcoin)
  Widget _buildMarketplaceButton() {
    return GestureDetector(
      onTap: () => Navigator.pushNamed(context, '/marketplace'),
      child: Container(
        height: 90,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              const Color(0xFFFF6B6B).withOpacity(0.3),
              const Color(0xFFFF6B6B).withOpacity(0.15),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: const Color(0xFFFF6B6B).withOpacity(0.4),
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.storefront, color: Color(0xFFFF8A8A), size: 28),
            const SizedBox(height: 6),
            Text(
              AppLocalizations.of(context).t('home_marketplace'),
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

  Widget _buildMetricsRow(OrderProvider orderProvider) {
    // CORREÇÃO VAZAMENTO: Usar myCreatedOrders para evitar contar ordens aceitas como provedor
    final myOrders = orderProvider.myCreatedOrders;
    final totalBills = myOrders.length;
    final pendingBills = myOrders.where((o) => o.status == 'pending').length;
    final completedOrders = myOrders
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
          _buildMetricItem('📋', '$totalBills', AppLocalizations.of(context).t('home_created')),
          _buildMetricDivider(),
          _buildMetricItem('⏳', '$pendingBills', AppLocalizations.of(context).t('home_pending')),
          _buildMetricDivider(),
          _buildMetricItem('✅', '$completedOrders', AppLocalizations.of(context).t('home_completed')),
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
    // CORREÇÃO VAZAMENTO: Usar myCreatedOrders para evitar contar ordens aceitas como provedor
    final myOrders = orderProvider.myCreatedOrders;
    final totalBills = myOrders.length;
    final pendingBills = myOrders.where((o) => o.status == 'pending').length;
    final completedToday = myOrders
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
          label: AppLocalizations.of(context).t('home_orders_created'),
        ),
        StatCard(
          emoji: '⏳',
          value: '$pendingBills',
          label: AppLocalizations.of(context).t('home_awaiting_bro'),
        ),
        StatCard(
          emoji: '✅',
          value: '$completedToday',
          label: AppLocalizations.of(context).t('home_completed_today'),
        ),
        StatCard(
          iconWidget: Image.asset(
            'assets/images/bitcoin-logo.png',
            height: 28,
            width: 28,
          ),
          value: btcPriceFormatted,
          label: AppLocalizations.of(context).t('home_bitcoin_price'),
        ),
      ],
    );
  }

  Widget _buildActionButtons() {
    return SizedBox(
      width: double.infinity,
      height: 60,
      child: GradientButton(
        text: AppLocalizations.of(context).t('home_pay_bill'),
        icon: Icons.receipt_long,
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const PaymentScreen()),
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
            child: Row(
              children: [
                const Icon(Icons.receipt_long, color: Colors.white, size: 20),
                const SizedBox(width: 12),
                Text(
                  AppLocalizations.of(context).t('home_my_trades'),
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),

          // Body - CORREÇÃO VAZAMENTO: Usar myCreatedOrders ao invés de filtrar manualmente
          Builder(
            builder: (context) {
              // myCreatedOrders já retorna apenas ordens onde userPubkey == currentUser
              final myOrders = orderProvider.myCreatedOrders;
              
              if (myOrders.isEmpty) {
                return Container(
                  padding: const EdgeInsets.all(20),
                  child: const EmptyTransactionState(),
                );
              }
              return ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.all(20),
                itemCount: myOrders.length,
                itemBuilder: (context, index) {
                  final order = myOrders[index];
                  return TransactionCard(
                    title: order.billType == 'pix' ? 'PIX' : 'Boleto',
                    amount: _currencyFormat.format(order.amount),
                    status: order.status,
                    statusLabel: _getStatusLabel(order.status, metadata: order.metadata),
                    orderId: order.id,
                    onTap: () {
                      _showOrderDetails(order);
                    },
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }

  /// v246: Seção de atividade recente do Marketplace na dashboard
  Widget _buildMarketplaceActivity(BreezProvider breezProvider) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: breezProvider.listPayments(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        
        final allPayments = snapshot.data!;
        // Filtrar apenas transações do marketplace
        final marketplaceTxs = allPayments.where((p) {
          final desc = p['description']?.toString() ?? '';
          return desc.contains('Bro Marketplace');
        }).take(5).toList();
        
        if (marketplaceTxs.isEmpty) return const SizedBox.shrink();
        
        return Container(
          decoration: BoxDecoration(
            color: const Color(0x0DFFFFFF),
            border: Border.all(
              color: const Color(0x33FF8A00),
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
                    colors: [Color(0xFFFF8A00), Color(0xFFFFAA33)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.storefront, color: Colors.white, size: 20),
                    const SizedBox(width: 12),
                    Text(
                      AppLocalizations.of(context).t('home_marketplace_section'),
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${marketplaceTxs.length} transaç${marketplaceTxs.length == 1 ? 'ão' : 'ões'}',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
              // Transactions list
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.all(12),
                itemCount: marketplaceTxs.length,
                itemBuilder: (context, index) {
                  final tx = marketplaceTxs[index];
                  final isReceived = tx['type'] == 'received' || 
                                     tx['direction'] == 'incoming' ||
                                     tx['type'] == 'Receive';
                  final amount = tx['amountSats'] ?? tx['amount'] ?? 0;
                  final description = tx['description']?.toString() ?? '';
                  final product = description
                      .replaceFirst('Bro Marketplace: ', '')
                      .replaceFirst('Bro Marketplace:', '')
                      .trim();
                  final date = tx['createdAt'] ?? tx['timestamp'];
                  
                  String dateStr = '';
                  if (date != null) {
                    try {
                      final dt = date is int 
                          ? DateTime.fromMillisecondsSinceEpoch(date * 1000) 
                          : DateTime.parse(date.toString());
                      dateStr = '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
                    } catch (_) {}
                  }
                  
                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A2A),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.orange.withOpacity(0.2)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: (isReceived ? Colors.green : Colors.orange).withOpacity(0.2),
                            borderRadius: BorderRadius.circular(17),
                          ),
                          child: Icon(
                            isReceived ? Icons.storefront : Icons.shopping_cart,
                            color: isReceived ? Colors.green : Colors.orange,
                            size: 17,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isReceived 
                                    ? AppLocalizations.of(context).tp('home_sale_label', {'product': product.isEmpty ? AppLocalizations.of(context).t('home_product') : product}) 
                                    : AppLocalizations.of(context).tp('home_purchase_label', {'product': product.isEmpty ? AppLocalizations.of(context).t('home_product') : product}),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (dateStr.isNotEmpty)
                                Text(
                                  dateStr,
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.4),
                                    fontSize: 11,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Text(
                          '${isReceived ? '+' : '-'}$amount sats',
                          style: TextStyle(
                            color: isReceived ? Colors.green : Colors.orange,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          Text(
            AppLocalizations.of(context).t('home_privacy_tagline'),
            style: const TextStyle(
              color: Color(0xFFFF6B6B),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  String _getStatusLabel(String status, {Map<String, dynamic>? metadata}) {
    final t = AppLocalizations.of(context);
    switch (status.toLowerCase()) {
      case 'pending':
      case 'payment_received':
      case 'confirmed':
        return t.t('home_status_awaiting_bro');
      case 'accepted':
        return t.t('home_status_bro_found');
      case 'awaiting_confirmation':
      case 'payment_submitted':
      case 'processing':
        return t.t('home_status_confirm_payment');
      case 'completed':
      case 'paid':
        // Mostrar 'Resolvida' para ordens que passaram por mediação
        if (metadata?['wasDisputed'] == true) {
          return t.t('home_status_resolved');
        }
        return t.t('home_status_completed');
      case 'cancelled':
        if (metadata?['wasDisputed'] == true) {
          return t.t('home_status_resolved');
        }
        return t.t('home_status_cancelled');
      case 'disputed':
        return t.t('home_status_in_dispute');
      case 'failed':
        return t.t('home_status_failed');
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
    broLog('Navegando para detalhes da ordem: ${order.id}');

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
      broLog('Erro ao navegar: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).tp('home_order_open_error', {'error': e})),
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

  void _openMessages() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const NostrConversationsScreen()),
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
      onTap: () async {
        // Obter pubkey do usuário atual
        final pubkey = await StorageService().getNostrPublicKey();
        // Verificar se já tem tier ativado (collateral)
        final collateralService = LocalCollateralService();
        final hasActiveTier = await collateralService.hasCollateral(userPubkey: pubkey);
        broLog('🔍 hasActiveTier (button): $hasActiveTier (pubkey: ${pubkey?.substring(0, 8) ?? "null"})');
        
        if (hasActiveTier) {
          // Já tem tier, ir direto para tela de ordens
          final providerId = pubkey ?? 'unknown';
          Navigator.pushNamed(context, '/provider-orders', arguments: {
            'providerId': providerId,
          });
        } else {
          // Não tem tier, mostrar educação primeiro
          Navigator.pushNamed(context, '/provider-education');
        }
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
            Expanded(
              child: Text(AppLocalizations.of(context).t('home_before_logout'), style: const TextStyle(color: Colors.white, fontSize: 18)),
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
                child: Row(
                  children: [
                    const Icon(Icons.warning, color: Colors.red, size: 24),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        AppLocalizations.of(context).t('home_have_sats'),
                        style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                AppLocalizations.of(context).t('home_save_seed'),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
              ),
              const SizedBox(height: 4),
              Text(
                AppLocalizations.of(context).t('home_seed_only_way'),
                style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 13),
              ),
              const SizedBox(height: 12),
              Text(
                AppLocalizations.of(context).t('home_or_withdraw'),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
              ),
              const SizedBox(height: 4),
              Text(
                AppLocalizations.of(context).t('home_transfer_before_logout'),
                style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 13),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.history, color: Colors.orange, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        AppLocalizations.of(context).t('home_history_lost'),
                        style: const TextStyle(color: Colors.orange, fontSize: 12),
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
            child: Text(AppLocalizations.of(context).t('cancel'), style: const TextStyle(color: Color(0x99FFFFFF))),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton.icon(
                onPressed: () => Navigator.pop(context, 'backup'),
                icon: const Icon(Icons.key, color: Colors.green, size: 18),
                label: Text(AppLocalizations.of(context).t('home_view_seed'), style: const TextStyle(color: Colors.green)),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, 'logout'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF6B6B),
                ),
                child: Text(AppLocalizations.of(context).t('home_logout'), style: const TextStyle(color: Colors.white)),
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
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(
            Icons.receipt_long_outlined,
            size: 64,
            color: Color(0x4DFFFFFF),
          ),
          const SizedBox(height: 16),
          Text(
            AppLocalizations.of(context).t('home_no_trades_yet'),
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Color(0x99FFFFFF),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            AppLocalizations.of(context).t('home_trades_will_appear'),
            style: const TextStyle(
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


