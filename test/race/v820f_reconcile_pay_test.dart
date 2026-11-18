/// v820f: reconciliador de ordens 'completed' sem pagamento liquidado.
///
/// Caso-âncora 98bc3e84 (17/11): o app do usuário marcou completed sem os
/// sats saírem (falso-positivo do guarda) e o provedor canônico — que tinha
/// pago o Pix de verdade — ficou sem receber. A dona da regra: "completou
/// sem pagar o provedor → paga sozinho, sem gasto duplo".
///
/// Aqui testamos o FILTRO de candidatas (quem entra/sai da reconciliação).

import 'package:flutter_test/flutter_test.dart';
import 'package:bro_app/models/order.dart';
import 'package:bro_app/providers/order_provider.dart';

Order _order(
  String id, {
  String? userPubkey,
  String? providerId,
  String status = 'accepted',
  DateTime? createdAt,
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
      createdAt: createdAt ?? DateTime.now(),
      providerId: providerId,
      metadata: metadata,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('v820f: candidatas = completed minhas, recentes, sem marca de pagamento', () {
    final provider = OrderProvider();
    provider.debugSetCurrentUserPubkeyForR5c('pk-me');
    provider.debugSeedOrdersForR5c([
      _order('v820f-alvo', userPubkey: 'pk-me', status: 'completed'),
      _order('v820f-nao-concluida', userPubkey: 'pk-me', status: 'accepted'),
      _order('v820f-ja-paga',
          userPubkey: 'pk-me',
          status: 'completed',
          metadata: {'providerPaidAt': DateTime.now().toIso8601String()}),
      _order('v820f-disputa',
          userPubkey: 'pk-me',
          status: 'completed',
          metadata: {'wasDisputed': true}),
      _order('v820f-antiga',
          userPubkey: 'pk-me',
          status: 'completed',
          createdAt: DateTime.now().subtract(const Duration(days: 6))),
      _order('v820f-de-outro', userPubkey: 'pk-outro', status: 'completed'),
      _order('v820f-cooldown',
          userPubkey: 'pk-me',
          status: 'completed',
          metadata: {
            'reconcilePaymentLastAttempt': DateTime.now().toIso8601String(),
          }),
    ]);

    final ids = provider.debugComputeReconcilePayCandidatesForV820f();

    expect(ids, contains('v820f-alvo'),
        reason: 'completed minha e recente sem marca de pagamento ENTRA');
    expect(ids, isNot(contains('v820f-nao-concluida')),
        reason: 'accepted não é completed');
    expect(ids, isNot(contains('v820f-ja-paga')),
        reason: 'já marcada como paga não repaga');
    expect(ids, isNot(contains('v820f-disputa')),
        reason: 'disputa tem pagadores próprios (winner/reembolso)');
    expect(ids, isNot(contains('v820f-antiga')),
        reason: 'fora da janela de 5 dias → mediação, não autopay (anti dupla cobrança v622)');
    expect(ids, isNot(contains('v820f-de-outro')),
        reason: 'só ordens MINHAS');
    expect(ids, isNot(contains('v820f-cooldown')),
        reason: 'cooldown de 10min entre tentativas');
  });

  test('v820f: cooldown expirado volta a candidatar', () {
    final provider = OrderProvider();
    provider.debugSetCurrentUserPubkeyForR5c('pk-me');
    provider.debugSeedOrdersForR5c([
      _order('v820f-cooldown-ok',
          userPubkey: 'pk-me',
          status: 'completed',
          metadata: {
            'reconcilePaymentLastAttempt':
                DateTime.now().subtract(const Duration(minutes: 11)).toIso8601String(),
          }),
    ]);

    final ids = provider.debugComputeReconcilePayCandidatesForV820f();
    expect(ids, contains('v820f-cooldown-ok'),
        reason: 'passado o cooldown, tenta de novo (pagamento em pendência liquida ou falha)');
  });
}
