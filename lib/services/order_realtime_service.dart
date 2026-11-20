import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:nostr/nostr.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bro_app/services/log_utils.dart';

/// Real-time Nostr WebSocket subscription for order events.
/// Maintains persistent connections to relays and triggers callbacks
/// when new order events arrive (accept, payment, billCode, complete, dispute).
class OrderRealtimeService {
  static final OrderRealtimeService _instance =
      OrderRealtimeService._internal();
  factory OrderRealtimeService() => _instance;
  OrderRealtimeService._internal();

  // v793: espelha NostrOrderService._relays (ordens operam em apexcord/fly —
  // damus 521 e nos.lol instáveis deixaram o RT cego pros eventos nossos).
  static const List<String> _relays = [
    'wss://apexcord.duckdns.org',
    'wss://bro-relay2.fly.dev',
    'wss://relay.primal.net',
    'wss://relay.damus.io',
    'wss://nos.lol',
  ];

  final Map<String, WebSocketChannel> _connections = {};
  final Set<String> _connecting = {};
  final Map<String, StreamSubscription<dynamic>> _subscriptions = {};
  final Map<String, WebSocketChannel> _pendingChannels = {};
  final Map<String, int> _reconnectFailures = {};
  final Map<String, DateTime> _reconnectNotBefore = {};
  final Set<String> _processedEventIds = {};
  String? _pubkey;
  bool _isRunning = false;
  Timer? _reconnectTimer;
  Timer? _cleanupTimer;
  int _eventsThisSecond = 0;
  int _lastSecond = 0;
  static const int _maxEventsPerSecond = 20;
  static const Duration _readyTimeout = Duration(seconds: 8);
  static const Duration _maxReconnectDelay = Duration(minutes: 5);

  @visibleForTesting
  static WebSocketChannel Function(Uri uri)? channelFactoryOverride;

  @visibleForTesting
  static Duration Function(int failures)? reconnectDelayOverride;

  @visibleForTesting
  static List<String>? relaysOverride;

  @visibleForTesting
  static Duration readyTimeoutOverride = _readyTimeout;

  @visibleForTesting
  static Duration reconnectCheckInterval = const Duration(seconds: 30);

  @visibleForTesting
  static DateTime Function() clockOverride = DateTime.now;

  static Duration reconnectDelay(int failures) {
    final exponent = min(max(failures - 1, 0), 6);
    final baseMs = 1000 * (1 << exponent);
    final jitterMs = Random().nextInt(baseMs + 1);
    return Duration(
        milliseconds:
            min(baseMs + jitterMs, _maxReconnectDelay.inMilliseconds));
  }

  // Callback when a new order event arrives — triggers sync
  void Function()? onOrderEvent;

  // v552: Callback when an order_update FCM push arrives.
  // Carries the orderId + subtype so the OrderProvider can mark the order
  // as "syncing" with an expected target status, allowing the UI to show
  // a spinner/placeholder while the relay sync catches up.
  void Function(String orderId, String subtype)? onOrderPush;

  // Nostr event kinds for orders
  static const int _kindAccept = 30079;
  static const int _kindPaymentProof = 30080;
  static const int _kindComplete = 30081;

  /// Start listening for real-time order events
  void start(String pubkey, {void Function()? onEvent}) {
    if (_isRunning && _pubkey == pubkey) {
      onOrderEvent = onEvent;
      return;
    }
    if (_isRunning || _pubkey != null) {
      stop();
    }

    _pubkey = pubkey;
    onOrderEvent = onEvent;
    _isRunning = true;

    broLog(
        '[RT] OrderRealtimeService starting for ${pubkey.substring(0, 16)}...');

    // Connect to all relays
    for (final url in relaysOverride ?? _relays) {
      unawaited(_connectAndSubscribe(url));
    }

    // Reconnect check periódico; cada relay tem seu próprio backoff.
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(reconnectCheckInterval, (_) {
      _checkReconnect();
    });

    // Cleanup old event IDs every 5 min to prevent memory leak
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (_processedEventIds.length > 500) {
        // Keep last 200 IDs instead of clearing all — prevents re-notification
        final keep = _processedEventIds
            .toList()
            .sublist(_processedEventIds.length - 200);
        _processedEventIds.clear();
        _processedEventIds.addAll(keep);
        broLog(
            '[RT] Trimmed processedEventIds to ${_processedEventIds.length}');
      }
    });
  }

  /// Stop listening
  void stop() {
    _isRunning = false;
    _reconnectTimer?.cancel();
    _cleanupTimer?.cancel();
    for (final subscription in _subscriptions.values) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    for (final channel in _connections.values) {
      try {
        unawaited(channel.sink.close());
      } catch (_) {}
    }
    for (final channel in _pendingChannels.values) {
      try {
        unawaited(channel.sink.close());
      } catch (_) {}
    }
    _pendingChannels.clear();
    _connections.clear();
    _connecting.clear();
    _reconnectFailures.clear();
    _reconnectNotBefore.clear();
    _processedEventIds.clear();
    broLog('[RT] OrderRealtimeService stopped');
  }

  Future<void> _connectAndSubscribe(String url) async {
    final pubkey = _pubkey;
    if (!_isRunning || pubkey == null) return;
    if (_connections.containsKey(url) || _connecting.contains(url)) return;
    final notBefore = _reconnectNotBefore[url];
    if (notBefore != null && clockOverride().isBefore(notBefore)) return;

    _connecting.add(url);
    WebSocketChannel? channel;
    try {
      final factory = channelFactoryOverride;
      channel = factory != null
          ? factory(Uri.parse(url))
          : WebSocketChannel.connect(Uri.parse(url));
      _pendingChannels[url] = channel;
      await channel.ready.timeout(readyTimeoutOverride);
      if (!_isRunning || _pubkey != pubkey) {
        await channel.sink.close();
        return;
      }

      _connections[url] = channel;
      _reconnectFailures.remove(url);
      _reconnectNotBefore.remove(url);
      _subscriptions[url] = channel.stream.listen(
        (message) => _handleMessage(url, message),
        onError: (error) {
          broLog('[RT] Error on $url: $error');
          _handleDisconnect(url, channel!);
        },
        onDone: () => _handleDisconnect(url, channel!),
      );

      // Subscribe to order events where I'm tagged (#p = my pubkey)
      final subId = 'rt_orders_${DateTime.now().millisecondsSinceEpoch}';
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      // Filter 1: Events tagged to me (I'm buyer or provider)
      final filter1 = {
        'kinds': [_kindAccept, _kindPaymentProof, _kindComplete],
        '#p': [pubkey],
        'since': now - 300, // Last 5 min to catch very recent + future
      };

      // Filter 2: Events authored by me (to see confirmations)
      final filter2 = {
        'kinds': [_kindAccept, _kindPaymentProof, _kindComplete],
        'authors': [pubkey],
        'since': now - 300,
      };

      channel.sink.add(jsonEncode(['REQ', '${subId}_1', filter1]));
      channel.sink.add(jsonEncode(['REQ', '${subId}_2', filter2]));
    } catch (e) {
      broLog('[RT] Failed to connect to $url: $e');
      if (_pubkey == pubkey) _scheduleReconnect(url);
      try {
        await channel?.sink.close();
      } catch (_) {}
    } finally {
      if (identical(_pendingChannels[url], channel)) {
        _pendingChannels.remove(url);
      }
      _connecting.remove(url);
    }
  }

  void _handleDisconnect(String url, WebSocketChannel channel) {
    if (!identical(_connections[url], channel)) return;
    _connections.remove(url);
    final subscription = _subscriptions.remove(url);
    if (subscription != null) unawaited(subscription.cancel());
    _scheduleReconnect(url);
  }

  void _scheduleReconnect(String url) {
    if (!_isRunning) return;
    final failures = (_reconnectFailures[url] ?? 0) + 1;
    _reconnectFailures[url] = failures;
    final delay =
        reconnectDelayOverride?.call(failures) ?? reconnectDelay(failures);
    _reconnectNotBefore[url] = clockOverride().add(delay);
    broLog(
        '[RT] $url reconnect em ${delay.inMilliseconds}ms (falha $failures)');
  }

  void _handleMessage(String relayUrl, dynamic message) {
    try {
      final data = jsonDecode(message);
      if (data is! List || data.isEmpty) return;

      final type = data[0];

      if (type == 'EVENT' && data.length >= 3) {
        // Rate limit: max events per second to prevent relay flooding
        final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        if (nowSec == _lastSecond) {
          _eventsThisSecond++;
          if (_eventsThisSecond > _maxEventsPerSecond) return;
        } else {
          _lastSecond = nowSec;
          _eventsThisSecond = 1;
        }

        final eventData = data[2] as Map<String, dynamic>;
        final eventId = eventData['id'] as String?;
        if (eventId == null) return;

        // Dedup — only process each event once
        if (_processedEventIds.contains(eventId)) return;
        _processedEventIds.add(eventId);

        // Don't process events authored by me (I already know about them)
        final author = eventData['pubkey'] as String?;
        if (author == _pubkey) return;

        // v448: Skip old events — only notify for events created in last 10 min
        final createdAt = eventData['created_at'] as int? ?? 0;
        final nowSec2 = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final eventAge = nowSec2 - createdAt;

        // Verify event signature
        try {
          Event.fromJson(eventData, verify: true);
        } catch (e) {
          broLog('[RT] REJECTED event with invalid signature: $e');
          return;
        }

        // Parse content to determine event type
        String? eventType;
        String? orderId;
        try {
          final content = jsonDecode(eventData['content'] as String);
          eventType = content['type'] as String?;
          orderId = content['orderId'] as String?;
        } catch (_) {}

        final kind = eventData['kind'] as int?;
        broLog(
            '[RT] New order event from $relayUrl: kind=$kind type=$eventType orderId=${orderId?.substring(0, 8) ?? "?"} age=${eventAge}s');

        // Trigger sync callback (always — to update order data)
        onOrderEvent?.call();

        // v450: NÃO mostrar notificação local quando o app está aberto.
        // O usuário já está vendo os dados na tela via sync.
        // Notificações chegam via FCM quando o app está em background.
      }
    } catch (_) {}
  }

  void _showNotificationForEvent(
      int? kind, String? eventType, String? status, String? orderId) {
    if (orderId == null) return;

    String? title;
    String? body;
    String? dedupType;
    final oid = orderId.length >= 8 ? orderId.substring(0, 8) : orderId;

    if (eventType == 'bro_billcode_encrypted') {
      title = '🔐 Código PIX recebido';
      body = 'Novo código de pagamento disponível';
      dedupType = 'billcode';
    } else if (kind == _kindAccept || status == 'accepted') {
      title = '🤝 Ordem aceita!';
      body = 'Um Bro aceitou sua ordem';
      dedupType = 'accepted';
    } else if (status == 'payment_received' || status == 'processing') {
      title = '📸 Comprovante recebido!';
      body = 'Verifique o comprovante e confirme';
      dedupType = 'payment_received';
    } else if (kind == _kindComplete && status != 'completed') {
      // v728: kind 30081 = COMPROVANTE chegou (a ordem NÃO concluiu — falta o
      // usuário confirmar). Antes caía como "Ordem concluída!" e a Carol via
      // notificação de concluída faltando a confirmação (43b789c7, 06/11).
      title = '📸 Comprovante recebido!';
      body = 'Verifique o comprovante e confirme';
      dedupType = 'payment_received';
    } else if (status == 'completed') {
      title = '✅ Ordem concluída!';
      body = 'Troca finalizada com sucesso';
      dedupType = 'completed';
    } else if (status == 'disputed') {
      title = '⚠️ Disputa aberta';
      body = 'Uma disputa foi aberta na sua ordem';
      dedupType = 'disputed';
    } else if (status == 'cancelled') {
      title = '❌ Ordem cancelada';
      body = 'Uma ordem foi cancelada';
      dedupType = 'cancelled';
    }

    if (title != null && body != null && dedupType != null) {
      _showLocalNotificationDeduped(
          orderId.hashCode, title, body, 'rt_order:$oid', '$dedupType:$oid');
    }
  }

  Future<void> _showLocalNotificationDeduped(int id, String title, String body,
      String payload, String dedupKey) async {
    try {
      // v448: SharedPreferences dedup — survives app restart
      final prefs = await SharedPreferences.getInstance();
      final notifiedJson = prefs.getString('bro_notified_transitions') ?? '[]';
      final notified = Set<String>.from(jsonDecode(notifiedJson) as List);
      if (notified.contains(dedupKey)) {
        broLog('[RT] Notification dedup skipped: $dedupKey');
        return;
      }
      notified.add(dedupKey);
      if (notified.length > 300) {
        final keep = notified.toList().sublist(notified.length - 300);
        notified.clear();
        notified.addAll(keep);
      }
      await prefs.setString(
          'bro_notified_transitions', jsonEncode(notified.toList()));

      final plugin = FlutterLocalNotificationsPlugin();
      await plugin.show(
        id,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'bro_orders_rt',
            'Order Updates',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        payload: payload,
      );
    } catch (_) {}
  }

  @visibleForTesting
  void debugCheckReconnect() => _checkReconnect();

  @visibleForTesting
  int debugReconnectFailures(String url) => _reconnectFailures[url] ?? 0;

  void _checkReconnect() {
    if (!_isRunning || _pubkey == null) return;

    for (final url in relaysOverride ?? _relays) {
      if (!_connections.containsKey(url) && !_connecting.contains(url)) {
        final notBefore = _reconnectNotBefore[url];
        if (notBefore != null && clockOverride().isBefore(notBefore)) continue;
        broLog('[RT] Reconnecting to $url');
        unawaited(_connectAndSubscribe(url));
      }
    }
  }
}
