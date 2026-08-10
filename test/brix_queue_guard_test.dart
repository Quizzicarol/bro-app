import 'package:flutter_test/flutter_test.dart';
import 'package:bro_app/services/brix_relay_service.dart';

void main() {
  group('BRIX-QUEUE anti double-spend (firstSettledHash)', () {
    test('returns null when no prior attempt settled', () async {
      final settled = await BrixRelayService.firstSettledHash(
        ['h1', 'h2', 'h3'],
        (h) async => false, // none paid
      );
      expect(settled, isNull);
    });

    test('detects a prior settled attempt and returns its hash', () async {
      final settled = await BrixRelayService.firstSettledHash(
        ['h1', 'h2', 'h3'],
        (h) async => h == 'h2', // h2 already settled on-chain
      );
      expect(settled, 'h2');
    });

    test('empty hash list is never settled', () async {
      final settled = await BrixRelayService.firstSettledHash(
        const <String>[],
        (h) async => true,
      );
      expect(settled, isNull);
    });

    test('a transient check error does NOT falsely report settled', () async {
      // If checkPaymentStatus throws, we must treat it as not-settled so the
      // guard errs toward re-checking next cycle rather than skipping a
      // legitimate unpaid payment.
      final settled = await BrixRelayService.firstSettledHash(
        ['h1', 'h2'],
        (h) async => throw Exception('network down'),
      );
      expect(settled, isNull);
    });

    test('returns first settled hash when multiple are paid', () async {
      final settled = await BrixRelayService.firstSettledHash(
        ['a', 'b', 'c'],
        (h) async => h == 'b' || h == 'c',
      );
      expect(settled, 'b');
    });

    test('exact double-pay scenario: retry after TIMEOUT_PENDING that settled',
        () async {
      // Attempt 1 timed out (TIMEOUT_PENDING) but actually settled; its hash
      // was persisted to the queue item. On the next retry cycle the guard MUST
      // detect it and refuse to generate a fresh invoice / pay again.
      const timedOutButSettled = 'hash_attempt_1';
      final priorHashes = [timedOutButSettled];
      final settled = await BrixRelayService.firstSettledHash(
        priorHashes,
        (h) async => h == timedOutButSettled, // ledger says it DID settle
      );
      expect(settled, timedOutButSettled,
          reason: 'must block a second payment to the recipient');
    });
  });
}
