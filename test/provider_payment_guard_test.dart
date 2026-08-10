// Testa a guarda anti gasto-duplo do pagamento ao provedor (v634).
//
// Invariante central: o comprador paga NO MÁXIMO uma vez por ordem, mesmo que
// a tela reabra, o status regrida (bro_republish_request) ou o app reinicie.
//
// Cobre:
//   1. Ordem "nova" não está paga; após markPaid fica paga e PERSISTE num restart.
//   2. tryAcquire dá lock exclusivo; segundo tryAcquire falha até release/markPaid.
//   3. release permite nova tentativa legítima após falha.
//   4. isPaid bloqueia tryAcquire (não paga de novo).
//   5. recordAttempt/attemptHashFor guardam o hash tentado (para re-checagem).

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bro_app/services/provider_payment_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const orderA = 'aaaa1111-0000-0000-0000-000000000000';
  const orderB = 'bbbb2222-0000-0000-0000-000000000000';

  setUp(() async {
    // Storage limpo + reload da guarda (zera sets em memória).
    SharedPreferences.setMockInitialValues({});
    await ProviderPaymentGuard.initialize();
  });

  test('ordem nova não está paga', () {
    expect(ProviderPaymentGuard.isPaid(orderA), isFalse);
    expect(ProviderPaymentGuard.attemptHashFor(orderA), isNull);
  });

  test('markPaid marca como paga e PERSISTE após restart (re-initialize)', () async {
    expect(ProviderPaymentGuard.isPaid(orderA), isFalse);
    await ProviderPaymentGuard.markPaid(orderA, paymentHash: 'hashA');
    expect(ProviderPaymentGuard.isPaid(orderA), isTrue);
    expect(ProviderPaymentGuard.attemptHashFor(orderA), 'hashA');

    // Simula reinício do app: recarrega do storage.
    await ProviderPaymentGuard.initialize();
    expect(ProviderPaymentGuard.isPaid(orderA), isTrue,
        reason: 'guarda deve sobreviver a restart — este é o cerne do fix');
    expect(ProviderPaymentGuard.attemptHashFor(orderA), 'hashA');
  });

  test('tryAcquire dá lock exclusivo dentro da sessão', () {
    expect(ProviderPaymentGuard.tryAcquire(orderA), isTrue);
    // Segundo acquire concorrente falha (evita duplo-pagamento na mesma sessão).
    expect(ProviderPaymentGuard.tryAcquire(orderA), isFalse);
    // Outra ordem não é afetada.
    expect(ProviderPaymentGuard.tryAcquire(orderB), isTrue);
  });

  test('release permite nova tentativa legítima após falha', () {
    expect(ProviderPaymentGuard.tryAcquire(orderA), isTrue);
    ProviderPaymentGuard.release(orderA);
    // Após falha + release, a ordem pode ser tentada de novo (não ficou paga).
    expect(ProviderPaymentGuard.isPaid(orderA), isFalse);
    expect(ProviderPaymentGuard.tryAcquire(orderA), isTrue);
  });

  test('isPaid bloqueia tryAcquire (nunca paga de novo)', () async {
    await ProviderPaymentGuard.markPaid(orderA);
    // Já pago → não adquire lock → fluxo de pagamento é pulado.
    expect(ProviderPaymentGuard.tryAcquire(orderA), isFalse);
  });

  test('markPaid libera o lock de pagamento', () async {
    expect(ProviderPaymentGuard.tryAcquire(orderA), isTrue);
    await ProviderPaymentGuard.markPaid(orderA);
    expect(ProviderPaymentGuard.isPaid(orderA), isTrue);
    // Novo acquire falha porque já está pago (não porque o lock vazou).
    expect(ProviderPaymentGuard.tryAcquire(orderA), isFalse);
  });

  test('recordAttempt guarda e persiste o hash tentado', () async {
    await ProviderPaymentGuard.recordAttempt(orderA, 'pendingHash');
    expect(ProviderPaymentGuard.attemptHashFor(orderA), 'pendingHash');
    // Persiste após restart (permite re-checar o status daquele hash).
    await ProviderPaymentGuard.initialize();
    expect(ProviderPaymentGuard.attemptHashFor(orderA), 'pendingHash');
  });

  test('cenário do bug 884e7ad9: 2ª confirmação após revert NÃO paga de novo', () async {
    // 1ª confirmação (manhã): adquire lock, paga, marca.
    expect(ProviderPaymentGuard.tryAcquire(orderA), isTrue);
    await ProviderPaymentGuard.markPaid(orderA, paymentHash: 'morningHash');

    // Provedor manda bro_republish_request → status regride → app reinicia.
    await ProviderPaymentGuard.initialize();

    // 2ª confirmação (tarde): botão reapareceu, usuário aperta de novo.
    expect(ProviderPaymentGuard.isPaid(orderA), isTrue,
        reason: 'a guarda persistente deve bloquear o 2º pagamento');
    expect(ProviderPaymentGuard.tryAcquire(orderA), isFalse,
        reason: 'sem lock → o fluxo pula o pagamento e apenas finaliza a ordem');
  });
}
