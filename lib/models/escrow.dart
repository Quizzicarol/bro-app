class Escrow {
  final String id;
  final String orderId;
  final String bitcoinAddress;
  final String? lightningInvoice;
  final double btcAmount;
  final int amountSats;
  final String status; // pending, funded, released, refunded
  final DateTime createdAt;
  final DateTime? fundedAt;
  final DateTime? releasedAt;
  final Map<String, dynamic>? metadata;

  Escrow({
    required this.id,
    required this.orderId,
    required this.bitcoinAddress,
    this.lightningInvoice,
    required this.btcAmount,
    required this.amountSats,
    required this.status,
    required this.createdAt,
    this.fundedAt,
    this.releasedAt,
    this.metadata,
  });

  factory Escrow.fromJson(Map<String, dynamic> json) {
    return Escrow(
      id: json['id'] ?? json['escrowId'] ?? '',
      orderId: json['orderId'] ?? '',
      bitcoinAddress: json['bitcoinAddress'] ?? json['address'] ?? '',
      lightningInvoice: json['lightningInvoice'],
      btcAmount: (json['btcAmount'] is num) ? json['btcAmount'].toDouble() : 0.0,
      amountSats: json['amountSats'] ?? 0,
      status: json['status'] ?? 'pending',
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'])
          : DateTime.now(),
      fundedAt: json['fundedAt'] != null ? DateTime.parse(json['fundedAt']) : null,
      releasedAt: json['releasedAt'] != null ? DateTime.parse(json['releasedAt']) : null,
      metadata: json['metadata'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'orderId': orderId,
      'bitcoinAddress': bitcoinAddress,
      if (lightningInvoice != null) 'lightningInvoice': lightningInvoice,
      'btcAmount': btcAmount,
      'amountSats': amountSats,
      'status': status,
      'createdAt': createdAt.toIso8601String(),
      if (fundedAt != null) 'fundedAt': fundedAt!.toIso8601String(),
      if (releasedAt != null) 'releasedAt': releasedAt!.toIso8601String(),
      if (metadata != null) 'metadata': metadata,
    };
  }

  bool get isPending => status == 'pending';
  bool get isFunded => status == 'funded';
  bool get isReleased => status == 'released';
  bool get isRefunded => status == 'refunded';
}
