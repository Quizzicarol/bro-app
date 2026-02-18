class NostrMessage {
  final String id;
  final String orderId;
  final String senderId;
  final String senderName;
  final String content;
  final DateTime timestamp;
  final bool isProvider;
  final Map<String, dynamic>? metadata;

  NostrMessage({
    required this.id,
    required this.orderId,
    required this.senderId,
    required this.senderName,
    required this.content,
    required this.timestamp,
    required this.isProvider,
    this.metadata,
  });

  factory NostrMessage.fromJson(Map<String, dynamic> json) {
    return NostrMessage(
      id: json['id'] ?? '',
      orderId: json['orderId'] ?? '',
      senderId: json['senderId'] ?? '',
      senderName: json['senderName'] ?? 'An�nimo',
      content: json['content'] ?? '',
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'])
          : DateTime.now(),
      isProvider: json['isProvider'] ?? false,
      metadata: json['metadata'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'orderId': orderId,
      'senderId': senderId,
      'senderName': senderName,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'isProvider': isProvider,
      if (metadata != null) 'metadata': metadata,
    };
  }
}
