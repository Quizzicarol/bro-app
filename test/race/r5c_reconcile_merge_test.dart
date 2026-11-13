/// R5c: merge aditivo do reconcile de relay na lista visível.
///
/// O R5b entregou o callback `onBackgroundReconcile`, mas o merge do
/// `lastRelayReconcileResult` nas listas do OrderProvider ficou pela metade
/// (a ordem que SÓ o relay viu só aparecia no próximo poll). O R5c fecha
/// esse gap: o callback aplica o merge aditivo e notifica.
///
/// Estratégia de teste (sem rede, sem initialize() pesado): hooks
/// `@visibleForTesting` no OrderProvider (mesmo padrão dos hooks do
/// NostrOrderService aprovados na revisão do R5b) + relays mortos.

import 'package:flutter_test/flutter_test.dart';
import 'package:bro_app/models/order.dart';
import 'package:bro_app/providers/order_provider.dart';
import 'package:bro_app/services/nostr_order_service.dart';

Order _order(
  String id, {
  String? userPubkey,
  String? providerId,
  String status = 'pending',
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
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    NostrOrderService().lastRelayReconcileResult = null;
  });

  group('R5c - merge aditivo do reconcile', () {
    test('(a) ordem minha que só o relay viu entra em _orders', () {
      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('pk-me');
      NostrOrderService().lastRelayReconcileResult = [
        _order('r5c-a-1', userPubkey: 'pk-me'),
      ];

      provider.debugApplyR5cReconcileMerge();

      expect(provider.orders.map((o) => o.id), contains('r5c-a-1'));
    });

    test('(b) ordem aceita por mim (providerId) que só o relay viu entra em _orders', () {
      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('pk-me');
      NostrOrderService().lastRelayReconcileResult = [
        _order('r5c-b-1', userPubkey: 'pk-buyer', providerId: 'pk-me',
            status: 'accepted'),
      ];

      provider.debugApplyR5cReconcileMerge();

      expect(provider.orders.map((o) => o.id), contains('r5c-b-1'));
    });

    test('(c) ordem de outro, pendente, entra nas Disponíveis (aditivo)', () {
      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('pk-me');
      NostrOrderService().lastRelayReconcileResult = [
        _order('r5c-c-1', userPubkey: 'pk-other'),
      ];

      provider.debugApplyR5cReconcileMerge();

      expect(provider.availableOrdersForProvider.map((o) => o.id),
          contains('r5c-c-1'));
      // Não pode vazar pra _orders (não é minha nem aceitei).
      expect(provider.orders.map((o) => o.id), isNot(contains('r5c-c-1')));
    });

    test('(d) NUNCA remove: ordem existente protegida não regride', () {
      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('pk-me');
      provider.debugSeedOrdersForR5c([
        _order('r5c-d-1', userPubkey: 'pk-me', status: 'completed'),
      ]);
      // Relay devolve a mesma ordem com status antigo (pending).
      NostrOrderService().lastRelayReconcileResult = [
        _order('r5c-d-1', userPubkey: 'pk-me', status: 'pending'),
      ];

      provider.debugApplyR5cReconcileMerge();

      expect(
        provider.orders.firstWhere((o) => o.id == 'r5c-d-1').status,
        'completed',
        reason: 'status final (completed) é protegido — merge é aditivo puro',
      );
    });

    test('(e) status avança: relay viu accepted, lista tinha pending', () {
      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('pk-me');
      provider.debugSeedOrdersForR5c([
        _order('r5c-e-1', userPubkey: 'pk-me', status: 'pending'),
      ]);
      NostrOrderService().lastRelayReconcileResult = [
        _order('r5c-e-1', userPubkey: 'pk-me', providerId: 'pk-provider',
            status: 'accepted'),
      ];

      provider.debugApplyR5cReconcileMerge();

      final updated =
          provider.orders.firstWhere((o) => o.id == 'r5c-e-1');
      expect(updated.status, 'accepted');
      // providerId faltando é preenchido pelo relay (nunca sobrescrito se já existir).
      expect(updated.providerId, 'pk-provider');
    });

    test('(f) reconcile vazio/null não faz nada (idempotente)', () {
      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('pk-me');
      provider.debugSeedOrdersForR5c([
        _order('r5c-f-1', userPubkey: 'pk-me'),
      ]);

      NostrOrderService().lastRelayReconcileResult = null;
      provider.debugApplyR5cReconcileMerge();
      NostrOrderService().lastRelayReconcileResult = [];
      provider.debugApplyR5cReconcileMerge();

      expect(provider.orders.length, 1);
    });
  });
}
