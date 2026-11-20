import 'dart:async';

import 'package:bro_app/main.dart';
import 'package:bro_app/providers/breez_provider_export.dart';
import 'package:bro_app/providers/order_provider.dart';
import 'package:bro_app/screens/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _TestBreezProvider extends BreezProvider {
  bool initialized = true;
  int revision = 0;
  int listCalls = 0;
  int allPaymentsCalls = 0;
  final List<Future<List<Map<String, dynamic>>> Function()> allPaymentsResults = [];
  final List<Completer<List<Map<String, dynamic>>>> listCompleters = [];

  @override
  bool get isInitialized => initialized;

  @override
  int get paymentRevision => revision;

  @override
  Future<List<Map<String, dynamic>>> listPayments() {
    listCalls++;
    if (listCompleters.isNotEmpty) {
      return listCompleters.removeAt(0).future;
    }
    return Future.value([
      {
        'description': 'Bro Marketplace: Produto $listCalls',
        'amountSats': listCalls,
        'type': 'received',
      },
    ]);
  }

  @override
  Future<List<Map<String, dynamic>>> getAllPayments() {
    allPaymentsCalls++;
    if (allPaymentsResults.isNotEmpty) {
      return allPaymentsResults.removeAt(0)();
    }
    return Future.value([
      {'id': 'payment-1'},
    ]);
  }
}

class _TestOrderProvider extends OrderProvider {
  int reconcileCalls = 0;
  int activeReconciliations = 0;
  int maxActiveReconciliations = 0;
  Completer<Map<String, int>>? reconcileCompleter;

  @override
  Future<Map<String, int>> autoReconcileWithBreezPayments(
    List<Map<String, dynamic>> breezPayments,
  ) async {
    reconcileCalls++;
    activeReconciliations++;
    if (activeReconciliations > maxActiveReconciliations) {
      maxActiveReconciliations = activeReconciliations;
    }
    if (reconcileCompleter != null) {
      final result = await reconcileCompleter!.future;
      activeReconciliations--;
      return result;
    }
    await Future<void>.delayed(Duration.zero);
    activeReconciliations--;
    return {'pendingReconciled': 0, 'completedReconciled': 0};
  }
}

Widget _marketplaceHarness(_TestBreezProvider breez, GlobalKey key) {
  return ChangeNotifierProvider<BreezProvider>.value(
    value: breez,
    child: MaterialApp(
      home: Scaffold(body: MarketplaceActivity(key: key)),
    ),
  );
}

void main() {
  testWidgets(
    'Marketplace reutiliza Future em rebuilds e notificações sem pagamento',
    (tester) async {
      final breez = _TestBreezProvider();
      final key = GlobalKey();
      await tester.pumpWidget(_marketplaceHarness(breez, key));
      await tester.pump();
      expect(breez.listCalls, 1);
      expect(find.textContaining('Produto 1'), findsOneWidget);

      for (var i = 0; i < 10; i++) {
        await tester.pumpWidget(_marketplaceHarness(breez, key));
      }
      breez.notifyListeners();
      await tester.pump();
      expect(breez.listCalls, 1);
      expect(find.textContaining('Produto 1'), findsOneWidget);
    },
  );

  testWidgets('Marketplace invalida no refresh e em evento de pagamento', (
    tester,
  ) async {
    final breez = _TestBreezProvider();
    final key = GlobalKey();
    await tester.pumpWidget(_marketplaceHarness(breez, key));
    await tester.pump();

    final dynamic state = key.currentState;
    await state.refresh();
    await tester.pump();
    await tester.pump();
    expect(breez.listCalls, 2);
    expect(find.textContaining('Produto 2'), findsOneWidget);

    breez.revision++;
    breez.notifyListeners();
    await tester.pump();
    await tester.pump();
    expect(breez.listCalls, 3);
    expect(find.textContaining('Produto 3'), findsOneWidget);
  });

  testWidgets('Marketplace ignora resposta antiga fora de ordem', (tester) async {
    final breez = _TestBreezProvider();
    final key = GlobalKey();
    final initial = Completer<List<Map<String, dynamic>>>();
    final refresh = Completer<List<Map<String, dynamic>>>();
    final payment = Completer<List<Map<String, dynamic>>>();
    breez.listCompleters.addAll([initial, refresh, payment]);
    await tester.pumpWidget(_marketplaceHarness(breez, key));
    initial.complete([
      {'description': 'Bro Marketplace: Inicial', 'amountSats': 1, 'type': 'received'},
    ]);
    await tester.pump();
    await tester.pump();

    final dynamic state = key.currentState;
    unawaited(state.refresh());
    await tester.pump();
    breez.revision++;
    breez.notifyListeners();
    await tester.pump();
    payment.complete([
      {'description': 'Bro Marketplace: Pagamento novo', 'amountSats': 3, 'type': 'received'},
    ]);
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Pagamento novo'), findsOneWidget);

    refresh.complete([
      {'description': 'Bro Marketplace: Refresh antigo', 'amountSats': 2, 'type': 'received'},
    ]);
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Pagamento novo'), findsOneWidget);
    expect(find.textContaining('Refresh antigo'), findsNothing);
  });

  testWidgets('Marketplace descarta Future ao trocar provider e ao dispose', (tester) async {
    final first = _TestBreezProvider();
    final second = _TestBreezProvider();
    final key = GlobalKey();
    final oldRequest = Completer<List<Map<String, dynamic>>>();
    final newRequest = Completer<List<Map<String, dynamic>>>();
    first.listCompleters.add(oldRequest);
    second.listCompleters.add(newRequest);
    await tester.pumpWidget(_marketplaceHarness(first, key));
    await tester.pumpWidget(_marketplaceHarness(second, GlobalKey()));
    newRequest.complete([
      {'description': 'Bro Marketplace: Provider novo', 'amountSats': 2, 'type': 'received'},
    ]);
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Provider novo'), findsOneWidget);

    oldRequest.complete([
      {'description': 'Bro Marketplace: Provider antigo', 'amountSats': 1, 'type': 'received'},
    ]);
    await tester.pump();
    expect(find.textContaining('Provider antigo'), findsNothing);

    final disposedRequest = Completer<List<Map<String, dynamic>>>();
    second.listCompleters.add(disposedRequest);
    second.revision++;
    second.notifyListeners();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    disposedRequest.complete([
      {'description': 'Bro Marketplace: Depois do dispose', 'amountSats': 3, 'type': 'received'},
    ]);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  test('falha permite retry só em nova inicialização e limpa single-flight', () async {
    final breez = _TestBreezProvider()..initialized = false;
    final orders = _TestOrderProvider();
    final coordinator = StartupReconciliationCoordinator(
      breez,
      orders,
      delay: const Duration(days: 1),
    )..start();
    addTearDown(coordinator.dispose);

    breez.allPaymentsResults.add(
      () => Future<List<Map<String, dynamic>>>.error(StateError('falha temporária')),
    );
    breez.initialized = true;
    breez.notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(breez.allPaymentsCalls, 1);
    expect(orders.reconcileCalls, 0);

    for (var i = 0; i < 5; i++) {
      breez.notifyListeners();
    }
    expect(breez.allPaymentsCalls, 1);

    orders.reconcileCompleter = Completer<Map<String, int>>();
    breez.initialized = false;
    breez.notifyListeners();
    breez.initialized = true;
    breez.notifyListeners();
    breez.notifyListeners();
    expect(breez.allPaymentsCalls, 2);
    await Future<void>.delayed(Duration.zero);
    expect(orders.reconcileCalls, 1);
    expect(orders.maxActiveReconciliations, 1);

    orders.reconcileCompleter!.complete({'pendingReconciled': 0, 'completedReconciled': 0});
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    breez.initialized = false;
    breez.notifyListeners();
    breez.initialized = true;
    breez.notifyListeners();
    expect(breez.allPaymentsCalls, 2);
  });

  test(
    'reconciliação inicial é única, single-flight e remove listener',
    () async {
      final breez = _TestBreezProvider()..initialized = false;
      final orders = _TestOrderProvider();
      final coordinator = StartupReconciliationCoordinator(
        breez,
        orders,
        delay: const Duration(days: 1),
      )..start();
      addTearDown(coordinator.dispose);

      breez.initialized = true;
      breez.notifyListeners();
      breez.notifyListeners();
      expect(breez.allPaymentsCalls, 1);
      var listenerCalls = 0;
      void listener() => listenerCalls++;
      breez.addListener(listener);
      breez.notifyListeners();
      expect(listenerCalls, 1);
      breez.removeListener(listener);

      for (var i = 0; i < 5; i++) {
        breez.notifyListeners();
      }
      await Future<void>.delayed(Duration.zero);
      expect(breez.allPaymentsCalls, 1);
      expect(orders.reconcileCalls, 1);
      expect(orders.maxActiveReconciliations, 1);
    },
  );
}
