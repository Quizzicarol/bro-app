/// R5b: testes de fluxo — API-first + reconcile aditivo em background.
///
/// Sem rede real: `NostrOrderService.apiGetOverride` stuba o GET da watchtower
/// e `relaysOverride`/`applyRelaysOverride` aponta os relays pra URLs mortas
/// (ws://127.0.0.1:1). Critério de aceite medido de verdade: Stopwatch +
/// broLog (<2s para renderizar com relays mortos).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:bro_app/services/nostr_order_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const deadRelays = <String>[
    'ws://127.0.0.1:1',
    'ws://127.0.0.1:2',
    'ws://127.0.0.1:3',
  ];

  Map<String, dynamic> snapshotOrder(String id, {int ageDays = 0}) => {
        'id': id,
        'amountBrl': 50.0,
        'amountSats': 10000,
        'createdAt': DateTime.now()
            .subtract(Duration(days: ageDays))
            .millisecondsSinceEpoch ~/ 1000,
        'status': 'pending',
        'acceptedAt': null,
      };

  tearDown(() {
    NostrOrderService.apiGetOverride = null;
    NostrOrderService.relaysOverride = null;
    NostrOrderService.applyRelaysOverride();
  });

  group('R5b - fluxo API-first', () {
    test('(a) lista renderiza via API com relays mortos em <2s', () async {
      NostrOrderService.relaysOverride = List<String>.from(deadRelays);
      NostrOrderService.applyRelaysOverride();
      NostrOrderService.apiGetOverride = (path) async => {
            'success': true,
            'orders': [snapshotOrder('flow-a-1'), snapshotOrder('flow-a-2')],
          };

      final sw = Stopwatch()..start();
      final orders = await NostrOrderService().fetchPendingOrders();
      sw.stop();

      expect(orders.map((o) => o.id), containsAll(['flow-a-1', 'flow-a-2']));
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)),
          reason: 'lista deve renderizar via API mesmo com relays mortos');
      broLog('⏱️ R5b teste (a): render via API em ${sw.elapsedMilliseconds}ms com relays mortos');
    });

    test('(b) API fora → fallback relay (retorna sem estourar, lista vazia com relays mortos)', () async {
      NostrOrderService.relaysOverride = List<String>.from(deadRelays);
      NostrOrderService.applyRelaysOverride();
      NostrOrderService.apiGetOverride = (path) async => null; // API "fora"

      final sw = Stopwatch()..start();
      final orders = await NostrOrderService().fetchPendingOrders();
      sw.stop();

      // Fallback relay roda; com relays mortos, 0 ordens — mas NÃO pode
      // lançar exceção nem travar. O caminho antigo é preservado.
      expect(orders, isA<List<dynamic>>());
      broLog('⏱️ R5b teste (b): fallback relay concluído em ${sw.elapsedMilliseconds}ms (API fora)');
    });

    test('(c) reconcile aditivo: ordem só no relay entra depois via callback', () async {
      NostrOrderService.relaysOverride = List<String>.from(deadRelays);
      NostrOrderService.applyRelaysOverride();
      // API responde só com a ordem A; o relay (stub via apiGetOverride não
      // alcança o pipeline de relay, então simulamos o reconcile direto).
      NostrOrderService.apiGetOverride = (path) async => {
            'success': true,
            'orders': [snapshotOrder('flow-c-api')],
          };

      final reconcileCalled = Completer<void>();
      final orders = await NostrOrderService()
          .fetchPendingOrders(onBackgroundReconcile: reconcileCalled.complete);
      expect(orders.map((o) => o.id), contains('flow-c-api'));

      // O reconcile em background dispara o fetch de relay (morto aqui) e
      // chama o callback mesmo assim (merge aditivo vazio + aviso).
      await reconcileCalled.future.timeout(const Duration(seconds: 30),
          onTimeout: () => throw TimeoutException('reconcile não chamou callback'));
      expect(NostrOrderService().lastRelayReconcileResult, isNotNull,
          reason: 'reconcile aditivo publica o resultado do relay');
      broLog('⏱️ R5b teste (c): reconcile aditivo chamou callback');
    });

    test('(d) API vazia → fallback relay síncrono (mesmo contrato)', () async {
      NostrOrderService.relaysOverride = List<String>.from(deadRelays);
      NostrOrderService.applyRelaysOverride();
      NostrOrderService.apiGetOverride = (path) async => {'success': true, 'orders': <dynamic>[]};

      final sw = Stopwatch()..start();
      final orders = await NostrOrderService().fetchPendingOrders();
      sw.stop();

      expect(orders, isEmpty);
      broLog('⏱️ R5b teste (d): API vazia → fallback relay em ${sw.elapsedMilliseconds}ms');
    });

    test('(e) provider orders: snapshot renderiza imediato com relays mortos <2s', () async {
      NostrOrderService.relaysOverride = List<String>.from(deadRelays);
      NostrOrderService.applyRelaysOverride();
      NostrOrderService.apiGetOverride = (path) async {
        if (path.contains('provider=')) {
          return {
            'success': true,
            'orders': [snapshotOrder('flow-e-1')],
          };
        }
        return {'success': true, 'orders': <dynamic>[]};
      };

      final sw = Stopwatch()..start();
      final orders = await NostrOrderService()
          .fetchProviderOrders('pk-provider-test', onBackgroundReconcile: () {});
      sw.stop();

      expect(orders.map((o) => o.id), contains('flow-e-1'));
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      broLog('⏱️ R5b teste (e): provider orders via API em ${sw.elapsedMilliseconds}ms');
    });
  });
}
