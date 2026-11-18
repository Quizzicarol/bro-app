/// v820e: ProviderPaymentGuard.clearPaid — self-heal da flag 'paga' sem
/// evidência de envio liquidado (falso-positivo que completava a ordem sem
/// pagar o provedor — caso 98bc3e84, 17/11).

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bro_app/services/provider_payment_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('markPaid persiste e clearPaid limpa (inclusive entre sessões)', () async {
    SharedPreferences.setMockInitialValues({});
    await ProviderPaymentGuard.initialize();

    expect(ProviderPaymentGuard.isPaid('ordem-x'), isFalse);

    await ProviderPaymentGuard.markPaid('ordem-x', paymentHash: 'hash123');
    expect(ProviderPaymentGuard.isPaid('ordem-x'), isTrue);
    expect(ProviderPaymentGuard.attemptHashFor('ordem-x'), 'hash123');

    // flag sem evidência settled → o chamador limpa (v820e)
    await ProviderPaymentGuard.clearPaid('ordem-x');
    expect(ProviderPaymentGuard.isPaid('ordem-x'), isFalse);

    // sobrevive "restart": re-inicializar lê do SharedPreferences
    await ProviderPaymentGuard.initialize();
    expect(ProviderPaymentGuard.isPaid('ordem-x'), isFalse,
        reason: 'flag limpa não pode ressuscitar num boot novo');

    // clearPaid de ordem não-marcada é no-op seguro
    await ProviderPaymentGuard.clearPaid('ordem-inexistente');
    expect(ProviderPaymentGuard.isPaid('ordem-inexistente'), isFalse);
  });

  test('markPaid de verdade NÃO deve ser afetado por clearPaid de outra ordem', () async {
    SharedPreferences.setMockInitialValues({});
    await ProviderPaymentGuard.initialize();

    await ProviderPaymentGuard.markPaid('ordem-a');
    await ProviderPaymentGuard.markPaid('ordem-b');
    await ProviderPaymentGuard.clearPaid('ordem-a');

    expect(ProviderPaymentGuard.isPaid('ordem-a'), isFalse);
    expect(ProviderPaymentGuard.isPaid('ordem-b'), isTrue);
  });
}
