/// Modelo de níveis de garantia (collateral) para provedores
class CollateralTier {
  final String id;
  final String name;
  final double maxOrderValueBrl; // Valor máximo de ordem que pode aceitar
  final double requiredCollateralBrl; // Garantia necessária em BRL
  final int requiredCollateralSats; // Garantia necessária em sats (calculado)
  final String description;
  final List<String> benefits;

  CollateralTier({
    required this.id,
    required this.name,
    required this.maxOrderValueBrl,
    required this.requiredCollateralBrl,
    required this.requiredCollateralSats,
    required this.description,
    required this.benefits,
  });

  factory CollateralTier.fromJson(Map<String, dynamic> json) {
    return CollateralTier(
      id: json['id'] as String,
      name: json['name'] as String,
      maxOrderValueBrl: (json['max_order_value_brl'] as num).toDouble(),
      requiredCollateralBrl: (json['required_collateral_brl'] as num).toDouble(),
      requiredCollateralSats: json['required_collateral_sats'] as int,
      description: json['description'] as String,
      benefits: List<String>.from(json['benefits'] as List),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'max_order_value_brl': maxOrderValueBrl,
      'required_collateral_brl': requiredCollateralBrl,
      'required_collateral_sats': requiredCollateralSats,
      'description': description,
      'benefits': benefits,
    };
  }

  /// Define os tiers disponíveis baseado no preço atual do Bitcoin
  static List<CollateralTier> getAvailableTiers(double btcPriceBrl) {
    final satsPerBrl = 100000000 / btcPriceBrl; // 1 BTC = 100M sats

    return [
      // 🧪 Tier Trial - para testar o app
      CollateralTier(
        id: 'trial',
        name: '🧪 Trial',
        maxOrderValueBrl: 10,
        requiredCollateralBrl: 10,
        requiredCollateralSats: (10 * satsPerBrl).round(),
        description: 'Tier de teste - contas até R\$ 10',
        benefits: [
          'Contas até R\$ 10',
          'Garantia: R\$ 10',
          'Taxa: 5% por transação',
          'Perfeito para testar o app',
        ],
      ),
      // 🥉 Tier Iniciante
      CollateralTier(
        id: 'starter',
        name: '🥉 Iniciante',
        maxOrderValueBrl: 50,
        requiredCollateralBrl: 50,
        requiredCollateralSats: (50 * satsPerBrl).round(),
        description: 'Ideal para começar - contas até R\$ 50',
        benefits: [
          'Contas até R\$ 50',
          'Garantia: R\$ 50',
          'Taxa: 5% por transação',
          'Perfeito para iniciantes',
        ],
      ),
      // 🥈 Tier Básico
      CollateralTier(
        id: 'basic',
        name: '🥈 Básico',
        maxOrderValueBrl: 200,
        requiredCollateralBrl: 200,
        requiredCollateralSats: (200 * satsPerBrl).round(),
        description: 'Aceite contas até R\$ 200',
        benefits: [
          'Contas até R\$ 200',
          'Garantia: R\$ 200',
          'Taxa: 5% por transação',
        ],
      ),
      // 🥇 Tier Intermediário
      CollateralTier(
        id: 'intermediate',
        name: '🥇 Intermediário',
        maxOrderValueBrl: 500,
        requiredCollateralBrl: 500,
        requiredCollateralSats: (500 * satsPerBrl).round(),
        description: 'Aceite contas até R\$ 500',
        benefits: [
          'Contas até R\$ 500',
          'Garantia: R\$ 500',
          'Taxa: 5% por transação',
          'Prioridade em ordens médias',
        ],
      ),
      // 💎 Tier Avançado
      CollateralTier(
        id: 'advanced',
        name: '💎 Avançado',
        maxOrderValueBrl: 1000,
        requiredCollateralBrl: 1000,
        requiredCollateralSats: (1000 * satsPerBrl).round(),
        description: 'Aceite contas até R\$ 1.000',
        benefits: [
          'Contas até R\$ 1.000',
          'Garantia: R\$ 1.000',
          'Taxa: 5% por transação',
          'Prioridade alta',
        ],
      ),
      // 👑 Tier Master
      CollateralTier(
        id: 'master',
        name: '👑 Master',
        maxOrderValueBrl: double.infinity,
        requiredCollateralBrl: 3000,
        requiredCollateralSats: (3000 * satsPerBrl).round(),
        description: 'Aceite contas de qualquer valor',
        benefits: [
          'Contas ilimitadas',
          'Garantia: R\$ 3.000',
          'Taxa: 5% por transação',
          'Prioridade máxima',
          'Suporte prioritário',
        ],
      ),
    ];
  }

  /// Retorna o tier adequado baseado no valor da ordem
  static CollateralTier? getTierForOrderValue(
    double orderValueBrl,
    double btcPriceBrl,
  ) {
    final tiers = getAvailableTiers(btcPriceBrl);
    
    for (final tier in tiers) {
      if (orderValueBrl <= tier.maxOrderValueBrl) {
        return tier;
      }
    }
    
    return null; // Valor acima do suportado
  }
}

/// Modelo de garantia bloqueada do provedor
class ProviderCollateral {
  final String providerId;
  final int lockedSats; // Total em garantia
  final int availableSats; // Disponível para aceitar novas ordens
  final String currentTierId; // Tier atual baseado na garantia
  final DateTime lastUpdated;
  final List<CollateralLock> activeLocks; // Garantias bloqueadas em ordens

  ProviderCollateral({
    required this.providerId,
    required this.lockedSats,
    required this.availableSats,
    required this.currentTierId,
    required this.lastUpdated,
    required this.activeLocks,
  });

  factory ProviderCollateral.fromJson(Map<String, dynamic> json) {
    return ProviderCollateral(
      providerId: json['provider_id'] as String,
      lockedSats: json['locked_sats'] as int,
      availableSats: json['available_sats'] as int,
      currentTierId: json['current_tier_id'] as String,
      lastUpdated: DateTime.parse(json['last_updated'] as String),
      activeLocks: (json['active_locks'] as List?)
              ?.map((lock) => CollateralLock.fromJson(lock as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'provider_id': providerId,
      'locked_sats': lockedSats,
      'available_sats': availableSats,
      'current_tier_id': currentTierId,
      'last_updated': lastUpdated.toIso8601String(),
      'active_locks': activeLocks.map((lock) => lock.toJson()).toList(),
    };
  }

  /// Total em garantia (locked + available)
  int get totalCollateral => lockedSats + availableSats;

  /// Verifica se pode aceitar uma ordem com esse valor
  bool canAcceptOrder(double orderValueBrl, double btcPriceBrl) {
    final tier = CollateralTier.getTierForOrderValue(orderValueBrl, btcPriceBrl);
    if (tier == null) return false;

    // Verifica se o tier atual suporta e se tem sats disponíveis
    return currentTierId == tier.id && availableSats >= tier.requiredCollateralSats;
  }
}

/// Modelo de garantia bloqueada em uma ordem específica
class CollateralLock {
  final String lockId;
  final String orderId;
  final int lockedSats;
  final String tierId;
  final DateTime lockedAt;
  final DateTime? expiresAt;
  final String status; // 'active', 'released', 'slashed'

  CollateralLock({
    required this.lockId,
    required this.orderId,
    required this.lockedSats,
    required this.tierId,
    required this.lockedAt,
    this.expiresAt,
    required this.status,
  });

  factory CollateralLock.fromJson(Map<String, dynamic> json) {
    return CollateralLock(
      lockId: json['lock_id'] as String,
      orderId: json['order_id'] as String,
      lockedSats: json['locked_sats'] as int,
      tierId: json['tier_id'] as String,
      lockedAt: DateTime.parse(json['locked_at'] as String),
      expiresAt: json['expires_at'] != null 
          ? DateTime.parse(json['expires_at'] as String) 
          : null,
      status: json['status'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'lock_id': lockId,
      'order_id': orderId,
      'locked_sats': lockedSats,
      'tier_id': tierId,
      'locked_at': lockedAt.toIso8601String(),
      'expires_at': expiresAt?.toIso8601String(),
      'status': status,
    };
  }

  bool get isActive => status == 'active';
  bool get isExpired => expiresAt != null && DateTime.now().isAfter(expiresAt!);
}
