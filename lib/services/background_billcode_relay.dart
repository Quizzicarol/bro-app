/// v574: Background billCode NIP-44 relay.
///
/// Top-level helper invoked by `_firebaseMessagingBackgroundHandler` when a
/// silent push of subtype 'accept_relay' arrives. Wakes the buyer's device
/// (even if app killed), reads the order's billCode from local storage,
/// encrypts it for the accepter's pubkey via NIP-44, and publishes kind
/// 30080. Provider sees the encrypted billCode without the buyer ever
/// having to open the app.
///
/// Design constraints:
/// - MUST be a top-level function (Flutter background isolate requirement)
/// - MUST be idempotent (FCM may deliver the same push multiple times,
///   server may re-push if it doesn't observe the kind 30080 follow-up)
/// - MUST be non-fatal: any failure is logged and recovered later by the
///   foreground sync (`_sendEncryptedBillCodeForAcceptedOrders`)
/// - MUST complete within ~25s on iOS (background time limit)
/// - MUST NOT depend on OrderProvider (lives in main isolate only)
///
/// Backward compat: plaintext billCode in kind 30078 remains the canonical
/// source for old providers. This handler is privacy-extra, not load-bearing.
library;

import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'log_utils.dart';
import 'nostr_order_service.dart';
import 'orders_storage.dart';
import 'storage_service.dart';

/// Returns true on success (event was accepted by at least 1 relay), false
/// on any failure (skipped, dedup hit, parse error, publish failure).
@pragma('vm:entry-point')
Future<bool> handleAcceptRelayInBackground(Map<String, dynamic> data) async {
  final orderId = data['order_id']?.toString();
  // Prefer 'accepter_pubkey' explicit field; fall back to 'sender_pubkey'
  // (watchtower fills both with the same value, but explicit is safer).
  final accepterPubkey = (data['accepter_pubkey']?.toString() ??
          data['sender_pubkey']?.toString() ??
          '')
      .toLowerCase();

  if (orderId == null || orderId.isEmpty) {
    broLog('[BG-Relay] missing order_id, skipping');
    return false;
  }
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(accepterPubkey)) {
    broLog('[BG-Relay] invalid accepter_pubkey, skipping');
    return false;
  }

  // Load identity
  final storage = StorageService();
  await storage.init();
  final myPubkey = (await storage.getNostrPublicKey())?.toLowerCase();
  final privKey = await storage.getNostrPrivateKey();
  if (myPubkey == null || myPubkey.isEmpty || privKey == null || privKey.isEmpty) {
    broLog('[BG-Relay] no identity in storage, skipping');
    return false;
  }

  // Sanity: never encrypt a billCode for ourselves
  if (accepterPubkey == myPubkey) {
    broLog('[BG-Relay] accepter is self, skipping');
    return false;
  }

  // Idempotency: per (orderId, accepterPubkey). If we already published the
  // NIP-44 follow-up for this pair, skip immediately. The accepter pubkey is
  // included so that if the legitimate winner changes (race), we re-publish
  // for the correct provider exactly once.
  final prefs = await SharedPreferences.getInstance();
  final dedupKey =
      'billcode_relayed_${orderId}_${accepterPubkey.substring(0, 16)}';
  if (prefs.getBool(dedupKey) == true) {
    broLog('[BG-Relay] order=${orderId.substring(0, 8)} accepter=${accepterPubkey.substring(0, 8)} already relayed, skipping');
    return false;
  }

  // Load my orders from disk. OrderProvider persists under 'orders_<pubkey>'.
  // v578: read via OrdersStorage (transparently decrypts).
  final ordersJson = await OrdersStorage.read(prefs, myPubkey);
  if (ordersJson == null || ordersJson.isEmpty) {
    broLog('[BG-Relay] no local orders for pubkey, skipping');
    return false;
  }

  Map<String, dynamic>? orderJson;
  try {
    final decoded = jsonDecode(ordersJson);
    if (decoded is List) {
      for (final item in decoded) {
        if (item is Map && item['id']?.toString() == orderId) {
          orderJson = Map<String, dynamic>.from(item);
          break;
        }
      }
    }
  } catch (e) {
    broLog('[BG-Relay] failed to parse orders JSON: $e');
    return false;
  }

  if (orderJson == null) {
    broLog('[BG-Relay] order ${orderId.substring(0, 8)} not found locally — was it created on another device?');
    return false;
  }

  // Defense-in-depth: confirm we are actually the order creator. Otherwise
  // a hostile push with someone else's orderId could trick us into nothing
  // (we'd have no billCode anyway), but this makes the intent explicit.
  final orderUserPubkey =
      (orderJson['userPubkey']?.toString() ?? '').toLowerCase();
  if (orderUserPubkey.isNotEmpty && orderUserPubkey != myPubkey) {
    broLog('[BG-Relay] order ${orderId.substring(0, 8)} not owned by me, skipping');
    return false;
  }

  final billCode = orderJson['billCode']?.toString() ?? '';
  if (billCode.isEmpty) {
    broLog('[BG-Relay] order ${orderId.substring(0, 8)} has empty billCode, nothing to relay');
    return false;
  }

  // vSEC: confirm the accepter is a REAL acceptor of this order before we
  // hand over the NIP-44-encrypted billCode. Previously we trusted the
  // accepter_pubkey from the FCM payload blindly — combined with the open
  // /push/notify endpoint, an attacker could push accept_relay with their own
  // pubkey and receive the victim's billCode (PIX/boleto PII).
  //
  // We verify against the actual kind 30079 accept events on the relays.
  // Fail-CLOSED on mismatch (attacker), fail-OPEN only when we genuinely
  // cannot determine the acceptor (relay timeout) — in that case the
  // plaintext billCode in kind 30078 remains the backward-compat source and
  // the foreground sync re-tries, so availability is preserved.
  try {
    final svc = NostrOrderService();
    final accepts = await svc
        .fetchAllAcceptsForOrder(orderId)
        .timeout(const Duration(seconds: 10));
    if (accepts.isNotEmpty && !accepts.contains(accepterPubkey)) {
      // We have authoritative accept data and this pubkey is NOT an acceptor.
      broLog('[BG-Relay] 🚫 accepter ${accepterPubkey.substring(0, 8)} is NOT a real acceptor of order ${orderId.substring(0, 8)} — REFUSING to relay billCode');
      return false;
    }
    // accepts.isEmpty → relays unreachable / no accept found yet → proceed
    // (fail-open for availability; the push came from the watchtower which
    // only sends accept_relay after observing a real bro_accept).
  } catch (e) {
    // Verification error (network/timeout) → fail-open, foreground retries.
    broLog('[BG-Relay] ⚠️ acceptor verification failed ($e) — proceeding (fail-open)');
  }

  // Publish kind 30080 NIP-44-encrypted billCode for the accepter.
  // NostrOrderService is a singleton; in a background isolate it's a fresh
  // instance with default _relays, which is exactly what we want.
  try {
    final svc = NostrOrderService();
    final ok = await svc
        .publishEncryptedBillCode(
          privateKey: privKey,
          orderId: orderId,
          billCode: billCode,
          providerPubkey: accepterPubkey,
          orderUserPubkey: myPubkey,
        )
        .timeout(const Duration(seconds: 20));

    if (ok) {
      await prefs.setBool(dedupKey, true);
      broLog('[BG-Relay] ✅ NIP-44 billCode published: order=${orderId.substring(0, 8)} → provider=${accepterPubkey.substring(0, 8)}');
      return true;
    }
    broLog('[BG-Relay] ⚠️ publish returned false for ${orderId.substring(0, 8)} — foreground sync will retry');
    return false;
  } on TimeoutException {
    broLog('[BG-Relay] ⏱️ timed out publishing ${orderId.substring(0, 8)} — foreground sync will retry');
    return false;
  } catch (e) {
    broLog('[BG-Relay] ❌ exception: $e');
    return false;
  }
}
