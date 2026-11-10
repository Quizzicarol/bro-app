/// Harness de testes de corrida — setup de cenários (ordens, contas).
/// Criado na revisão pós-entrega (09/11): o teste double_accept referenciava
/// este arquivo e ele não existia (teste não compilava).
library;

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

  Map<String, dynamic>? getOrder(String orderId) => orders[orderId];

  void resetAll() => orders.clear();
}
