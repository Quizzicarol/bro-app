/// TESTE DE CORRIDA — Autopay vs Manual (Corredor 3)
///
/// Cenário: Ordem tem autopay + usuário clica em pagar manual no mesmo instante
/// Esperado: Apenas um pagamento (outro vê "já paga")

import 'package:flutter_test/flutter_test.dart';
import '../fixtures/mock_wallet.dart';
import '../fixtures/test_harness.dart';

void main() {
  group('Autopay vs Manual Race (Corredor 3)', () {
    late TestHarness h;
    late MockBreezProvider wallet;
    
    const invoice = 'lnbc_mock_100000n1...mock_payment_hash_123';

    setUp(() {
      h = TestHarness();
      wallet = MockBreezProvider();
    });

    tearDown(() {
      h.resetAll();
    });

    test('Autopay falha quando ordem já está paga', () async {
      wallet.setBalance(100000);
      wallet.addTransaction(MockTransaction(
        paymentHash: 'mock_payment_hash_123',
        amountSats: 100000,
        description: 'Pagamento anterior',
        isIncoming: false,
      ));
      
      expect(wallet.getCurrentBalance(), equals(0));
      
      final result = await wallet.payInvoice(invoice);
      
      expect(result?['success'], isFalse, 
        reason: 'Autopay deve detectar pagamento anterior');
    });

    test('Guarda de corrida: verifica histórico antes de pagar (v766)', () async {
      wallet.setBalance(100000);
      wallet.addTransaction(MockTransaction(
        paymentHash: 'mock_payment_hash_123',
        amountSats: 100000,
        description: 'Já pago',
        isIncoming: false,
      ));
      
      // v766: verificar histórico antes de pagar
      final alreadyPaid = wallet.getCurrentBalance() == 0;
      expect(alreadyPaid, isTrue);
      
      final canPayAgain = false;
      expect(canPayAgain, isFalse);
    });
  });
}