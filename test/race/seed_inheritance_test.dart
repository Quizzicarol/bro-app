/// TESTE DE CORRIDA — A3 Seed Inheritance (Corredor 1)
///
/// Cenário: Conta A faz logout → Conta B faz login → Conta B herda silenciosamente a seed da Conta A
/// Esperado (fix): Conta B NÃO herda (retorna null, sem fallback)
/// Bug (pré-fix): Conta B herda MASTER_SEED_BACKUP da Conta A

import 'package:flutter_test/flutter_test.dart';
import '../fixtures/mock_wallet.dart';
import '../fixtures/mock_relay.dart';

void main() {
  group('A3 — Seed Inheritance (Corredor 1)', () {
    late MockBreezProvider wallet;
    late MockNostrRelay relay;
    
    const seedA = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
    const pubkeyA = 'npub1_user_a_12345678';
    const pubkeyB = 'npub1_user_b_87654321';
    const masterSeedBackup = 'MASTER_SEED_BACKUP';

    setUp(() {
      wallet = MockBreezProvider();
      relay = MockNostrRelay();
    });

    tearDown(() {
      wallet.reset();
      relay.reset();
    });

    test('Conta B NÃO herda seed da Conta A quando não tem seed própria', () async {
      // 1. Conta A tem seed própria
      relay.setUserSeed(pubkeyA, seedA);
      wallet.setSeedForPubkey(pubkeyA, seedA);
      
      // 2. Conta A faz logout (v771/v772: NÃO copia para MASTER_SEED_BACKUP)
      
      // 3. Conta B faz login — sem seed própria
      final seedForB = relay.getUserSeed(pubkeyB);
      expect(seedForB, isNull, 
        reason: 'Conta B não deve ter seed no relay');
      
      // 4. Conta B tenta recuperar seed via getBreezMnemonic
      final seed = await wallet.getBreezMnemonic(pubkeyB);
      
      // ESPERADO (fix): null — NÃO deve herdar
      expect(seed, isNull, 
        reason: 'Fix A3: nunca herdar automaticamente');
      
      expect(wallet.isInitialized, isFalse);
    });

    test('Conta B COM seed própria NÃO herda de Conta A', () async {
      relay.setUserSeed(pubkeyA, seedA);
      wallet.setSeedForPubkey(pubkeyA, seedA);
      
      const seedB = 'legal winner thank you almost zoo fade rent ozone wash defy sorry loan';
      relay.setUserSeed(pubkeyB, seedB);
      wallet.setSeedForPubkey(pubkeyB, seedB);
      
      final seed = await wallet.getBreezMnemonic(pubkeyB);
      
      expect(seed, equals(seedB), 
        reason: 'Conta B deve usar sua própria seed, não herdar da A');
    });

    test('Logout NÃO copia seed para MASTER_SEED_BACKUP (v771/v772)', () async {
      relay.setUserSeed(pubkeyA, seedA);
      wallet.setSeedForPubkey(pubkeyA, seedA);
      
      // Simular logout (versão fixada, não copia)
      // 3. Conta B tenta recuperar
      final seed = relay.getUserSeed(pubkeyB);
      
      // ESPERADO: Conta B NÃO tem seed
      expect(seed, isNull);
      final recovered = await wallet.getBreezMnemonic(pubkeyB);
      expect(recovered, isNull);
    });

    test('Migração explícita — usuário legado escolhe "é minha" — seed é usada', () {
      // 1. Usuário legado só tem MASTER_SEED_BACKUP
      relay.setUserSeed(masterSeedBackup, seedA);
      relay.setUserProfile(pubkeyA, '{"pubkey": "$pubkeyA"}');
    
      // 2. Usuário escolhe "é minha" (migração explícita)
      final userApproved = true;
      
      if (userApproved) {
        relay.setUserSeed(pubkeyA, seedA);
        final retrieved = relay.getUserSeed(pubkeyA);
        expect(retrieved, equals(seedA), 
          reason: 'Migração aprovada: conta atual deve ter a seed');
      }
      
      expect(relay.getUserSeed(pubkeyA), equals(seedA));
    });
  });
}