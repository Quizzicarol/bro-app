import 'package:bro_app/services/nostr_order_service.dart';
import 'package:flutter_test/flutter_test.dart';

const orderId = '4e2c858a';
const canonical = '6ac7f189';
const buyer = 'buyer-pubkey';
const expiredAt = 1763749572; // 2026-11-21 14:26:12 UTC-3
const completeAt = 1763749588; // 2026-11-21 14:26:28 UTC-3

Map<String, dynamic> event({
  required int kind,
  required String author,
  required int createdAt,
  required Map<String, dynamic> content,
}) =>
    {
      'id': '$kind-$author-$createdAt-${content['status']}',
      'kind': kind,
      'pubkey': author,
      'created_at': createdAt,
      'parsedContent': {
        'orderId': orderId,
        'providerId': canonical,
        ...content,
      },
    };

Map<String, dynamic> accept({
  String author = canonical,
  int createdAt = 1763749500,
  String? acceptedAt,
}) =>
    event(
      kind: 30079,
      author: author,
      createdAt: createdAt,
      content: {
        'type': 'bro_accept',
        'status': 'accepted',
        'providerId': author,
        if (acceptedAt != null) 'acceptedAt': acceptedAt,
      },
    );

Map<String, dynamic> expired({int createdAt = expiredAt}) => event(
      kind: 30080,
      author: buyer,
      createdAt: createdAt,
      content: {'type': 'bro_order_update', 'status': 'accept_expired'},
    );

Map<String, dynamic> complete({
  String author = canonical,
  int createdAt = completeAt,
}) =>
    event(
      kind: 30081,
      author: author,
      createdAt: createdAt,
      content: {
        'type': 'bro_complete',
        'providerId': author,
        'status': 'awaiting_confirmation',
        'proofImage': 'proof-image',
        'proofImage_nip44': 'encrypted-proof',
        'providerInvoice': 'provider-invoice',
        'completedAt': '2026-11-21T14:26:28.000',
      },
    );

Map<String, dynamic> status(
  String value, {
  int createdAt = completeAt + 20,
}) =>
    event(
      kind: 30080,
      author: buyer,
      createdAt: createdAt,
      content: {
        'type': value == 'disputed' ? 'bro_dispute_resolution' : 'bro_order_update',
        'status': value,
      },
    );

Map<String, dynamic> select(List<Map<String, dynamic>> events) =>
    NostrOrderService.selectOrderUpdatesForUser(
      events,
      activeOrderIdSet: {orderId},
      userPubkey: buyer,
    )[orderId]!;

void main() {
  test('4e2c858a: complete anterior supera accept_expired posterior', () {
    for (final events in [
      [expired(), complete(), accept()],
      [accept(), complete(), expired()],
    ]) {
      final update = select(events);
      expect(update['status'], 'awaiting_confirmation');
      expect(update['providerId'], canonical);
      expect(update['proofAuthorPubkey'], canonical);
      expect(update['proofImage'], 'proof-image');
      expect(update['proofImage_nip44'], 'encrypted-proof');
      expect(update['providerInvoice'], 'provider-invoice');
    }
  });

  test('autor errado não supera accept_expired', () {
    final update = select([accept(), expired(), complete(author: 'attacker')]);
    expect(update['status'], 'accept_expired');
    expect(update['providerId'], canonical);
  });

  test('accepted antigo não supera accept_expired', () {
    final update = select([expired(), accept(createdAt: expiredAt - 60)]);
    expect(update['status'], 'accept_expired');
  });

  test('completed e cancelled não regridem para prova tardia', () {
    for (final terminal in ['completed', 'cancelled']) {
      final update = select([
        accept(),
        status(terminal, createdAt: completeAt - 20),
        complete(),
      ]);
      expect(update['status'], terminal, reason: update.toString());
    }
  });

  test('4e2c858a: eventos sem prova não apagam recuperação nem regridem completed', () {
    final recovered = select([
      expired(),
      complete(),
      accept(),
      status('completed', createdAt: completeAt + 10),
      status('awaiting_confirmation', createdAt: completeAt + 20),
    ]);

    expect(recovered['status'], 'completed');
    expect(recovered['providerId'], canonical);
    expect(recovered['proofAuthorPubkey'], canonical);
    expect(recovered['proofImage'], 'proof-image');
    expect(recovered['proofImage_nip44'], 'encrypted-proof');
    expect(recovered['providerInvoice'], 'provider-invoice');

    final completedWithoutProofFirst = select([
      status('completed', createdAt: completeAt + 10),
      expired(),
      complete(),
      status('awaiting_confirmation', createdAt: completeAt + 20),
      accept(),
    ]);

    expect(completedWithoutProofFirst['status'], 'completed');
    expect(completedWithoutProofFirst['providerId'], canonical);
    expect(completedWithoutProofFirst['proofAuthorPubkey'], canonical);
    expect(completedWithoutProofFirst['proofImage'], 'proof-image');
    expect(completedWithoutProofFirst['proofImage_nip44'], 'encrypted-proof');
    expect(completedWithoutProofFirst['providerInvoice'], 'provider-invoice');
    expect(completedWithoutProofFirst['completedAt'], '2026-11-21T14:26:28.000');
  });

  test('aceite canônico usa acceptedAt imutável, não a ordem de iteração', () {
    final older = accept(
      author: 'provider-older',
      createdAt: expiredAt - 100,
      acceptedAt: '2026-11-21T14:20:00.000',
    );
    final newer = accept(
      author: 'provider-newer',
      createdAt: expiredAt - 50,
      acceptedAt: '2026-11-21T14:25:00.000',
    );
    for (final events in [
      [older, newer, expired(), complete(author: 'provider-older')],
      [newer, older, expired(), complete(author: 'provider-older')],
    ]) {
      final update = select(events);
      expect(update['status'], 'awaiting_confirmation');
      expect(update['providerId'], 'provider-older');
      expect(update['proofAuthorPubkey'], 'provider-older');
    }
  });

  test('acceptedAt divergente do relay não rouba a canonicalidade', () {
    final genuine = accept(
      author: 'provider-genuine',
      createdAt: expiredAt - 100,
      acceptedAt: '2026-11-21T14:20:00.000',
    );
    final wrongClock = accept(
      author: 'provider-wrong-clock',
      createdAt: expiredAt - 50,
      acceptedAt: '2020-01-01T00:00:00.000',
    );
    final update = select([
      genuine,
      wrongClock,
      expired(),
      complete(author: 'provider-genuine'),
    ]);
    expect(update['status'], 'awaiting_confirmation');
    expect(update['providerId'], 'provider-genuine');
  });

  test('cancelled permite disputed posterior, mas não prova tardia', () {
    final update = select([
      accept(),
      status('cancelled', createdAt: completeAt - 20),
      complete(),
      status('disputed', createdAt: completeAt + 20),
    ]);
    expect(update['status'], 'disputed');
  });

  test('disputed antigo não sobrescreve cancelled mais recente', () {
    final update = select([
      accept(),
      status('disputed', createdAt: completeAt - 20),
      status('cancelled', createdAt: completeAt + 20),
    ]);
    expect(update['status'], 'cancelled');
  });
}
