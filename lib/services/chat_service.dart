import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:nostr/nostr.dart';
import 'nip04_service.dart';
import 'storage_service.dart';

/// Modelo de mensagem de chat
class ChatMessage {
  final String id;
  final String senderPubkey;
  final String receiverPubkey;
  final String content;
  final DateTime timestamp;
  final bool isFromMe;
  final bool isEncrypted;

  ChatMessage({
    required this.id,
    required this.senderPubkey,
    required this.receiverPubkey,
    required this.content,
    required this.timestamp,
    required this.isFromMe,
    this.isEncrypted = true,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'senderPubkey': senderPubkey,
    'receiverPubkey': receiverPubkey,
    'content': content,
    'timestamp': timestamp.millisecondsSinceEpoch,
    'isFromMe': isFromMe,
    'isEncrypted': isEncrypted,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'],
    senderPubkey: json['senderPubkey'],
    receiverPubkey: json['receiverPubkey'],
    content: json['content'],
    timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp']),
    isFromMe: json['isFromMe'],
    isEncrypted: json['isEncrypted'] ?? true,
  );
}

/// Servi�o de Chat via Nostr DMs (NIP-04)
class ChatService {
  static final ChatService _instance = ChatService._internal();
  factory ChatService() => _instance;
  ChatService._internal();

  final _nip04 = Nip04Service();
  final _storage = StorageService();
  
  final Map<String, WebSocketChannel> _connections = {};
  final Map<String, StreamController<ChatMessage>> _messageStreams = {};
  final Map<String, List<ChatMessage>> _messageCache = {};
  
  String? _privateKey;
  String? _publicKey;
  
  // Relays para chat (mesmos das ofertas)
  static const List<String> chatRelays = [
    'wss://relay.damus.io',
    'wss://nos.lol',
    'wss://relay.nostr.band',
    'wss://relay.primal.net',
  ];

  /// Limpar cache de mensagens (chamado no logout)
  Future<void> clearCache() async {
    _messageCache.clear();
    debugPrint('?? ChatService: Cache de mensagens limpo');
  }

  /// Inicializar servi�o de chat
  Future<void> initialize(String privateKey, String publicKey) async {
    // Limpar cache de mem�ria ao trocar de usu�rio
    if (_publicKey != null && _publicKey != publicKey) {
      _messageCache.clear();
      debugPrint('?? ChatService: Cache limpo - usu�rio mudou');
    }
    
    _privateKey = privateKey;
    _publicKey = publicKey;
    
    debugPrint('?? ChatService: Inicializando com pubkey ${publicKey.substring(0, 16)}...');
    debugPrint('?? ChatService: PrivateKey hash: ${privateKey.hashCode}');
    
    // Carregar mensagens do cache local
    await _loadCachedMessages();
    debugPrint('?? ChatService: ${_messageCache.length} conversas no cache local');
    
    // Listar todas as conversas carregadas
    for (final entry in _messageCache.entries) {
      final isSelf = entry.key == publicKey;
      debugPrint('   - ${entry.key.substring(0, 8)}...: ${entry.value.length} msgs ${isSelf ? "(SELF)" : ""}');
    }
    
    // Conectar aos relays
    int connectedCount = 0;
    for (final relay in chatRelays) {
      final connected = await _connectToRelay(relay);
      if (connected) connectedCount++;
    }
    debugPrint('?? ChatService: Conectado a $connectedCount/${chatRelays.length} relays');
    
    // Come�ar a escutar DMs
    _subscribeToDirectMessages();
    debugPrint('?? ChatService: Inscrito para receber DMs');
  }

  /// Conectar a um relay
  Future<bool> _connectToRelay(String url) async {
    if (_connections.containsKey(url)) return true;
    
    try {
      debugPrint('?? Chat: Conectando ao relay $url');
      final channel = WebSocketChannel.connect(Uri.parse(url));
      
      _connections[url] = channel;
      
      channel.stream.listen(
        (message) => _handleMessage(url, message),
        onError: (error) {
          debugPrint('? Chat: Erro no relay $url: $error');
          _connections.remove(url);
        },
        onDone: () {
          debugPrint('?? Chat: Desconectado de $url');
          _connections.remove(url);
        },
      );
      
      debugPrint('? Chat: Conectado ao relay $url');
      return true;
    } catch (e) {
      debugPrint('? Chat: Falha ao conectar ao relay $url: $e');
      return false;
    }
  }

  /// Inscrever-se para receber DMs
  void _subscribeToDirectMessages() {
    if (_publicKey == null) return;
    
    final subscriptionId = 'chat_${DateTime.now().millisecondsSinceEpoch}';
    
    // Filtro NIP-04: kind 4, destinado a mim ou enviado por mim
    final filters = [
      {
        'kinds': [4],
        '#p': [_publicKey],
        'limit': 100,
      },
      {
        'kinds': [4],
        'authors': [_publicKey],
        'limit': 100,
      },
    ];
    
    for (final filter in filters) {
      final request = jsonEncode(['REQ', subscriptionId, filter]);
      
      for (final channel in _connections.values) {
        try {
          channel.sink.add(request);
        } catch (e) {
          debugPrint('? Chat: Erro ao enviar subscription: $e');
        }
      }
    }
  }

  /// Handler de mensagens recebidas
  void _handleMessage(String relayUrl, dynamic message) {
    try {
      final data = jsonDecode(message);
      if (data is! List || data.isEmpty) return;
      
      final type = data[0];
      
      if (type == 'EVENT' && data.length >= 3) {
        final eventData = data[2] as Map<String, dynamic>;
        _handleIncomingEvent(eventData);
      } else if (type == 'OK') {
        debugPrint('? Chat: Mensagem aceita pelo relay $relayUrl');
      } else if (type == 'NOTICE') {
        debugPrint('?? Chat: $relayUrl: ${data[1]}');
      }
    } catch (e) {
      debugPrint('? Chat: Erro ao processar mensagem: $e');
    }
  }

  /// Processar evento de DM recebido
  void _handleIncomingEvent(Map<String, dynamic> eventData) {
    try {
      final kind = eventData['kind'] as int;
      if (kind != 4) return; // Apenas DMs
      
      final id = eventData['id'] as String;
      final pubkey = eventData['pubkey'] as String;
      final content = eventData['content'] as String;
      final createdAt = eventData['created_at'] as int;
      final tags = eventData['tags'] as List<dynamic>;
      
      debugPrint('?? Chat: Recebido evento DM de ${pubkey.substring(0, 8)}...');
      
      // Extrair destinat�rio da tag 'p'
      String? recipientPubkey;
      for (final tag in tags) {
        if (tag is List && tag.isNotEmpty && tag[0] == 'p') {
          recipientPubkey = tag[1] as String;
          break;
        }
      }
      
      if (recipientPubkey == null) {
        debugPrint('?? Chat: Evento sem tag p (destinat�rio)');
        return;
      }
      
      // Determinar se sou o remetente ou destinat�rio
      final isFromMe = pubkey == _publicKey;
      final otherPubkey = isFromMe ? recipientPubkey : pubkey;
      
      debugPrint('?? Chat: isFromMe=$isFromMe, otherPubkey=${otherPubkey.substring(0, 8)}...');
      
      // Descriptografar mensagem
      String decryptedContent;
      try {
        decryptedContent = _nip04.decrypt(
          content,
          _privateKey!,
          otherPubkey,
        );
        debugPrint('? Chat: Mensagem descriptografada com sucesso');
      } catch (e) {
        debugPrint('?? Chat: N�o foi poss�vel descriptografar: $e');
        decryptedContent = '[Mensagem criptografada]';
      }
      
      final chatMessage = ChatMessage(
        id: id,
        senderPubkey: pubkey,
        receiverPubkey: recipientPubkey,
        content: decryptedContent,
        timestamp: DateTime.fromMillisecondsSinceEpoch(createdAt * 1000),
        isFromMe: isFromMe,
      );
      
      // Adicionar ao cache se n�o existir
      _messageCache.putIfAbsent(otherPubkey, () => []);
      if (!_messageCache[otherPubkey]!.any((m) => m.id == id)) {
        _messageCache[otherPubkey]!.add(chatMessage);
        _messageCache[otherPubkey]!.sort((a, b) => a.timestamp.compareTo(b.timestamp));
        
        // Notificar stream
        _messageStreams[otherPubkey]?.add(chatMessage);
        
        // Salvar no storage
        _saveCachedMessages();
      }
      
      debugPrint('?? Chat: Mensagem ${isFromMe ? "enviada" : "recebida"} de/para $otherPubkey');
    } catch (e) {
      debugPrint('? Chat: Erro ao processar evento: $e');
    }
  }

  /// Enviar mensagem para um pubkey
  Future<bool> sendMessage(String recipientPubkey, String message) async {
    if (_privateKey == null || _publicKey == null) {
      debugPrint('? Chat: Chaves n�o configuradas');
      return false;
    }
    
    try {
      // Criptografar mensagem usando NIP-04
      final encryptedContent = _nip04.encrypt(
        message,
        _privateKey!,
        recipientPubkey,
      );
      
      // Criar evento NIP-04 (kind 4)
      final keychain = Keychain(_privateKey!);
      final event = Event.from(
        kind: 4,
        tags: [['p', recipientPubkey]],
        content: encryptedContent,
        privkey: keychain.private,
      );
      
      // Converter para JSON
      final eventJson = {
        'id': event.id,
        'pubkey': event.pubkey,
        'created_at': event.createdAt,
        'kind': event.kind,
        'tags': event.tags,
        'content': event.content,
        'sig': event.sig,
      };
      
      // Publicar nos relays
      final eventMessage = jsonEncode(['EVENT', eventJson]);
      var sentCount = 0;
      
      for (final channel in _connections.values) {
        try {
          channel.sink.add(eventMessage);
          sentCount++;
        } catch (e) {
          debugPrint('? Chat: Erro ao enviar para relay: $e');
        }
      }
      
      if (sentCount > 0) {
        // Adicionar ao cache local imediatamente
        final chatMessage = ChatMessage(
          id: event.id!,
          senderPubkey: _publicKey!,
          receiverPubkey: recipientPubkey,
          content: message,
          timestamp: DateTime.now(),
          isFromMe: true,
        );
        
        _messageCache.putIfAbsent(recipientPubkey, () => []);
        _messageCache[recipientPubkey]!.add(chatMessage);
        _messageStreams[recipientPubkey]?.add(chatMessage);
        _saveCachedMessages();
        
        debugPrint('? Chat: Mensagem enviada para $sentCount relays');
        return true;
      }
      
      return false;
    } catch (e) {
      debugPrint('? Chat: Erro ao enviar mensagem: $e');
      return false;
    }
  }

  /// Obter stream de mensagens para uma conversa
  Stream<ChatMessage> getMessageStream(String otherPubkey) {
    _messageStreams.putIfAbsent(
      otherPubkey,
      () => StreamController<ChatMessage>.broadcast(),
    );
    return _messageStreams[otherPubkey]!.stream;
  }

  /// Obter hist�rico de mensagens com um pubkey
  List<ChatMessage> getMessages(String otherPubkey) {
    return _messageCache[otherPubkey] ?? [];
  }

  /// For�ar re-fetch de todas as mensagens dos relays
  Future<void> refreshAllMessages() async {
    if (_publicKey == null) return;
    
    debugPrint('?? Chat: For�ando refresh de todas as mensagens...');
    
    // Re-inscrever para DMs
    _subscribeToDirectMessages();
    
    // Buscar mensagens de cada conversa conhecida
    for (final pubkey in _messageCache.keys.toList()) {
      await fetchMessagesFrom(pubkey);
    }
    
    debugPrint('?? Chat: Refresh solicitado para ${_messageCache.length} conversas');
  }

  /// Obter n�mero total de mensagens no cache
  int get totalCachedMessages {
    int total = 0;
    for (final messages in _messageCache.values) {
      total += messages.length;
    }
    return total;
  }

  /// Obter lista de conversas
  List<String> getConversations() {
    return _messageCache.keys.toList();
  }

  /// Carregar mensagens do cache local
  Future<void> _loadCachedMessages() async {
    try {
      final prefs = await _storage.prefs;
      // Usar chave per-user para n�o vazar mensagens entre usu�rios
      final cacheKey = _publicKey != null ? 'chat_messages_${_publicKey!.substring(0, 16)}' : 'chat_messages';
      final cached = prefs?.getString(cacheKey);
      if (cached != null) {
        final data = jsonDecode(cached) as Map<String, dynamic>;
        for (final entry in data.entries) {
          final messages = (entry.value as List)
              .map((m) => ChatMessage.fromJson(m))
              .toList();
          _messageCache[entry.key] = messages;
        }
        debugPrint('?? Chat: ${_messageCache.length} conversas carregadas');
      }
    } catch (e) {
      debugPrint('?? Chat: Erro ao carregar cache: $e');
    }
  }

  /// Salvar mensagens no cache local
  Future<void> _saveCachedMessages() async {
    try {
      final data = <String, dynamic>{};
      for (final entry in _messageCache.entries) {
        data[entry.key] = entry.value.map((m) => m.toJson()).toList();
      }
      final prefs = await _storage.prefs;
      // Usar chave per-user para n�o vazar mensagens entre usu�rios
      final cacheKey = _publicKey != null ? 'chat_messages_${_publicKey!.substring(0, 16)}' : 'chat_messages';
      await prefs?.setString(cacheKey, jsonEncode(data));
    } catch (e) {
      debugPrint('?? Chat: Erro ao salvar cache: $e');
    }
  }

  /// Buscar mensagens antigas de um pubkey espec�fico
  Future<void> fetchMessagesFrom(String otherPubkey) async {
    if (_publicKey == null) return;
    
    final subscriptionId = 'fetch_${DateTime.now().millisecondsSinceEpoch}';
    
    // Buscar mensagens enviadas para mim por esse pubkey
    final filter1 = {
      'kinds': [4],
      'authors': [otherPubkey],
      '#p': [_publicKey],
      'limit': 50,
    };
    
    // Buscar mensagens que eu enviei para esse pubkey
    final filter2 = {
      'kinds': [4],
      'authors': [_publicKey],
      '#p': [otherPubkey],
      'limit': 50,
    };
    
    final request1 = jsonEncode(['REQ', '${subscriptionId}_1', filter1]);
    final request2 = jsonEncode(['REQ', '${subscriptionId}_2', filter2]);
    
    for (final channel in _connections.values) {
      try {
        channel.sink.add(request1);
        channel.sink.add(request2);
      } catch (e) {
        debugPrint('? Chat: Erro ao buscar mensagens: $e');
      }
    }
  }

  /// Fechar todas as conex�es
  void dispose() {
    for (final channel in _connections.values) {
      channel.sink.close();
    }
    _connections.clear();
    
    for (final stream in _messageStreams.values) {
      stream.close();
    }
    _messageStreams.clear();
  }
}
