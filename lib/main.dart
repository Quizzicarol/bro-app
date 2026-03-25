import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:provider/provider.dart';
import 'package:breez_sdk_spark_flutter/breez_sdk_spark.dart' as spark;
import 'package:path_provider/path_provider.dart';
import 'l10n/app_localizations.dart';
import 'providers/locale_provider.dart';
import 'screens/login_screen.dart'; // Login original com chave privada
import 'screens/onboarding_screen.dart';
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
import 'screens/brix_screen.dart';
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
import 'services/background_notification_service.dart';
import 'services/nostr_order_service.dart';
import 'services/brix_service.dart';
import 'services/brix_relay_service.dart';
import 'config.dart';
import 'config/breez_config.dart';
import 'extensions/breez_extensions.dart';

/// Top-level handler for background FCM messages (required by Firebase).
/// When the app is killed, this tries to generate invoices for BRIX payments.
/// If SDK init fails, shows a notification to prompt the user to open the app.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  broLog('[FCM-BG] Background message: ${message.data}');

  // v390: Handle notification-type FCM messages (show notification directly)
  final notifTitle = message.notification?.title;
  final notifBody = message.notification?.body;
  if (notifTitle != null && notifBody != null) {
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
      const settings = InitializationSettings(android: androidSettings, iOS: DarwinInitializationSettings());
      await plugin.initialize(settings);
      await plugin.show(
        DateTime.now().millisecondsSinceEpoch % 2147483647,
        notifTitle,
        notifBody,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'bro_app_channel', 'Bro App',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
    } catch (_) {}
  }

  if (message.data['type'] != 'brix_invoice_request') return;

  final requestId = message.data['request_id'];
  final amountStr = message.data['amount_sats'];
  if (requestId == null || amountStr == null) return;

  final amountSats = int.tryParse(amountStr);
  if (amountSats == null || amountSats <= 0) return;

  spark.BreezSdk? sdk;
  try {
    final storage = StorageService();
    await storage.init();
    final pubkey = await storage.getNostrPublicKey();
    if (pubkey == null || pubkey.isEmpty) return;

    final mnemonic = await storage.getBreezMnemonic(forPubkey: pubkey);
    if (mnemonic == null || mnemonic.isEmpty) return;

    await spark.BreezSdkSparkLib.init();
    final seed = spark.Seed.mnemonic(mnemonic: mnemonic);
    final network = BreezConfig.useMainnet ? spark.Network.mainnet : spark.Network.regtest;
    final config = spark.defaultConfig(network: network).copyWith(
      apiKey: BreezConfig.apiKey,
    );
    final appDir = await getApplicationDocumentsDirectory();
    // Use the SAME storageDir as the main isolate — when the background handler
    // runs, the main isolate is stopped (app killed) so there's no SQLite conflict.
    // Sharing the cache avoids a full re-sync on every background wake-up, making
    // invoice generation fast enough for WoS's ~10s timeout.
    final storageDir = '${appDir.path}/breez_spark_${pubkey.substring(0, 8)}';

    sdk = await spark.connect(
      request: spark.ConnectRequest(config: config, seed: seed, storageDir: storageDir),
    ).timeout(const Duration(seconds: 15));

    final resp = await sdk.receivePayment(
      request: spark.ReceivePaymentRequest(
        paymentMethod: spark.ReceivePaymentMethod.bolt11Invoice(
          description: 'BRIX Payment',
          amountSats: BigInt.from(amountSats),
        ),
      ),
    ).timeout(const Duration(seconds: 10));

    final bolt11 = resp.paymentRequest;
    final brixService = BrixService();
    final ok = await brixService.submitInvoice(requestId, bolt11, pubkey);
    broLog('[FCM-BG] Invoice ${ok ? "submitted" : "failed"}: $amountSats sats');
  } catch (e) {
    broLog('[FCM-BG] Error generating invoice in background: $e');
    // Show notification so user knows to open the app
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
      const iosSettings = DarwinInitializationSettings();
      const settings = InitializationSettings(android: androidSettings, iOS: iosSettings);
      await plugin.initialize(settings);
      await plugin.show(
        9999,
        'Pagamento BRIX recebendo...',
        'Abra o app para receber $amountSats sats',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'brix_payments', 'BRIX Payments',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
      );
    } catch (_) {}
  } finally {
    try { await sdk?.disconnect(); } catch (_) {}
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase (optional — app works without it, just no push notifications)
  String? fcmToken;
  try {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission();
    // iOS: Permitir exibição de notificações em foreground
    // Sem isso, firebase_messaging suprime alertas quando o app está aberto
    await messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );
    fcmToken = await messaging.getToken();
    broLog('[FCM] Push token: $fcmToken');
  } catch (e) {
    broLog('[FCM] Firebase init failed (push disabled): $e');
  }

  // Inicializar notificacoes
  await NotificationService().initialize();

  // Inicializar cache
  await CacheService().init();
  
  // Inicializar PlatformFeeService (carrega ordens já pagas do storage)
  await PlatformFeeService.initialize();

  // Inicializar ApiService (Dio + NIP-98 interceptor)
  await ApiService().init();

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
    broLog('📦 Pubkey para OrderProvider: ${userPubkey?.substring(0, 16) ?? "null"}...');
    
    // Register FCM token with BRIX server for offline push notifications
    if (fcmToken != null && userPubkey != null) {
      BrixService().initCredentials().then((_) {
        BrixService().registerPushToken(fcmToken, userPubkey).then((ok) {
          broLog('[FCM] BRIX push token registered: $ok');
        });
      });

      // Re-register when Firebase rotates the FCM token
      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) {
        broLog('[FCM] Token refreshed, re-registering...');
        BrixService().registerPushToken(newToken, userPubkey!).then((ok) {
          broLog('[FCM] BRIX push token re-registered after refresh: $ok');
        });
        // Reset relay service FCM state so it also re-registers
        BrixRelayService().resetFcmRegistration();
      });

      // Listen for foreground FCM messages (BRIX wake-up)
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        broLog('[FCM] Foreground message: ${message.data}');
        if (message.data['type'] == 'brix_invoice_request') {
          BrixRelayService().triggerPoll();
        }
      });

      // When user taps notification to open app, also trigger poll
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        broLog('[FCM] App opened from notification: ${message.data}');
        if (message.data['type'] == 'brix_invoice_request') {
          BrixRelayService().triggerPoll();
        }
      });
    }
    
    // v262: Iniciar background notifications (polling Nostr a cada 15min)
    await initBackgroundNotifications();
    broLog('🔔 Background notifications ativado');
  }

  // Verificar se já viu onboarding
  final hasSeenOnboarding = await storage.getData('has_seen_onboarding') == 'true';

  // Inicializar LocaleProvider (idioma salvo ou auto-detectar)
  final localeProvider = LocaleProvider();
  await localeProvider.initialize();

  // Breez SDK sera inicializado no provider (lazy initialization)

  runApp(BroApp(isLoggedIn: isLoggedIn, userPubkey: userPubkey, hasSeenOnboarding: hasSeenOnboarding, localeProvider: localeProvider));
}

/// Restaurar chaves Nostr do armazenamento seguro
Future<void> _restoreNostrKeys(StorageService storage) async {
  try {
    final privateKey = await storage.getNostrPrivateKey();
    if (privateKey != null && privateKey.isNotEmpty) {
      final nostrService = NostrService();
      final publicKey = nostrService.getPublicKey(privateKey);
      nostrService.setKeys(privateKey, publicKey);
      broLog('🔑 Chaves Nostr restauradas na inicialização: ${publicKey.substring(0, 16)}...');
    } else {
      broLog('⚠️ Nenhuma chave Nostr salva para restaurar');
    }
  } catch (e) {
    broLog('❌ Erro ao restaurar chaves Nostr: $e');
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
    broLog('SDK ainda nao inicializado, reconciliacao adiada');
    return;
  }

  try {
    broLog('🔄 Iniciando reconciliação automática na inicialização...');
    
    // Buscar TODOS os pagamentos (recebidos e enviados)
    final payments = await breezProvider.getAllPayments();
    
    if (payments.isEmpty) {
      broLog('📭 Nenhum pagamento na carteira para reconciliar');
      return;
    }
    
    broLog('💰 ${payments.length} pagamentos encontrados, reconciliando...');
    
    // Usar o novo método completo de reconciliação
    final result = await orderProvider.autoReconcileWithBreezPayments(payments);
    
    final pendingReconciled = result['pendingReconciled'] ?? 0;
    final completedReconciled = result['completedReconciled'] ?? 0;
    
    if (pendingReconciled > 0 || completedReconciled > 0) {
      broLog('🎉 Reconciliação na inicialização: $pendingReconciled pending→paid, $completedReconciled awaiting→completed');
    } else {
      broLog('✅ Nenhuma ordem precisou ser reconciliada na inicialização');
    }
  } catch (e) {
    broLog('Erro na reconciliacao: $e');
  }
}

class BroApp extends StatelessWidget {
  final bool isLoggedIn;
  final String? userPubkey;
  final bool hasSeenOnboarding;
  final LocaleProvider localeProvider;

  const BroApp({Key? key, required this.isLoggedIn, this.userPubkey, required this.hasSeenOnboarding, required this.localeProvider}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: localeProvider),
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
            broLog('🔔 CALLBACK MAIN: Pagamento recebido! Reconciliando automaticamente...');
            orderProvider.onPaymentReceived(
              paymentId: paymentId,
              amountSats: amountSats,
              paymentHash: paymentHash,
            );
          };
          
          // Callback para pagamentos ENVIADOS (quando usuário libera BTC para o Bro)
          breezProvider.onPaymentSent = (String paymentId, int amountSats, String? paymentHash) {
            broLog('🔔 CALLBACK MAIN: Pagamento ENVIADO! Marcando ordem como completed...');
            orderProvider.onPaymentSent(
              paymentId: paymentId,
              amountSats: amountSats,
              paymentHash: paymentHash,
            );
          };

          // v132: Callback para auto-pagamento de ordens liquidadas
          final liquidProvider = context.read<BreezLiquidProvider>();
          orderProvider.onAutoPayLiquidation = (String orderId, order) async {
            broLog('⚡ [AutoPay-Main] Auto-pagamento para ordem ${orderId.substring(0, 8)}');
            
            // Buscar providerInvoice do metadata ou Nostr
            String? providerInvoice;
            providerInvoice = order.metadata?['providerInvoice'] as String?;
            
            if (providerInvoice == null || providerInvoice.isEmpty) {
              try {
                final nostrService = NostrOrderService();
                final completeData = await nostrService.fetchOrderCompleteEvent(orderId);
                if (completeData != null) {
                  providerInvoice = completeData['providerInvoice'] as String?;
                }
              } catch (e) {
                broLog('⚠️ [AutoPay-Main] Erro ao buscar invoice do Nostr: $e');
              }
            }
            
            if (providerInvoice == null || providerInvoice.isEmpty) {
              broLog('❌ [AutoPay-Main] Sem providerInvoice para ${orderId.substring(0, 8)}');
              return false;
            }
            
            // Tentar pagar via Spark ou Liquid (3 tentativas)
            for (int attempt = 1; attempt <= 3; attempt++) {
              try {
                Map<String, dynamic>? payResult;
                
                if (breezProvider.isInitialized) {
                  payResult = await breezProvider.payInvoice(providerInvoice).timeout(
                    const Duration(seconds: 30),
                    onTimeout: () => {'success': false, 'error': 'timeout'},
                  );
                } else if (liquidProvider.isInitialized) {
                  payResult = await liquidProvider.payInvoice(providerInvoice).timeout(
                    const Duration(seconds: 30),
                    onTimeout: () => {'success': false, 'error': 'timeout'},
                  );
                } else {
                  broLog('⚠️ [AutoPay-Main] Nenhuma carteira inicializada');
                  return false;
                }
                
                if (payResult != null && payResult['success'] == true) {
                  broLog('✅ [AutoPay-Main] Pagamento OK na tentativa $attempt');
                  // Pagar taxa da plataforma
                  final amountSats = (order.metadata?['amountSats'] as num?)?.toInt()
                      ?? (order.btcAmount * 100000000).round();
                  if (AppConfig.platformLightningAddress.isNotEmpty && amountSats > 0) {
                    await PlatformFeeService.sendPlatformFee(
                      orderId: orderId,
                      totalSats: amountSats,
                    );
                  }
                  return true;
                }
                
                broLog('⚠️ [AutoPay-Main] Tentativa $attempt falhou: ${payResult?['error']}');
              } catch (e) {
                broLog('⚠️ [AutoPay-Main] Tentativa $attempt erro: $e');
              }
              
              if (attempt < 3) {
                await Future.delayed(const Duration(seconds: 2));
              }
            }
            
            broLog('❌ [AutoPay-Main] 3 tentativas falharam para ${orderId.substring(0, 8)}');
            return false;
          };

          // v133: Callback para gerar invoice Lightning (provider side)
          orderProvider.onGenerateProviderInvoice = (int amountSats, String orderId) async {
            try {
              Map<String, dynamic>? result;
              if (breezProvider.isInitialized) {
                result = await breezProvider.createInvoice(
                  amountSats: amountSats,
                  description: 'Bro - Ordem ${orderId.substring(0, 8)}',
                ).timeout(const Duration(seconds: 30));
              } else if (liquidProvider.isInitialized) {
                result = await liquidProvider.createInvoice(
                  amountSats: amountSats,
                  description: 'Bro - Ordem ${orderId.substring(0, 8)}',
                ).timeout(const Duration(seconds: 30));
              }
              return result?['bolt11'] as String?;
            } catch (e) {
              broLog('⚠️ [InvoiceRefresh-Main] Erro ao gerar invoice: $e');
              return null;
            }
          };

          // Verificar reconciliacao na inicializacao (quando SDK estiver pronto)
          _scheduleReconciliationOnStartup(breezProvider, orderProvider);

          return Consumer<ThemeProvider>(
            builder: (context, themeProvider, _) {
              final locProv = context.watch<LocaleProvider>();
              return MaterialApp(
                title: 'Bro',
                debugShowCheckedModeBanner: false,
                theme: BroThemes.lightTheme,
                darkTheme: BroThemes.darkTheme,
                themeMode: themeProvider.themeMode,
                locale: locProv.locale,
                supportedLocales: AppLocalizations.supportedLocales,
                localizationsDelegates: const [
                  AppLocalizationsDelegate(),
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                // Banner ALFA em todas as telas
                builder: (context, child) {
                  return Column(
                    children: [
                      const AlfaBanner(),
                      Expanded(child: child ?? const SizedBox()),
                    ],
                  );
                },
                home: isLoggedIn 
                    ? const HomeScreen() 
                    : (!hasSeenOnboarding 
                        ? const OnboardingScreen() 
                        : const LoginScreen()),
            onGenerateRoute: (settings) {
              // Rotas com parametros
              if (settings.name == '/order-status') {
                final args = settings.arguments as Map<String, dynamic>?;
                broLog('Navegando para /order-status com args: $args');

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
              '/brix': (context) => const BrixScreen(),
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
