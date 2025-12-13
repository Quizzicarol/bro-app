import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'screens/provider_education_screen.dart';
import 'screens/provider_collateral_screen.dart';
import 'screens/provider_orders_screen.dart';
import 'screens/provider_order_detail_screen.dart';
import 'screens/provider_my_orders_screen.dart';
import 'screens/provider_order_history_screen.dart';
import 'screens/provider_balance_screen.dart';
import 'screens/platform_balance_screen.dart';
import 'screens/order_status_screen.dart';
import 'screens/user_orders_screen.dart';
import 'screens/nostr_messages_screen.dart';
import 'screens/relay_management_screen.dart';
import 'screens/nostr_profile_screen.dart';
import 'screens/nip06_backup_screen.dart';
import 'screens/privacy_settings_screen.dart';
import 'providers/breez_provider_export.dart';
import 'providers/order_provider.dart';
import 'providers/collateral_provider.dart';
import 'providers/provider_balance_provider.dart';
import 'providers/platform_balance_provider.dart';
import 'services/storage_service.dart';
import 'services/notification_service.dart';
import 'services/api_service.dart';
import 'theme/bro_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicializar notificacoes
  await NotificationService().initialize();

  // Verificar se ja esta logado
  final storage = StorageService();
  final isLoggedIn = await storage.isLoggedIn();

  // Breez SDK sera inicializado no provider (lazy initialization)

  runApp(BroApp(isLoggedIn: isLoggedIn));
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

/// Tentar reconciliacao se houver saldo
Future<void> _tryReconciliation(BreezProvider breezProvider, OrderProvider orderProvider) async {
  if (!breezProvider.isInitialized) {
    debugPrint('SDK ainda nao inicializado, reconciliacao adiada');
    return;
  }

  try {
    final balanceData = await breezProvider.getBalance();
    final balance = int.tryParse(balanceData['balance']?.toString() ?? '0') ?? 0;

    if (balance > 0) {
      debugPrint('Reconciliacao automatica: Saldo detectado = $balance sats');
      await orderProvider.reconcileOnStartup(balance);
    } else {
      debugPrint('Saldo zero, nenhuma reconciliacao necessaria');
    }
  } catch (e) {
    debugPrint('Erro na reconciliacao: $e');
  }
}

class BroApp extends StatelessWidget {
  final bool isLoggedIn;

  const BroApp({Key? key, required this.isLoggedIn}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider(create: (_) => ApiService()),
        ChangeNotifierProvider(create: (_) => BreezProvider()),
        ChangeNotifierProvider(
          create: (_) {
            final provider = OrderProvider();
            provider.initialize(); // Carregar ordens salvas
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
          breezProvider.onPaymentReceived = (String paymentId, int amountSats) {
            debugPrint('CALLBACK: Pagamento recebido! Reconciliando automaticamente...');
            orderProvider.onPaymentReceived(
              paymentId: paymentId,
              amountSats: amountSats,
            );
          };

          // Verificar reconciliacao na inicializacao (quando SDK estiver pronto)
          _scheduleReconciliationOnStartup(breezProvider, orderProvider);

          return MaterialApp(
            title: 'Bro',
            debugShowCheckedModeBanner: false,
            theme: BroTheme.darkTheme,
            themeMode: ThemeMode.dark,
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
              '/nostr-messages': (context) => const NostrMessagesScreen(),
              '/relay-management': (context) => const RelayManagementScreen(),
              '/nostr-profile': (context) => const NostrProfileScreen(),
              '/nip06-backup': (context) => const Nip06BackupScreen(),
              '/privacy-settings': (context) => const PrivacySettingsScreen(),
              '/provider-education': (context) => const ProviderEducationScreen(),
              '/provider-collateral': (context) => const ProviderCollateralScreen(providerId: 'temp'),
              '/provider-order-detail': (context) => const ProviderOrderDetailScreen(orderId: 'temp', providerId: 'temp'),
              '/provider-balance': (context) => const ProviderBalanceScreen(),
              '/platform-balance': (context) => const PlatformBalanceScreen(),
            },
          );
        },
      ),
    );
  }
}
