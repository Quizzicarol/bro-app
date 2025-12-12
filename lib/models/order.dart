class Order {
  final String id;
  final String billType;
  final String billCode;
  final double amount;
  final double btcAmount;
  final double btcPrice;
  final double providerFee;
  final double platformFee;
  final double total;
  final String status;
  final DateTime createdAt;
  final String? providerId;
  final DateTime? acceptedAt;
  final DateTime? completedAt;
  final Map<String, dynamic>? metadata;

  Order({
    required this.id,
    required this.billType,
    required this.billCode,
    required this.amount,
    required this.btcAmount,
    required this.btcPrice,
    required this.providerFee,
    required this.platformFee,
    required this.total,
    required this.status,
    required this.createdAt,
    this.providerId,
    this.acceptedAt,
    this.completedAt,
    this.metadata,
  });

  factory Order.fromJson(Map<String, dynamic> json) {
    return Order(
      id: json['id'] ?? json['orderId'] ?? '',
      billType: json['billType'] ?? 'pix',
      billCode: json['billCode'] ?? '',
      amount: (json['amount'] ?? 0).toDouble(),
      btcAmount: (json['btcAmount'] ?? 0).toDouble(),
      btcPrice: (json['btcPrice'] ?? 0).toDouble(),
      providerFee: (json['providerFee'] ?? 0).toDouble(),
      platformFee: (json['platformFee'] ?? 0).toDouble(),
      total: (json['total'] ?? 0).toDouble(),
      status: json['status'] ?? 'pending',
      createdAt: json['createdAt'] != null 
          ? DateTime.parse(json['createdAt']) 
          : DateTime.now(),
      providerId: json['providerId'],
      acceptedAt: json['acceptedAt'] != null 
          ? DateTime.parse(json['acceptedAt']) 
          : null,
      completedAt: json['completedAt'] != null 
          ? DateTime.parse(json['completedAt']) 
          : null,
      metadata: json['metadata'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'billType': billType,
      'billCode': billCode,
      'amount': amount,
      'btcAmount': btcAmount,
      'btcPrice': btcPrice,
      'providerFee': providerFee,
      'platformFee': platformFee,
      'total': total,
      'status': status,
      'createdAt': createdAt.toIso8601String(),
      if (providerId != null) 'providerId': providerId,
      if (acceptedAt != null) 'acceptedAt': acceptedAt!.toIso8601String(),
      if (completedAt != null) 'completedAt': completedAt!.toIso8601String(),
      if (metadata != null) 'metadata': metadata,
    };
  }

  Order copyWith({
    String? id,
    String? billType,
    String? billCode,
    double? amount,
    double? btcAmount,
    double? btcPrice,
    double? providerFee,
    double? platformFee,
    double? total,
    String? status,
    DateTime? createdAt,
    String? providerId,
    DateTime? acceptedAt,
    DateTime? completedAt,
    Map<String, dynamic>? metadata,
  }) {
    return Order(
      id: id ?? this.id,
      billType: billType ?? this.billType,
      billCode: billCode ?? this.billCode,
      amount: amount ?? this.amount,
      btcAmount: btcAmount ?? this.btcAmount,
      btcPrice: btcPrice ?? this.btcPrice,
      providerFee: providerFee ?? this.providerFee,
      platformFee: platformFee ?? this.platformFee,
      total: total ?? this.total,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      providerId: providerId ?? this.providerId,
      acceptedAt: acceptedAt ?? this.acceptedAt,
      completedAt: completedAt ?? this.completedAt,
      metadata: metadata ?? this.metadata,
    );
  }

  bool get isPending => status == 'pending';
  bool get isPaymentReceived => status == 'payment_received';
  bool get isConfirmed => status == 'confirmed';
  bool get isAccepted => status == 'accepted';
  bool get isProcessing => status == 'processing';
  bool get isCompleted => status == 'completed';
  bool get isCancelled => status == 'cancelled';

  String get statusText {
    switch (status) {
      case 'pending':
        return 'Pendente';
      case 'payment_received':
        return 'Pagamento Recebido';
      case 'confirmed':
        return 'Confirmado';
      case 'accepted':
        return 'Aceito';
      case 'processing':
        return 'Processando';
      case 'completed':
        return 'Concluído';
      case 'cancelled':
        return 'Cancelado';
      default:
        return status;
    }
  }

  String get billTypeText {
    switch (billType) {
      case 'pix':
        return 'PIX';
      case 'boleto':
        return 'Boleto';
      case 'bancario':
        return 'Boleto Bancário';
      case 'concessionaria':
        return 'Concessionária';
      default:
        return billType;
    }
  }
}
