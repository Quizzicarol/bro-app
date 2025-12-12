/// Modelo para saldo do provedor
/// Representa o saldo acumulado de taxas ganhas ao completar ordens
class ProviderBalance {
  final String providerId;
  final double availableBalanceSats; // Saldo disponível para saque
  final double totalEarnedSats; // Total ganho desde o início
  final List<BalanceTransaction> transactions; // Histórico de transações
  final DateTime updatedAt;

  ProviderBalance({
    required this.providerId,
    required this.availableBalanceSats,
    required this.totalEarnedSats,
    required this.transactions,
    required this.updatedAt,
  });

  double get availableBalanceBtc => availableBalanceSats / 100000000;
  double get totalEarnedBtc => totalEarnedSats / 100000000;

  factory ProviderBalance.fromJson(Map<String, dynamic> json) {
    return ProviderBalance(
      providerId: json['provider_id'] as String,
      availableBalanceSats: (json['available_balance_sats'] as num).toDouble(),
      totalEarnedSats: (json['total_earned_sats'] as num).toDouble(),
      transactions: (json['transactions'] as List<dynamic>?)
              ?.map((t) => BalanceTransaction.fromJson(t as Map<String, dynamic>))
              .toList() ??
          [],
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'provider_id': providerId,
      'available_balance_sats': availableBalanceSats,
      'total_earned_sats': totalEarnedSats,
      'transactions': transactions.map((t) => t.toJson()).toList(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  ProviderBalance copyWith({
    String? providerId,
    double? availableBalanceSats,
    double? totalEarnedSats,
    List<BalanceTransaction>? transactions,
    DateTime? updatedAt,
  }) {
    return ProviderBalance(
      providerId: providerId ?? this.providerId,
      availableBalanceSats: availableBalanceSats ?? this.availableBalanceSats,
      totalEarnedSats: totalEarnedSats ?? this.totalEarnedSats,
      transactions: transactions ?? this.transactions,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// Transação no histórico do saldo do provedor
class BalanceTransaction {
  final String id;
  final String type; // 'earning' | 'withdrawal_lightning' | 'withdrawal_onchain'
  final double amountSats;
  final String? orderId; // ID da ordem que gerou o ganho (se type = earning)
  final String? orderDescription; // Descrição da ordem (ex: "PIX R$ 50.00")
  final String? txHash; // Hash da transação onchain (se type = withdrawal_onchain)
  final String? invoice; // Invoice Lightning (se type = withdrawal_lightning)
  final DateTime createdAt;

  BalanceTransaction({
    required this.id,
    required this.type,
    required this.amountSats,
    this.orderId,
    this.orderDescription,
    this.txHash,
    this.invoice,
    required this.createdAt,
  });

  double get amountBtc => amountSats / 100000000;

  factory BalanceTransaction.fromJson(Map<String, dynamic> json) {
    return BalanceTransaction(
      id: json['id'] as String,
      type: json['type'] as String,
      amountSats: (json['amount_sats'] as num).toDouble(),
      orderId: json['order_id'] as String?,
      orderDescription: json['order_description'] as String?,
      txHash: json['tx_hash'] as String?,
      invoice: json['invoice'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type,
      'amount_sats': amountSats,
      'order_id': orderId,
      'order_description': orderDescription,
      'tx_hash': txHash,
      'invoice': invoice,
      'created_at': createdAt.toIso8601String(),
    };
  }
}
