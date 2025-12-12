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
import 'services/api_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Verificar se já está logado
  final storage = StorageService();
  final isLoggedIn = await storage.isLoggedIn();
  
  // Breez SDK será inicializado no provider (lazy initialization)
  
  runApp(PagaContaApp(isLoggedIn: isLoggedIn));
}

/// Agendar reconciliação automática quando o SDK estiver pronto
void _scheduleReconciliationOnStartup(BreezProvider breezProvider, OrderProvider orderProvider) {
  // Tentar reconciliação inicial após 5 segundos
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

/// Tentar reconciliação se houver saldo
Future<void> _tryReconciliation(BreezProvider breezProvider, OrderProvider orderProvider) async {
  if (!breezProvider.isInitialized) {
    debugPrint('⏳ SDK ainda não inicializado, reconciliação adiada');
    return;
  }
  
  try {
    final balanceData = await breezProvider.getBalance();
    final balance = int.tryParse(balanceData['balance']?.toString() ?? '0') ?? 0;
    
    if (balance > 0) {
      debugPrint('🔄 Reconciliação automática: Saldo detectado = $balance sats');
      await orderProvider.reconcileOnStartup(balance);
    } else {
      debugPrint('💰 Saldo zero, nenhuma reconciliação necessária');
    }
  } catch (e) {
    debugPrint('⚠️ Erro na reconciliação: $e');
  }
}

class PagaContaApp extends StatelessWidget {
  final bool isLoggedIn;
  
  const PagaContaApp({Key? key, required this.isLoggedIn}) : super(key: key);

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
          
          // RECONCILIAÇÃO AUTOMÁTICA: Conectar callback de pagamento ao OrderProvider
          final orderProvider = context.read<OrderProvider>();
          breezProvider.onPaymentReceived = (String paymentId, int amountSats) {
            debugPrint('🔔 CALLBACK: Pagamento recebido! Reconciliando automaticamente...');
            orderProvider.onPaymentReceived(
              paymentId: paymentId,
              amountSats: amountSats,
            );
          };
          
          // Verificar reconciliação na inicialização (quando SDK estiver pronto)
          _scheduleReconciliationOnStartup(breezProvider, orderProvider);
          
          return MaterialApp(
        title: 'Paga Conta',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          // Tema Dark com cores do web app
          brightness: Brightness.dark,
          primaryColor: const Color(0xFFFF6B35), // --primary-orange
          scaffoldBackgroundColor: const Color(0xFF0A0A0A), // --dark-bg
          
          // Colors
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFFFF6B35),
            secondary: Color(0xFFFF8F65),
            surface: Color(0xFF1A1A1A),
            background: Color(0xFF0A0A0A),
            error: Color(0xFFF44336),
          ),
          
          // AppBar
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xF70A0A0A), // rgba(10, 10, 10, 0.98)
            foregroundColor: Colors.white,
            elevation: 0,
            centerTitle: false,
          ),
          
          // Cards
          // Use CardThemeData to match the expected ThemeData parameter type
          cardTheme: CardThemeData(
            color: const Color(0x0DFFFFFF), // rgba(255, 255, 255, 0.05)
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(
                color: Color(0x33FF6B35), // rgba(255, 107, 53, 0.2)
                width: 1,
              ),
            ),
          ),
          
          // Buttons
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF6B35),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              elevation: 4,
            ),
          ),
          
          // Text Fields
          inputDecorationTheme: InputDecorationTheme(
            filled: true,
            fillColor: const Color(0x0DFFFFFF), // rgba(255, 255, 255, 0.05)
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(
                color: Color(0x33FF6B35), // rgba(255, 107, 53, 0.2)
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(
                color: Color(0x33FF6B35),
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(
                color: Color(0xFFFF6B35),
                width: 2,
              ),
            ),
            labelStyle: const TextStyle(color: Color(0x99FFFFFF)),
            hintStyle: const TextStyle(color: Color(0x66FFFFFF)),
          ),
          
          // Text
          textTheme: const TextTheme(
            displayLarge: TextStyle(color: Colors.white),
            displayMedium: TextStyle(color: Colors.white),
            displaySmall: TextStyle(color: Colors.white),
            headlineMedium: TextStyle(color: Colors.white),
            headlineSmall: TextStyle(color: Colors.white),
            titleLarge: TextStyle(color: Colors.white),
            bodyLarge: TextStyle(color: Colors.white),
            bodyMedium: TextStyle(color: Colors.white),
          ),
        ),
        themeMode: ThemeMode.dark, // Forçar tema escuro
        home: isLoggedIn ? const HomeScreen() : const LoginScreen(),
        onGenerateRoute: (settings) {
          // Rotas com parâmetros
          if (settings.name == '/order-status') {
            final args = settings.arguments as Map<String, dynamic>?;
            debugPrint('🔍 Navegando para /order-status com args: $args');
            debugPrint('  orderId: ${args?['orderId']} (${args?['orderId'].runtimeType})');
            debugPrint('  userId: ${args?['userId']} (${args?['userId'].runtimeType})');
            debugPrint('  amountBrl: ${args?['amountBrl']} (${args?['amountBrl'].runtimeType})');
            debugPrint('  amountSats: ${args?['amountSats']} (${args?['amountSats'].runtimeType})');
            
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
