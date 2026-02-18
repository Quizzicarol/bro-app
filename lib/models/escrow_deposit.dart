/// Modelo de depósito de garantia do provedor
class EscrowDeposit {
  final String id;
  final String providerId;
  final int amountBrl;
  final String status; // 'pending', 'locked', 'released', 'slashed'
  final String? paymentHash; // HODL invoice payment hash
  final String? preimage; // Para release
  final DateTime createdAt;
  final DateTime? lockedAt;
  final DateTime? releasedAt;
  final int activeOrders;
  final int disputes;
  
  EscrowDeposit({
    required this.id,
    required this.providerId,
    required this.amountBrl,
    required this.status,
    this.paymentHash,
    this.preimage,
    required this.createdAt,
    this.lockedAt,
    this.releasedAt,
    this.activeOrders = 0,
    this.disputes = 0,
  });

  bool get canBeReleased => 
      status == 'locked' && 
      activeOrders == 0 && 
      disputes == 0;

  bool get isActive => status == 'locked';

  factory EscrowDeposit.fromJson(Map<String, dynamic> json) {
    return EscrowDeposit(
      id: json['id'] as String,
      providerId: json['providerId'] as String,
      amountBrl: json['amountBrl'] as int,
      status: json['status'] as String,
      paymentHash: json['paymentHash'] as String?,
      preimage: json['preimage'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      lockedAt: json['lockedAt'] != null 
          ? DateTime.parse(json['lockedAt'] as String) 
          : null,
      releasedAt: json['releasedAt'] != null 
          ? DateTime.parse(json['releasedAt'] as String) 
          : null,
      activeOrders: json['activeOrders'] as int? ?? 0,
      disputes: json['disputes'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'providerId': providerId,
      'amountBrl': amountBrl,
      'status': status,
      'paymentHash': paymentHash,
      'preimage': preimage,
      'createdAt': createdAt.toIso8601String(),
      'lockedAt': lockedAt?.toIso8601String(),
      'releasedAt': releasedAt?.toIso8601String(),
      'activeOrders': activeOrders,
      'disputes': disputes,
    };
  }
}

/// Modelo de mensagem do chat order
class OrderMessage {
  final String id;
  final String orderId;
  final String senderId;
  final String senderType; // 'client' | 'provider'
  final String message;
  final String? attachmentUrl; // URL de comprovante
  final String? attachmentType; // 'image' | 'pdf'
  final DateTime timestamp;
  final bool read;
  
  OrderMessage({
    required this.id,
    required this.orderId,
    required this.senderId,
    required this.senderType,
    required this.message,
    this.attachmentUrl,
    this.attachmentType,
    required this.timestamp,
    this.read = false,
  });

  bool get isFromClient => senderType == 'client';
  bool get hasAttachment => attachmentUrl != null;

  factory OrderMessage.fromJson(Map<String, dynamic> json) {
    return OrderMessage(
      id: json['id'] as String,
      orderId: json['orderId'] as String,
      senderId: json['senderId'] as String,
      senderType: json['senderType'] as String,
      message: json['message'] as String,
      attachmentUrl: json['attachmentUrl'] as String?,
      attachmentType: json['attachmentType'] as String?,
      timestamp: DateTime.parse(json['timestamp'] as String),
      read: json['read'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'orderId': orderId,
      'senderId': senderId,
      'senderType': senderType,
      'message': message,
      'attachmentUrl': attachmentUrl,
      'attachmentType': attachmentType,
      'timestamp': timestamp.toIso8601String(),
      'read': read,
    };
  }
}
