library;

/// Harness de testes de corrida — setup de cenários
class TestHarness {
  final Map<String, Map<String, dynamic>> orders = {};

  void setupOrder({
    required String orderId,
    required String userPubkey,
    required int amountSats,
    String status = 'pending',
  }) {
    orders[orderId] = {
      'id': orderId,
      'userPubkey': userPubkey,
      'amountSats': amountSats,
      'status': status,
      'createdAt': DateTime.now().toIso8601String(),
    };
  }

  /// Marca ordem como terminal (v765)
  void setupTerminalOrder(String orderId) {
    orders[orderId] = {
      'id': orderId,
      'userPubkey': 'system',
      'amountSats': 0,
      'status': 'completed',
      'createdAt': DateTime.now().toIso8601String(),
      'terminal': true,
    };
  }

  Map<String, dynamic>? getOrder(String orderId) => orders[orderId];

  void resetAll() => orders.clear();
}