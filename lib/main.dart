import 'dart:convert';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
import 'screens/notifications_inbox_screen.dart';
import 'models/notification_item.dart';
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
import 'services/provider_payment_guard.dart';
import 'providers/theme_provider.dart';
import 'widgets/alfa_banner.dart';

import 'services/nostr_service.dart';
import 'services/background_notification_service.dart';
import 'services/nostr_order_service.dart';
import 'services/order_realtime_service.dart';
import 'services/brix_service.dart';
import 'services/brix_relay_service.dart';
import 'services/push_diag.dart';
import 'services/secure_storage_service.dart';
import 'services/background_billcode_relay.dart';
import 'config.dart';
import 'config/breez_config.dart';

/// Top-level handler for background FCM messages (required by Firebase).
/// When the app is killed, this tries to generate invoices for BRIX payments.
/// If SDK init fails, shows a notification to prompt the user to open the app.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  broLog('[FCM-BG] Background message: ${message.data}');

  // v492: order_update notifications are now delivered via FCM notification+data field
  // The system (Android/iOS) shows the notification automatically — no local notification needed
  // This fixes background notification delivery on BOTH platforms (data-only was "best effort")
  if (message.data['type'] == 'order_update') {
    final subtype = message.data['subtype']?.toString() ?? '';

    // v574: 'accept_relay' is a SILENT push that wakes us so we can publish
    // the NIP-44-encrypted billCode for the provider that just accepted —
    // even if the app is killed. Non-fatal: if it fails, the foreground
    // sync (`_sendEncryptedBillCodeForAcceptedOrders`) retries on next open
    // AND plaintext billCode in kind 30078 keeps the order working for the
    // provider regardless. Returns early so we don't fall through to
    // notification dedup logic (no visible notification for accept_relay).
    if (subtype == 'accept_relay') {
      try {
        await handleAcceptRelayInBackground(message.data);
      } catch (e) {
        broLog('[FCM-BG] accept_relay handler crashed: $e');
      }
      return;
    }

    broLog('[FCM-BG] order_update received — system notification handles display');

    // v553: Marca a chave de dedup como ja exibida pelo sistema. Quando o
    // usuario abrir o app, o sync local detecta a transicao e tenta exibir
    // uma SEGUNDA notificacao via NotificationService — bloqueamos isso
    // gravando a chave no set de notificadas antes que isso aconteca.
    try {
      final orderId = message.data['order_id']?.toString() ?? '';
      final subtype2 = message.data['subtype']?.toString() ?? '';
      const subtypeToPayload = {
        'accepted': 'order_accepted',
        'awaiting_confirmation': 'payment_received',
        'payment_submitted': 'payment_submitted',
        'completed': 'order_completed',
        'cancelled': 'order_cancelled',
        'disputed': 'order_disputed',
        'liquidated': 'order_liquidated',
        'new_order': 'new_order',
      };
      final prefix = subtypeToPayload[subtype2] ?? subtype2;
      if (orderId.isNotEmpty && prefix.isNotEmpty) {
        await NotificationService().markShown('$prefix:$orderId');
      }
    } catch (e) {
      broLog('[FCM-BG] markShown error: $e');
    }
    return;
  }

  if (message.data['type'] != 'brix_invoice_request' &&
      message.data['type'] != 'brix_pending_claim') return;

  final isPendingClaim = message.data['type'] == 'brix_pending_claim';
  final requestId = isPendingClaim
      ? message.data['payment_id']
      : message.data['request_id'];
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
    final ok = isPendingClaim
        ? await brixService.claimPayment(requestId, bolt11, pubkey)
        : await brixService.submitInvoice(requestId, bolt11, pubkey);
    broLog('[FCM-BG] ${isPendingClaim ? "Claim" : "Invoice"} ${ok ? "submitted" : "failed"}: $amountSats sats');

    // Show local notification on success so user knows payment is arriving
    if (ok) {
      try {
        final plugin = FlutterLocalNotificationsPlugin();
        const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
        const settings = InitializationSettings(android: androidSettings, iOS: DarwinInitializationSettings());
        await plugin.initialize(settings);
        await plugin.show(
          DateTime.now().millisecondsSinceEpoch % 2147483647,
          'Pagamento BRIX recebido!',
          'Recebendo $amountSats sats na sua carteira',
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
    }
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
  PushDiag.log('main: starting FCM init');
  try {
    await Firebase.initializeApp();
    PushDiag.log('main: Firebase.initializeApp OK');
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission();
    PushDiag.log('main: permission=${settings.authorizationStatus.name}');
    // iOS: Permitir exibição de notificações em foreground
    // Sem isso, firebase_messaging suprime alertas quando o app está aberto
    await messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );
    // Get FCM token (avoid deleteToken on iOS — it invalidates APNs mapping
    // and can cause a gap where pushes are lost)
    // iOS: APNS token must be available before FCM can map it to an FCM token.
    // Without this wait, getToken() returns null on iOS cold start.
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      String? apnsToken = await messaging.getAPNSToken();
      if (apnsToken == null) {
        broLog('[FCM] iOS: APNS token not ready, waiting 3s...');
        PushDiag.log('main: APNS null, waiting 3s');
        await Future.delayed(const Duration(seconds: 3));
        apnsToken = await messaging.getAPNSToken();
      }
      if (apnsToken == null) {
        broLog('[FCM] iOS: APNS still null, waiting 5s more...');
        PushDiag.log('main: APNS null, waiting 5s');
        await Future.delayed(const Duration(seconds: 5));
        apnsToken = await messaging.getAPNSToken();
      }
      broLog('[FCM] iOS APNS: ${apnsToken != null ? "ready" : "STILL NULL — push may fail"}');
      PushDiag.log('main: APNS=${apnsToken != null ? "ready(${apnsToken.length})" : "NULL"}');
    }
    fcmToken = await messaging.getToken();
    broLog('[FCM] Push token: ${fcmToken != null ? "present (${fcmToken!.length} chars)" : "NULL"}');
    PushDiag.log('main: FCM token=${fcmToken != null ? "ok(${fcmToken.length})" : "NULL"}');
  } catch (e) {
    broLog('[FCM] Firebase init failed (push disabled): $e');
    PushDiag.log('main: Firebase init FAILED: $e');
  }

  // Inicializar notificacoes
  await NotificationService().initialize();

  // Inicializar cache
  await CacheService().init();
  
  // Inicializar PlatformFeeService (carrega ordens já pagas do storage)
  await PlatformFeeService.initialize();

  // Inicializar ProviderPaymentGuard (anti gasto-duplo do pagamento ao provedor)
  await ProviderPaymentGuard.initialize();

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
      final token = fcmToken;
      final pubkey = userPubkey!;
      PushDiag.log('main: registering token pk=${pubkey.substring(0, 8)}');
      // Fire-and-forget with retry — don't block app startup
      _retryAsync('BRIX push', () async {
        await BrixService().initCredentials();
        final ok = await BrixService().registerPushToken(token, pubkey);
        PushDiag.log('main: BRIX register=$ok');
        return ok;
      });

      _retryAsync('Backend push', () async {
        // v544: Inclui flag provider_enabled para backend saber se deve
        // enviar broadcasts de 'Nova ordem' para este usuario.
        //
        // v559: Auto-heal removido. O bug original (provider_education_screen
        // marcando true prematuramente) ja foi corrigido na fonte. O auto-heal
        // estava REBAIXANDO provedores legitimos quando LocalCollateralService
        // perdia o cache (ex: instalacao limpa apos restore parcial), parando
        // de receber broadcasts de 'Nova ordem'.
        //
        // v559: Quando isProvider=false, OMITIMOS o flag em vez de mandar
        // false. O backend (v544) preserva o flag existente quando o campo
        // e omitido — assim o provider mode so liga via tier_deposit ou
        // provider_orders_screen, nunca "desliga" sozinho aqui.
        final isProvider = await SecureStorageService.isProviderMode(userPubkey: pubkey);
        final ok = isProvider
            ? await ApiService().registerPushToken(token, providerEnabled: true)
            : await ApiService().registerPushToken(token);
        PushDiag.log('main: backend register=$ok provider=$isProvider${isProvider ? '' : '(omitido)'}');
        return ok;
      });
    } else {
      broLog('[FCM] ⚠️ CANNOT register push: fcmToken=${fcmToken != null ? "present" : "NULL"} pubkey=${userPubkey != null ? "present" : "NULL"}');
      PushDiag.log('main: SKIP register (fcm=${fcmToken != null} pk=${userPubkey != null})');
    }

    // Re-register when Firebase rotates the FCM token
    FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
      broLog('[FCM] Token refreshed, re-registering...');
      // Reset relay service flags FIRST so next poll re-registers too
      BrixRelayService().resetFcmRegistration();
      if (userPubkey != null) {
        try {
          await BrixService().initCredentials();
          final brixOk = await BrixService().registerPushToken(newToken, userPubkey!);
          broLog('[FCM] BRIX push token re-registered after refresh: $brixOk');
        } catch (e) {
          broLog('[FCM] BRIX re-registration failed: $e');
        }
        try {
          // v633: preserve provider status on token rotation. Previously this
          // re-registration omitted providerEnabled, and if the backend had
          // never received the flag (startup race), the rotated token stayed
          // non-provider → provider stopped getting 'Nova ordem' broadcasts.
          final isProv = await SecureStorageService.isProviderMode(userPubkey: userPubkey);
          final backendOk = isProv
              ? await ApiService().registerPushToken(newToken, providerEnabled: true)
              : await ApiService().registerPushToken(newToken);
          broLog('[FCM] Backend push token re-registered after refresh: $backendOk (provider=$isProv)');
        } catch (e) {
          broLog('[FCM] Backend re-registration failed: $e');
        }
      }
    });

    // Listen for foreground FCM messages (BRIX wake-up + order updates)
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      broLog('[FCM] Foreground message: ${message.data}');
      if (message.data['type'] == 'brix_invoice_request' ||
          message.data['type'] == 'brix_pending_claim') {
        BrixRelayService().triggerPoll();
      } else if (message.data['type'] == 'order_update') {
        broLog('[FCM] Order update push — triggering sync');
        // Sync will be triggered when OrderProvider is available
        OrderRealtimeService().onOrderEvent?.call();

        // v552: notify OrderProvider to mark this order as "syncing" so the
        // UI can show a spinner/placeholder until the relay event arrives.
        final orderId = message.data['order_id']?.toString() ?? '';
        final subtype = message.data['subtype']?.toString() ?? '';
        if (orderId.isNotEmpty && subtype.isNotEmpty) {
          OrderRealtimeService().onOrderPush?.call(orderId, subtype);
        }

        // v553: Mapeamento canonico subtype -> payload, usado tanto para
        // dedup local (Android showGeneric) quanto para markShown (iOS).
        const subtypeToPayload = {
          'accepted': 'order_accepted',
          'awaiting_confirmation': 'payment_received',
          'payment_submitted': 'payment_submitted',
          'completed': 'order_completed',
          'cancelled': 'order_cancelled',
          'disputed': 'order_disputed',
          'liquidated': 'order_liquidated',
          'new_order': 'new_order',
        };
        final prefix = subtypeToPayload[subtype] ?? subtype;
        final dedupKey = (orderId.isNotEmpty && prefix.isNotEmpty)
            ? '$prefix:$orderId'
            : null;

        // v553: o sistema (iOS em foreground via setForegroundNotificationPresentationOptions
        // e iOS/Android em background) JA exibiu a notificacao do payload FCM.
        // Marcamos a chave como "ja exibida" antes que o sync local detecte
        // a transicao em order_status_screen e tente mostrar uma SEGUNDA
        // notificacao via NotificationService (foi o caso de "Comprovante
        // Recebido" + "Comprovante recebido" em iOS).
        if (dedupKey != null) {
          NotificationService().markShown(dedupKey);
        }

        // Persiste no inbox de notificacoes (independente de plataforma).
        // Mesmo se o sistema ja exibiu nativamente, queremos a entrada salva.
        {
          final notif = message.notification;
          final title = notif?.title?.trim() ?? '';
          final body = notif?.body?.trim() ?? '';
          if (title.isNotEmpty || body.isNotEmpty) {
            NotificationInbox.addRaw(
              title: title.isNotEmpty ? title : 'Bro',
              body: body,
              payload: dedupKey,
            );
          }
        }

        // v545: Android nao exibe automaticamente o campo 'notification' do FCM
        // quando o app esta em foreground. Mostra local notification aqui (o
        // dedup em NotificationService via bro_notified_transitions impede que
        // seja exibida duas vezes para a mesma ordem quando o sistema ja
        // mostrou em background).
        //
        // v548: iOS ja exibe a notificacao FCM em foreground via
        // setForegroundNotificationPresentationOptions(alert: true). Chamar
        // showGeneric aqui duplicava a notificacao no iOS ("Bro encontrado"
        // aparecia 2x por ordem). So disparamos local notification no Android.
        if (defaultTargetPlatform == TargetPlatform.android) {
          final notif = message.notification;
          if (notif != null && (notif.title?.isNotEmpty ?? false)) {
            NotificationService().showGeneric(
              title: notif.title!,
              body: notif.body ?? '',
              dedupKey: dedupKey,
            );
          }
        }
      }
    });

    // When user taps notification to open app, also trigger poll
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      broLog('[FCM] App opened from notification: ${message.data}');
      if (message.data['type'] == 'brix_invoice_request' ||
          message.data['type'] == 'brix_pending_claim') {
        BrixRelayService().triggerPoll();
      } else if (message.data['type'] == 'order_update') {
        OrderRealtimeService().onOrderEvent?.call();
        // v552: also mark order as syncing so opening the app shows the
        // spinner immediately while the relay catches up.
        final orderId = message.data['order_id']?.toString() ?? '';
        final subtype = message.data['subtype']?.toString() ?? '';
        if (orderId.isNotEmpty && subtype.isNotEmpty) {
          OrderRealtimeService().onOrderPush?.call(orderId, subtype);
        }
      }
    });

    // v262: Iniciar background notifications (polling Nostr a cada 15min)
    await initBackgroundNotifications();
    broLog('🔔 Background notifications ativado');

    // v441: Start real-time Nostr subscription for order events
    if (userPubkey != null) {
      OrderRealtimeService().start(userPubkey!, onEvent: () {
        broLog('[RT] Order event received — will sync on next poll');
      });
      broLog('⚡ Order real-time subscription ativado');
    }
  }

  // Verificar se já viu onboarding
  final hasSeenOnboarding = await storage.getData('has_seen_onboarding') == 'true';

  // Inicializar LocaleProvider (idioma salvo ou auto-detectar)
  final localeProvider = LocaleProvider();
  await localeProvider.initialize();

  // Breez SDK sera inicializado no provider (lazy initialization)

  runApp(BroApp(isLoggedIn: isLoggedIn, userPubkey: userPubkey, hasSeenOnboarding: hasSeenOnboarding, localeProvider: localeProvider));
}

/// Retry an async action with exponential backoff (fire-and-forget safe)
Future<bool> _retryAsync(String label, Future<bool> Function() action, {int maxRetries = 3}) async {
  for (int attempt = 1; attempt <= maxRetries; attempt++) {
    try {
      final ok = await action().timeout(const Duration(seconds: 10));
      if (ok) return true;
    } catch (e) {
      broLog('[FCM] $label attempt $attempt/$maxRetries failed: $e');
    }
    if (attempt < maxRetries) {
      await Future.delayed(Duration(seconds: 2 * attempt));
    }
  }
  broLog('[FCM] ⚠️ $label failed after $maxRetries retries');
  return false;
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

          // v441: Connect real-time order subscription to trigger sync
          OrderRealtimeService().onOrderEvent = () {
            broLog('[RT] Triggering immediate sync from real-time event');
            orderProvider.syncOrdersFromNostr(force: true);
          };

          // v552: Connect FCM order_update push -> mark order as syncing
          // so UI can show spinner/placeholder while the relay catches up.
          OrderRealtimeService().onOrderPush = (String orderId, String subtype) {
            final expected = OrderProvider.expectedStatusForSubtype(subtype);
            if (expected != null) {
              orderProvider.markSyncing(orderId, expected);
            }
          };
          
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

            // 🛡️ v634 ANTI GASTO-DUPLO: se o provedor JÁ foi pago (via confirmação
            // manual ou auto-pagamento anterior), NÃO pagar de novo. Mesmo invoice.
            if (ProviderPaymentGuard.isPaid(orderId)) {
              broLog('🛡️ [AutoPay-Main] Ordem ${orderId.substring(0, 8)} já teve o provedor PAGO — pulando (anti double-spend)');
              return true;
            }

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
            
            // v449: Validar invoice amount antes de pagar (segurança contra invoice inflado)
            final baseSats = (order.btcAmount * 100000000).round();
            final expectedWithFee = baseSats + (baseSats * AppConfig.providerFeePercent).round();
            final maxAllowed = (expectedWithFee * 1.03).ceil();
            final minAllowed = (expectedWithFee * 0.97).floor();
            try {
              if (breezProvider.isInitialized) {
                final decoded = await breezProvider.decodeInvoice(providerInvoice);
                if (decoded != null && decoded['success'] == true) {
                  // v622: proteção anti-carol — NÃO tentar pagar invoice EXPIRADO.
                  // Pagar um invoice vencido faz o SDK emitir "Pagamento falhou"
                  // (notificação chata que aparecia toda madrugada). Se expirou,
                  // pulamos silenciosamente; o provedor renova o invoice a cada
                  // 30min e o pagamento acontece assim que chega um fresco.
                  final tsSecs = int.tryParse(decoded['invoice']?['timestamp']?.toString() ?? '0') ?? 0;
                  final expSecs = int.tryParse(decoded['invoice']?['expiry']?.toString() ?? '0') ?? 0;
                  if (tsSecs > 0 && expSecs > 0) {
                    final expiresAt = DateTime.fromMillisecondsSinceEpoch((tsSecs + expSecs) * 1000);
                    if (DateTime.now().isAfter(expiresAt)) {
                      broLog('⏳ [AutoPay-Main] Invoice EXPIRADO em $expiresAt — pulando sem tentar pagar (aguardando invoice fresco do provedor).');
                      return false;
                    }
                  }
                  final invoiceSats = int.tryParse(decoded['invoice']?['amountSats']?.toString() ?? '0') ?? 0;
                  if (invoiceSats <= 0) {
                    broLog('🚨 [AutoPay-Main] BLOQUEADO: invoice com 0 sats! Aguardando invoice válido.');
                    return false;
                  }
                  if (invoiceSats > maxAllowed) {
                    broLog('🚨 [AutoPay-Main] BLOQUEADO: invoice inflado! $invoiceSats > $maxAllowed (esperado ~$expectedWithFee). Aguardando novo invoice do provedor.');
                    return false;
                  }
                  // v621: NÃO adiar mais invoices ABAIXO do esperado. O invoice é
                  // assinado pelo provedor (evento bro_complete) e um valor menor só
                  // beneficia o comprador — sem vetor de ataque. Bloquear aqui deixava
                  // o PROVEDOR SEM RECEBER (ordem marcada "liquidada" mas auto-pagamento
                  // adiado p/ sempre) quando order.btcAmount ficou poluído com base+5%
                  // (bug de taxa composta) → esperado inflado rejeitava o invoice correto
                  // base+3%. Mantemos só o teto anti-inflação (maxAllowed) e o >0.
                  if (invoiceSats < minAllowed) {
                    broLog('⚠️ [AutoPay-Main] Invoice abaixo do esperado ($invoiceSats < $minAllowed) — pagando mesmo assim (valor autorizado pelo provedor, sem risco p/ comprador).');
                  } else {
                    broLog('✅ [AutoPay-Main] Invoice validado: $invoiceSats sats (esperado ~$expectedWithFee, range $minAllowed-$maxAllowed)');
                  }
                }
              }
            } catch (e) {
              broLog('🚨 [AutoPay-Main] Erro ao decodificar invoice — bloqueando por segurança: $e');
              return false;
            }
            
            // Tentar pagar via Spark ou Liquid (3 tentativas)
            for (int attempt = 1; attempt <= 3; attempt++) {
              try {
                Map<String, dynamic>? payResult;
                
                if (breezProvider.isInitialized) {
                  payResult = await breezProvider.payInvoice(providerInvoice);
                } else if (liquidProvider.isInitialized) {
                  payResult = await liquidProvider.payInvoice(providerInvoice);
                } else {
                  broLog('⚠️ [AutoPay-Main] Nenhuma carteira inicializada');
                  return false;
                }
                
                if (payResult != null && payResult['success'] == true) {
                  broLog('✅ [AutoPay-Main] Pagamento OK na tentativa $attempt');
                  // 🛡️ v634: travar a ordem de forma persistente (anti gasto-duplo)
                  await ProviderPaymentGuard.markPaid(orderId);
                  // Pagar taxa da plataforma
                  // v621: taxa da plataforma = 2% da BASE (order.btcAmount). Antes usava
                  // metadata['amountSats'] que em fluxos wallet guardava o TOTAL (base+5%),
                  // cobrando 2% do total (~2.1% da base) e deixando o comprador levemente
                  // curto. Derivar da base garante comprador paga exatamente base+5%
                  // (provider base+3% + plataforma 2%), com a plataforma absorvendo roteamento.
                  final amountSats = (order.btcAmount * 100000000).round();
                  if (AppConfig.platformLightningAddress.isNotEmpty && amountSats > 0) {
                    await PlatformFeeService.sendPlatformFee(
                      orderId: orderId,
                      totalSats: amountSats,
                    );
                  }
                  return true;
                }
                
                // v515: Detect AlreadyExists → invoice was already paid, treat as success
                final payError = payResult?['error']?.toString().toLowerCase() ?? '';
                if (payError.contains('alreadyexists') ||
                    payError.contains('already paid') ||
                    payError.contains('already settled') ||
                    payError.contains('preimage request already exists')) {
                  broLog('✅ [AutoPay-Main] Invoice já pago (AlreadyExists) — marcando como sucesso');
                  await ProviderPaymentGuard.markPaid(orderId);
                  return true;
                }
                
                broLog('⚠️ [AutoPay-Main] Tentativa $attempt falhou: ${payResult?['error']}');
              } catch (e) {
                final errStr = e.toString().toLowerCase();
                if (errStr.contains('alreadyexists') ||
                    errStr.contains('already paid') ||
                    errStr.contains('preimage request already exists')) {
                  broLog('✅ [AutoPay-Main] Invoice já pago (AlreadyExists exception) — marcando como sucesso');
                  await ProviderPaymentGuard.markPaid(orderId);
                  return true;
                }
                broLog('⚠️ [AutoPay-Main] Tentativa $attempt erro: $e');
              }
              
              if (attempt < 3) {
                await Future.delayed(const Duration(seconds: 2));
              }
            }
            
            broLog('❌ [AutoPay-Main] 3 tentativas falharam para ${orderId.substring(0, 8)}');
            return false;
          };

          // Callback para auto-pagamento EM BACKGROUND do reembolso de disputa
          // resolvida a favor do provedor (roda no sync, sem abrir a ordem).
          // SEGURANÇA: o invoice de reembolso só é aceito se assinado pelo ADMIN
          // (validado em fetchAdminReimbursementInvoice). Aqui ainda validamos
          // valor > 0, não-expirado e um teto de sanidade (defesa contra chave
          // admin comprometida).
          orderProvider.onAutoPayDisputeReimbursement = (String orderId, order) async {
            broLog('⚡ [DisputeAutoPay-Main] Reembolso admin para ordem ${orderId.substring(0, 8)}');
            // 🛡️ v634: o comprador paga NO MÁXIMO uma vez por ordem. Se já pagou
            // (providerInvoice na confirmação/liquidação), NÃO pagar reembolso também.
            if (ProviderPaymentGuard.isPaid(orderId)) {
              broLog('🛡️ [DisputeAutoPay-Main] Ordem ${orderId.substring(0, 8)} já paga — pulando reembolso (anti double-spend)');
              return true;
            }
            final nostrService = NostrOrderService();
            String? adminInvoice;
            try {
              adminInvoice = await nostrService.fetchAdminReimbursementInvoice(orderId);
            } catch (e) {
              broLog('⚠️ [DisputeAutoPay-Main] Erro ao buscar invoice de reembolso: $e');
            }
            if (adminInvoice == null || adminInvoice.isEmpty) {
              broLog('❌ [DisputeAutoPay-Main] Sem invoice de reembolso admin para ${orderId.substring(0, 8)}');
              return false;
            }

            // Validar invoice antes de pagar
            try {
              if (breezProvider.isInitialized) {
                final decoded = await breezProvider.decodeInvoice(adminInvoice);
                if (decoded != null && decoded['success'] == true) {
                  final tsSecs = int.tryParse(decoded['invoice']?['timestamp']?.toString() ?? '0') ?? 0;
                  final expSecs = int.tryParse(decoded['invoice']?['expiry']?.toString() ?? '0') ?? 0;
                  if (tsSecs > 0 && expSecs > 0) {
                    final expiresAt = DateTime.fromMillisecondsSinceEpoch((tsSecs + expSecs) * 1000);
                    if (DateTime.now().isAfter(expiresAt)) {
                      broLog('⏳ [DisputeAutoPay-Main] Invoice de reembolso EXPIRADO — pulando (admin renova).');
                      return false;
                    }
                  }
                  final invoiceSats = int.tryParse(decoded['invoice']?['amountSats']?.toString() ?? '0') ?? 0;
                  if (invoiceSats <= 0) {
                    broLog('🚨 [DisputeAutoPay-Main] BLOQUEADO: invoice reembolso 0 sats.');
                    return false;
                  }
                  // Teto de sanidade: reembolso ~ base + taxa; 2x cobre folga de
                  // roteamento. Só o admin assina, mas isto limita dano se a
                  // chave admin vazar.
                  final baseSats = (order.btcAmount * 100000000).round();
                  final sanityCap = ((baseSats + (baseSats * AppConfig.providerFeePercent).round()) * 2).ceil();
                  if (sanityCap > 0 && invoiceSats > sanityCap) {
                    broLog('🚨 [DisputeAutoPay-Main] BLOQUEADO: invoice reembolso inflado! $invoiceSats > $sanityCap');
                    return false;
                  }
                }
              }
            } catch (e) {
              broLog('🚨 [DisputeAutoPay-Main] Erro ao decodificar invoice reembolso — bloqueando: $e');
              return false;
            }

            for (int attempt = 1; attempt <= 3; attempt++) {
              try {
                Map<String, dynamic>? payResult;
                if (breezProvider.isInitialized) {
                  payResult = await breezProvider.payInvoice(adminInvoice);
                } else if (liquidProvider.isInitialized) {
                  payResult = await liquidProvider.payInvoice(adminInvoice);
                } else {
                  broLog('⚠️ [DisputeAutoPay-Main] Nenhuma carteira inicializada');
                  return false;
                }
                if (payResult != null && payResult['success'] == true) {
                  broLog('✅ [DisputeAutoPay-Main] Reembolso pago na tentativa $attempt');
                  await ProviderPaymentGuard.markPaid(orderId);
                  return true;
                }
                final payError = payResult?['error']?.toString().toLowerCase() ?? '';
                if (payError.contains('alreadyexists') ||
                    payError.contains('already paid') ||
                    payError.contains('already settled') ||
                    payError.contains('preimage request already exists')) {
                  broLog('✅ [DisputeAutoPay-Main] Invoice já pago (AlreadyExists) — sucesso');
                  await ProviderPaymentGuard.markPaid(orderId);
                  return true;
                }
                broLog('⚠️ [DisputeAutoPay-Main] Tentativa $attempt falhou: ${payResult?['error']}');
              } catch (e) {
                final errStr = e.toString().toLowerCase();
                if (errStr.contains('alreadyexists') ||
                    errStr.contains('already paid') ||
                    errStr.contains('preimage request already exists')) {
                  broLog('✅ [DisputeAutoPay-Main] Invoice já pago (AlreadyExists exception) — sucesso');
                  await ProviderPaymentGuard.markPaid(orderId);
                  return true;
                }
                broLog('⚠️ [DisputeAutoPay-Main] Tentativa $attempt erro: $e');
              }
              if (attempt < 3) {
                await Future.delayed(const Duration(seconds: 2));
              }
            }
            broLog('❌ [DisputeAutoPay-Main] 3 tentativas falharam para ${orderId.substring(0, 8)}');
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
              '/notifications': (context) => const NotificationsInboxScreen(),
            },
          );
            },
          );
        },
      ),
    );
  }
}
