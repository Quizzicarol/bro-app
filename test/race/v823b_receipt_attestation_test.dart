/// v823b: atestado de recebimento do provedor — o filtro de candidatas.
///
/// Nasceu do caso 98bc3e84 (17/11): o provedor trabalhou, o pagamento ficou
/// em dúvida e NINGUÉM conseguia verificar a entrega (pagamento Lightning é
/// privado por design). Com o recibo assinado no relay + o preimage do
/// comprador, a entrega passa a ser verificável sem perguntar a ninguém.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bro_app/models/order.dart';
import 'package:bro_app/providers/order_provider.dart';

Order _order(
  String id, {
  String? userPubkey,
  String? providerId,
  String status = 'completed',
  Map<String, dynamic>? metadata,
}) =>
    Order(
      id: id,
      userPubkey: userPubkey,
      billType: 'pix',
      billCode: 'CODE-$id',
      amount: 50.0,
      btcAmount: 0.0001,
      btcPrice: 500000.0,
      providerFee: 1.0,
      platformFee: 1.0,
      total: 52.0,
      status: status,
      createdAt: DateTime.now(),
      providerId: providerId,
      metadata: metadata,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('v823b: candidatas ao recibo = minhas como provedor + hash da invoice + ainda não publicado', () {
    final provider = OrderProvider();
    provider.debugSetCurrentUserPubkeyForR5c('pk-provider');
    provider.debugSeedOrdersForR5c([
      _order('v823b-match',
          providerId: 'pk-provider',
          metadata: {'providerInvoiceHash': 'hash123'}),
      _order('v823b-outra-hash',
          providerId: 'pk-provider',
          metadata: {'providerInvoiceHash': 'hash999'}),
      _order('v823b-nao-minha',
          userPubkey: 'pk-provider',
          providerId: 'pk-outro',
          metadata: {'providerInvoiceHash': 'hash123'}),
      _order('v823b-ja-publicada',
          providerId: 'pk-provider',
          metadata: {
            'providerInvoiceHash': 'hash123',
            'paymentReceiptPublished': true,
          }),
      _order('v823b-sem-hash', providerId: 'pk-provider'),
    ]);

    final ids = provider.debugAttestableOrdersForV823b('hash123');

    expect(ids, ['v823b-match'],
        reason: 'só a ordem que é minha como provedor, com o hash casando e sem recibo publicado');
  });

  test('v823b: setProviderInvoiceHash grava e ativa a candidatura', () async {
    SharedPreferences.setMockInitialValues({});
    final provider = OrderProvider();
    provider.debugSetCurrentUserPubkeyForR5c('pk-provider');
    provider.debugSeedOrdersForR5c([
      // userPubkey preenchido: o getter `orders` precisa enxergar a ordem
      // como "minha como provedor" (compra do pk-buyer, eu sou o Bro).
      _order('v823b-late', userPubkey: 'pk-buyer', providerId: 'pk-provider'),
    ]);

    expect(provider.debugAttestableOrdersForV823b('hashABC'), isEmpty,
        reason: 'sem hash gravado, não tem como casar');

    try {
      await provider.setProviderInvoiceHash('v823b-late', 'hashABC');
    } catch (_) {
      // os plugins de storage não existem em teste (MissingPluginException no
      // _saveOrders) — o estado em MEMÓRIA é o que este teste verifica; no
      // aparelho o save funciona.
    }

    expect(provider.debugAttestableOrdersForV823b('hashABC'), ['v823b-late'],
        reason: 'hash gravado → a ordem fica atestável');
    final o = provider.orders.firstWhere((o) => o.id == 'v823b-late');
    expect(o.metadata?['providerInvoiceHash'], 'hashABC');
  });
}
