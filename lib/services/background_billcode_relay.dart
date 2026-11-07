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

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../config.dart';
import 'log_utils.dart';
import 'nip98_signer.dart';
import 'nostr_order_service.dart';
import 'orders_storage.dart';
import 'storage_service.dart';

/// v688: canal redundante — o backend avisa via FCM silencioso que o billCode
/// chegou por ELE (caminho usado quando os relays falham no aparelho do
/// comprador). Baixamos o blob NIP-44, descriptografamos com a chave local e
/// gravamos no metadata da ordem — mesmo destino do caminho via relay.
@pragma('vm:entry-point')
Future<bool> handleBillcodeFallbackInBackground(Map<String, dynamic> data) async {
  final orderId = data['order_id']?.toString();
  if (orderId == null || orderId.isEmpty) return false;
  try {
    final storage = StorageService();
    await storage.init();
    final myPubkey = (await storage.getNostrPublicKey())?.toLowerCase();
    final privKey = await storage.getNostrPrivateKey();
    if (myPubkey == null || myPubkey.isEmpty || privKey == null || privKey.isEmpty) {
      return false;
    }

    final dio = Dio(BaseOptions(
      baseUrl: AppConfig.defaultBackendUrl,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
    ));
    // v747 (B3): assina NIP-98 também no background isolate
    final headers = await nip98Headers(
      url: '${AppConfig.defaultBackendUrl}/billcode-fallback/$orderId',
      method: 'GET',
    );
    final resp = await dio.get('/billcode-fallback/$orderId', options: Options(headers: headers));
    if (resp.statusCode != 200 || resp.data?['ok'] != true) return false;
    // Só processa se o blob é destinado a MIM
    final forProvider = (resp.data['providerPubkey'] as String? ?? '').toLowerCase();
    if (forProvider != myPubkey) return false;
    final blob = resp.data['blob'] as String;
    final senderPubkey = resp.data['senderPubkey'] as String;

    String plain = '';
    try {
      plain = NostrOrderService().decryptNip44(blob, privKey, senderPubkey);
    } catch (e) {
      broLog('[BG-Fallback] decrypt falhou: $e');
    }

    final prefs = await SharedPreferences.getInstance();
    final ordersJson = await OrdersStorage.read(prefs, myPubkey);
    if (ordersJson == null || ordersJson.isEmpty) return false;
    final decoded = jsonDecode(ordersJson);
    if (decoded is! List) return false;
    bool found = false;
    for (final item in decoded) {
      if (item is Map && item['id']?.toString() == orderId) {
        final meta = Map<String, dynamic>.from(item['metadata'] ?? {});
        meta['billCode_nip44'] = blob;
        if (plain.isNotEmpty) meta['billCode'] = plain;
        item['metadata'] = meta;
        found = true;
        break;
      }
    }
    if (!found) return false;
    await OrdersStorage.write(prefs, myPubkey, jsonEncode(decoded));
    broLog('[BG-Fallback] ✅ billCode via backend gravado p/ ${orderId.substring(0, 8)}');
    return true;
  } catch (e) {
    broLog('[BG-Fallback] erro: $e');
    return false;
  }
}

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

  // v725: NUNCA publicar sem provar que o accepter É o canônico. Este handler
  // publicava-pra-verificar-depois (otimização de latência da v574) e o
  // watchtower empurra o PRIMEIRO accept que ELE viu (ordem de chegada, não
  // acceptedAt) — resultado: o código ia pro PERDEDOR da corrida, que pagava
  // de verdade (caso 43b789c7, 06/11 — o tripwire v702 disparou e alertou a
  // admin: sent_to=4b72ee02, canonical=0b31181f). Se o accepter não for o
  // canônico (ou os relays estiverem parciais), NÃO publicamos: o caminho de
  // foreground (quórum v712 no OrderProvider) entrega no próximo sync.
  try {
    final svcCheck = NostrOrderService();
    final accepts = await svcCheck.fetchAllAcceptsForOrder(orderId)
        .timeout(const Duration(seconds: 10), onTimeout: () => <String>[]);
    if (accepts.isEmpty) {
      broLog('[BG-Relay] v725: aceites não verificáveis — NÃO publicando (foreground entrega via quórum)');
      return false;
    }
    if (svcCheck.lastAcceptsRelayCoverage < 2) {
      broLog('[BG-Relay] v725: cobertura < 2 relays — NÃO publicando agora');
      return false;
    }
    if (accepts.first.toLowerCase() != accepterPubkey) {
      broLog('[BG-Relay] v725: accepter ${accepterPubkey.substring(0, 8)} NÃO é o canônico (${accepts.first.substring(0, 8)}) — perdedor de corrida NÃO recebe o código');
      return false;
    }
    broLog('[BG-Relay] v725: accepter É o canônico (${accepts.first.substring(0, 8)}, ${svcCheck.lastAcceptsRelayCoverage} relays) — publicando');
  } catch (e) {
    broLog('[BG-Relay] v725: verificação falhou — não publicando: $e');
    return false;
  }

  // vSEC: confirmação do accepter. IMPORTANTE (latência): PUBLICAMOS PRIMEIRO
  // e verificamos DEPOIS. Antes eu verificava ANTES (fetchAllAcceptsForOrder),
  // mas NostrOrderService é SINGLETON — a verify-query abria WebSockets nos
  // mesmos relays e competia/atrapalhava o publish seguinte, E adicionava
  // até ~24s sequenciais no caminho crítico (provider esperando o PIX).
  //
  // Por que publicar-primeiro é seguro aqui:
  //   1. Este handler SÓ roda quando o watchtower (servidor) observou um
  //      bro_accept REAL e enviou accept_relay — a fonte já é autenticada.
  //   2. O /push/notify (único caminho p/ um atacante forjar accept_relay)
  //      agora exige que o sender seja PARTE da ordem (Fix #1).
  //   3. O publish NIP-44 só é legível pelo accepter — mesmo se por algum
  //      deslize fosse para o pubkey errado, só ELE decifra, e ele já é um
  //      aceitante válido (o watchtower só dispara após ver o accept).
  // A verificação pós-publish vira AUDITORIA (log) — não bloqueia a entrega.
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
      // Auditoria pós-publish (não-bloqueante, conexões já quentes = rápido):
      // se o accepter NÃO for um aceitante real, apenas LOGAMOS (o dano já foi
      // contido pelas camadas acima; reverter o publish não é possível nem
      // necessário — só o aceitante decifra).
      svc.fetchAllAcceptsForOrder(orderId).then((accepts) {
        if (accepts.isNotEmpty && !accepts.contains(accepterPubkey)) {
          broLog('[BG-Relay] 🚨 AUDIT: billCode publicado p/ ${accepterPubkey.substring(0, 8)} que NÃO consta como aceitante de ${orderId.substring(0, 8)} (investigar)');
        }
      }).catchError((_) {});
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
