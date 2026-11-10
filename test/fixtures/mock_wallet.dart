/// Mock do BreezProvider para testes
/// NOTA: Implementação simples

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
    
    // Mock: extrair valor da invoice
    final amountMatch = RegExp(r'lnbc_mock_(\d+)').firstMatch(bolt11);
    final amountSats = amountMatch != null ? int.tryParse(amountMatch.group(1)!) ?? 0 : 0;
    
    if (amountSats <= 0) {
      return {'success': false, 'error': 'Invoice inválida'};
    }
    if (_balanceSats < amountSats) {
      return {'success': false, 'error': 'Saldo insuficiente'};
    }
    
    final paymentHash = 'mock_hash_\${DateTime.now().millisecondsSinceEpoch}';
    _transactions[paymentHash] = MockTransaction(
      paymentHash: paymentHash,
      amountSats: amountSats,
      description: 'Saque mock',
      isIncoming: false,
      invoice: bolt11,
    );
    _balanceSats -= amountSats;
    
    return {'success': true, 'paymentHash': paymentHash, 'amountSats': amountSats, 'error': null};
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