/// Modelo para registrar saques realizados
class Withdrawal {
  final String id;
  final String orderId;
  final int amountSats;
  final String destination;
  final String destinationType; // 'invoice', 'lnaddress', 'lnurl'
  final DateTime createdAt;
  final String status; // 'success', 'failed', 'pending'
  final String? txId;
  final String? error;

  Withdrawal({
    required this.id,
    required this.orderId,
    required this.amountSats,
    required this.destination,
    required this.destinationType,
    required this.createdAt,
    required this.status,
    this.txId,
    this.error,
  });

  factory Withdrawal.fromJson(Map<String, dynamic> json) {
    return Withdrawal(
      id: json['id'] ?? '',
      orderId: json['orderId'] ?? '',
      amountSats: json['amountSats'] ?? 0,
      destination: json['destination'] ?? '',
      destinationType: json['destinationType'] ?? 'unknown',
      createdAt: json['createdAt'] != null 
          ? DateTime.parse(json['createdAt']) 
          : DateTime.now(),
      status: json['status'] ?? 'pending',
      txId: json['txId'],
      error: json['error'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'orderId': orderId,
      'amountSats': amountSats,
      'destination': destination,
      'destinationType': destinationType,
      'createdAt': createdAt.toIso8601String(),
      'status': status,
      if (txId != null) 'txId': txId,
      if (error != null) 'error': error,
    };
  }

  String get statusText {
    switch (status) {
      case 'success':
        return 'Conclu�do';
      case 'failed':
        return 'Falhou';
      case 'pending':
        return 'Pendente';
      default:
        return status;
    }
  }

  String get destinationShort {
    if (destination.length <= 20) return destination;
    
    // Para Lightning Address (user@domain)
    if (destination.contains('@')) return destination;
    
    // Para invoices longas
    return '${destination.substring(0, 10)}...${destination.substring(destination.length - 10)}';
  }
}
