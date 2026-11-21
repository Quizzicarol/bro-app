import 'dart:async';

import 'package:bro_app/screens/order_status_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DateTime now;
  late ProofFetchCoordinator coordinator;

  setUp(() {
    now = DateTime(2026, 11, 21);
    coordinator = ProofFetchCoordinator(clock: () => now);
  });

  tearDown(() => coordinator.dispose());

  test('rajada compartilha fetch e not-found respeita cooldown', () async {
    var calls = 0;
    final pending = Completer<bool>();
    Future<bool> operation() {
      calls++;
      return pending.future;
    }

    final first = coordinator.fetch(operation);
    final second = coordinator.fetch(operation);
    expect(identical(first, second), isTrue);
    expect(calls, 1);

    pending.complete(false);
    await Future.wait([first, second]);
    await coordinator.fetch(operation);
    await coordinator.fetch(operation);
    expect(calls, 1);

    now = now.add(const Duration(seconds: 30));
    await coordinator.fetch(operation);
    expect(calls, 2);
  });

  test('indício novo de proof e refresh explícito liberam imediato', () async {
    var calls = 0;
    Future<bool> notFound() async {
      calls++;
      return false;
    }

    await coordinator.fetch(notFound);
    coordinator.noteProofHint('encrypted-v1');
    await coordinator.fetch(notFound);
    expect(calls, 2);

    coordinator.noteProofHint('encrypted-v1');
    await coordinator.fetch(notFound);
    expect(calls, 2, reason: 'mesmo indício não invalida repetidamente');

    await coordinator.fetch(notFound, force: true);
    expect(calls, 3);
  });

  test('erro libera lock, aplica backoff e permite retry posterior', () async {
    var calls = 0;
    Future<bool> operation() async {
      calls++;
      if (calls == 1) throw StateError('timeout');
      return false;
    }

    await expectLater(coordinator.fetch(operation), throwsStateError);
    expect(coordinator.isFetching, isFalse);
    await coordinator.fetch(operation);
    expect(calls, 1);

    now = now.add(const Duration(seconds: 30));
    await coordinator.fetch(operation);
    expect(calls, 2);
  });

  test('dispose impede novos fetch e conclusão tardia não recria cooldown', () async {
    var calls = 0;
    final pending = Completer<bool>();
    final first = coordinator.fetch(() {
      calls++;
      return pending.future;
    });
    coordinator.dispose();
    pending.complete(false);
    await first;

    await coordinator.fetch(() async {
      calls++;
      return true;
    });
    expect(calls, 1);
    expect(coordinator.isFetching, isFalse);
  });
}
