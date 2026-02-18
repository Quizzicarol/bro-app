import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'storage_service.dart';

/// Gerenciador de Relays Nostr
class RelayService {
  static final RelayService _instance = RelayService._internal();
  factory RelayService() => _instance;
  RelayService._internal();

  final Map<String, WebSocketChannel> _connections = {};
  final Map<String, bool> _relayStatus = {};
  final _storage = StorageService();

  // Relays padrão populares
  static const List<String> defaultRelays = [
    'wss://relay.damus.io',
    'wss://relay.nostr.band',
    'wss://nos.lol',
    'wss://relay.snort.social',
    'wss://nostr.wine',
    'wss://relay.primal.net',
  ];

  // Relays pagos (mais privacidade)
  static const List<String> paidRelays = [
    'wss://relay.nostr.com.au',
    'wss://eden.nostr.land',
  ];

  List<String> _activeRelays = [];

  List<String> get activeRelays => _activeRelays;
  Map<String, bool> get relayStatus => Map.unmodifiable(_relayStatus);

  /// Inicializar relays salvos ou padrão
  Future<void> initialize() async {
    final saved = await _storage.getRelays();
    _activeRelays = saved ?? defaultRelays.take(3).toList();
    
    // Conectar aos relays ativos
    for (final relay in _activeRelays) {
      await connectToRelay(relay);
    }
  }

  /// Conectar a um relay específico
  Future<bool> connectToRelay(String url) async {
    if (_connections.containsKey(url)) {
      return _relayStatus[url] ?? false;
    }

    try {
      debugPrint('🔌 Conectando ao relay: $url');
      final channel = WebSocketChannel.connect(Uri.parse(url));
      
      _connections[url] = channel;
      _relayStatus[url] = true;

      // Escutar mensagens
      channel.stream.listen(
        (message) {
          _handleMessage(url, message);
        },
        onError: (error) {
          debugPrint('❌ Erro no relay $url: $error');
          _relayStatus[url] = false;
        },
        onDone: () {
          debugPrint('🔌 Desconectado do relay: $url');
          _relayStatus[url] = false;
          _connections.remove(url);
        },
      );

      debugPrint('✅ Conectado ao relay: $url');
      return true;
    } catch (e) {
      debugPrint('❌ Falha ao conectar ao relay $url: $e');
      _relayStatus[url] = false;
      return false;
    }
  }

  /// Desconectar de um relay
  Future<void> disconnectFromRelay(String url) async {
    final channel = _connections[url];
    if (channel != null) {
      await channel.sink.close();
      _connections.remove(url);
      _relayStatus.remove(url);
    }
  }

  /// Adicionar relay à lista ativa
  Future<void> addRelay(String url) async {
    if (!_activeRelays.contains(url)) {
      _activeRelays.add(url);
      await _storage.saveRelays(_activeRelays);
      await connectToRelay(url);
    }
  }

  /// Remover relay da lista ativa
  Future<void> removeRelay(String url) async {
    _activeRelays.remove(url);
    await _storage.saveRelays(_activeRelays);
    await disconnectFromRelay(url);
  }

  /// Enviar evento para todos os relays conectados
  Future<void> publishEvent(Map<String, dynamic> event) async {
    final message = jsonEncode(['EVENT', event]);
    
    for (final entry in _connections.entries) {
      if (_relayStatus[entry.key] == true) {
        try {
          entry.value.sink.add(message);
          debugPrint('📤 Evento enviado para ${entry.key}');
        } catch (e) {
          debugPrint('❌ Erro ao enviar para ${entry.key}: $e');
        }
      }
    }
  }

  /// Buscar perfil Nostr (NIP-01)
  Future<Map<String, dynamic>?> fetchProfile(String pubkey) async {
    final completer = Completer<Map<String, dynamic>?>();
    final subscriptionId = 'profile_${DateTime.now().millisecondsSinceEpoch}';

    // Criar filtro para metadados (kind 0)
    final filter = {
      'kinds': [0],
      'authors': [pubkey],
      'limit': 1,
    };

    final request = jsonEncode(['REQ', subscriptionId, filter]);

    // Enviar para primeiro relay conectado
    for (final entry in _connections.entries) {
      if (_relayStatus[entry.key] == true) {
        entry.value.sink.add(request);
        
        // Timeout de 5 segundos
        Timer(const Duration(seconds: 5), () {
          if (!completer.isCompleted) {
            completer.complete(null);
          }
        });
        
        break;
      }
    }

    return completer.future;
  }

  /// Handler de mensagens dos relays
  void _handleMessage(String relayUrl, dynamic message) {
    try {
      final data = jsonDecode(message);
      if (data is List && data.isNotEmpty) {
        final type = data[0];
        
        switch (type) {
          case 'EVENT':
            _handleEvent(relayUrl, data);
            break;
          case 'EOSE':
            debugPrint('📭 Fim de eventos do relay $relayUrl');
            break;
          case 'OK':
            debugPrint('✅ Evento aceito pelo relay $relayUrl');
            break;
          case 'NOTICE':
            debugPrint('📢 Aviso do relay $relayUrl: ${data[1]}');
            break;
        }
      }
    } catch (e) {
      debugPrint('❌ Erro ao processar mensagem: $e');
    }
  }

  void _handleEvent(String relayUrl, List<dynamic> data) {
    if (data.length >= 3) {
      final event = data[2];
      debugPrint('📨 Evento recebido de $relayUrl: ${event['kind']}');
      // TODO: Processar diferentes tipos de eventos
    }
  }

  /// Fechar todas as conexões
  Future<void> dispose() async {
    for (final channel in _connections.values) {
      await channel.sink.close();
    }
    _connections.clear();
    _relayStatus.clear();
  }
}
