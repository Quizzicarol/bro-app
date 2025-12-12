import 'dart:convert';
import 'package:nostr/nostr.dart';

class NostrService {
  static final NostrService _instance = NostrService._internal();
  factory NostrService() => _instance;
  NostrService._internal();

  String? _privateKey;
  String? _publicKey;

  // Gerar par de chaves Nostr usando biblioteca real
  Map<String, String> generateKeys() {
    final keyPair = Keychain.generate();
    final privateKey = keyPair.private;
    final publicKey = keyPair.public;

    return {
      'privateKey': privateKey,
      'publicKey': publicKey,
    };
  }

  // Derivar chave pública da privada usando biblioteca real
  String getPublicKey(String privateKey) {
    try {
      final keyPair = Keychain(privateKey);
      return keyPair.public;
    } catch (e) {
      throw Exception('Invalid private key: $e');
    }
  }

  // Assinar evento Nostr usando biblioteca real
  String signEvent(Event event, String privateKey) {
    try {
      final keyPair = Keychain(privateKey);
      // Event.from já retorna evento assinado
      final signedEvent = Event.from(
        kind: event.kind,
        tags: event.tags,
        content: event.content,
        privkey: keyPair.private,
      );
      return signedEvent.sig ?? '';
    } catch (e) {
      throw Exception('Failed to sign event: $e');
    }
  }

  // Criar evento Nostr usando biblioteca real
  Event createNostrEvent({
    required String privateKey,
    required int kind,
    required String content,
    List<List<String>> tags = const [],
  }) {
    try {
      final keyPair = Keychain(privateKey);
      final event = Event.from(
        kind: kind,
        tags: tags,
        content: content,
        privkey: keyPair.private,
      );
      return event;
    } catch (e) {
      throw Exception('Failed to create event: $e');
    }
  }

  // Criar evento Nostr compatível com backend (retorna Map)
  Map<String, dynamic> createEvent({
    required String privateKey,
    required int kind,
    required String content,
    List<List<String>> tags = const [],
  }) {
    final event = createNostrEvent(
      privateKey: privateKey,
      kind: kind,
      content: content,
      tags: tags,
    );

    return {
      'id': event.id,
      'pubkey': event.pubkey,
      'created_at': event.createdAt,
      'kind': event.kind,
      'tags': event.tags,
      'content': event.content,
      'sig': event.sig,
    };
  }

  // Criar evento de ordem
  Map<String, dynamic> createOrderEvent({
    required String privateKey,
    required String billType,
    required String billCode,
    required double amount,
    required double btcAmount,
  }) {
    final content = jsonEncode({
      'type': 'order',
      'billType': billType,
      'billCode': billCode,
      'amount': amount,
      'btcAmount': btcAmount,
      'timestamp': DateTime.now().toIso8601String(),
    });

    return createEvent(
      privateKey: privateKey,
      kind: 1000, // Custom kind for orders
      content: content,
      tags: [
        ['t', 'paga-conta'],
        ['t', 'order'],
      ],
    );
  }

  // Validar chave privada
  bool isValidPrivateKey(String key) {
    try {
      final keyPair = Keychain(key);
      return keyPair.public.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  // Set current keys
  void setKeys(String privateKey, String publicKey) {
    _privateKey = privateKey;
    _publicKey = publicKey;
  }

  // Getters
  String? get privateKey => _privateKey;
  String? get publicKey => _publicKey;
}
