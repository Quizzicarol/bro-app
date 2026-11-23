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

  testWidgets('aviso de 1 hora fica visível junto ao billcode', (tester) async {
    final acceptedAt = DateTime(2026, 11, 23, 7, 0);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: buildAcceptExpiryNotice(
          acceptedAt: acceptedAt,
          now: acceptedAt.add(const Duration(minutes: 8)),
        ),
      ),
    ));
    expect(find.textContaining('52 minutos'), findsOneWidget);
    expect(find.textContaining('código será bloqueado'), findsOneWidget);
    expect(find.textContaining('republicada'), findsOneWidget);
    final text = tester.widget<Text>(find.textContaining('52 minutos'));
    expect(text.style?.color, Colors.redAccent);
    expect(text.style?.fontWeight, FontWeight.w700);
  });

  testWidgets('ordem nova de 4 minutos não mostra código expirado', (tester) async {
    final acceptedAt = DateTime.now().subtract(const Duration(minutes: 4));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: buildAcceptExpiryNotice(
          acceptedAt: acceptedAt,
          now: DateTime.now(),
        ),
      ),
    ));
    expect(find.textContaining('56 minutos'), findsOneWidget);
    expect(find.textContaining('tempo para pagamento expirou'), findsNothing);
    expect(find.textContaining('código foi bloqueado'), findsNothing);
  });

  testWidgets('aceite anterior à republicação não contamina aviso da nova rodada',
      (tester) async {
    final republishedAt = DateTime.now().subtract(const Duration(minutes: 4));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: buildAcceptExpiryNotice(
          acceptedAt: DateTime.now().subtract(const Duration(hours: 2)),
          republishedAt: republishedAt,
          now: DateTime.now(),
        ),
      ),
    ));
    expect(find.textContaining('60 minutos'), findsOneWidget);
    expect(find.textContaining('tempo para pagamento expirou'), findsNothing);
  });

  testWidgets('aviso expirado orienta recuperar com comprovante', (tester) async {
    final acceptedAt = DateTime(2026, 11, 23, 7, 0);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: buildAcceptExpiryNotice(
          acceptedAt: acceptedAt,
          now: acceptedAt.add(const Duration(minutes: 61)),
        ),
      ),
    ));
    expect(find.textContaining('tempo para pagamento expirou'), findsOneWidget);
    expect(find.textContaining('Não envie mais comprovante nem abra disputa'), findsOneWidget);
  });

  testWidgets('billcode expirado é bloqueado na UI sem apagar prova', (tester) async {
    await tester.pumpWidget(MaterialApp(home: buildExpiredProviderPaymentBlock()));
    expect(find.textContaining('código Pix/boleto está bloqueado'), findsOneWidget);
    expect(find.textContaining('Não envie mais comprovante nem abra disputa'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(ElevatedButton), findsNothing);
  });

  test('aceite expirado não recupera por comprovante tardio', () {
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
    expect(OrderProvider.hasCanonicalProofForExpiredOrder(expired), isFalse);
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
      expect(at20.single['body'], contains('40 minutos'));
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

    test('expiração notifica o comprador para republicar ou cancelar', () {
      final reminders = OrderReminderService().debugDueReminders(
        order: order('accept_expired'),
        currentPubkey: 'buyer',
        now: acceptedAt.add(const Duration(minutes: 60)),
      );
      expect(reminders.single['key'], '4e2c858a:E:60m');
      expect(reminders.single['role'], 'user');
      expect(reminders.single['title'], contains('republicar ou cancelar'));
      expect(reminders.single['body'], contains('sacar seus sats'));
      expect(
        OrderReminderService().debugDueReminders(
          order: order('accept_expired'),
          currentPubkey: '6ac7f189',
          now: acceptedAt.add(const Duration(minutes: 60)),
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
