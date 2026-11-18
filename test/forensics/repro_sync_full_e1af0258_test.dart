/// FORENSE 27c916e7 (17/11, 23:00): o usuário abriu DISPUTA dizendo que o
/// botão de confirmação ficou indisponível MESMO no build 817. O complete
/// existe no apexcord desde 13:05, o fetch isolado por #d FUNCIONA (repro
/// anterior), mas o app dele nunca aplicou. Hipótese: a fase 1 do sync
/// (fetchUserOrders — puxa os 30078 DELE, incluindo um evento de 203KB!)
/// morre/estoura antes de chegar na fase 2 (fetchOrderUpdatesForUser).
///
/// Este teste roda as DUAS fases, na ordem do sync real, com a pubkey real
/// dele, contra os relays reais, medindo o tempo de cada fase.
///   flutter test test/forensics/repro_sync_full_e1af0258_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:bro_app/services/nostr_order_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    NostrOrderService.relaysOverride = null;
    NostrOrderService.applyRelaysOverride();
  });

  test('sync completo do e1af0258: fase1 (orders) -> fase2 (updates)', () async {
    const userPubkey =
        'e1af02582bbbcf83e3badad024884d4811303c06670e307ef7a0ee77d0b9a3b6';
    const targetOrder = '27c916e7-887d-44fa-a90d-670287cb1a4b';

    NostrOrderService.relaysOverride = const [
      'wss://apexcord.duckdns.org',
      'wss://bro-relay2.fly.dev',
      'wss://relay.primal.net',
      'wss://relay.damus.io',
      'wss://nos.lol',
      'wss://relay.nostr.band',
      'wss://nostr.mom',
    ];
    NostrOrderService.applyRelaysOverride();
    final svc = NostrOrderService();

    // FASE 1 — fetchUserOrders (igual syncOrdersFromNostr linha ~5670)
    final sw1 = Stopwatch()..start();
    final orders = await svc.fetchUserOrders(userPubkey);
    sw1.stop();
    // ignore: avoid_print
    print('FASE 1: ${orders.length} ordens em ${sw1.elapsed.inMilliseconds}ms');
    for (final o in orders) {
      // ignore: avoid_print
      print('  ${o.id.substring(0, 8)} status=${o.status} amount=${o.amount}');
    }

    final hasTarget = orders.any((o) => o.id == targetOrder);
    // ignore: avoid_print
    print('  ordem 27c916e7 presente na fase 1: $hasTarget');

    // FASE 2 — fetchOrderUpdatesForUser com os ids ativos (v809)
    const terminal = ['completed', 'cancelled', 'liquidated'];
    final activeIds = orders
        .where((o) => !terminal.contains(o.status))
        .map((o) => o.id)
        .toList();
    if (!activeIds.contains(targetOrder)) activeIds.add(targetOrder); // ordem ativa pra ele
    // ignore: avoid_print
    print('FASE 2: ${activeIds.length} ordens ativas -> fetch updates...');
    final sw2 = Stopwatch()..start();
    final updates = await svc.fetchOrderUpdatesForUser(userPubkey, orderIds: activeIds);
    sw2.stop();
    // ignore: avoid_print
    print('FASE 2: ${updates.length} updates em ${sw2.elapsed.inMilliseconds}ms');

    final u = updates[targetOrder];
    // ignore: avoid_print
    print('  27c916e7 no mapa de updates: ${u != null} '
        '${u != null ? 'status=${u['status']} proof=${(u['proofImage'] as String?)?.length ?? 0}chars' : ''}');

    expect(u, isNotNull,
        reason: 'se a fase 2 acha o complete com as duas fases em sequência, '
            'o caminho é são e o problema é do aparelho/rede dele');
    expect(u!['status'], 'awaiting_confirmation');
  }, timeout: const Timeout(Duration(seconds: 180)), skip: 'forense de 17/11: bate em relay REAL e a ordem real já foi resolvida via disputa (status=completed) — não é mais reproduzível. Rodar manual só com nova ordem-âncora.');
}
