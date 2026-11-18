/// v820a: fetchProofFromRelay aceita prova PLAINTEXT.
///
/// Caso real 27c916e7 (17/11): ordem API-sourced chegou ao provedor com
/// userPubkey '' → o NIP-44 falhou → o complete saiu com proofImage em
/// plaintext (59KB). O fetch de último recurso (v696) exigia
/// proofImage_nip44 e descartava o evento → a tela nunca mostrou a prova e
/// o usuário abriu disputa sem necessidade ("botão indisponível").
///
/// Este teste serve o evento no formato EXATO de produção (#p vazio,
/// proofImage plaintext, sem proofImage_nip44) e exige que o fetch a retorne.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nostr/nostr.dart' show Event, Keychain;
import 'package:bro_app/services/nostr_order_service.dart';

class _MiniRelay {
  HttpServer? _server;
  String get url => 'ws://127.0.0.1:${_server!.port}';
  final List<Map<String, dynamic>> events;
  _MiniRelay(this.events);

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server!.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen((raw) {
        final msg = jsonDecode(raw as String);
        if (msg[0] == 'REQ') {
          final subId = msg[1] as String;
          final sent = <String>{};
          for (var i = 2; i < msg.length; i++) {
            final filter = msg[i] as Map<String, dynamic>;
            final dTags = (filter['#d'] as List?)?.cast<String>() ?? const [];
            final orderIdTags =
                (filter['#orderId'] as List?)?.cast<String>() ?? const [];
            final kinds = (filter['kinds'] as List?)?.cast<int>() ?? const [];
            for (final e in events) {
              if (kinds.isNotEmpty && !kinds.contains(e['kind'])) continue;
              final eDTags = (e['tags'] as List)
                  .where((t) => t is List && t.isNotEmpty && t[0] == 'd')
                  .map((t) => t[1].toString())
                  .toSet();
              final eOrderTags = (e['tags'] as List)
                  .where((t) => t is List && t.isNotEmpty && t[0] == 'orderId')
                  .map((t) => t[1].toString())
                  .toSet();
              if (dTags.isNotEmpty && !eDTags.any(dTags.contains)) continue;
              if (orderIdTags.isNotEmpty &&
                  !eOrderTags.any(orderIdTags.contains)) {
                continue;
              }
              if (sent.add(e['id'] as String)) {
                ws.add(jsonEncode(['EVENT', subId, e]));
              }
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

  test('v820a: complete com proofImage PLAINTEXT (sem nip44) é retornado', () async {
    const orderId = '27c916e7-0000-4000-8000-000000000001';
    final providerKeys = Keychain.generate();
    const fakeImage = 'aW1hZ2VtX2Zha2VfZW1fYmFzZTY0X3BsYWludGV4dA==';

    final ev = Event.from(
      kind: 30081,
      tags: [
        ['d', '${orderId}_complete'],
        ['p', ''], // #p VAZIO — ordem API-sourced, formato real de produção
        ['t', 'bro-order'],
        ['t', 'bro-complete'],
        ['orderId', orderId],
      ],
      content: jsonEncode({
        'type': 'bro_complete',
        'orderId': orderId,
        'orderEventId': null,
        'providerId': providerKeys.public,
        'userPubkey': '',
        'recipientPubkey': '',
        'completedAt': DateTime.now().toIso8601String(),
        'proofImage': fakeImage, // PLAINTEXT — o fallback de criptografia
        'providerInvoice': 'lnbc100n1fake',
      }),
      privkey: providerKeys.private,
    );

    final relay = _MiniRelay([ev.toJson()]);
    await relay.start();
    addTearDown(relay.stop);
    NostrOrderService.relaysOverride = [relay.url];
    NostrOrderService.applyRelaysOverride();

    final res = await NostrOrderService().fetchProofFromRelay(orderId);

    expect(res, isNotNull,
        reason: 'prova plaintext TEM que ser encontrada (era descartada no filtro nip44-only)');
    expect(res!['proofImage_plain'], fakeImage);
    expect(res['senderPubkey'], providerKeys.public);
    expect(res['providerInvoice'], 'lnbc100n1fake');
    expect(res.containsKey('proofImage_nip44'), isFalse);
  });

  test('v820a: marcador [encrypted:] sozinho NÃO é prova (segue invisível)', () async {
    const orderId = '27c916e7-0000-4000-8000-000000000002';
    final providerKeys = Keychain.generate();

    final ev = Event.from(
      kind: 30081,
      tags: [
        ['d', '${orderId}_complete'],
        ['t', 'bro-order'],
        ['orderId', orderId],
      ],
      content: jsonEncode({
        'type': 'bro_complete',
        'orderId': orderId,
        'providerId': providerKeys.public,
        'proofImage': '[encrypted:nip44v2]', // marcador sem payload = sem prova
      }),
      privkey: providerKeys.private,
    );

    final relay = _MiniRelay([ev.toJson()]);
    await relay.start();
    addTearDown(relay.stop);
    NostrOrderService.relaysOverride = [relay.url];
    NostrOrderService.applyRelaysOverride();

    final res = await NostrOrderService().fetchProofFromRelay(orderId);
    expect(res, isNull,
        reason: 'marcador sem payload não pode ser tratado como prova');
  });
}
