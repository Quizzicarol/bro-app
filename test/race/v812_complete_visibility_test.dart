/// v812: complete (30081) com #p VAZIO continua visível pra usuária.
///
/// Incidente ac6ae697/cdbd6089 (16/11): a ordem do provedor veio do snapshot
/// API (R5b) com userPubkey '' → o complete saiu com #p vazio → o fetch da
/// usuária (#p=ela) nunca via o evento → "travada em Bro encontrado" /
/// "concluída sem comprovante". O fix busca completes por #d={id}_complete.
///
/// Serve um relay WebSocket mínimo que responde #d e prova o caminho.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nostr/nostr.dart' show Event, Keychain;
import 'package:bro_app/services/log_utils.dart';
import 'package:bro_app/services/nostr_order_service.dart';

class _MiniRelay {
  HttpServer? _server;
  String get url => 'ws://127.0.0.1:${_server!.port}';
  final List<Map<String, dynamic>> events;

  _MiniRelay(this.events);

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server!.listen((req) async {
      if (req.uri.path == '/__health') {
        req.response..statusCode = 200..write('ok');
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen((raw) {
        final msg = jsonDecode(raw as String);
        if (msg[0] == 'REQ') {
          final subId = msg[1] as String;
          final sent = <String>{};
          for (var i = 2; i < msg.length; i++) {
            final filter = msg[i] as Map<String, dynamic>;
            final dTags = (filter['#d'] as List?)?.cast<String>() ?? const [];
            final kinds = (filter['kinds'] as List?)?.cast<int>() ?? const [];
            for (final e in events) {
              final eKind = e['kind'] as int;
              if (kinds.isNotEmpty && !kinds.contains(eKind)) continue;
              if (dTags.isNotEmpty) {
                final eDTags = (e['tags'] as List)
                    .where((t) => t is List && t.isNotEmpty && t[0] == 'd')
                    .map((t) => t[1].toString())
                    .toSet();
                if (!eDTags.any(dTags.contains)) continue;
              }
              if (sent.add(e['id'] as String)) {
                ws.add(jsonEncode(['EVENT', subId, e]));
              }
            }
          }
          ws.add(jsonEncode(['EOSE', subId]));
        } else if (msg[0] == 'CLOSE') {
          // ok
        }
      });
    });
  }

  Future<void> stop() async => _server?.close(force: true);
}

Map<String, dynamic> _completeEvent(
  String orderId,
  Keychain providerKeys, {
  int? createdAt,
}) {
  // v803 valida assinatura (verify:true) — o evento precisa ser assinado DE
  // VERDADE, senão é rejeitado no caminho (como em produção).
  final ev = Event.from(
    kind: 30081,
    tags: [
      ['d', '${orderId}_complete'],
      ['p', ''], // #p VAZIO — o bug em pessoa. Só #d indexável existe.
      ['t', 'bro-order'],
      ['t', 'bro-complete'],
    ],
    content: jsonEncode({
      'type': 'bro_complete',
      'orderId': orderId,
      'providerId': providerKeys.public,
      'status': 'awaiting_confirmation',
      'proofImage': 'raw_base64_da_prova',
      'providerInvoice': 'lnbc100n1fake',
      'completedAt': DateTime.now().toIso8601String(),
    }),
    privkey: providerKeys.private,
    createdAt: createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
  );
  return ev.toJson();
}

Map<String, dynamic> _statusEvent(
  String orderId,
  Keychain keys,
  String status,
  int createdAt,
  String providerId,
) =>
    Event.from(
      kind: 30080,
      tags: [
        ['r', orderId],
        ['p', providerId],
      ],
      content: jsonEncode({
        'type': 'bro_order_update',
        'orderId': orderId,
        'providerId': providerId,
        'status': status,
      }),
      privkey: keys.private,
      createdAt: createdAt,
    ).toJson();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    NostrOrderService.relaysOverride = null;
    NostrOrderService.applyRelaysOverride();
  });

  test('v812: complete com #p vazio é encontrado via #d (prova não some)', () async {
    const orderId = 'v812-order-1';
    final providerKeys = Keychain.generate();
    final relay = _MiniRelay([_completeEvent(orderId, providerKeys)]);
    await relay.start();
    NostrOrderService.relaysOverride = [relay.url];
    NostrOrderService.applyRelaysOverride();

    final sw = Stopwatch()..start();
    final updates = await NostrOrderService().fetchOrderUpdatesForUser(
      'user812',
      orderIds: const [orderId],
    );
    sw.stop();

    expect(updates.containsKey(orderId), isTrue,
        reason: 'complete com #p vazio TEM que aparecer via #d (era invisível no bug)');
    final u = updates[orderId]!;
    expect(u['proofImage'], 'raw_base64_da_prova');
    expect(u['providerInvoice'], 'lnbc100n1fake');
    broLog('⏱️ v812: complete sem #p encontrado via #d em ${sw.elapsedMilliseconds}ms');

    await relay.stop();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('R3 4e2c858a: accept_expired posterior não descarta complete canônico', () async {
    const orderId = '4e2c858a';
    const expiredAt = 1763749572;
    const completeAt = 1763749588;
    final providerKeys = Keychain.generate();
    final buyerKeys = Keychain.generate();
    final relay = _MiniRelay([
      _statusEvent(orderId, buyerKeys, 'accept_expired', expiredAt, providerKeys.public),
      _completeEvent(orderId, providerKeys, createdAt: completeAt),
    ]);
    await relay.start();
    NostrOrderService.relaysOverride = [relay.url];
    NostrOrderService.applyRelaysOverride();

    final updates = await NostrOrderService().fetchOrderUpdatesForUser(
      buyerKeys.public,
      orderIds: const [orderId],
    );
    final update = updates[orderId]!;
    expect(update['status'], 'awaiting_confirmation');
    expect(update['providerId'], providerKeys.public);
    expect(update['proofAuthorPubkey'], providerKeys.public);
    expect(update['proofImage'], 'raw_base64_da_prova');
    await relay.stop();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('v812: sem orderIds ativos, fetch nem sai (performance)', () async {
    final updates = await NostrOrderService().fetchOrderUpdatesForUser('user812', orderIds: const []);
    expect(updates, isEmpty);
  });
}
