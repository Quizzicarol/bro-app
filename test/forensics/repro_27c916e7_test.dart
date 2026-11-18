/// FORENSE 27c916e7 (17/11): usuário no build 817 (v813 presente) segue preso
/// na etapa "Bro paga a conta" — o complete do provedor (apexcord, #p vazio,
/// proofImage PLAINTEXT 59.8KB porque o userPubkey veio '' do snapshot R5b e
/// o NIP-44 caiu no fallback) não aparece pra ele.
///
/// Este teste aponta o NostrOrderService REAL para os relays REAIS e roda o
/// MESMO fetchOrderUpdatesForUser que o app dele roda, com o MESMO orderId.
/// Se o update voltar com awaiting_confirmation + proofImage, o caminho de
/// código está sadio e o problema é ambiental (rede/relays no aparelho dele).
/// Se NÃO voltar, o bug é de código e este teste é a repro mínima.
///
/// NÃO roda na suíte padrão (depende de rede real):
///   flutter test test/forensics/repro_27c916e7_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:bro_app/services/nostr_order_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    NostrOrderService.relaysOverride = null;
    NostrOrderService.applyRelaysOverride();
  });

  test('repro 27c916e7: complete #p-vazio plaintext aparece via #d nos relays reais', () async {
    const orderId = '27c916e7-887d-44fa-a90d-670287cb1a4b';
    const userPubkey =
        'e1af02582bbbcf83e3badad024884d4811303c06670e307ef7a0ee77d0b9a3b6';

    // Lista REAL do app (build 817) — mesma ordem de _relays + fallbacks.
    NostrOrderService.relaysOverride = const [
      'wss://apexcord.duckdns.org',
      'wss://bro-relay2.fly.dev',
      'wss://relay.primal.net',
      'wss://relay.damus.io',
      'wss://nos.lol',
      'wss://relay.nostr.band',
      'wss://nostr.mom',
    ];
    NostrOrderService.applyRelaysOverride();

    final sw = Stopwatch()..start();
    final updates = await NostrOrderService().fetchOrderUpdatesForUser(
      userPubkey,
      orderIds: const [orderId],
    );
    sw.stop();

    // ignore: avoid_print
    print('⏱️ fetch levou ${sw.elapsed.inMilliseconds}ms — updates: ${updates.keys}');

    expect(
      updates.containsKey(orderId),
      isTrue,
      reason: 'o complete (30081, #d=${orderId}_complete) EXISTE no apexcord '
          'e no bro-relay2 com assinatura válida — o fetch #d do v813 TEM que achar',
    );

    final u = updates[orderId]!;
    // ignore: avoid_print
    print('status=${u['status']} providerId=${(u['providerId'] as String?)?.substring(0, 8)} '
        'proofImage=${(u['proofImage'] as String?)?.length ?? 0} chars '
        'proofImage_nip44=${(u['proofImage_nip44'] as String?)?.length ?? 0} chars '
        'invoice=${(u['providerInvoice'] as String?)?.length ?? 0} chars');

    expect(u['status'], 'awaiting_confirmation');
    expect(
      (u['proofImage'] as String?)?.isNotEmpty ?? false,
      isTrue,
      reason: 'proofImage plaintext (fallback de criptografia) precisa sobreviver até o update',
    );
    expect((u['providerInvoice'] as String?)?.isNotEmpty ?? false, isTrue);
  }, timeout: const Timeout(Duration(seconds: 90)), skip: 'forense de 17/11: bate em relay REAL e a ordem real já foi concluída — estado de produção mudou, não é mais reproduzível. Rodar manual só com nova ordem-âncora.');
}
