import 'dart:async';

import 'package:bro_app/models/order.dart';
import 'package:bro_app/providers/order_provider.dart';
import 'package:flutter_test/flutter_test.dart';

Order _completedOrder(String id, {Map<String, dynamic>? metadata}) => Order(
      id: id,
      userPubkey: 'buyer-pubkey',
      providerId: 'provider-pubkey',
      billType: 'pix',
      billCode: 'code',
      amount: 50,
      btcAmount: 0.0001,
      btcPrice: 500000,
      providerFee: 1,
      platformFee: 1,
      total: 52,
      status: 'completed',
      createdAt: DateTime.now(),
      metadata: metadata ?? {'paymentProof': 'proof'},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PERF-SYNC coalescência', () {
    late OrderProvider provider;
    late List<Completer<void>> passes;
    late List<bool> forceCalls;
    late DateTime now;
    late int cacheInvalidations;

    setUp(() {
      provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('buyer-pubkey');
      passes = [];
      forceCalls = [];
      now = DateTime(2026, 11, 20, 12);
      cacheInvalidations = 0;
      provider.syncClockOverride = () => now;
      provider.statusCacheInvalidatorOverride = () => cacheInvalidations++;
      provider.syncDelayOverride = (_) => Future<void>.value();
      provider.userSyncRunnerOverride = ({bool force = false}) {
        forceCalls.add(force);
        final completer = Completer<void>();
        passes.add(completer);
        return completer.future;
      };
    });

    tearDown(() {
      for (final pass in passes) {
        if (!pass.isCompleted) pass.complete();
      }
      provider.dispose();
    });

    test('rajada mantém um ativo e um pendente compartilhado', () async {
      final active = provider.syncOrdersFromNostr();
      await Future<void>.delayed(Duration.zero);
      expect(passes, hasLength(1));

      final pending1 = provider.syncOrdersFromNostr();
      final pending2 = provider.syncOrdersFromNostr(force: true);
      final pending3 = provider.syncOrdersFromNostr();
      expect(identical(pending1, pending2), isTrue);
      expect(identical(pending2, pending3), isTrue);
      expect(passes, hasLength(1));

      passes[0].complete();
      await active;
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(passes, hasLength(2));
      expect(forceCalls, [false, true]);

      passes[1].complete();
      await Future.wait([pending1, pending2, pending3]);
      await Future<void>.delayed(Duration.zero);
      expect(passes, hasLength(2));
    });

    test('force recebido durante o pendente não é rebaixado', () async {
      final active = provider.syncOrdersFromNostr(force: true);
      await Future<void>.delayed(Duration.zero);
      final pending = provider.syncOrdersFromNostr();
      final urgent = provider.syncOrdersFromNostr(force: true);
      expect(identical(pending, urgent), isTrue);

      passes[0].complete();
      await active;
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(forceCalls, [true, true]);
      passes[1].complete();
      await pending;
    });

    test('evento na transição entre passes não cai no throttle', () async {
      final active = provider.syncOrdersFromNostr();
      await Future<void>.delayed(Duration.zero);
      final pending = provider.syncOrdersFromNostr(force: true);
      passes[0].complete();
      await active;
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(passes, hasLength(2));

      final next = provider.syncOrdersFromNostr(force: true);
      expect(identical(next, pending), isFalse);
      passes[1].complete();
      await pending;
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(passes, hasLength(3));
      expect(forceCalls, [false, true, true]);
      passes[2].complete();
      await next;
    });

    test('force durante stale invalida cache e finally antigo não toca novo passe', () async {
      final stale = provider.syncOrdersFromNostr();
      await Future<void>.delayed(Duration.zero);
      expect(passes, hasLength(1));
      expect(cacheInvalidations, 0);

      now = now.add(const Duration(seconds: 61));
      final replacement = provider.syncOrdersFromNostr(force: true);
      await Future<void>.delayed(Duration.zero);
      expect(passes, hasLength(2));
      expect(forceCalls, [false, true]);
      expect(cacheInvalidations, 1);
      expect(provider.isSyncingUser, isTrue);

      final pending = provider.syncOrdersFromNostr(force: true);
      passes[0].complete();
      await stale;
      await Future<void>.delayed(Duration.zero);
      expect(provider.isSyncingUser, isTrue,
          reason: 'finally do passe stale não pode liberar o passe novo');
      expect(passes, hasLength(2),
          reason: 'finally antigo não pode drenar a fila do novo passe');

      passes[1].complete();
      await replacement;
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(passes, hasLength(3));
      expect(forceCalls, [false, true, true]);
      expect(cacheInvalidations, 2);

      passes[2].complete();
      await pending;
      expect(provider.isSyncingUser, isFalse);
    });

    test('stale seguido de cooldown conclui awaiter abandonado sem novo passe', () async {
      final stale = provider.syncOrdersFromNostr();
      await Future<void>.delayed(Duration.zero);
      final pending = provider.syncOrdersFromNostr(force: true);
      var pendingCompleted = false;
      pending.then((_) => pendingCompleted = true);

      now = now.add(const Duration(seconds: 61));
      provider.debugMarkUserSyncStartedForTest(now.subtract(const Duration(seconds: 61)));
      provider.debugMarkLastUserSyncForTest(now);
      final throttled = provider.syncOrdersFromNostr();
      await throttled;
      await Future<void>.delayed(Duration.zero);

      expect(pendingCompleted, isTrue);
      expect(passes, hasLength(1), reason: 'cooldown não pode disparar passe');
      expect(provider.isSyncingUser, isFalse);

      passes[0].complete();
      await stale;
      await Future<void>.delayed(Duration.zero);
      expect(passes, hasLength(1), reason: 'finally antigo não recria fila');
    });
  });

  group('PERF-SYNC cooldown de completions', () {
    late OrderProvider provider;
    late DateTime now;
    late List<String> publications;
    late bool publishResult;

    setUp(() {
      provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('buyer-pubkey');
      now = DateTime(2026, 11, 20, 12);
      provider.completionClockOverride = () => now;
      publications = [];
      publishResult = true;
      provider.completionRepublisherOverride = (order) async {
        publications.add(order.id);
        return publishResult;
      };
    });

    tearDown(() => provider.dispose());

    test('ACK recente suprime loop, expiração permite recuperação', () async {
      provider.debugSeedOrdersForR5c([_completedOrder('order-ack')]);

      await provider.debugRepublishUnconfirmedCompletions();
      await provider.debugRepublishUnconfirmedCompletions();
      await provider.debugRepublishUnconfirmedCompletions();
      expect(publications, ['order-ack']);

      now = now.add(const Duration(minutes: 10));
      await provider.debugRepublishUnconfirmedCompletions();
      expect(publications, ['order-ack', 'order-ack']);
    });

    test('falha não cria cooldown e resolução de disputa não republica',
        () async {
      publishResult = false;
      provider.debugSeedOrdersForR5c([
        _completedOrder('order-failure'),
        _completedOrder('order-dispute', metadata: {
          'paymentProof': 'proof',
          'wasDisputed': true,
          'disputeResolvedAt': '2026-11-20T10:00:00.000',
        }),
      ]);

      await provider.debugRepublishUnconfirmedCompletions();
      await provider.debugRepublishUnconfirmedCompletions();
      expect(publications, ['order-failure', 'order-failure']);
    });

    test('timeout externo não permite segunda execução sobreposta', () async {
      provider.debugSeedOrdersForR5c([_completedOrder('order-slow')]);
      final slowPublish = Completer<bool>();
      provider.completionRepublisherOverride = (order) {
        publications.add(order.id);
        return slowPublish.future;
      };

      final first = provider.debugRepublishUnconfirmedCompletions();
      await Future<void>.delayed(Duration.zero);
      final timedOut = first.timeout(
        const Duration(milliseconds: 10),
        onTimeout: () {},
      );
      await timedOut;

      final second = provider.debugRepublishUnconfirmedCompletions();
      await Future<void>.delayed(Duration.zero);
      expect(publications, ['order-slow']);
      expect(identical(first, second), isTrue);

      slowPublish.complete(true);
      await Future.wait([first, second]);
      await provider.debugRepublishUnconfirmedCompletions();
      expect(publications, ['order-slow'],
          reason: 'ACK da execução única ativa o cooldown após conclusão');
    });

    test('exceção libera single-flight para retry posterior', () async {
      provider.debugSeedOrdersForR5c([_completedOrder('order-retry')]);
      var attempts = 0;
      provider.completionRepublisherOverride = (order) async {
        attempts++;
        publications.add(order.id);
        if (attempts == 1) throw StateError('relay failed');
        return true;
      };

      await provider.debugRepublishUnconfirmedCompletions();
      await provider.debugRepublishUnconfirmedCompletions();
      expect(publications, ['order-retry', 'order-retry']);

      await provider.debugRepublishUnconfirmedCompletions();
      expect(publications, ['order-retry', 'order-retry'],
          reason: 'retry com ACK ativa cooldown');
    });
  });
}
