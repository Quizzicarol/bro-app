/// R2 — Tier-1 "Meus Primeiros Sats": provedor sem sats aceita ordens ≤ R$ 10.
///
/// Estratégia lógica (sem rede, sem widget, mesmo padrão de
/// tier_deposit_race_test.dart): exercita CollateralTier (definição do tier),
/// LocalCollateralService.canAcceptOrderWithReason (gate de aceite com o
/// limite de 1 ordem ativa) e Order.isActive (base da contagem usada pelas
/// telas de aceite).
///
/// Dinheiro 100% Nostr: nada aqui toca billcode/aceite/comprovante — só o
/// gate de garantia e a definição do tier.

import 'package:flutter_test/flutter_test.dart';
import 'package:bro_app/models/collateral_tier.dart';
import 'package:bro_app/models/order.dart';
import 'package:bro_app/services/local_collateral_service.dart';

LocalCollateral _collateral({
  String tierId = 'trial',
  String tierName = '🌱 Meus Primeiros Sats',
  int requiredSats = 0,
  int lockedSats = 0,
  double maxOrderBrl = 10,
}) =>
    LocalCollateral(
      tierId: tierId,
      tierName: tierName,
      requiredSats: requiredSats,
      lockedSats: lockedSats,
      activeOrders: 0,
      maxOrderBrl: maxOrderBrl,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

Order _order(
  String id, {
  String? userPubkey,
  String? providerId,
  String status = 'pending',
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
      providerId: providerId,
    );

void main() {
  group('R2 - definição do tier-1 (Meus Primeiros Sats)', () {
    test('trial: 0 sats de garantia, limite R\$ 10, id preservado', () {
      final tiers = CollateralTier.getAvailableTiers(500000.0);
      final trial = tiers.firstWhere((t) => t.id == 'trial');

      expect(trial.requiredCollateralSats, 0,
          reason: 'R2: tier-1 não exige garantia');
      expect(trial.requiredCollateralBrl, 0);
      expect(trial.maxOrderValueBrl, 10,
          reason: 'limite de R\$ 10 por ordem mantido');
      expect(trial.id, 'trial', reason: 'id preservado p/ compat de storage');
    });

    test('ordem de R\$ 10 mapeia pro tier-1 (getTierForOrderValue)', () {
      final tier = CollateralTier.getTierForOrderValue(10.0, 500000.0);
      expect(tier?.id, 'trial');
    });

    test('tiers pagos continuam exigindo garantia', () {
      final tiers = CollateralTier.getAvailableTiers(500000.0);
      final starter = tiers.firstWhere((t) => t.id == 'starter');
      expect(starter.requiredCollateralSats, greaterThan(0),
          reason: 'R2 não pode ter zerado os tiers pagos');
    });
  });

  group('R2 - gate de aceite (LocalCollateralService)', () {
    final service = LocalCollateralService();

    test('(a) tier-1 com saldo 0 aceita ordem de R\$ 8', () {
      final (canAccept, reason) = service.canAcceptOrderWithReason(
        _collateral(),
        8.0,
        0, // saldo zero — sem garantia não precisa de saldo
      );
      expect(canAccept, isTrue, reason: 'tier-1 não exige saldo');
      expect(reason, isNull);
    });

    test('(b) tier pago com saldo 0 NÃO aceita (garantia ainda exigida)', () {
      final (canAccept, reason) = service.canAcceptOrderWithReason(
        _collateral(
          tierId: 'starter',
          tierName: '🥉 Iniciante',
          requiredSats: 10000,
          lockedSats: 10000,
          maxOrderBrl: 50,
        ),
        8.0,
        0,
      );
      expect(canAccept, isFalse,
          reason: 'tier-2+ continua exigindo collateral');
      expect(reason, isNotNull);
    });

    test('(c) limite de 1 ordem ativa: count=1 bloqueia, count=0 passa', () {
      // Com 1 ordem ativa → bloqueia.
      final (blocked, blockReason) = service.canAcceptOrderWithReason(
        _collateral(),
        8.0,
        0,
        activeOrdersCount: 1,
      );
      expect(blocked, isFalse, reason: 'tier-1: máx 1 ordem ativa por vez');
      expect(blockReason, contains('1 ordem ativa'));

      // Sem ordens ativas → passa.
      final (ok, _) = service.canAcceptOrderWithReason(
        _collateral(),
        8.0,
        0,
        activeOrdersCount: 0,
      );
      expect(ok, isTrue);
    });

    test('(c2) limite de 1 ordem NÃO se aplica a tier pago', () {
      final (ok, _) = service.canAcceptOrderWithReason(
        _collateral(
          tierId: 'starter',
          tierName: '🥉 Iniciante',
          requiredSats: 10000,
          lockedSats: 10000,
          maxOrderBrl: 50,
        ),
        8.0,
        10000,
        activeOrdersCount: 3,
      );
      expect(ok, isTrue,
          reason: 'limite de 1 ordem é exclusivo do tier-1 sem garantia');
    });

    test('(d) tier-1: ordem acima de R\$ 10 continua bloqueada', () {
      final (canAccept, reason) = service.canAcceptOrderWithReason(
        _collateral(),
        25.0,
        0,
      );
      expect(canAccept, isFalse, reason: 'maxOrderBrl do tier-1 é R\$ 10');
      expect(reason, contains('limite'));
    });

    test('(e) count sem activeOrdersCount (chamadores antigos) não bloqueia',
        () {
      // Chamadores de display (provider_orders_screen L1701/L1734) não passam
      // count — comportamento antigo preservado.
      final (ok, _) = service.canAcceptOrderWithReason(
        _collateral(),
        8.0,
        0,
      );
      expect(ok, isTrue);
    });
  });

  group('R2 - contagem de ordens ativas (Order.isActive)', () {
    test('status não-terminal conta como ativo', () {
      final active = _order('r2-1', userPubkey: 'pk-buyer',
          providerId: 'pk-me', status: 'accepted');
      expect(active.isActive, isTrue);
    });

    test('status terminal NÃO conta como ativo', () {
      final done = _order('r2-2', userPubkey: 'pk-buyer',
          providerId: 'pk-me', status: 'completed');
      final cancelled = _order('r2-3', userPubkey: 'pk-buyer',
          providerId: 'pk-me', status: 'cancelled');
      expect(done.isActive, isFalse);
      expect(cancelled.isActive, isFalse);
    });

    test('padrão das telas: filtra minhas ativas excluindo a ordem atual', () {
      // Mesma expressão usada em provider_order_detail_screen / provider_screen
      // / provider_orders_screen: myAcceptedOrders.where((o) => o.isActive &&
      // o.id != currentOrderId).length
      final myOrders = [
        _order('r2-a', userPubkey: 'pk-buyer', providerId: 'pk-me',
            status: 'accepted'),
        _order('r2-b', userPubkey: 'pk-buyer2', providerId: 'pk-me',
            status: 'processing'),
        _order('r2-c', userPubkey: 'pk-buyer', providerId: 'pk-me',
            status: 'completed'),
        _order('r2-d', userPubkey: 'pk-buyer3', providerId: 'pk-other',
            status: 'accepted'),
      ];
      const currentOrderId = 'r2-a';

      final myActiveOrders = myOrders
          .where((o) =>
              o.providerId == 'pk-me' && o.isActive && o.id != currentOrderId)
          .length;

      expect(myActiveOrders, 1,
          reason: 'só r2-b conta: r2-a é a ordem atual, r2-c é terminal, '
              'r2-d é de outro provedor');
    });
  });
}
