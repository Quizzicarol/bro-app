import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'screens/login_screen.dart'; // Login original com chave privada
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/provider_education_screen.dart';
import 'screens/provider_collateral_screen.dart';
import 'screens/provider_orders_screen.dart';
import 'screens/provider_order_detail_screen.dart';
import 'screens/provider_my_orders_screen.dart';
import 'screens/provider_order_history_screen.dart';
import 'screens/provider_balance_screen.dart';
import 'screens/platform_balance_screen.dart';
import 'screens/platform_admin_screen.dart';
import 'screens/order_status_screen.dart';
import 'screens/user_orders_screen.dart';
import 'screens/nostr_conversations_screen.dart';
import 'screens/relay_management_screen.dart';
import 'screens/nostr_profile_screen.dart';
import 'screens/nip06_backup_screen.dart';
import 'screens/privacy_settings_screen.dart';
import 'screens/wallet_screen.dart';
import 'screens/marketplace_screen.dart';
import 'providers/breez_provider_export.dart';
import 'providers/breez_liquid_provider.dart';
import 'providers/lightning_provider.dart';
import 'providers/order_provider.dart';
import 'providers/collateral_provider.dart';
import 'providers/provider_balance_provider.dart';
import 'providers/platform_balance_provider.dart';
import 'services/storage_service.dart';
import 'services/notification_service.dart';
import 'services/api_service.dart';
import 'services/cache_service.dart';
import 'services/platform_fee_service.dart';
import 'providers/theme_provider.dart';
import 'widgets/alfa_banner.dart';

import 'services/nostr_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicializar notificacoes
  await NotificationService().initialize();

  // Inicializar cache
  await CacheService().init();
  
  // Inicializar PlatformFeeService (carrega ordens já pagas do storage)
  await PlatformFeeService.initialize();

  // Verificar se ja esta logado
  final storage = StorageService();
  await storage.init();
  final isLoggedIn = await storage.isLoggedIn();
  
  // Obter pubkey para o OrderProvider (antes de restaurar chaves)
  String? userPubkey;
  
  // Se já está logado, restaurar chaves Nostr
  if (isLoggedIn) {
    await _restoreNostrKeys(storage);
    userPubkey = await storage.getNostrPublicKey();
    debugPrint('📦 Pubkey para OrderProvider: ${userPubkey?.substring(0, 16) ?? "null"}...');
  }

  // Breez SDK sera inicializado no provider (lazy initialization)

  runApp(BroApp(isLoggedIn: isLoggedIn, userPubkey: userPubkey));
}

/// Restaurar chaves Nostr do armazenamento seguro
Future<void> _restoreNostrKeys(StorageService storage) async {
  try {
    final privateKey = await storage.getNostrPrivateKey();
    if (privateKey != null && privateKey.isNotEmpty) {
      final nostrService = NostrService();
      final publicKey = nostrService.getPublicKey(privateKey);
      nostrService.setKeys(privateKey, publicKey);
      debugPrint('🔑 Chaves Nostr restauradas na inicialização: ${publicKey.substring(0, 16)}...');
    } else {
      debugPrint('⚠️ Nenhuma chave Nostr salva para restaurar');
    }
  } catch (e) {
    debugPrint('❌ Erro ao restaurar chaves Nostr: $e');
  }
}

/// Agendar reconciliacao automatica quando o SDK estiver pronto
void _scheduleReconciliationOnStartup(BreezProvider breezProvider, OrderProvider orderProvider) {
  // Tentar reconciliacao inicial apos 5 segundos
  Future.delayed(const Duration(seconds: 5), () async {
    await _tryReconciliation(breezProvider, orderProvider);
  });

  // Adicionar listener para quando o SDK inicializar depois
  breezProvider.addListener(() async {
    if (breezProvider.isInitialized) {
      await _tryReconciliation(breezProvider, orderProvider);
    }
  });
}

/// Tentar reconciliacao completa com pagamentos do Breez
Future<void> _tryReconciliation(BreezProvider breezProvider, OrderProvider orderProvider) async {
  if (!breezProvider.isInitialized) {
    debugPrint('SDK ainda nao inicializado, reconciliacao adiada');
    return;
  }

  try {
    debugPrint('🔄 Iniciando reconciliação automática na inicialização...');
    
    // Buscar TODOS os pagamentos (recebidos e enviados)
    final payments = await breezProvider.getAllPayments();
    
    if (payments.isEmpty) {
      debugPrint('📭 Nenhum pagamento na carteira para reconciliar');
      return;
    }
    
    debugPrint('💰 ${payments.length} pagamentos encontrados, reconciliando...');
    
    // Usar o novo método completo de reconciliação
    final result = await orderProvider.autoReconcileWithBreezPayments(payments);
    
    final pendingReconciled = result['pendingReconciled'] ?? 0;
    final completedReconciled = result['completedReconciled'] ?? 0;
    
    if (pendingReconciled > 0 || completedReconciled > 0) {
      debugPrint('🎉 Reconciliação na inicialização: $pendingReconciled pending→paid, $completedReconciled awaiting→completed');
    } else {
      debugPrint('✅ Nenhuma ordem precisou ser reconciliada na inicialização');
    }
  } catch (e) {
    debugPrint('Erro na reconciliacao: $e');
  }
}

class BroApp extends StatelessWidget {
  final bool isLoggedIn;
  final String? userPubkey;

  const BroApp({Key? key, required this.isLoggedIn, this.userPubkey}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider(create: (_) => ApiService()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => BreezProvider()),
        ChangeNotifierProvider(create: (_) => BreezLiquidProvider()),
        // LightningProvider - abstração que unifica Spark e Liquid com fallback
        // IMPORTANTE: Usar as mesmas instâncias de Spark e Liquid, não criar novas!
        ChangeNotifierProxyProvider2<BreezProvider, BreezLiquidProvider, LightningProvider>(
          create: (context) {
            // Na criação inicial, pegar as instâncias do context
            final spark = context.read<BreezProvider>();
            final liquid = context.read<BreezLiquidProvider>();
            return LightningProvider(spark, liquid);
          },
          update: (_, spark, liquid, previous) {
            // Se já existe, retornar o mesmo (não criar novo)
            if (previous != null) return previous;
            return LightningProvider(spark, liquid);
          },
        ),
        ChangeNotifierProvider(
          create: (_) {
            final provider = OrderProvider();
            provider.initialize(userPubkey: userPubkey); // Passar a pubkey!
            return provider;
          },
        ),
        ChangeNotifierProvider(create: (_) => CollateralProvider()),
        ChangeNotifierProvider(create: (_) => ProviderBalanceProvider()),
        ChangeNotifierProvider(create: (_) => PlatformBalanceProvider()),
      ],
      child: Builder(
        builder: (context) {
          // Conectar BreezProvider ao ProviderBalanceProvider
          final breezProvider = context.read<BreezProvider>();
          final balanceProvider = context.read<ProviderBalanceProvider>();
          balanceProvider.setBreezProvider(breezProvider);

          // RECONCILIACAO AUTOMATICA: Conectar callback de pagamento ao OrderProvider
          final orderProvider = context.read<OrderProvider>();
          
          // Callback para pagamentos RECEBIDOS (menos comum no fluxo atual)
          breezProvider.onPaymentReceived = (String paymentId, int amountSats, String? paymentHash) {
            debugPrint('🔔 CALLBACK MAIN: Pagamento recebido! Reconciliando automaticamente...');
            orderProvider.onPaymentReceived(
              paymentId: paymentId,
              amountSats: amountSats,
              paymentHash: paymentHash,
            );
          };
          
          // Callback para pagamentos ENVIADOS (quando usuário libera BTC para o Bro)
          breezProvider.onPaymentSent = (String paymentId, int amountSats, String? paymentHash) {
            debugPrint('🔔 CALLBACK MAIN: Pagamento ENVIADO! Marcando ordem como completed...');
            orderProvider.onPaymentSent(
              paymentId: paymentId,
              amountSats: amountSats,
              paymentHash: paymentHash,
            );
          };

          // Verificar reconciliacao na inicializacao (quando SDK estiver pronto)
          _scheduleReconciliationOnStartup(breezProvider, orderProvider);

          return Consumer<ThemeProvider>(
            builder: (context, themeProvider, _) {
              return MaterialApp(
                title: 'Bro',
                debugShowCheckedModeBanner: false,
                theme: BroThemes.lightTheme,
                darkTheme: BroThemes.darkTheme,
                themeMode: themeProvider.themeMode,
                // Banner ALFA em todas as telas
                builder: (context, child) {
                  return Column(
                    children: [
                      const AlfaBanner(),
                      Expanded(child: child ?? const SizedBox()),
                    ],
                  );
                },
                home: isLoggedIn ? const HomeScreen() : const LoginScreen(),
            onGenerateRoute: (settings) {
              // Rotas com parametros
              if (settings.name == '/order-status') {
                final args = settings.arguments as Map<String, dynamic>?;
                debugPrint('Navegando para /order-status com args: $args');

                final amountSatsValue = args?['amountSats'];
                final int sats = amountSatsValue is int ? amountSatsValue : (amountSatsValue ?? 0).toInt();

                return MaterialPageRoute(
                  builder: (context) => OrderStatusScreen(
                    orderId: args?['orderId'] ?? '',
                    userId: args?['userId'],
                    amountBrl: (args?['amountBrl'] ?? 0.0).toDouble(),
                    amountSats: sats,
                  ),
                );
              }
              if (settings.name == '/user-orders') {
                final args = settings.arguments as Map<String, dynamic>;
                return MaterialPageRoute(
                  builder: (context) => UserOrdersScreen(userId: args['userId']),
                );
              }
              if (settings.name == '/provider-orders') {
                final args = settings.arguments as Map<String, dynamic>?;
                final providerId = args?['providerId'] as String? ?? 'temp';
                return MaterialPageRoute(
                  builder: (context) => ProviderOrdersScreen(providerId: providerId),
                );
              }
              if (settings.name == '/provider-my-orders') {
                final args = settings.arguments as String?;
                final providerId = args ?? 'temp';
                return MaterialPageRoute(
                  builder: (context) => ProviderMyOrdersScreen(providerId: providerId),
                );
              }
              if (settings.name == '/provider-history') {
                final args = settings.arguments as String?;
                final providerId = args ?? 'temp';
                return MaterialPageRoute(
                  builder: (context) => ProviderOrderHistoryScreen(providerId: providerId),
                );
              }
              return null;
            },
            routes: {
              '/home': (context) => const HomeScreen(),
              '/login': (context) => const LoginScreen(),
              '/settings': (context) => const SettingsScreen(),
              '/nostr-messages': (context) => const NostrConversationsScreen(),
              '/relay-management': (context) => const RelayManagementScreen(),
              '/nostr-profile': (context) => const NostrProfileScreen(),
              '/nip06-backup': (context) => const Nip06BackupScreen(),
              '/privacy-settings': (context) => const PrivacySettingsScreen(),
              '/wallet': (context) => const WalletScreen(),
              '/marketplace': (context) => const MarketplaceScreen(),
              '/provider-education': (context) => const ProviderEducationScreen(),
              '/provider-collateral': (context) => const ProviderCollateralScreen(providerId: 'temp'),
              '/provider-order-detail': (context) => const ProviderOrderDetailScreen(orderId: 'temp', providerId: 'temp'),
              '/provider-balance': (context) => const ProviderBalanceScreen(),
              '/platform-balance': (context) => const PlatformBalanceScreen(),
                '/admin-bro-2024': (context) => const PlatformAdminScreen(),
            },
          );
            },
          );
        },
      ),
    );
  }
}
