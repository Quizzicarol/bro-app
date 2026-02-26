class Order {
  final String id;
  final String? eventId; // ID do evento Nostr
  final String? userPubkey; // Pubkey do usuário que criou a ordem
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
  final String? paymentHash; // Hash da invoice Lightning para verificação de pagamento
  final String? invoice; // Invoice BOLT11 gerada para esta ordem

  Order({
    required this.id,
    this.eventId,
    this.userPubkey,
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
    this.paymentHash,
    this.invoice,
  });

  factory Order.fromJson(Map<String, dynamic> json) {
    return Order(
      id: json['id'] ?? json['orderId'] ?? '',
      eventId: json['eventId'],
      userPubkey: json['userPubkey'] ?? json['pubkey'],
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
      paymentHash: json['paymentHash'],
      invoice: json['invoice'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      if (eventId != null) 'eventId': eventId,
      if (userPubkey != null) 'userPubkey': userPubkey,
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
      if (paymentHash != null) 'paymentHash': paymentHash,
      if (invoice != null) 'invoice': invoice,
    };
  }

  Order copyWith({
    String? id,
    String? eventId,
    String? userPubkey,
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
    String? paymentHash,
    String? invoice,
  }) {
    return Order(
      id: id ?? this.id,
      eventId: eventId ?? this.eventId,
      userPubkey: userPubkey ?? this.userPubkey,
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
      paymentHash: paymentHash ?? this.paymentHash,
      invoice: invoice ?? this.invoice,
    );
  }

  // Status checks
  bool get isPending => status == 'pending';
  bool get isPaymentReceived => status == 'payment_received';
  bool get isConfirmed => status == 'confirmed';
  bool get isAccepted => status == 'accepted';
  bool get isProcessing => status == 'processing';
  bool get isAwaitingConfirmation => status == 'awaiting_confirmation';
  bool get isCompleted => status == 'completed';
  bool get isLiquidated => status == 'liquidated';
  bool get isCancelled => status == 'cancelled';
  bool get isDisputed => status == 'disputed';

  /// Retorna true se o pagamento Lightning foi realmente recebido e confirmado
  /// Uma ordem só é considerada "paga" se tiver um paymentHash válido
  bool get isPaymentVerified => paymentHash != null && paymentHash!.isNotEmpty;

  /// Retorna true se o status indica que o pagamento Lightning foi recebido
  /// Isso inclui payment_received, confirmed, accepted, awaiting_confirmation, completed
  bool get hasPaymentBeenReceived {
    return status == 'payment_received' || 
           status == 'confirmed' || 
           status == 'accepted' || 
           status == 'awaiting_confirmation' || 
           status == 'completed';
  }

  /// Retorna true se a ordem está em um estado ativo (não finalizado)
  bool get isActive {
    return status == 'pending' || 
           status == 'payment_received' || 
           status == 'confirmed' || 
           status == 'accepted' ||
           status == 'processing' ||
           status == 'awaiting_confirmation';
  }

  String get statusText {
    // v233: Verificar se a ordem foi resolvida por mediação de disputa
    final wasDisputed = metadata?['wasDisputed'] == true;
    if (wasDisputed) {
      if (status == 'completed') return 'Resolvida por Mediação ⚖️';
      if (status == 'cancelled') return 'Cancelada (Disputa) ⚖️';
    }
    switch (status) {
      case 'pending':
        return 'Aguardando Pagamento';
      case 'payment_received':
        return 'Pagamento Recebido ✓';
      case 'confirmed':
        return 'Aguardando Bro';
      case 'accepted':
        return 'Bro Aceitou';
      case 'processing':
        return 'Processando';
      case 'awaiting_confirmation':
        return 'Verificar Comprovante';
      case 'completed':
        return 'Concluído ✓';
      case 'liquidated':
        return 'Liquidada ⚡';
      case 'cancelled':
        return 'Cancelado';
      case 'disputed':
        return 'Em Disputa';
      default:
        return status;
    }
  }

  /// Retorna uma descrição mais detalhada do status para exibição ao usuário
  String get statusDescription {
    // v233: Verificar se foi resolvida por mediação
    final wasDisputed = metadata?['wasDisputed'] == true;
    if (wasDisputed) {
      if (status == 'completed') return 'Disputa resolvida por mediação a favor do provedor';
      if (status == 'cancelled') return 'Disputa resolvida por mediação a favor do usuário';
    }
    switch (status) {
      case 'pending':
        return 'Pague com Bitcoin Lightning para prosseguir';
      case 'payment_received':
        return 'Seus sats foram recebidos! Aguardando um Bro aceitar';
      case 'confirmed':
        return 'Sua ordem está disponível para Bros';
      case 'accepted':
        return 'Um Bro aceitou e está processando seu pagamento';
      case 'processing':
        return 'O Bro está realizando o pagamento';
      case 'awaiting_confirmation':
        return 'Verifique o comprovante enviado pelo Bro';
      case 'completed':
        return 'Sua conta foi paga com sucesso!';
      case 'liquidated':
        return 'Ordem liquidada automaticamente após 36h sem confirmação';
      case 'cancelled':
        return 'Ordem cancelada. Seus sats continuam na carteira';
      case 'disputed':
        return 'Disputa aberta. Aguardando mediação';
      default:
        return '';
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
