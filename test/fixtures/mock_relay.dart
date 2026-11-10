/// Mock do NostrServiceRelay para testes
///
/// NOTA: Sem mockito

class MockNostrEvent {
  final String id;
  final String pubkey;
  final int createdAt;
  final String kind;
  final String content;
  final Map<String, dynamic> tags;

  MockNostrEvent({
    required this.id,
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.content,
    this.tags = const {},
  });

  toJson() => {
    'id': id,
    'pubkey': pubkey,
    'created_at': createdAt,
    'kind': int.tryParse(kind) ?? 1,
    'content': content,
    'tags': tags,
    'sig': 'mock_sig_\$id',
  };
}

class MockNostrRelay {
  final List<MockNostrEvent> _events = [];
  final Map<String, String> _userProfiles = {};
  final Map<String, String> _seeds = {};
  String? _adminPubkey;
  bool _isConnected = false;

  void setAdminPubkey(String pubkey) { _adminPubkey = pubkey; }
  void disconnect() { _isConnected = false; }
  void connect() { _isConnected = true; }
  void reset() { _events.clear(); _userProfiles.clear(); _seeds.clear(); }

  Future<bool> publishEvent(MockNostrEvent event) async {
    if (!_isConnected) return false;
    _events.add(event);
    return true;
  }

  List<MockNostrEvent> queryEvents({String? kind, String? author, int? since}) {
    return _events.where((e) {
      if (kind != null && e.kind != kind) return false;
      if (author != null && e.pubkey != author) return false;
      if (since != null && e.createdAt < since) return false;
      return true;
    }).toList();
  }

  void setUserProfile(String pubkey, String profileJson) { _userProfiles[pubkey] = profileJson; }
  String? getUserProfile(String pubkey) { return _userProfiles[pubkey]; }
  void setUserSeed(String pubkey, String seed) { _seeds[pubkey] = seed; }
  String? getUserSeed(String pubkey) { return _seeds[pubkey]; }

  List<MockNostrEvent> getAllEvents() => List.from(_events);
  int getEventCount() => _events.length;
}

/// Mock do NostrService
class MockNostrService {
  // v-fix (09/11): relay INJETÁVEL — antes cada service tinha seu relay
  // PRIVADO e o teste lia um relay separado (asserts sempre vazios).
  final MockNostrRelay _relay;
  String? _currentPubkey;
  String? _currentPrivkey;
  bool _isInitialized = false;

  MockNostrService({MockNostrRelay? relay}) : _relay = relay ?? MockNostrRelay();

  MockNostrRelay get relay => _relay;

  Future<void> initialize({required String mnemonic, required String? privKey}) async {
    _isInitialized = true;
    _currentPrivkey = privKey;
    if (privKey != null && privKey.length >= 8) {
      _currentPubkey = 'npub1\${_shortHash(privKey)}';
    }
  }

  void reset() {
    _relay.reset();
    _currentPubkey = null;
    _currentPrivkey = null;
    _isInitialized = false;
  }

  Future<String?> getPublicKey() async => _currentPubkey;
  Future<String?> getPrivateKey() async => _currentPrivkey;
  Future<bool> isInitialized() async => _isInitialized;

  Future<bool> publishEvent(Map<String, dynamic> event) async {
    if (!_isInitialized) return false;
    if (_currentPubkey == null) return false;
    final mockEvent = MockNostrEvent(
      id: 'evt_\${DateTime.now().millisecondsSinceEpoch}',
      pubkey: _currentPubkey!,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      kind: event['kind']?.toString() ?? '1',
      content: event['content']?.toString() ?? '',
      tags: event['tags'] as Map<String, dynamic>? ?? {},
    );
    return _relay.publishEvent(mockEvent);
  }

  Future<List<dynamic>> fetchEvents({String? id, String? author, String? kind, int? since, int? until, int? limit}) async {
    if (!_isInitialized) return [];
    var results = _relay.queryEvents(kind: kind, author: author);
    if (since != null) results = results.where((e) => e.createdAt >= since).toList();
    if (until != null) results = results.where((e) => e.createdAt <= until).toList();
    if (limit != null) results = results.take(limit).toList();
    return results.map((e) => e.toJson()).toList();
  }

  String _shortHash(String input) {
    return input.substring(0, 8).hashCode.abs().toString();
  }
}