// R3 (v816): aceite expira em 1h sem prova.
//
// Cobre os critérios de aceite do ROADMAP (seção R3):
/// - Expira em 60min: _checkAcceptExpiry publica accept_expired e marca a ordem.
/// - Prova aos 59min: aceite se mantém (billcode_locked trava a janela).
/// - Prova tardia não recupera: comprador republica ou cancela; provedor não disputa.
/// - Guardas de progressão: accept_expired só nasce de accepted/processing;
///   sem prova, a partir dele só cancelled ou pending (republicar).
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
    test(
        'accept_expired só é progressão válida a partir de accepted/processing',
        () {
      // Válido
      expect(
          NostrOrderService.isStatusProgressionPublic(
              'accept_expired', 'accepted'),
          isTrue);
      expect(
          NostrOrderService.isStatusProgressionPublic(
              'accept_expired', 'processing'),
          isTrue);
      // Inválido: nunca depois de prova enviada ou além
      expect(
          NostrOrderService.isStatusProgressionPublic(
              'accept_expired', 'awaiting_confirmation'),
          isFalse);
      expect(
          NostrOrderService.isStatusProgressionPublic(
              'accept_expired', 'completed'),
          isFalse);
      expect(
          NostrOrderService.isStatusProgressionPublic(
              'accept_expired', 'liquidated'),
          isFalse);
      expect(
          NostrOrderService.isStatusProgressionPublic(
              'accept_expired', 'disputed'),
          isFalse);
      expect(
          NostrOrderService.isStatusProgressionPublic(
              'accept_expired', 'cancelled'),
          isFalse);
      expect(
          NostrOrderService.isStatusProgressionPublic(
              'accept_expired', 'pending'),
          isFalse);
    });

    test('accept_expired não avança sem validar prova canônica', () {
      expect(
          NostrOrderService.isStatusProgressionPublic(
              'cancelled', 'accept_expired'),
          isTrue);
      expect(
          NostrOrderService.isStatusProgressionPublic(
              'pending', 'accept_expired'),
          isTrue);
      expect(
          NostrOrderService.isStatusProgressionPublic(
              'awaiting_confirmation', 'accept_expired'),
          isFalse);
      expect(
          NostrOrderService.isStatusProgressionPublic(
              'accepted', 'accept_expired'),
          isFalse);
      expect(
          NostrOrderService.isStatusProgressionPublic(
              'completed', 'accept_expired'),
          isFalse);
      expect(
          NostrOrderService.isStatusProgressionPublic(
              'disputed', 'accept_expired'),
          isFalse);
    });
  });

  group('R3 - regressão e8817d9d (aceite sem prova)', () {
    const orderId = 'e8817d9d-0000-4000-8000-000000000001';
    final acceptedAt = DateTime(2026, 11, 21, 12, 48, 1);
    final afterWindow = acceptedAt.add(const Duration(minutes: 3));

    Order acceptedOrder({Map<String, dynamic>? metadata}) => _order(
          orderId,
          userPubkey: 'pk-user-r3',
          providerId: 'pk-provider-r3',
          acceptedAt: acceptedAt,
          metadata: metadata,
        );

    Map<String, dynamic> acceptUpdate({int? createdAt}) => {
          'status': 'accepted',
          'providerId': 'pk-provider-r3',
          'eventAuthorPubkey': 'pk-provider-r3',
          'acceptedAt': acceptedAt.toIso8601String(),
          'created_at': createdAt ?? acceptedAt.millisecondsSinceEpoch ~/ 1000,
        };

    test(
        'kind30079 sem prova não grava timestamps de prova e preserva acceptedAt',
        () {
      final updated = NostrOrderService().debugApplyStatusUpdateForR3(
        acceptedOrder(),
        {orderId: acceptUpdate()},
      );

      expect(updated.acceptedAt, acceptedAt);
      expect(updated.metadata?['proofReceivedAt'], isNull);
      expect(updated.metadata?['receipt_submitted_at'], isNull);
    });

    test('NIP-44 é prova; billcode vazio não contamina timestamps', () {
      final proofAt = acceptedAt.add(const Duration(minutes: 1));
      final withProof = NostrOrderService().debugApplyStatusUpdateForR3(
        acceptedOrder(),
        {
          orderId: {
            ...acceptUpdate(createdAt: proofAt.millisecondsSinceEpoch ~/ 1000),
            'proofImage_nip44': 'encrypted-proof',
          },
        },
      );
      expect(withProof.metadata?['proofReceivedAt'], isNotNull);
      expect(withProof.metadata?['receipt_submitted_at'], isNotNull);

      final withBillcode = NostrOrderService().debugApplyStatusUpdateForR3(
        acceptedOrder(),
        {
          orderId: {
            ...acceptUpdate(),
            'billCode_nip44': 'encrypted-billcode',
          },
        },
      );
      expect(withBillcode.metadata?['proofReceivedAt'], isNull);
      expect(withBillcode.metadata?['receipt_submitted_at'], isNull);
    });

    test('accepted sem prova continua candidato após a janela de 2min', () {
      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('pk-user-r3');
      provider.debugSeedOrdersForR5c([acceptedOrder()]);

      expect(
        provider.debugAcceptExpiryCandidatesForR3(now: afterWindow),
        contains(orderId),
      );
      provider.dispose();
    });

    test('sync de aceite sem prova preserva acceptedAt canônico', () {
      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('pk-user-r3');
      provider.debugSeedOrdersForR5c([
        acceptedOrder().copyWith(acceptedAt: null),
      ]);

      provider.debugApplyUserStatusUpdateForR3(orderId, acceptUpdate());
      expect(provider.getOrderById(orderId)?.acceptedAt, acceptedAt);

      provider.debugApplyUserStatusUpdateForR3(orderId, {
        ...acceptUpdate(createdAt: afterWindow.millisecondsSinceEpoch ~/ 1000),
        'acceptedAt': afterWindow.toIso8601String(),
      });
      expect(provider.getOrderById(orderId)?.acceptedAt, acceptedAt,
          reason: 'republish não pode renovar a referência do aceite');
      expect(
          provider.getOrderById(orderId)?.metadata?['proofReceivedAt'], isNull);
      expect(provider.getOrderById(orderId)?.metadata?['receipt_submitted_at'],
          isNull);
      expect(
        provider.debugAcceptExpiryCandidatesForR3(now: afterWindow),
        contains(orderId),
      );
      provider.dispose();
    });

    test(
        'complete com prova não é candidato e mantém âncora de auto-liquidação',
        () {
      final proofAt = acceptedAt.add(const Duration(minutes: 1));
      final updated = NostrOrderService().debugApplyStatusUpdateForR3(
        acceptedOrder(),
        {
          orderId: {
            ...acceptUpdate(createdAt: proofAt.millisecondsSinceEpoch ~/ 1000),
            'status': 'awaiting_confirmation',
            'proofImage': 'plaintext-proof',
            'completedAt': proofAt.toIso8601String(),
          },
        },
      );

      expect(updated.status, 'awaiting_confirmation');
      expect(updated.acceptedAt, acceptedAt);
      expect(updated.metadata?['proofReceivedAt'], proofAt.toIso8601String());
      expect(
          updated.metadata?['receipt_submitted_at'], proofAt.toIso8601String());

      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('pk-user-r3');
      provider.debugSeedOrdersForR5c([updated]);
      expect(
          provider.debugAcceptExpiryCandidatesForR3(now: afterWindow), isEmpty);
      provider.dispose();
    });

    test('sync com prova real não é candidato e mantém lock/âncora', () {
      final proofAt = acceptedAt.add(const Duration(minutes: 1));
      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('pk-user-r3');
      provider.debugSeedOrdersForR5c([acceptedOrder()]);

      provider.debugApplyUserStatusUpdateForR3(orderId, {
        ...acceptUpdate(createdAt: proofAt.millisecondsSinceEpoch ~/ 1000),
        'status': 'awaiting_confirmation',
        'proofImage': 'plaintext-proof',
      });

      final updated = provider.getOrderById(orderId)!;
      expect(updated.status, 'awaiting_confirmation');
      expect(updated.acceptedAt, acceptedAt);
      expect(updated.metadata?['billcode_locked'], isTrue);
      expect(updated.metadata?['proofReceivedAt'], isNotNull);
      expect(updated.metadata?['receipt_submitted_at'], isNotNull);
      expect(
          provider.debugAcceptExpiryCandidatesForR3(now: afterWindow), isEmpty);
      provider.dispose();
    });

    test('invoice/billcode sem prova não criam lock nem timestamps no sync',
        () {
      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('pk-user-r3');
      provider.debugSeedOrdersForR5c([acceptedOrder()]);

      provider.debugApplyUserStatusUpdateForR3(orderId, {
        ...acceptUpdate(),
        'providerInvoice': 'invoice-only',
        'billCode_nip44': 'encrypted-billcode',
      });

      final updated = provider.getOrderById(orderId)!;
      expect(updated.metadata?['providerInvoice'], 'invoice-only');
      expect(updated.metadata?['billcode_locked'], isNot(true));
      expect(updated.metadata?['proofReceivedAt'], isNull);
      expect(updated.metadata?['receipt_submitted_at'], isNull);
      expect(
        provider.debugAcceptExpiryCandidatesForR3(now: afterWindow),
        contains(orderId),
      );
      provider.dispose();
    });

    test('billcode sem prova não bloqueia expiração', () {
      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('pk-user-r3');
      provider.debugSeedOrdersForR5c([
        acceptedOrder(metadata: {
          'billcode_locked': true,
          'billCode_nip44': 'encrypted-billcode',
        }),
      ]);

      expect(
        provider.debugAcceptExpiryCandidatesForR3(now: afterWindow),
        contains(orderId),
      );
      provider.dispose();
    });

    test('complete após accept_expired não recupera nem permite disputa',
        () async {
      final proofAt = DateTime(2026, 11, 21, 14, 26, 28);
      final expired = acceptedOrder().copyWith(
        status: 'accept_expired',
        metadata: {'accept_expired_published': true},
      );
      final update = {
        ...acceptUpdate(createdAt: proofAt.millisecondsSinceEpoch ~/ 1000),
        'status': 'awaiting_confirmation',
        'proofImage': 'late-proof',
        'proofImage_nip44': 'encrypted-proof',
        'providerInvoice': 'lnbc-provider-invoice',
        'proofAuthorPubkey': 'pk-provider-r3',
      };

      final updated = NostrOrderService().debugApplyStatusUpdateForR3(
        expired,
        {orderId: update},
      );
      expect(updated.status, 'accept_expired');
      expect(updated.providerId, 'pk-provider-r3');
      expect(updated.metadata?['accept_expired_published'], isTrue);

      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('pk-user-r3');
      provider.debugSeedOrdersForR5c([expired]);
      provider.debugApplyUserStatusUpdateForR3(orderId, update);
      final recovered = provider.getOrderById(orderId)!;
      expect(recovered.status, 'accept_expired');
      expect(recovered.providerId, 'pk-provider-r3');
      expect(provider.debugTerminalRepublishAttemptsForR3, 0);
      expect(
        NostrOrderService.isStatusProgressionPublic(
            'disputed', 'accept_expired'),
        isFalse,
      );
      expect(await provider.completeOrderAsProvider(orderId, 'late-proof'),
          isFalse);
      provider.dispose();
    });

    test('prova de outro autor não recupera nem troca providerId', () async {
      final expired = acceptedOrder().copyWith(
        status: 'accept_expired',
        metadata: {'accept_expired_published': true},
      );
      final update = {
        ...acceptUpdate(),
        'status': 'awaiting_confirmation',
        'providerId': 'pk-attacker',
        'eventAuthorPubkey': 'pk-attacker',
        'proofAuthorPubkey': 'pk-attacker',
        'proofImage': 'wrong-author-proof',
      };
      final updated = NostrOrderService().debugApplyStatusUpdateForR3(
        expired,
        {orderId: update},
      );
      expect(updated.status, 'accept_expired');
      expect(updated.providerId, 'pk-provider-r3');

      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('pk-user-r3');
      provider.debugSeedOrdersForR5c([expired]);
      provider.debugApplyUserStatusUpdateForR3(orderId, update);
      expect(provider.getOrderById(orderId)?.status, 'accept_expired');
      expect(provider.getOrderById(orderId)?.providerId, 'pk-provider-r3');
      expect(await provider.republicarOrderExpirada(orderId), isFalse);
      expect(provider.getOrderById(orderId)?.status, 'accept_expired');
      provider.dispose();
    });

    test('sem prova canônica, UI só oferece republicar/cancelar', () {
      final expired = acceptedOrder().copyWith(status: 'accept_expired');
      expect(OrderProvider.hasCanonicalProofForExpiredOrder(expired.toJson()),
          isFalse);
      final withProof = expired.copyWith(metadata: {
        'proofImage_nip44': 'proof',
        'proofImage_senderPubkey': 'pk-provider-r3',
      });
      expect(OrderProvider.hasCanonicalProofForExpiredOrder(withProof.toJson()),
          isFalse);
      final wrongAuthor = withProof.copyWith(metadata: {
        ...?withProof.metadata,
        'proofImage_senderPubkey': 'pk-attacker',
      });
      expect(
          OrderProvider.hasCanonicalProofForExpiredOrder(wrongAuthor.toJson()),
          isFalse);
    });
  });

  group('R3 - nova rodada após expiração', () {
    test('pending local desatualizado recupera expiração sem prova', () {
      final acceptedAt = DateTime.now().subtract(const Duration(hours: 2));
      final stale = _order(
        'stale-pending',
        userPubkey: 'pk-user-r3',
        providerId: 'pk-provider-r3',
        status: 'pending',
        acceptedAt: acceptedAt,
        metadata: {
          'republishedAt': acceptedAt
              .add(const Duration(minutes: 30))
              .toIso8601String(),
        },
      );
      final update = {
        'status': 'accept_expired',
        'providerId': 'pk-provider-r3',
        'eventAuthorPubkey': 'pk-user-r3',
        'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      };
      expect(
        NostrOrderService.canRecoverExpiredAccept(stale.toJson(), update),
        isTrue,
      );
      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('pk-user-r3');
      provider.debugSeedOrdersForR5c([stale]);
      provider.debugApplyUserStatusUpdateForR3(stale.id, update);
      expect(provider.getOrderById(stale.id)?.status, 'accept_expired');
      provider.dispose();
    });

    test('nova rodada pending não volta a expirada nem mantém aceite antigo',
        () {
      final expired = _order(
        'republished-round',
        userPubkey: 'pk-user-r3',
        providerId: 'pk-provider-r3',
        status: 'accept_expired',
        acceptedAt: DateTime.now().subtract(const Duration(hours: 2)),
      );
      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('pk-user-r3');
      provider.debugSeedOrdersForR5c([expired]);
      provider.debugApplyUserStatusUpdateForR3(expired.id, {
        'status': 'pending',
        'providerId': null,
        'eventAuthorPubkey': 'pk-user-r3',
        'republishedAt': DateTime.now().toIso8601String(),
        'created_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      });
      final pending = provider.getOrderById(expired.id)!;
      expect(pending.status, 'pending');
      expect(pending.providerId, isNull);
      expect(pending.acceptedAt, isNull);
      expect(
        NostrOrderService.canRecoverExpiredAccept(pending.toJson(), {
          'status': 'accept_expired',
          'providerId': 'pk-provider-r3',
        }),
        isFalse,
      );
      provider.dispose();
    });

    test('sync local rejeita aceite anterior ao republishedAt', () {
      final republishedAt = DateTime.now().subtract(const Duration(minutes: 1));
      final pending = _order(
        'republished-stale-accept',
        userPubkey: 'pk-user-r3',
        status: 'pending',
        metadata: {'republishedAt': republishedAt.toIso8601String()},
      );
      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('pk-user-r3');
      provider.debugSeedOrdersForR5c([pending]);
      provider.debugApplyUserStatusUpdateForR3(pending.id, {
        'status': 'accepted',
        'providerId': 'pk-provider-r3',
        'eventAuthorPubkey': 'pk-provider-r3',
        'acceptedAt': DateTime.now()
            .subtract(const Duration(hours: 2))
            .toIso8601String(),
        'created_at': republishedAt.millisecondsSinceEpoch ~/ 1000 - 3600,
      });
      final current = provider.getOrderById(pending.id)!;
      expect(current.status, 'pending');
      expect(current.providerId, isNull);
      expect(current.acceptedAt, isNull);
      provider.dispose();
    });

    test('novo aceite após republishedAt atualiza provedor e libera nova rodada', () {
      final republishedAt = DateTime.now().subtract(const Duration(minutes: 5));
      final pending = _order(
        'new-round-provider',
        userPubkey: 'pk-user-r3',
        status: 'pending',
        metadata: {
          'republishedAt': republishedAt.toIso8601String(),
          'lostRace': true,
          'lostRaceTo': 'pk-old-provider',
          'accept_expired_published': true,
        },
      );
      final acceptedAt = republishedAt.add(const Duration(minutes: 2));
      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('pk-user-r3');
      provider.debugSeedOrdersForR5c([pending]);
      provider.debugApplyUserStatusUpdateForR3(pending.id, {
        'status': 'accepted',
        'providerId': '6b79131b',
        'eventAuthorPubkey': '6b79131b',
        'acceptedAt': acceptedAt.toIso8601String(),
        'created_at': acceptedAt.millisecondsSinceEpoch ~/ 1000,
      });
      final current = provider.getOrderById(pending.id)!;
      expect(current.status, 'accepted');
      expect(current.providerId, '6b79131b');
      expect(current.acceptedAt, acceptedAt);
      expect(current.metadata?['lostRace'], isFalse);
      expect(current.metadata?['lostRaceTo'], isNull);
      expect(current.metadata?['accept_expired_published'], isFalse);
      provider.dispose();
    });

    test('ordem nova sem republishedAt nunca usa recuperação de rodada antiga', () {
      final fresh = _order(
        '90800cdf',
        userPubkey: 'pk-user-r3',
        providerId: 'pk-provider-r3',
        status: 'pending',
        acceptedAt: DateTime.now().subtract(const Duration(minutes: 4)),
      );
      expect(
        NostrOrderService.canRecoverExpiredAccept(fresh.toJson(), {
          'status': 'accept_expired',
          'providerId': 'pk-provider-r3',
        }),
        isFalse,
      );
    });

    test('aceite anterior à republicação não expira nova rodada', () {
      final republishedAt = DateTime.now().subtract(const Duration(minutes: 4));
      final staleAccepted = _order(
        'new-round-not-expired',
        userPubkey: 'pk-user-r3',
        providerId: 'pk-provider-r3',
        status: 'accepted',
        acceptedAt: DateTime.now().subtract(const Duration(hours: 2)),
        metadata: {'republishedAt': republishedAt.toIso8601String()},
      );
      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('pk-user-r3');
      provider.debugSeedOrdersForR5c([staleAccepted]);
      expect(
        provider.debugAcceptExpiryCandidatesForR3(now: DateTime.now()),
        isEmpty,
      );
      provider.dispose();
    });

    test('pending sem aceite antigo ou com prova não é curado como expirado',
        () {
      final fresh = _order(
        'fresh-pending',
        userPubkey: 'pk-user-r3',
        providerId: 'pk-provider-r3',
        status: 'pending',
      );
      final update = {
        'status': 'accept_expired',
        'providerId': 'pk-provider-r3',
      };
      expect(
        NostrOrderService.canRecoverExpiredAccept(fresh.toJson(), update),
        isFalse,
      );
      final withProof = fresh.copyWith(
        acceptedAt: DateTime.now().subtract(const Duration(hours: 2)),
        metadata: {'proofImage_nip44': 'proof'},
      );
      expect(
        NostrOrderService.canRecoverExpiredAccept(withProof.toJson(), update),
        isFalse,
      );
    });

    test('copyWith limpa provedor e aceite somente quando solicitado', () {
      final acceptedAt = DateTime(2026, 11, 21, 12, 48, 1);
      final expired = _order(
        'expired-order',
        providerId: 'pk-provider-r3',
        status: 'accept_expired',
        acceptedAt: acceptedAt,
      );
      final pending = expired.copyWith(
        status: 'pending',
        clearProviderId: true,
        clearAcceptedAt: true,
      );
      expect(pending.providerId, isNull);
      expect(pending.acceptedAt, isNull);
      expect(pending.status, 'pending');

      final preserved = expired.copyWith(status: 'pending');
      expect(preserved.providerId, 'pk-provider-r3');
      expect(preserved.acceptedAt, acceptedAt);
    });
  });

  group('R3 - corrida prova vs prazo de 1h', () {
    test('(a) prova aos 59min mantém o aceite (billcode_locked trava a janela)',
        () async {
      NostrOrderService.relaysOverride = List<String>.from(deadRelays);
      NostrOrderService.applyRelaysOverride();

      final order = _order(
        'r3-keep-1',
        userPubkey: 'pk-user-r3',
        providerId: 'pk-provider-r3',
        acceptedAt: DateTime.now().subtract(const Duration(minutes: 59)),
        metadata: {
          'billcode_locked': true,
          'proofImage': 'real-proof',
        },
      );
      expect(order.status, 'accepted');
      // Lock com prova real → filtro do _checkAcceptExpiry exclui a ordem
      expect(order.metadata?['billcode_locked'], true);
      expect(order.metadata?['proofImage'], isNotEmpty);
    });

    test('(b) prova tardia não volta a accepted nem reabre corrida', () {
      // Guarda de progressão: accepted NÃO é progressão válida a partir de
      // accept_expired — nem um accept re-publicado ressuscita a ordem.
      expect(
          NostrOrderService.isStatusProgressionPublic(
              'accepted', 'accept_expired'),
          isFalse);
      expect(
          NostrOrderService.isStatusProgressionPublic(
              'processing', 'accept_expired'),
          isFalse);
    });

    test('(c) ordem sem prova e acceptedAt > 1h é candidata à expiração',
        () async {
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

    test('(d) idempotência: accept_expired_published exclui da re-expiração',
        () async {
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
