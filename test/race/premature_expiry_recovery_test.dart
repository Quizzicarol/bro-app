import 'package:bro_app/services/nostr_order_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const orderId = '90800cdf-541e-457c-bf93-daa6fd17c1ec';
  const buyer = '0b31181f021539d1afcda76e66577d5a7797a9603ac4a7aa46514745c8acfc26';
  const provider = '345cbfb6c2f9be6bcca057ef1edcbb6d5934330f10d87abb4171f5fd84c8f51f';

  Map<String, dynamic> event({
    required int kind,
    required String author,
    required int createdAt,
    required Map<String, dynamic> content,
  }) =>
      {
        'id': '$kind-$createdAt-${content['status']}',
        'kind': kind,
        'pubkey': author,
        'created_at': createdAt,
        'parsedContent': {'orderId': orderId, ...content},
      };

  final accept = event(
    kind: 30079,
    author: provider,
    createdAt: 1795468712, // 2026-11-23T21:18:32Z
    content: {
      'type': 'bro_accept',
      'providerId': provider,
      'acceptedAt': '2026-11-23T18:18:32.792536-03:00',
    },
  );

  Map<String, dynamic> expiry({
    String expiredAt = '2026-11-23T21:21:10.765946Z',
    String acceptedAt = '2026-11-23T20:18:41.638537Z', // UTC explícito
  }) =>
      event(
        kind: 30080,
        author: buyer,
        createdAt: 1795468870,
        content: {
          'type': 'bro_order_update',
          'status': 'accept_expired',
          'providerId': provider,
          'expiredAt': expiredAt,
          'expiredAcceptAt': acceptedAt,
        },
      );

  final complete = event(
    kind: 30081,
    author: provider,
    createdAt: 1795468967,
    content: {
      'type': 'bro_complete',
      'providerId': provider,
      'proofImage_nip44': 'encrypted-proof',
      'providerInvoice': 'provider-invoice',
    },
  );

  test('detecta aceite canônico recente apesar do aceite com relógio errado', () {
    Map<String, dynamic> content(Map<String, dynamic> event) =>
        Map<String, dynamic>.from(event['parsedContent'] as Map);
    expect(
      NostrOrderService.hasRecentCanonicalAcceptForExpiry(
        [accept],
        content(expiry()),
        1795468870,
      ),
      isTrue,
    );
    expect(
      NostrOrderService.hasRecentCanonicalAcceptForExpiry(
        [accept],
        content(
          expiry(
            expiredAt: '2026-11-23T22:00:00.000000Z',
            acceptedAt: '2026-11-23T18:18:32.792536-03:00',
          ),
        ),
        1795468870,
      ),
      isFalse,
    );
  });

  test('comprovante canônico prevalece sobre expiração prematura', () {
    final updates = NostrOrderService.selectOrderUpdatesForUserEvents(
      [accept, expiry(), complete],
      activeOrderIdSet: {orderId},
      userPubkey: buyer,
    );
    final update = updates[orderId]!;
    expect(update['status'], 'awaiting_confirmation');
    expect(update['providerId'], provider);
    expect(update['proofImage_nip44'], 'encrypted-proof');
    expect(update['status'], isNot('completed'));
  });

  test('expiração válida não recebe marcação de recuperação indevida', () {
    final validExpiry = expiry(
      expiredAt: '2026-11-23T22:00:00.000000Z',
      acceptedAt: '2026-11-23T18:18:32.792536-03:00',
    );
    expect(
      NostrOrderService.hasRecentCanonicalAcceptForExpiry(
        [accept],
        Map<String, dynamic>.from(validExpiry['parsedContent'] as Map),
        1795468870,
      ),
      isFalse,
    );
    final updates = NostrOrderService.selectOrderUpdatesForUserEvents(
      [accept, validExpiry, complete],
      activeOrderIdSet: {orderId},
      userPubkey: buyer,
    );
    expect(updates[orderId]?['recoveredFromPrematureExpiry'], isNull);
  });
}
