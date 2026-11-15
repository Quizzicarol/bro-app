import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'storage_service.dart';

/// Gerenciador de Relays Nostr
class RelayService extends ChangeNotifier {
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

  // v791: relays REAIS das ordens (NostrOrderService._relays). A tela de
  // gestão mostrava só a lista legada (que nenhuma ordem usa) — a Carol
  // via damus/nos.lol "conectados" enquanto o app operava em apexcord/fly.
  // Espelhado de nostr_order_service.dart L184 (manter em sincronia).
  static const List<String> orderRelays = [
    'wss://apexcord.duckdns.org',
    'wss://bro-relay2.fly.dev',
    'wss://relay.primal.net',
    // v799: damus/nos.lol de volta (vide NostrOrderService._relays — alcance
    // de relay é por-rede; remover zerou o quórum no celular da Carol, 15/11).
    'wss://relay.damus.io',
    'wss://nos.lol',
  ];

  // v791: status de conectividade dos relays de ordens (probe real).
  final Map<String, bool> _orderRelayStatus = {};
  Map<String, bool> get orderRelayStatus => Map.unmodifiable(_orderRelayStatus);

  /// v791: quantos relays de ordens responderam no último probe.
  int get orderRelaysAlive => _orderRelayStatus.values.where((s) => s).length;

  /// v791: testa conectividade REAL (TCP+WebSocket) com os relays de ordens.
  /// Não publica nada — só abre conexão e fecha. Usado pela tela de gestão
  /// e pelo fail-closed do aceite (order_provider).
  ///
  /// v802: considerar o relay VIVO quando o handshake WebSocket completa
  /// (channel.ready). Antes esperávamos o primeiro frame espontâneo do stream
  /// (channel.stream.first) — relays públicos raramente mandam frame sem
  /// subscrição, então contavam como MORTOS (falso-negativo) e o fail-closed
  /// bloqueava aceites com rede perfeitamente boa. Timeout 5s→3s: o probe é
  /// paralelo, o wall time do aceite não pode pagar 5s de relay morto.
  Future<Map<String, bool>> probeOrderRelays({Duration timeout = const Duration(seconds: 3)}) async {
    _orderRelayStatus.clear();
    await Future.wait(orderRelays.map((url) async {
      WebSocketChannel? channel;
      try {
        channel = WebSocketChannel.connect(Uri.parse(url));
        final ok = await channel.ready
            .timeout(timeout, onTimeout: () => throw TimeoutException('probe $url'))
            .then((_) => true)
            .catchError((_) => false);
        _orderRelayStatus[url] = ok;
      } catch (_) {
        _orderRelayStatus[url] = false;
      } finally {
        try { await channel?.sink.close().timeout(const Duration(seconds: 1), onTimeout: () {}); } catch (_) {}
      }
    }));
    notifyListeners();
    return Map.unmodifiable(_orderRelayStatus);
  }

  List<String> _activeRelays = [];

  List<String> get activeRelays => _activeRelays;
  Map<String, bool> get relayStatus => Map.unmodifiable(_relayStatus);

  /// Número de relays atualmente conectados
  int get connectedCount => _relayStatus.values.where((s) => s).length;

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
      broLog('🔌 Conectando ao relay: $url');
      final channel = WebSocketChannel.connect(Uri.parse(url));
      
      _connections[url] = channel;
      _relayStatus[url] = true;
      notifyListeners();

      // Escutar mensagens
      channel.stream.listen(
        (message) {
          _handleMessage(url, message);
        },
        onError: (error) {
          broLog('❌ Erro no relay $url: $error');
          _relayStatus[url] = false;
          notifyListeners();
        },
        onDone: () {
          broLog('🔌 Desconectado do relay: $url');
          _relayStatus[url] = false;
          _connections.remove(url);
          notifyListeners();
        },
      );

      broLog('✅ Conectado ao relay: $url');
      return true;
    } catch (e) {
      broLog('❌ Falha ao conectar ao relay $url: $e');
      _relayStatus[url] = false;
      notifyListeners();
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

  /// Adicionar relay à lista ativa (apenas wss://)
  Future<void> addRelay(String url) async {
    if (!url.startsWith('wss://')) {
      broLog('❌ Relay rejeitado: apenas wss:// é permitido ($url)');
      return;
    }
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
          broLog('📤 Evento enviado para ${entry.key}');
        } catch (e) {
          broLog('❌ Erro ao enviar para ${entry.key}: $e');
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
            broLog('📭 Fim de eventos do relay $relayUrl');
            break;
          case 'OK':
            broLog('✅ Evento aceito pelo relay $relayUrl');
            break;
          case 'NOTICE':
            broLog('📢 Aviso do relay $relayUrl: ${data[1]}');
            break;
        }
      }
    } catch (e) {
      broLog('❌ Erro ao processar mensagem: $e');
    }
  }

  void _handleEvent(String relayUrl, List<dynamic> data) {
    if (data.length >= 3) {
      final event = data[2];
      broLog('📨 Evento recebido de $relayUrl: ${event['kind']}');
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
