import 'dart:convert';

import 'package:bro_app/providers/order_provider.dart';
import 'package:bro_app/screens/provider_order_detail_screen.dart';
import 'package:bro_app/services/order_reminder_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('janela de produção R3 é 60 minutos', () {
    expect(OrderProvider.acceptExpiryWindow, const Duration(minutes: 60));
  });

  testWidgets('billcode expirado é bloqueado na UI sem apagar prova', (tester) async {
    await tester.pumpWidget(MaterialApp(home: buildExpiredProviderPaymentBlock()));
    expect(find.textContaining('código Pix/boleto está bloqueado'), findsOneWidget);
    expect(find.textContaining('envie ou visualize o comprovante'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(ElevatedButton), findsNothing);
  });

  test('billcode expirado não é ação de pagamento; prova continua recuperável',
      () {
    final expired = {
      'id': '4e2c858a',
      'status': 'accept_expired',
      'providerId': '6ac7f189',
      'metadata': {
        'accept_expired_published': true,
        'proofImage_nip44': 'encrypted-proof',
        'proofImage_senderPubkey': '6ac7f189',
      },
    };
    expect(OrderProvider.hasCanonicalProofForExpiredOrder(expired), isTrue);
    expect(expired['status'], 'accept_expired');
    expect((expired['metadata'] as Map)['accept_expired_published'], isTrue);
  });

  group('lembretes R3', () {
    final acceptedAt = DateTime(2026, 11, 21, 13, 0);
    Map<String, dynamic> order(String status) => {
          'id': '4e2c858a',
          'status': status,
          'providerId': '6ac7f189',
          'userPubkey': 'buyer',
          'acceptedAt': acceptedAt.toIso8601String(),
          'metadata': {
            'receipt_submitted_at': acceptedAt.toIso8601String(),
          },
        };

    test('20/40min somente para o provedor e dedup por ordem/marco', () {
      final service = OrderReminderService();
      final at20 = service.debugDueReminders(
        order: order('accepted'),
        currentPubkey: '6ac7f189',
        now: acceptedAt.add(const Duration(minutes: 20)),
      );
      expect(at20.single['key'], '4e2c858a:A:20m');
      expect(at20.single['role'], 'provider');
      expect(at20.single['body'], contains('1h'));
      expect(at20.single['body'], isNot(contains('36h')));

      final at40 = service.debugDueReminders(
        order: order('accepted'),
        currentPubkey: '6ac7f189',
        now: acceptedAt.add(const Duration(minutes: 40)),
        alreadySent: {'4e2c858a:A:20m'},
      );
      expect(at40.single['key'], '4e2c858a:A:40m');
      expect(
        service.debugDueReminders(
          order: order('accepted'),
          currentPubkey: '6ac7f189',
          now: acceptedAt.add(const Duration(minutes: 41)),
          alreadySent: {'4e2c858a:A:20m', '4e2c858a:A:40m'},
        ),
        isEmpty,
      );
      expect(
        service.debugDueReminders(
          order: order('accepted'),
          currentPubkey: 'buyer',
          now: acceptedAt.add(const Duration(minutes: 40)),
        ),
        isEmpty,
      );
    });

    test('prova antes da janela não gera lembrete de expiração', () {
      expect(
        OrderReminderService().debugDueReminders(
          order: order('awaiting_confirmation'),
          currentPubkey: '6ac7f189',
          now: acceptedAt.add(const Duration(minutes: 59)),
        ),
        isEmpty,
      );
    });

    test('dedup persiste por ordem e marco', () {
      final sent = <String>{};
      for (final reminder in OrderReminderService().debugDueReminders(
        order: order('accepted'),
        currentPubkey: '6ac7f189',
        now: acceptedAt.add(const Duration(minutes: 40)),
      )) {
        sent.add(reminder['key']!);
      }
      expect(jsonEncode(sent.toList()), contains('4e2c858a:A:20m'));
      expect(sent, containsAll(['4e2c858a:A:20m', '4e2c858a:A:40m']));
    });
  });
}
