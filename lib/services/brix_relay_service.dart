import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:bro_app/services/brix_service.dart';
import 'package:bro_app/services/api_service.dart';
import 'package:bro_app/services/storage_service.dart';
import 'package:bro_app/services/secure_storage_service.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:bro_app/services/push_diag.dart';
import 'package:bro_app/services/lnaddress_service.dart';
import 'package:bro_app/services/platform_fee_service.dart';
import 'package:bro_app/providers/breez_provider.dart';
import 'package:bro_app/config.dart';
import 'package:bro_app/config/payment_methods.dart';

/// Global BRIX invoice relay service.
/// Polls the BRIX server for incoming invoice requests and auto-generates
/// invoices via the user's Breez wallet. Runs whenever the app is in foreground.
/// Also retries queued outgoing BRIX payments when recipients come online.
class BrixRelayService {
  static final BrixRelayService _instance = BrixRelayService._internal();
  factory BrixRelayService() => _instance;
  BrixRelayService._internal();

  final _brixService = BrixService();
  final _storage = StorageService();

  Timer? _pollTimer;
  bool _running = false;
  String? _pubkey;
  String? _brixUsername;
  BuildContext? _context;
  bool _fcmRegistered = false;
  bool _backendFcmRegistered = false;

  /// Callback for when a queued outgoing payment is completed.
  void Function(String recipient, int amountSats)? onQueuedPaymentCompleted;

  int _fcmRetryCount = 0;

  /// Ensure FCM token is registered with BRIX server (idempotent).
  /// Retries automatically on failure until successful.
  Future<void> _ensureFcmRegistered() async {
    if (_fcmRegistered && _backendFcmRegistered) return;
    try {
      _pubkey ??= await _storage.getNostrPublicKey();
      if (_pubkey == null || _pubkey!.isEmpty) {
        PushDiag.log('relay: no pubkey');
        return;
      }
      // iOS: APNS token must be ready before FCM can provide a token
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        String? apns = await FirebaseMessaging.instance.getAPNSToken();
        // v524: aggressive APNS wait within a single attempt (up to 8s).
        // On iOS, APNS can take 10-30s on cold starts and the old code bailed immediately.
        if (apns == null) {
          for (int i = 0; i < 4 && apns == null; i++) {
            await Future.delayed(const Duration(seconds: 2));
            apns = await FirebaseMessaging.instance.getAPNSToken();
          }
        }
        if (apns == null) {
          if (_fcmRetryCount % 5 == 0) {
            broLog('[BRIX-RELAY] iOS: APNS still not ready after 8s (retry $_fcmRetryCount)');
            PushDiag.log('relay: APNS null retry=$_fcmRetryCount');
          }
          _fcmRetryCount++;
          return;
        }
      }
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) {
        _fcmRetryCount++;
        broLog('[BRIX-RELAY] FCM token is null (retry $_fcmRetryCount) — cannot register');
        PushDiag.log('relay: FCM token NULL retry=$_fcmRetryCount');
        return;
      }

      // Register with BRIX server
      if (!_fcmRegistered) {
        // Ensure NIP-98 credentials are loaded before signing the request
        await _brixService.initCredentials();
        final ok = await _brixService.registerPushToken(token, _pubkey!);
        if (ok) {
          _fcmRegistered = true;
          _fcmRetryCount = 0;
          broLog('[BRIX-RELAY] FCM token registered successfully (BRIX)');
          // Auto-claim any web-created BRIX accounts with same email
          final linked = await _brixService.claimWebAccounts(_pubkey!);
          if (linked.isNotEmpty) {
            broLog('[BRIX-RELAY] Auto-linked web accounts: ${linked.join(", ")}');
          }
        } else {
          _fcmRetryCount++;
          broLog('[BRIX-RELAY] BRIX FCM registration failed (attempt $_fcmRetryCount)');
        }
      }

      // Register with main backend for order_update push notifications
      if (!_backendFcmRegistered) {
        try {
          // v633: assert providerEnabled=true when in provider mode. The
          // reliable retry loop previously registered WITHOUT the flag, so if
          // the one-shot startup registration failed (network unavailable in
          // the ~8s startup window), the provider NEVER got 'Nova ordem'
          // broadcasts — the backend preserves the (absent → false) flag.
          // Now the loop itself enforces provider status.
          final isProvider = await SecureStorageService.isProviderMode(userPubkey: _pubkey);
          final ok = isProvider
              ? await ApiService().registerPushToken(token, providerEnabled: true)
              : await ApiService().registerPushToken(token);
          if (ok) {
            _backendFcmRegistered = true;
            broLog('[BRIX-RELAY] FCM token registered successfully (backend, provider=$isProvider)');
            PushDiag.log('relay: backend register OK provider=$isProvider');
            if (isProvider) {
              unawaited(_resyncProviderFilters());
            }
          } else {
            broLog('[BRIX-RELAY] Backend FCM registration returned false');
            PushDiag.log('relay: backend register FALSE');
          }
        } catch (e) {
          broLog('[BRIX-RELAY] Backend FCM registration error: $e');
          PushDiag.log('relay: backend register ERR ${e.toString().substring(0, e.toString().length > 60 ? 60 : e.toString().length)}');
        }
      }
    } catch (e) {
      _fcmRetryCount++;
      broLog('[BRIX-RELAY] FCM registration error (attempt $_fcmRetryCount): $e');
    }
  }

  /// v524: Ask the backend whether our token is actually stored.
  /// If not, flip the flag so the next poll re-registers.
  Future<void> _verifyBackendRegistration() async {
    try {
      final registered = await ApiService().diagnosePushToken();
      PushDiag.log('relay: diagnose=${registered ?? "null"}');
      if (registered == false) {
        broLog('[BRIX-RELAY] Backend says NOT registered — forcing re-registration');
        _backendFcmRegistered = false;
      }
    } catch (e) {
      PushDiag.log('relay: diagnose ERR $e');
    }
  }

  /// v633: Re-send provider payment-method + accepted-currency filters to the
  /// backend. The UI syncs these fire-and-forget only when the filter changes;
  /// if that single call failed (network), the provider could stop receiving
  /// matching 'Nova ordem' broadcasts. Re-asserting on every fresh backend
  /// registration heals it automatically (no user action needed).
  Future<void> _resyncProviderFilters() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('bro_provider_selected_methods');
      if (raw == null || raw.isEmpty) return; // nothing saved → backend keeps 'all'
      final methods = (jsonDecode(raw) as List).map((e) => e.toString()).toList();
      if (methods.isEmpty) return;
      await ApiService().setProviderPaymentMethods(methods);
      final accepted = <String>[];
      for (final g in PaymentMethods.kGroups) {
        if (g.currency == 'BRL') continue; // BRL always delivered by backend
        if (g.ids.every(methods.contains)) accepted.add(g.currency);
      }
      await ApiService().setProviderAcceptedCurrencies(accepted);
      PushDiag.log('relay: provider filters resynced (methods=${methods.length}, cur=${accepted.length})');
    } catch (e) {
      broLog('[BRIX-RELAY] provider filter resync failed: $e');
    }
  }

  /// v633: Periodic re-assert of provider status. Protects against the backend
  /// dropping the providerEnabled flag on restart / token rotation. Idempotent.
  Future<void> _reassertProviderStatusPeriodic() async {
    try {
      if (_pubkey == null || _pubkey!.isEmpty) return;
      final isProvider = await SecureStorageService.isProviderMode(userPubkey: _pubkey);
      if (!isProvider) return;
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) return;
      await ApiService().registerPushToken(token, providerEnabled: true);
      await _resyncProviderFilters();
      PushDiag.log('relay: periodic provider re-assert OK');
    } catch (e) {
      broLog('[BRIX-RELAY] periodic provider re-assert failed: $e');
    }
  }

  /// Start the relay service. Call from main app after login.
  void start(BuildContext context) {
    _context = context;
    if (_running) {
      broLog('[BRIX-RELAY] start() called but already running');
      return;
    }
    _running = true;
    _fcmRegistered = false; // Reset on start so we always try to register
    _backendFcmRegistered = false;
    _pollTimer?.cancel();
    // v535: intervalo de 5s (antes 1.5s). 1.5s era excessivo e causava
    // lentidao na UI por fazer 2 chamadas HTTP a cada polling (invoice requests
    // + pending payments). FCM push faz triggerPoll() imediato quando chega
    // pagamento, entao 5s de fallback eh suficiente.
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _poll());
    _poll(); // immediate first check
    _ensureFcmRegistered();
    broLog('[BRIX-RELAY] Service started');
  }

  /// Restart the relay (e.g. after app resumes from background).
  void restart(BuildContext context) {
    _context = context;
    _pollTimer?.cancel();
    _running = true;
    _fcmRegistered = false; // Force re-registration after resume (token may have rotated)
    _backendFcmRegistered = false;
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _poll());
    _poll();
    _ensureFcmRegistered();
    broLog('[BRIX-RELAY] Service restarted (resume)');
  }

  /// Stop the relay service.
  void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _running = false;
    _context = null;
    broLog('[BRIX-RELAY] Service stopped');
  }

  /// Trigger an immediate poll cycle. Called when FCM push arrives.
  void triggerPoll() {
    if (_running && _context != null) {
      broLog('[BRIX-RELAY] FCM wake-up → immediate poll');
      _poll();
    }
  }

  /// Reset FCM registration state so next poll re-registers.
  /// Called when Firebase rotates the FCM token.
  void resetFcmRegistration() {
    _fcmRegistered = false;
    _backendFcmRegistered = false;
    _fcmRetryCount = 0;
  }

  int _pollCount = 0;
  bool _polling = false;

  Future<void> _poll() async {
    if (!_running || _context == null) return;
    if (_polling) return; // Prevent concurrent polls
    _polling = true;
    _pollCount++;

    try {
      await _pollInner();
    } finally {
      _polling = false;
    }
  }

  Future<void> _pollInner() async {

    // Log every 20th poll (~30s) for visibility
    if (_pollCount % 20 == 1) {
      broLog('[BRIX-RELAY] Poll #$_pollCount (running=$_running, fcmRegistered=$_fcmRegistered, pubkey=${_pubkey?.substring(0, 8) ?? "null"})');
    }

    // Retry FCM registration every ~30s until successful.
    // v620: poll passou de 1.5s→5s (v535) mas o módulo continuava 20, o que
    // esticou o retry real para ~100s. % 6 com poll de 5s = ~30s (intenção original).
    if ((!_fcmRegistered || !_backendFcmRegistered) && _pollCount % 6 == 1) {
      _ensureFcmRegistered();
    }

    // v524: A cada ~2min, verifica se o backend REALMENTE tem nosso token.
    // Protege contra deregistro silencioso (FCM rotaciona sem disparar
    // onTokenRefresh, ou servidor descarta tokens antigos).
    // v620: % 24 com poll de 5s = ~120s (antes % 80 = ~6,7min por causa do 5s).
    if (_backendFcmRegistered && _pollCount % 24 == 1) {
      unawaited(_verifyBackendRegistration());
    }

    // v633: A cada ~10min, re-afirma providerEnabled + filtros no backend.
    // Protege contra o backend perder a flag em restart/rotacao de token, o
    // que silenciava os broadcasts de 'Nova ordem' (causa das ordens perdidas).
    if (_backendFcmRegistered && _pollCount % 120 == 61) {
      unawaited(_reassertProviderStatusPeriodic());
    }

    try {
      // Get pubkey lazily
      _pubkey ??= await _storage.getNostrPublicKey();
      if (_pubkey == null || _pubkey!.isEmpty) {
        if (_pollCount % 20 == 1) {
          broLog('[BRIX-RELAY] ⚠ No pubkey in storage — relay inactive');
        }
        return;
      }

      // Load BRIX username lazily (needed to filter requests per-account)
      if (_brixUsername == null) {
        try {
          final prefs = await SharedPreferences.getInstance();
          final raw = prefs.getString('brix_cached');
          if (raw != null) {
            final cached = jsonDecode(raw) as Map<String, dynamic>;
            _brixUsername = cached['username'] as String?;
            if (_brixUsername != null) {
              broLog('[BRIX-RELAY] Loaded BRIX username: $_brixUsername');
            }
          }
        } catch (_) {}
      }

      // Init NIP-98 credentials lazily (loads private key for signed auth)
      await _brixService.initCredentials();

      // Check if user has active BRIX invoice requests (online flow)
      final requests = await _brixService.getInvoiceRequests(_pubkey!, username: _brixUsername);

      final breezProvider = _context!.read<BreezProvider>();

      for (final request in requests) {
        broLog('⚡ [BRIX-RELAY] Generating invoice: ${request.amountSats} sats (request=${request.id})${request.comment != null ? ' memo: ${request.comment}' : ''}');

        // Generate invoice for FULL amount (LNURL wallets verify amount match)
        final description = request.comment != null && request.comment!.isNotEmpty
            ? 'BRIX: ${request.comment}'
            : 'BRIX Payment';
        final invoiceResult = await breezProvider.createInvoice(
          amountSats: request.amountSats,
          description: description,
        );

        if (invoiceResult == null) {
          broLog('❌ [BRIX-RELAY] createInvoice returned null for ${request.amountSats} sats');
          continue;
        }

        if (invoiceResult['success'] != true) {
          broLog('❌ [BRIX-RELAY] createInvoice FAILED for ${request.amountSats} sats: ${invoiceResult['error']}');
          continue;
        }

        if (invoiceResult['success'] == true) {
          final bolt11 = invoiceResult['bolt11'] as String? ??
              invoiceResult['invoice'] as String?;
          if (bolt11 != null) {
            final ok = await _brixService.submitInvoice(
                request.id, bolt11, _pubkey!);
            broLog(
                '⚡ [BRIX-RELAY] Invoice ${ok ? "submitted" : "failed"} for ${request.amountSats} sats');

            // Persist locally so it appears in wallet even if SDK forgets
            if (ok) {
              persistBrixPayment(
                amountSats: request.amountSats,
                description: description,
                paymentHash: invoiceResult['paymentHash'] as String?,
              );
            }

            // Schedule platform fee after payment settles
            if (ok) {
              final feeSats = (request.amountSats * AppConfig.brixFeePercent).round();
              if (feeSats > 0) {
                // Delay to allow payment to settle before sending fee
                Future.delayed(const Duration(seconds: 12), () {
                  _sendBrixFee(request.id, feeSats);
                });
              }
            }
          }
        }
      }

      // ── Claim pending offline payments ──
      final pendingPayments = await _brixService.getPendingPayments(_pubkey!);
      for (final payment in pendingPayments) {
        if (_claimedPayments.contains(payment.id)) continue;
        _claimedPayments.add(payment.id);

        broLog('💰 [BRIX-RELAY] Claiming offline payment: ${payment.amountSats} sats');

        final offlineDesc = payment.senderNote != null && payment.senderNote!.isNotEmpty
            ? 'BRIX: ${payment.senderNote}'
            : 'BRIX Payment';
        final invoiceResult = await breezProvider.createInvoice(
          amountSats: payment.amountSats,
          description: offlineDesc,
        );

        if (invoiceResult != null && invoiceResult['success'] == true) {
          final bolt11 = invoiceResult['bolt11'] as String? ??
              invoiceResult['invoice'] as String?;
          if (bolt11 != null) {
            final claimed = await _brixService.claimPayment(
                payment.id, bolt11, _pubkey!);
            broLog(
                '💰 [BRIX-RELAY] Claim ${claimed ? "success" : "failed"} for ${payment.amountSats} sats');
            if (claimed) {
              persistBrixPayment(
                amountSats: payment.amountSats,
                description: offlineDesc,
                paymentHash: invoiceResult['paymentHash'] as String?,
              );
            }
            if (!claimed) _claimedPayments.remove(payment.id);
          } else {
            _claimedPayments.remove(payment.id);
          }
        } else {
          _claimedPayments.remove(payment.id);
        }
      }
    } catch (e) {
      // Log errors periodically (every ~30s) to avoid spam but still visible
      if (_pollCount % 20 == 1) {
        broLog('[BRIX-RELAY] Poll error: $e');
      }
    }

    // Retry queued outgoing BRIX payments (async, non-blocking)
    _scheduleRetryIfNeeded();
  }

  /// Schedule retry in a separate async task so it doesn't block the poll loop.
  /// The 25+ second LNURL callback would otherwise block incoming invoice handling.
  void _scheduleRetryIfNeeded() {
    if (_retrying) return;
    final now = DateTime.now();
    if (_lastRetryCheck != null &&
        now.difference(_lastRetryCheck!).inSeconds < _retryIntervalSeconds) {
      return;
    }
    // Fire and forget — don't await
    _retryOutgoingPayments();
  }

  // Track fees already sent to prevent duplicates
  final Set<String> _paidFees = {};
  // Track claims in progress to prevent duplicates
  final Set<String> _claimedPayments = {};

  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );
  static const _brixPaymentsKey = 'brix_received_payments';
  static bool _migrated = false;

  /// One-time migration from SharedPreferences to FlutterSecureStorage
  static Future<void> _migrateIfNeeded() async {
    if (_migrated) return;
    _migrated = true;
    try {
      final existing = await _secureStorage.read(key: _brixPaymentsKey);
      if (existing != null) return; // already migrated
      final prefs = await SharedPreferences.getInstance();
      final old = prefs.getString(_brixPaymentsKey);
      if (old != null && old != '[]') {
        await _secureStorage.write(key: _brixPaymentsKey, value: old);
        await prefs.remove(_brixPaymentsKey);
        broLog('🔒 [BRIX] Migrated payments to secure storage');
      }
    } catch (e) {
      broLog('⚠️ [BRIX] Migration error (non-fatal): $e');
    }
  }

  /// Persist a received BRIX payment locally so it appears in wallet history
  /// even if the Spark SDK doesn't return it in listPayments().
  static Future<void> persistBrixPayment({
    required int amountSats,
    required String description,
    String? paymentHash,
    DateTime? timestamp,
  }) async {
    try {
      await _migrateIfNeeded();
      final raw = await _secureStorage.read(key: _brixPaymentsKey) ?? '[]';
      final List<dynamic> list = json.decode(raw);
      // Dedup by paymentHash
      if (paymentHash != null && list.any((p) => p['paymentHash'] == paymentHash)) return;
      list.add({
        'amountSats': amountSats,
        'description': description,
        'paymentHash': paymentHash,
        'createdAt': (timestamp ?? DateTime.now()).toIso8601String(),
        'type': 'received',
        'direction': 'incoming',
        'status': 'Complete',
        'isBrix': true,
      });
      await _secureStorage.write(key: _brixPaymentsKey, value: json.encode(list));
      broLog('💾 [BRIX] Persisted local: $amountSats sats, hash=${paymentHash?.substring(0, 8) ?? "N/A"}');
    } catch (e) {
      broLog('❌ [BRIX] Failed to persist: $e');
    }
  }

  /// Load locally persisted BRIX payments for wallet screen fallback.
  static Future<List<Map<String, dynamic>>> getLocalBrixPayments() async {
    try {
      await _migrateIfNeeded();
      final raw = await _secureStorage.read(key: _brixPaymentsKey) ?? '[]';
      final List<dynamic> list = json.decode(raw);
      return list.map((p) => Map<String, dynamic>.from(p)).toList();
    } catch (e) {
      broLog('❌ [BRIX] Failed to load local: $e');
      return [];
    }
  }

  /// Send the 0.5% BRIX fee to the platform Lightning address
  Future<void> _sendBrixFee(String requestId, int feeSats) async {
    if (_paidFees.contains(requestId)) return;
    _paidFees.add(requestId);

    if (AppConfig.platformLightningAddress.isEmpty || _context == null) return;

    try {
      final lnService = LnAddressService();
      final result = await lnService.getInvoice(
        lnAddress: AppConfig.platformLightningAddress,
        amountSats: feeSats,
        comment: 'BRIX fee',
      );

      if (result['success'] == true && result['invoice'] != null) {
        final breezProvider = _context!.read<BreezProvider>();
        final payResult = await breezProvider.payInvoice(result['invoice'] as String);
        final success = payResult != null && payResult['success'] == true;
        broLog('⚡ [BRIX-RELAY] Fee ${success ? "paid" : "failed"}: $feeSats sats');
        if (success) {
          // Ocultar a taxa do histórico da carteira — ela já foi deduzida
          // conceitualmente do valor exibido como "BRIX recebido" para o usuário.
          final hash = payResult['payment']?['paymentHash']?.toString();
          if (hash != null && hash.isNotEmpty) {
            await PlatformFeeService.registerFeePaymentHash(hash);
            broLog('🔇 [BRIX-RELAY] Fee hash registrado para ocultar do histórico: ${hash.substring(0, hash.length > 16 ? 16 : hash.length)}');
          }
        } else {
          _paidFees.remove(requestId);
        }
      } else {
        _paidFees.remove(requestId);
      }
    } catch (e) {
      broLog('⚠️ [BRIX-RELAY] Fee payment error: $e');
      _paidFees.remove(requestId);
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  // OUTGOING PAYMENT QUEUE — Retry when recipients come online
  // ═══════════════════════════════════════════════════════════════════

  static const _pendingOutgoingKey = 'brix_pending_outgoing';
  static const _retryIntervalSeconds = 30;
  static const _maxAgeHours = 24;
  DateTime? _lastRetryCheck;
  bool _retrying = false;

  /// Queue an outgoing BRIX payment for retry when recipient comes online.
  /// Called when payInvoice fails (offline recipient or Spark incompatibility).
  Future<void> queueOutgoingPayment({
    required String recipient,
    required int amountSats,
    String? originalDest,
    String? comment,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final list = _loadQueue(prefs);

    // Prevent duplicate entries for same recipient+amount
    final exists = list.any((p) =>
        p['recipient'] == recipient &&
        p['amountSats'] == amountSats &&
        p['status'] == 'pending');
    if (exists) {
      broLog('⏳ [BRIX-QUEUE] Already queued: $amountSats sats → $recipient');
      return;
    }

    list.add({
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'recipient': recipient,
      'originalDest': originalDest ?? recipient,
      'amountSats': amountSats,
      'comment': comment,
      'createdAt': DateTime.now().toIso8601String(),
      'retryCount': 0,
      'lastRetry': null,
      'status': 'pending',
    });

    await _saveQueue(prefs, list);
    broLog('⏳ [BRIX-QUEUE] Queued: $amountSats sats → $recipient');
  }

  /// Get list of pending and expired outgoing payments (for UI display).
  Future<List<Map<String, dynamic>>> getPendingOutgoing() async {
    final prefs = await SharedPreferences.getInstance();
    return _loadQueue(prefs)
        .where((p) => p['status'] == 'pending' || p['status'] == 'expired')
        .toList();
  }

  /// Cancel a queued outgoing payment by id.
  Future<void> cancelOutgoingPayment(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final list = _loadQueue(prefs);
    list.removeWhere((p) => p['id'] == id);
    await _saveQueue(prefs, list);
    broLog('🗑️ [BRIX-QUEUE] Cancelled: $id');
  }

  /// Called from _poll(). Retries pending outgoing BRIX payments.
  Future<void> _retryOutgoingPayments() async {
    if (_retrying || _context == null) return;

    // Rate limit retries
    final now = DateTime.now();
    if (_lastRetryCheck != null &&
        now.difference(_lastRetryCheck!).inSeconds < _retryIntervalSeconds) {
      return;
    }
    _lastRetryCheck = now;

    final prefs = await SharedPreferences.getInstance();
    final list = _loadQueue(prefs);
    if (list.isEmpty) return;

    _retrying = true;
    bool changed = false;

    try {
      final breezProvider = _context!.read<BreezProvider>();
      final lnService = LnAddressService();

      for (final payment in List.of(list)) {
        if (payment['status'] != 'pending') continue;

        // Expire old payments
        final created = DateTime.tryParse(payment['createdAt'] ?? '');
        if (created != null && now.difference(created).inHours > _maxAgeHours) {
          payment['status'] = 'expired';
          changed = true;
          broLog('⏰ [BRIX-QUEUE] Expired: ${payment['recipient']}');
          continue;
        }

        // Rate limit individual payment retries (30s minimum)
        final lastRetry = DateTime.tryParse(payment['lastRetry'] ?? '');
        if (lastRetry != null &&
            now.difference(lastRetry).inSeconds < _retryIntervalSeconds) {
          continue;
        }

        final recipient = payment['recipient'] as String;
        final amountSats = payment['amountSats'] as int;
        final paymentComment = payment['comment'] as String?;

        broLog('🔄 [BRIX-QUEUE] Retrying: $amountSats sats → $recipient (attempt ${payment['retryCount'] + 1})');
        payment['lastRetry'] = now.toIso8601String();
        payment['retryCount'] = (payment['retryCount'] as int) + 1;
        changed = true;

        try {
          // Try LNURL flow again
          final invoiceResult = await lnService.getInvoice(
            lnAddress: recipient,
            amountSats: amountSats,
            comment: paymentComment,
            senderPubkey: _pubkey,
          );

          if (invoiceResult['success'] != true) {
            // Still offline or errored — keep queued
            broLog('⏳ [BRIX-QUEUE] Still offline: $recipient');
            continue;
          }

          final invoice = invoiceResult['invoice'] as String;

          // Try to pay
          final payResult = await breezProvider.payInvoice(invoice);

          if (payResult != null && payResult['success'] == true) {
            payment['status'] = 'completed';
            changed = true;
            broLog('✅ [BRIX-QUEUE] Payment completed: $amountSats sats → $recipient');
            // Notify listeners
            onQueuedPaymentCompleted?.call(recipient, amountSats);
          } else {
            // Payment failed (e.g., still LNbits invoice) — keep queued
            broLog('⏳ [BRIX-QUEUE] Pay failed, keeping queued: $recipient');
          }
        } catch (e) {
          broLog('⚠️ [BRIX-QUEUE] Retry error: $e');
        }
      }

      if (changed) {
        // Remove only completed entries; keep expired for user visibility
        list.removeWhere((p) => p['status'] == 'completed');
        await _saveQueue(prefs, list);
      }
    } catch (e) {
      broLog('⚠️ [BRIX-QUEUE] Retry cycle error: $e');
    } finally {
      _retrying = false;
    }
  }

  List<Map<String, dynamic>> _loadQueue(SharedPreferences prefs) {
    final raw = prefs.getString(_pendingOutgoingKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      return (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveQueue(SharedPreferences prefs, List<Map<String, dynamic>> list) async {
    await prefs.setString(_pendingOutgoingKey, jsonEncode(list));
  }
}
