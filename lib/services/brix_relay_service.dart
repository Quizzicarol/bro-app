import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:bro_app/services/brix_service.dart';
import 'package:bro_app/services/storage_service.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:bro_app/services/lnaddress_service.dart';
import 'package:bro_app/providers/breez_provider.dart';
import 'package:bro_app/config.dart';

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
  BuildContext? _context;
  bool _fcmRegistered = false;

  /// Callback for when a queued outgoing payment is completed.
  void Function(String recipient, int amountSats)? onQueuedPaymentCompleted;

  /// Ensure FCM token is registered with BRIX server (idempotent).
  Future<void> _ensureFcmRegistered() async {
    if (_fcmRegistered) return;
    try {
      _pubkey ??= await _storage.getNostrPublicKey();
      if (_pubkey == null || _pubkey!.isEmpty) return;
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;
      final ok = await _brixService.registerPushToken(token, _pubkey!);
      if (ok) {
        _fcmRegistered = true;
        broLog('[BRIX-RELAY] FCM token registered successfully');
      }
    } catch (e) {
      // Will retry next start/restart
    }
  }

  /// Start the relay service. Call from main app after login.
  void start(BuildContext context) {
    _context = context;
    if (_running) return;
    _running = true;
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
    _poll(); // immediate first check
    _ensureFcmRegistered();
    broLog('[BRIX-RELAY] Service started');
  }

  /// Restart the relay (e.g. after app resumes from background).
  void restart(BuildContext context) {
    _context = context;
    _pollTimer?.cancel();
    _running = true;
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
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

  Future<void> _poll() async {
    if (!_running || _context == null) return;

    try {
      // Get pubkey lazily
      _pubkey ??= await _storage.getNostrPublicKey();
      if (_pubkey == null || _pubkey!.isEmpty) return;

      // Check if user has active BRIX
      final requests = await _brixService.getInvoiceRequests(_pubkey!);
      if (requests.isEmpty) return;

      final breezProvider = _context!.read<BreezProvider>();

      for (final request in requests) {
        broLog('⚡ [BRIX-RELAY] Generating invoice: ${request.amountSats} sats');

        // Generate invoice for FULL amount (LNURL wallets verify amount match)
        final invoiceResult = await breezProvider.createInvoice(
          amountSats: request.amountSats,
          description: 'BRIX Payment',
        );

        if (invoiceResult != null && invoiceResult['success'] == true) {
          final bolt11 = invoiceResult['bolt11'] as String? ??
              invoiceResult['invoice'] as String?;
          if (bolt11 != null) {
            final ok = await _brixService.submitInvoice(
                request.id, bolt11, _pubkey!);
            broLog(
                '⚡ [BRIX-RELAY] Invoice ${ok ? "submitted" : "failed"} for ${request.amountSats} sats');

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

        final invoiceResult = await breezProvider.createInvoice(
          amountSats: payment.amountSats,
          description: 'BRIX Payment (offline)',
        );

        if (invoiceResult != null && invoiceResult['success'] == true) {
          final bolt11 = invoiceResult['bolt11'] as String? ??
              invoiceResult['invoice'] as String?;
          if (bolt11 != null) {
            final claimed = await _brixService.claimPayment(
                payment.id, bolt11, _pubkey!);
            broLog(
                '💰 [BRIX-RELAY] Claim ${claimed ? "success" : "failed"} for ${payment.amountSats} sats');
            if (!claimed) _claimedPayments.remove(payment.id);
          } else {
            _claimedPayments.remove(payment.id);
          }
        } else {
          _claimedPayments.remove(payment.id);
        }
      }
    } catch (e) {
      // Silent — don't spam logs on connection errors
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
        if (!success) _paidFees.remove(requestId);
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
      'createdAt': DateTime.now().toIso8601String(),
      'retryCount': 0,
      'lastRetry': null,
      'status': 'pending',
    });

    await _saveQueue(prefs, list);
    broLog('⏳ [BRIX-QUEUE] Queued: $amountSats sats → $recipient');
  }

  /// Get list of pending outgoing payments (for UI display).
  Future<List<Map<String, dynamic>>> getPendingOutgoing() async {
    final prefs = await SharedPreferences.getInstance();
    return _loadQueue(prefs)
        .where((p) => p['status'] == 'pending')
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

        broLog('🔄 [BRIX-QUEUE] Retrying: $amountSats sats → $recipient (attempt ${payment['retryCount'] + 1})');
        payment['lastRetry'] = now.toIso8601String();
        payment['retryCount'] = (payment['retryCount'] as int) + 1;
        changed = true;

        try {
          // Try LNURL flow again
          final invoiceResult = await lnService.getInvoice(
            lnAddress: recipient,
            amountSats: amountSats,
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
        // Remove completed/expired entries
        list.removeWhere((p) => p['status'] != 'pending');
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
