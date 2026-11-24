import 'package:bro_app/models/order.dart';
import 'package:bro_app/providers/order_provider.dart';
import 'package:flutter_test/flutter_test.dart';

Order _order(String id, String status, {DateTime? proofAt}) => Order(
      id: id,
      userPubkey: 'buyer-pk',
      providerId: 'provider-pk',
      billType: 'pix',
      billCode: 'CODE',
      amount: 96.0,
      btcAmount: 0.00026427,
      btcPrice: 363271.0,
      providerFee: 2.88,
      platformFee: 1.92,
      total: 100.8,
      status: status,
      createdAt: DateTime.now().subtract(const Duration(hours: 2)),
      metadata: {
        'proofImage_nip44': 'encrypted-proof',
        'providerInvoice': 'lnbc-invoice',
        if (proofAt != null) 'receipt_submitted_at': proofAt.toIso8601String(),
      },
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AutoPay não paga awaiting_confirmation antes de 36h', () {
    test('comprovante recém-chegado NÃO dispara autopay', () async {
      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('buyer-pk');
      var payCalls = 0;
      provider.onAutoPayLiquidation = (id, order) async {
        payCalls++;
        return true;
      };
      provider.debugSeedOrdersForR5c([
        _order('fresh-proof', 'awaiting_confirmation',
            proofAt: DateTime.now().subtract(const Duration(minutes: 5))),
      ]);
      await provider.debugAutoPayLiquidatedOrders();
      expect(payCalls, 0,
          reason: 'comprovante de 5min deve esperar confirmação manual');
      provider.dispose();
    });

    test('awaiting_confirmation após 36h pode usar autopay como rede de segurança',
        () async {
      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('buyer-pk');
      var payCalls = 0;
      provider.onAutoPayLiquidation = (id, order) async {
        payCalls++;
        return true;
      };
      provider.debugSeedOrdersForR5c([
        _order('old-proof', 'awaiting_confirmation',
            proofAt: DateTime.now().subtract(const Duration(hours: 37))),
      ]);
      await provider.debugAutoPayLiquidatedOrders();
      expect(payCalls, 1,
          reason: 'após 36h sem confirmação, autopay é legítimo');
      provider.dispose();
    });

    test('liquidated continua elegível independente do tempo', () async {
      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('buyer-pk');
      var payCalls = 0;
      provider.onAutoPayLiquidation = (id, order) async {
        payCalls++;
        return true;
      };
      provider.debugSeedOrdersForR5c([
        _order('liquidated-order', 'liquidated',
            proofAt: DateTime.now().subtract(const Duration(minutes: 10))),
      ]);
      await provider.debugAutoPayLiquidatedOrders();
      expect(payCalls, 1, reason: 'liquidated sempre foi uso legítimo do autopay');
      provider.dispose();
    });

    test('awaiting_confirmation sem timestamp de prova NÃO paga (fail-closed)',
        () async {
      final provider = OrderProvider();
      provider.debugSetCurrentUserPubkeyForR5c('buyer-pk');
      var payCalls = 0;
      provider.onAutoPayLiquidation = (id, order) async {
        payCalls++;
        return true;
      };
      provider.debugSeedOrdersForR5c([
        _order('no-timestamp', 'awaiting_confirmation'),
      ]);
      await provider.debugAutoPayLiquidatedOrders();
      expect(payCalls, 0, reason: 'sem âncora de tempo, não paga');
      provider.dispose();
    });
  });
}
