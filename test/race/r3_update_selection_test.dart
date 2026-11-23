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

Map<String, dynamic> expired({
  int createdAt = expiredAt,
  String providerId = canonical,
}) =>
    event(
      kind: 30080,
      author: buyer,
      createdAt: createdAt,
      content: {
        'type': 'bro_order_update',
        'status': 'accept_expired',
        'providerId': providerId,
      },
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
  test('complete anterior à expiração permanece; tardio não recupera', () {
    final beforeExpiry = select([accept(), complete(), expired()]);
    expect(beforeExpiry['status'], 'awaiting_confirmation');
    expect(beforeExpiry['providerId'], canonical);
    expect(beforeExpiry['proofImage'], 'proof-image');

    for (final events in [
      [expired(), complete(), accept()],
      [accept(), expired(), complete()],
    ]) {
      final update = select(events);
      expect(update['status'], 'accept_expired');
      expect(update['providerId'], canonical);
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

  test('eventos sem prova não apagam prova anterior nem regridem completed', () {
    final completed = select([
      accept(),
      complete(),
      status('completed', createdAt: completeAt + 10),
      status('awaiting_confirmation', createdAt: completeAt + 20),
      expired(createdAt: completeAt + 30),
    ]);

    expect(completed['status'], 'completed');
    expect(completed['providerId'], canonical);
    expect(completed['proofAuthorPubkey'], canonical);
    expect(completed['proofImage'], 'proof-image');
    expect(completed['proofImage_nip44'], 'encrypted-proof');
    expect(completed['providerInvoice'], 'provider-invoice');
    expect(completed['completedAt'], '2026-11-21T14:26:28.000');
  });

  test('aceite canônico é determinístico e prova tardia não recupera', () {
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
      [older, newer, expired(providerId: 'provider-older'), complete(author: 'provider-older')],
      [newer, older, expired(providerId: 'provider-older'), complete(author: 'provider-older')],
    ]) {
      final update = select(events);
      expect(update['status'], 'accept_expired');
      expect(update['providerId'], 'provider-older');
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
      expired(providerId: 'provider-genuine'),
      complete(author: 'provider-genuine'),
    ]);
    expect(update['status'], 'accept_expired');
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
