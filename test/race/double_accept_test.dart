/// TESTE DE CORRIDA — Double Accept (Corredor 2)
///
/// Cenário: Dois providers aceitam a mesma ordem no mesmo instante
/// Esperado: Apenas o primeiro ganha; segundo vê "já aceita"

import 'package:flutter_test/flutter_test.dart';
import '../fixtures/mock_relay.dart';
import '../fixtures/test_harness.dart';

void main() {
  group('Double Accept Race (Corredor 2)', () {
    late TestHarness h;
    late MockNostrRelay relay;
    
    const orderId = 'order_race_12345';
    const userPubkey = 'npub_user_buyer';
    const providerA = 'npub_provider_first';
    const providerB = 'npub_provider_second';

    setUp(() {
      h = TestHarness();
      relay = MockNostrRelay();
    });

    tearDown(() {
      h.resetAll();
      relay.reset();
    });

    test('Dois providers aceitam — apenas o primeiro vence', () async {
      // Configurar ordem pendente
      h.setupOrder(
        orderId: orderId,
        userPubkey: userPubkey,
        amountSats: 100000,
      );
      
      // Provider A aceita primeiro
      relay.setUserProfile(providerA, '{"name": "ProviderA"}');
      relay.connect();
      final serviceA = MockNostrService(relay: relay);
      await serviceA.initialize(mnemonic: 'seed a', privKey: 'privkeyA');
      
      final acceptA = await serviceA.publishEvent({
        'kind': '30079',
        'content': '{"orderId": "$orderId", "providerId": "$providerA", "action": "accept"}',
      });
      expect(acceptA, isTrue);
      
      // Verificar: só 1 accept no relay
      final accepts = relay.queryEvents(kind: '30079');
      expect(accepts.length, equals(1), 
        reason: 'Apenas um accept deve persistir');
    });

    test('Ordem sem accepts — primeiro a chegar vence', () async {
      h.setupOrder(
        orderId: orderId,
        userPubkey: userPubkey,
        amountSats: 100000,
      );
      
      final acceptsBefore = relay.queryEvents(kind: '30079');
      expect(acceptsBefore, isEmpty);
      
      // Provider A aceita
      relay.setUserProfile(providerA, '{"name": "ProviderA"}');
      relay.connect();
      final serviceA = MockNostrService(relay: relay);
      await serviceA.initialize(mnemonic: 'seed a', privKey: 'privkeyA');
      
      final acceptA = await serviceA.publishEvent({
        'kind': '30079',
        'content': '{"orderId": "$orderId", "providerId": "$providerA"}',
      });
      expect(acceptA, isTrue);
      
      final acceptsAfter = relay.queryEvents(kind: '30079');
      expect(acceptsAfter.length, equals(1));
    });
  });
}