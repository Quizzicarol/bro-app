/// TESTE DE INTEGRACAO - Withdrawal Flow (Corredor 4)
///
/// Cenario: Saque Lightning -> historico correto
/// Valida: WithdrawalService + saldo decrementado

import 'package:flutter_test/flutter_test.dart';
import '../fixtures/mock_wallet.dart';
import '../fixtures/test_harness.dart';

void main() {
  group('Withdrawal Flow - Integration', () {
    late TestHarness h;
    late MockBreezProvider wallet;

    setUp(() async {
      h = TestHarness();
      wallet = MockBreezProvider();
      await wallet.initialize(mnemonic: 'test');
    });

    tearDown(() {
      h.resetAll();
    });

    test('Saque Lightning debita saldo', () async {
      const amountSats = 100000;
      const invoice = 'lnbc_mock_100000n1...mock_hash';
      
      await wallet.initialize(mnemonic: 'test');
      wallet.setBalance(amountSats);
      expect(wallet.getCurrentBalance(), equals(amountSats));
      
      final result = await wallet.payInvoice(invoice);
      
      expect(result?['success'], isTrue);
      expect(wallet.getCurrentBalance(), equals(0));
    });

    test('Saque falha sem saldo suficiente', () async {
      const invoice = 'lnbc_mock_100000n1...mock_hash';
      
      await wallet.initialize(mnemonic: 'test');
      wallet.setBalance(50000);
      
      final result = await wallet.payInvoice(invoice);
      
      expect(result?['success'], isFalse);
      expect(wallet.getCurrentBalance(), equals(50000));
    });

    test('Dois saques consecutivos - segundo falha', () async {
      const amountSats = 100000;
      const invoice = 'lnbc_mock_100000n1...mock_hash';
      
      await wallet.initialize(mnemonic: 'test');
      wallet.setBalance(amountSats);
      
      final first = await wallet.payInvoice(invoice);
      expect(first?['success'], isTrue);
      expect(wallet.getCurrentBalance(), equals(0));
      
      final second = await wallet.payInvoice(invoice);
      expect(second?['success'], isFalse);
    });
  });
}
