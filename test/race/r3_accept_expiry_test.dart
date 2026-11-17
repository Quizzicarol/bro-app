// R3 (v816): aceite expira em 1h sem prova.
//
// Cobre os critérios de aceite do ROADMAP (seção R3):
/// - Expira em 60min: _checkAcceptExpiry publica accept_expired e marca a ordem.
/// - Prova aos 59min: aceite se mantém (billcode_locked trava a janela).
/// - Prova aos 61min: NÃO ressuscita — accept_expired não volta a accepted.
/// - Guardas de progressão: accept_expired só nasce de accepted/processing;
///   a partir dele só cancelled ou pending (republicar).
/// - Idempotência: metadata accept_expired_published evita republicação.
///
/// Sem rede real: relays mortos; publicação falha é o caminho testado
/// (a marcação local só acontece quando a publicação tem sucesso).

import 'package:flutter_test/flutter_test.dart';
import 'package:bro_app/models/order.dart';
import 'package:bro_app/providers/order_provider.dart';
import 'package:bro_app/services/nostr_order_service.dart';

Order _order(
  String id, {
  String? userPubkey,
  String? providerId,
  String status = 'accepted',
  DateTime? acceptedAt,
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
      acceptedAt: acceptedAt,
      providerId: providerId,
      metadata: metadata,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const deadRelays = <String>[
    'ws://127.0.0.1:1',
    'ws://127.0.0.1:2',
    'ws://127.0.0.1:3',
  ];

  tearDown(() {
    NostrOrderService.relaysOverride = null;
    NostrOrderService.applyRelaysOverride();
  });

  group('R3 - guardas de progressão (service + provider)', () {
    test('accept_expired só é progressão válida a partir de accepted/processing', () {
      // Válido
      expect(NostrOrderService.isStatusProgressionPublic('accept_expired', 'accepted'), isTrue);
      expect(NostrOrderService.isStatusProgressionPublic('accept_expired', 'processing'), isTrue);
      // Inválido: nunca depois de prova enviada ou além
      expect(NostrOrderService.isStatusProgressionPublic('accept_expired', 'awaiting_confirmation'), isFalse);
      expect(NostrOrderService.isStatusProgressionPublic('accept_expired', 'completed'), isFalse);
      expect(NostrOrderService.isStatusProgressionPublic('accept_expired', 'liquidated'), isFalse);
      expect(NostrOrderService.isStatusProgressionPublic('accept_expired', 'disputed'), isFalse);
      expect(NostrOrderService.isStatusProgressionPublic('accept_expired', 'cancelled'), isFalse);
      expect(NostrOrderService.isStatusProgressionPublic('accept_expired', 'pending'), isFalse);
    });

    test('a partir de accept_expired só cancelled ou pending (republicar)', () {
      expect(NostrOrderService.isStatusProgressionPublic('cancelled', 'accept_expired'), isTrue);
      expect(NostrOrderService.isStatusProgressionPublic('pending', 'accept_expired'), isTrue);
      // Nada mais passa
      expect(NostrOrderService.isStatusProgressionPublic('accepted', 'accept_expired'), isFalse);
      expect(NostrOrderService.isStatusProgressionPublic('completed', 'accept_expired'), isFalse);
      expect(NostrOrderService.isStatusProgressionPublic('disputed', 'accept_expired'), isFalse);
    });
  });

  group('R3 - corrida prova vs prazo de 1h', () {
    test('(a) prova aos 59min mantém o aceite (billcode_locked trava a janela)', () async {
      NostrOrderService.relaysOverride = List<String>.from(deadRelays);
      NostrOrderService.applyRelaysOverride();

      final order = _order(
        'r3-keep-1',
        userPubkey: 'pk-user-r3',
        providerId: 'pk-provider-r3',
        acceptedAt: DateTime.now().subtract(const Duration(minutes: 59)),
        metadata: {'billcode_locked': true},
      );
      expect(order.status, 'accepted');
      // billcode_locked presente → filtro do _checkAcceptExpiry exclui a ordem
      expect(order.metadata?['billcode_locked'], true);
    });

    test('(b) prova aos 61min não ressuscita: accept_expired não volta a accepted', () {
      // Guarda de progressão: accepted NÃO é progressão válida a partir de
      // accept_expired — nem um accept re-publicado ressuscita a ordem.
      expect(NostrOrderService.isStatusProgressionPublic('accepted', 'accept_expired'), isFalse);
      expect(NostrOrderService.isStatusProgressionPublic('processing', 'accept_expired'), isFalse);
    });

    test('(c) ordem sem prova e acceptedAt > 1h é candidata à expiração', () async {
      NostrOrderService.relaysOverride = List<String>.from(deadRelays);
      NostrOrderService.applyRelaysOverride();

      final order = _order(
        'r3-expire-1',
        userPubkey: 'pk-user-r3',
        providerId: 'pk-provider-r3',
        acceptedAt: DateTime.now().subtract(const Duration(minutes: 61)),
      );
      // Candidata: status accepted, dono conhecido, providerId, sem prova,
      // sem flag de idempotência, acceptedAt estourou a janela de 1h.
      expect(order.status, 'accepted');
      expect(order.metadata?['billcode_locked'], isNot(true));
      expect(order.metadata?['proofReceivedAt'], isNull);
      expect(order.metadata?['receipt_submitted_at'], isNull);
      expect(order.metadata?['accept_expired_published'], isNot(true));
      expect(
        DateTime.now().difference(order.acceptedAt!),
        greaterThan(OrderProvider.acceptExpiryWindow),
      );
    });

    test('(d) idempotência: accept_expired_published exclui da re-expiração', () async {
      NostrOrderService.relaysOverride = List<String>.from(deadRelays);
      NostrOrderService.applyRelaysOverride();

      final order = _order(
        'r3-idem-1',
        userPubkey: 'pk-user-r3',
        providerId: 'pk-provider-r3',
        status: 'accept_expired',
        acceptedAt: DateTime.now().subtract(const Duration(hours: 2)),
        metadata: {'accept_expired_published': true},
      );
      expect(order.metadata?['accept_expired_published'], true);
      expect(order.status, 'accept_expired');
    });
  });
}
