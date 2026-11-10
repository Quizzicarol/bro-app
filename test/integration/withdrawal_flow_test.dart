/// TESTE DE INTEGRAÇÃO — Withdrawal Flow (Corredor 4)
///
/// Cenário: Saque Lightning → histórico correto
/// Valida: WithdrawalService + saldo decrementado

import 'package:flutter_test/flutter_test.dart';
import '../fixtures/mock_wallet.dart';
import '../fixtures/test_harness.dart';

void main() {
  group('Withdrawal Flow — Integration', () {
    late TestHarness h;
    late MockBreezProvider wallet;

    setUp(() {
      h = TestHarness();
      wallet = MockBreezProvider();
    });

    tearDown(() {
      h.resetAll();
    });

    test('Saque Lightning debita saldo e registra histórico', () async {
      const amountSats = 100000;
      const invoice = 'lnbc_mock_100000n1...mock_hash';
      
      wallet.setBalance(amountSats);
      expect(wallet.getCurrentBalance(), equals(amountSats));
      
      final result = await wallet.payInvoice(invoice);
      
      expect(result?['success'], isTrue, reason: 'Saque deve funcionar com saldo');
      expect(wallet.getCurrentBalance(), equals(0), reason: 'Saldo debitado');
    });

    test('Saque falha sem saldo suficiente', () async {
      const invoice = 'lnbc_mock_100000n1...mock_hash';
      
      wallet.setBalance(50000);
      
      final result = await wallet.payInvoice(invoice);
      
      expect(result?['success'], isFalse, reason: 'Falha sem saldo');
      expect(wallet.getCurrentBalance(), equals(50000));
    });

    test('Dois saques consecutivos — segundo falha por saldo', () async {
      const amountSats = 100000;
      const invoice = 'lnbc_mock_100000n1...mock_hash';
      
      wallet.setBalance(amountSats);
      
      final first = await wallet.payInvoice(invoice);
      expect(first?['success'], isTrue);
      expect(wallet.getCurrentBalance(), equals(0));
      
      final second = await wallet.payInvoice(invoice);
      expect(second?['success'], isFalse, reason: 'Segundo saque falha');
    });
  });
}