/// Mock do BreezProvider para testes
///
/// NOTA: Implementação simples (sem mockito) para evitar complexity.

class MockTransaction {
  final String paymentHash;
  final int amountSats;
  final String description;
  final bool isIncoming;
  final int timestamp;
  final String? invoice;

  MockTransaction({
    required this.paymentHash,
    required this.amountSats,
    required this.description,
    this.isIncoming = false,
    this.timestamp = 0,
    this.invoice,
  });
}

class MockBreezProvider {
  int _balanceSats = 0;
  final Map<String, MockTransaction> _transactions = {};
  final Map<String, String> _seeds = {};
  bool _isInitialized = false;
  String? _error;

  void setBalance(int sats) { _balanceSats = sats; }
  void setError(String? error) { _error = error; }
  // v-fix (09/11): semear histórico direto — o teste autopay_manual_race
  // precisa disso e o método não existia. Uma transação semeada AFETA o saldo
  // (é o modelo mental do teste: gastou 100000 → saldo cai).
  // (getCurrentBalance já existia mais abaixo — não duplicar.)
  void addTransaction(MockTransaction tx) {
    _transactions[tx.paymentHash] = tx;
    _balanceSats += tx.isIncoming ? tx.amountSats : -tx.amountSats;
  }
  void reset() { _balanceSats = 0; _transactions.clear(); _seeds.clear(); _isInitialized = false; _error = null; }

  Future<Map<String, dynamic>> getBalance() async {
    return {'balance': _balanceSats, 'walletBalance': _balanceSats, 'channelBalance': _balanceSats, 'blockHeight': 123456, 'error': _error};
  }

  Future<Map<String, dynamic>?> checkPaymentStatus(String paymentHash) async {
    if (_error != null) return {'paid': false, 'error': _error};
    final tx = _transactions[paymentHash];
    if (tx == null) return {'paid': false};
    return {'paid': true, 'status': 'completed', 'amountSats': tx.amountSats, 'description': tx.description};
  }

  Future<Map<String, dynamic>?> createInvoice({int? amountSats, String? description}) async {
    if (!_isInitialized) return {'success': false, 'error': 'Wallet não inicializada'};
    final paymentHash = 'mock_hash_\${DateTime.now().millisecondsSinceEpoch}';
    final invoice = 'lnbc_mock_\${amountSats ?? 1000}n1...\$paymentHash';
    _transactions[paymentHash] = MockTransaction(
      paymentHash: paymentHash,
      amountSats: amountSats ?? 1000,
      description: description ?? 'Mock Invoice',
      isIncoming: false,
      invoice: invoice,
    );
    return {'success': true, 'bolt11': invoice, 'invoice': invoice, 'paymentHash': paymentHash, 'error': null};
  }

  Future<Map<String, dynamic>?> payInvoice(String bolt11) async {
    if (!_isInitialized) return {'success': false, 'error': 'Wallet não inicializada'};
    final regex = RegExp(r'mock_hash_([a-zA-Z0-9_]+)');
    final match = regex.firstMatch(bolt11);
    if (match == null) return {'success': false, 'error': 'Invoice inválida'};
    final paymentHash = match.group(1)!;
    final tx = _transactions[paymentHash];
    if (tx == null) return {'success': false, 'error': 'Invoice não encontrada'};
    if (_balanceSats < tx.amountSats) return {'success': false, 'error': 'Saldo insuficiente'};
    _balanceSats -= tx.amountSats;
    return {'success': true, 'paymentHash': paymentHash, 'amountSats': tx.amountSats, 'error': null};
  }

  Future<List<Map<String, dynamic>>> getAllPayments() async {
    return _transactions.values.map((tx) => {
      'paymentHash': tx.paymentHash,
      'amountSats': tx.amountSats,
      'description': tx.description,
      'paymentTime': tx.timestamp,
      'status': 'completed',
    }).toList();
  }

  Future<void> forceSyncWallet() async { _isInitialized = true; }
  Future<void> refreshBalance() async {}

  void setSeedForPubkey(String pubkey, String seed) { _seeds[pubkey] = seed; }
  Future<String?> getSeedForPubkey(String pubkey) async => _seeds[pubkey];
  Future<String?> getBreezMnemonic(String pubkey) async => getSeedForPubkey(pubkey);

  Future<bool> initialize({String? mnemonic}) async { _isInitialized = true; return true; }

  List<String> getPaymentHashes() => _transactions.keys.toList();
  int getTransactionCount() => _transactions.length;
  int getCurrentBalance() => _balanceSats;
  bool get isInitialized => _isInitialized;
  bool hasSeed(String pubkey) => _seeds.containsKey(pubkey);
}