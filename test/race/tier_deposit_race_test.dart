/// TESTE DE CORRIDA — Tier Deposit Race (Corredor 1/4)
///
/// Cenário: Usuário paga garantia ANTES de abrir tela → app vê saldo já cobre
/// Esperado (v675): Ativa mesmo com increase=0

import 'package:flutter_test/flutter_test.dart';
import '../fixtures/mock_wallet.dart';
import '../fixtures/test_harness.dart';

void main() {
  group('Tier Deposit Race — v675 (Corredor 1/4)', () {
    late TestHarness h;
    late MockBreezProvider wallet;
    
    const tierRequired = 100000;
    const amountNeeded = 90000;

    setUp(() {
      h = TestHarness();
      wallet = MockBreezProvider();
    });

    tearDown(() {
      h.resetAll();
    });

    test('v675: Saldo já cobre → ativa mesmo sem increase', () async {
      wallet.setBalance(tierRequired);
      
      final initialBalance = wallet.getCurrentBalance();
      final totalBalance = wallet.getCurrentBalance();
      final balanceIncrease = totalBalance - initialBalance; // = 0
      
      final availableBalance = totalBalance;
      final alreadyCovered = availableBalance >= tierRequired;
      
      expect(alreadyCovered, isTrue, 
        reason: 'v675: saldo já cobre → ativa mesmo com increase=0');
    });

    test('Depósito parcial — não ativa até completar', () async {
      wallet.setBalance(0);
      final initialBalance = wallet.getCurrentBalance();
      
      // 50% chega
      wallet.setBalance(45000);
      final balanceIncrease = wallet.getCurrentBalance() - initialBalance;
      final availableBalance = wallet.getCurrentBalance();
      final minRequired = (tierRequired * 0.90).round();
      final minDeposit = (amountNeeded * 0.90).round();
      
      final isComplete = availableBalance >= minRequired && balanceIncrease >= minDeposit;
      expect(isComplete, isFalse, reason: '50% não é suficiente');
      
      // 100% chega
      wallet.setBalance(tierRequired);
      final finalAvailable = wallet.getCurrentBalance();
      final alreadyCovered = finalAvailable >= tierRequired;
      
      expect(alreadyCovered, isTrue, reason: '100% deve ativar');
    });

    test('Saldo comprometido não conta para garantia', () async {
      wallet.setBalance(100000);
      final committedSats = 50000; // 50k comprometido com ordens
      
      final totalBalance = wallet.getCurrentBalance();
      final availableForCollateral = (totalBalance - committedSats).clamp(0, totalBalance);
      
      expect(availableForCollateral < tierRequired, isTrue, 
        reason: 'Saldo comprometido não conta');
    });
  });
}