/// v820b: completar ordem API-sourced (userPubkey '') resolve o dono no 30078
/// ANTES de criptografar — a prova sai cifrada (proofImage_nip44) e o evento
/// sai endereçado (#p = usuário), em vez de plaintext público.
///
/// Caso real 27c916e7 / 98bc3e84 (17/11): provas de 56-60KB em plaintext em
/// relay público + invisíveis pra builds antigos.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nostr/nostr.dart' show Event, Keychain;
import 'package:bro_app/models/order.dart';
import 'package:bro_app/services/nostr_order_service.dart';

class _CapturingRelay {
  HttpServer? _server;
  String get url => 'ws://127.0.0.1:${_server!.port}';
  final List<Map<String, dynamic>> served;
  final List<Map<String, dynamic>> published = [];
  _CapturingRelay(this.served);

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server!.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen((raw) {
        final msg = jsonDecode(raw as String);
        if (msg[0] == 'EVENT') {
          final ev = msg[1] as Map<String, dynamic>;
          published.add(ev);
          ws.add(jsonEncode(['OK', ev['id'], true, '']));
        } else if (msg[0] == 'REQ') {
          final subId = msg[1] as String;
          for (var i = 2; i < msg.length; i++) {
            final filter = msg[i] as Map<String, dynamic>;
            final dTags = (filter['#d'] as List?)?.cast<String>() ?? const [];
            final kinds = (filter['kinds'] as List?)?.cast<int>() ?? const [];
            for (final e in served) {
              if (kinds.isNotEmpty && !kinds.contains(e['kind'])) continue;
              if (dTags.isNotEmpty) {
                final eDTags = (e['tags'] as List)
                    .where((t) => t is List && t.isNotEmpty && t[0] == 'd')
                    .map((t) => t[1].toString())
                    .toSet();
                if (!eDTags.any(dTags.contains)) continue;
              }
              ws.add(jsonEncode(['EVENT', subId, e]));
            }
          }
          ws.add(jsonEncode(['EOSE', subId]));
        }
      });
    });
  }

  Future<void> stop() async => _server?.close(force: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    NostrOrderService.relaysOverride = null;
    NostrOrderService.applyRelaysOverride();
  });

  test('v820b: complete de ordem API-sourced sai cifrado e endereçado', () async {
    const orderId = 'v820b-0000-4000-8000-000000000001';
    final userKeys = Keychain.generate();
    final providerKeys = Keychain.generate();

    // O 30078 original no relay TEM o dono no content.
    final orderEvent = Event.from(
      kind: 30078,
      tags: [
        ['d', orderId],
        ['t', 'bro-order'],
      ],
      content: jsonEncode({
        'type': 'bro_order',
        'orderId': orderId,
        'userPubkey': userKeys.public,
        'billType': 'pix',
        'amount': 100.0,
        'status': 'accepted',
        'createdAt': DateTime.now().toIso8601String(),
      }),
      privkey: userKeys.private,
    );

    final relay = _CapturingRelay([orderEvent.toJson()]);
    await relay.start();
    addTearDown(relay.stop);
    NostrOrderService.relaysOverride = [relay.url];
    NostrOrderService.applyRelaysOverride();

    // A cópia local do provedor veio do snapshot API: userPubkey '' e sem eventId.
    final order = Order(
      id: orderId,
      userPubkey: '',
      billType: 'pix',
      billCode: 'CODE',
      amount: 100.0,
      btcAmount: 0.0001,
      btcPrice: 500000.0,
      providerFee: 3.0,
      platformFee: 2.0,
      total: 105.0,
      status: 'accepted',
      createdAt: DateTime.now(),
      providerId: providerKeys.public,
    );

    final ok = await NostrOrderService().completeOrderOnNostr(
      order: order,
      providerPrivateKey: providerKeys.private,
      proofImageBase64: 'aW1hZ2Vt',
      providerInvoice: 'lnbc100n1fake',
    );
    expect(ok, isTrue);

    final completes = relay.published.where((e) => e['kind'] == 30081).toList();
    expect(completes, isNotEmpty, reason: 'o complete tem que ter sido publicado');
    final c = jsonDecode(completes.first['content'] as String) as Map<String, dynamic>;

    expect(c['proofImage_nip44'], isNotNull,
        reason: 'com userPubkey resolvido, a prova sai CIFRADA');
    expect(c['proofImage'], '[encrypted:nip44v2]',
        reason: 'plaintext não pode vazar no relay público');
    expect(c['userPubkey'], userKeys.public);
    expect(c['recipientPubkey'], userKeys.public);
    final pTag = (completes.first['tags'] as List)
        .firstWhere((t) => t is List && t[0] == 'p');
    expect(pTag[1], userKeys.public,
        reason: '#p endereçado = visível até pra builds sem o fetch #d');
  });

  test('v820b: sem 30078 no relay, cai no fallback atual (fail-open)', () async {
    const orderId = 'v820b-0000-4000-8000-000000000002';
    final providerKeys = Keychain.generate();

    final relay = _CapturingRelay([]); // relay não conhece a ordem
    await relay.start();
    addTearDown(relay.stop);
    NostrOrderService.relaysOverride = [relay.url];
    NostrOrderService.applyRelaysOverride();

    final order = Order(
      id: orderId,
      userPubkey: '',
      billType: 'pix',
      billCode: 'CODE',
      amount: 100.0,
      btcAmount: 0.0001,
      btcPrice: 500000.0,
      providerFee: 3.0,
      platformFee: 2.0,
      total: 105.0,
      status: 'accepted',
      createdAt: DateTime.now(),
      providerId: providerKeys.public,
    );

    final ok = await NostrOrderService().completeOrderOnNostr(
      order: order,
      providerPrivateKey: providerKeys.private,
      proofImageBase64: 'aW1hZ2Vt',
    );
    expect(ok, isTrue, reason: 'nunca bloquear o complete por causa de relay');

    final completes = relay.published.where((e) => e['kind'] == 30081).toList();
    expect(completes, isNotEmpty);
    final c = jsonDecode(completes.first['content'] as String) as Map<String, dynamic>;
    expect(c['proofImage'], 'aW1hZ2Vt',
        reason: 'fallback plaintext preservado quando não há como cifrar');
  });
}
