// R5c "corrida perdida": o provedor perdedor fica no escuro em PRODUÇÃO
// (ordem f9ea1899, 13/nov — Carol testando v788).
//
// Cobre as 3 peças testáveis app-side:
/// - Snapshot do watchtower inclui o perdedor com raceWon=false/acceptsCount
///   (PEÇA 2) e o app propaga pra Order.metadata como lostRace (PEÇA 3).
/// - Lista "Minhas Ordens" mostra a ordem perdida (não filtra fora).
/// - Merge aditivo do reconcile continua intacto (PEÇA 1, já coberta em
///   r5c_reconcile_merge_test.dart — aqui só o caso novo do perdedor).
///
/// Sem rede real: apiGetOverride stuba o GET da watchtower; relays mortos.

import 'package:flutter_test/flutter_test.dart';
import 'package:bro_app/models/order.dart';
import 'package:bro_app/providers/order_provider.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:bro_app/services/nostr_order_service.dart';

Order _order(
  String id, {
  String? userPubkey,
  String? providerId,
  String status = 'accepted',
  Map<String, dynamic>? metadata,
}) =>
    Order(
      id: id,
      userPubkey: userPubkey,
      billType: 'pix',
      billCode: 'CODE-$id',
      amount: 50.0,
      btcAmount: 0.0001,
      btcPrice: 500000.0,
      providerFee: 1.0,
      platformFee: 1.0,
      total: 52.0,
      status: status,
      createdAt: DateTime.now(),
      providerId: providerId,
      metadata: metadata,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const deadRelays = <String>[
    'ws://127.0.0.1:1',
    'ws://127.0.0.1:2',
    'ws://127.0.0.1:3',
  ];

  Map<String, dynamic> snapshotOrder(
    String id, {
    bool? raceWon,
    int? acceptsCount,
    String status = 'accepted',
  }) =>
      {
        'id': id,
        'amountBrl': 50.0,
        'amountSats': 10000,
        'createdAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'status': status,
        'acceptedAt': null,
        if (raceWon != null) 'raceWon': raceWon,
        if (acceptsCount != null) 'acceptsCount': acceptsCount,
      };

  tearDown(() {
    NostrOrderService.apiGetOverride = null;
    NostrOrderService.relaysOverride = null;
    NostrOrderService.applyRelaysOverride();
    NostrOrderService().lastRelayReconcileResult = null;
  });

  group('R5c race-lost - snapshot do perdedor (PEÇA 2+3, mapeamento app)', () {
    test('(a) perdedor aparece na lista com lostRace=true na metadata', () async {
      NostrOrderService.relaysOverride = List<String>.from(deadRelays);
      NostrOrderService.applyRelaysOverride();
      NostrOrderService.apiGetOverride = (path) async {
        if (path.contains('provider=')) {
          return {
            'success': true,
            'orders': [
              snapshotOrder('r5cl-loser-1', raceWon: false, acceptsCount: 2),
              snapshotOrder('r5cl-winner-1', raceWon: true, acceptsCount: 2),
            ],
          };
        }
        return {'success': true, 'orders': <dynamic>[]};
      };

      final sw = Stopwatch()..start();
      final orders = await NostrOrderService()
          .fetchProviderOrders('pk-provider-test', onBackgroundReconcile: () {});
      sw.stop();

      final loser = orders.where((o) => o.id == 'r5cl-loser-1').toList();
      expect(loser, isNotEmpty,
          reason: 'perdedor NÃO pode sumir de Minhas Ordens (caso f9ea1899)');
      expect(loser.first.metadata?['lostRace'], true);
      expect(loser.first.metadata?['raceWon'], false);
      expect(loser.first.metadata?['acceptsCount'], 2);

      final winner = orders.firstWhere((o) => o.id == 'r5cl-winner-1');
      expect(winner.metadata?['raceWon'], true);
      expect(winner.metadata?['lostRace'], isNot(true));

      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      broLog('⏱️ R5c teste (a): snapshot com perdedor renderizado em ${sw.elapsedMilliseconds}ms');
    });

    test('(b) snapshot sem raceWon (backend velho) não quebra o mapeamento', () async {
      NostrOrderService.relaysOverride = List<String>.from(deadRelays);
      NostrOrderService.applyRelaysOverride();
      NostrOrderService.apiGetOverride = (path) async {
        if (path.contains('provider=')) {
          return {
            'success': true,
            'orders': [snapshotOrder('r5cl-old-1')],
          };
        }
        return {'success': true, 'orders': <dynamic>[]};
      };

      final orders = await NostrOrderService()
          .fetchProviderOrders('pk-provider-test', onBackgroundReconcile: () {});

      final o = orders.firstWhere((o) => o.id == 'r5cl-old-1');
      expect(o.metadata?['lostRace'], isNull,
          reason: 'sem raceWon não há veredito de corrida — não marcar');
    });
  });

  group('R5c race-lost - lista Minhas Ordens inclui o perdedor (PEÇA 3)', () {
    test('(c) myAcceptedOrders não filtra mais lostRace', () {
      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('pk-me');
      provider.debugSeedOrdersForR5c([
        _order('r5cl-list-1', userPubkey: 'pk-buyer', providerId: 'pk-me',
            metadata: {'lostRace': true, 'raceWon': false, 'acceptsCount': 2}),
      ]);

      expect(provider.myAcceptedOrders.map((o) => o.id),
          contains('r5cl-list-1'),
          reason: 'o filtro v699 que escondia a ordem perdida foi removido');
    });

    test('(d) merge aditivo: ordem perdida que só o relay viu entra em _orders', () {
      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('pk-me');
      NostrOrderService().lastRelayReconcileResult = [
        _order('r5cl-merge-1', userPubkey: 'pk-buyer', providerId: 'pk-me',
            metadata: {'lostRace': true, 'raceWon': false}),
      ];

      provider.debugApplyR5cReconcileMerge();

      expect(provider.orders.map((o) => o.id), contains('r5cl-merge-1'));
    });
  });
}
