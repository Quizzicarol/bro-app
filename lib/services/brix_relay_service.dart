import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:bro_app/services/brix_service.dart';
import 'package:bro_app/services/storage_service.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:bro_app/services/lnaddress_service.dart';
import 'package:bro_app/providers/breez_provider.dart';
import 'package:bro_app/config.dart';

/// Global BRIX invoice relay service.
/// Polls the BRIX server for incoming invoice requests and auto-generates
/// invoices via the user's Breez wallet. Runs whenever the app is in foreground.
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

  /// Start the relay service. Call from main app after login.
  void start(BuildContext context) {
    if (_running) return;
    _context = context;
    _running = true;
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
    _poll(); // immediate first check
    broLog('[BRIX-RELAY] Service started');
  }

  /// Stop the relay service.
  void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _running = false;
    _context = null;
    broLog('[BRIX-RELAY] Service stopped');
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
    } catch (e) {
      // Silent — don't spam logs on connection errors
    }
  }

  // Track fees already sent to prevent duplicates
  final Set<String> _paidFees = {};

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
}
