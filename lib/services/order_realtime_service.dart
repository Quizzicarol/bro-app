import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:nostr/nostr.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:bro_app/services/log_utils.dart';

/// Real-time Nostr WebSocket subscription for order events.
/// Maintains persistent connections to relays and triggers callbacks
/// when new order events arrive (accept, payment, billCode, complete, dispute).
class OrderRealtimeService {
  static final OrderRealtimeService _instance = OrderRealtimeService._internal();
  factory OrderRealtimeService() => _instance;
  OrderRealtimeService._internal();

  static const List<String> _relays = [
    'wss://relay.damus.io',
    'wss://nos.lol',
    'wss://relay.primal.net',
  ];

  final Map<String, WebSocketChannel> _connections = {};
  final Set<String> _processedEventIds = {};
  String? _pubkey;
  bool _isRunning = false;
  Timer? _reconnectTimer;
  Timer? _cleanupTimer;
  int _eventsThisSecond = 0;
  int _lastSecond = 0;
  static const int _maxEventsPerSecond = 20;

  // Callback when a new order event arrives — triggers sync
  void Function()? onOrderEvent;

  // Nostr event kinds for orders
  static const int _kindAccept = 30079;
  static const int _kindPaymentProof = 30080;
  static const int _kindComplete = 30081;

  /// Start listening for real-time order events
  void start(String pubkey, {void Function()? onEvent}) {
    if (_isRunning && _pubkey == pubkey) return;

    _pubkey = pubkey;
    onOrderEvent = onEvent;
    _isRunning = true;

    broLog('[RT] OrderRealtimeService starting for ${pubkey.substring(0, 16)}...');

    // Connect to all relays
    for (final url in _relays) {
      _connectAndSubscribe(url);
    }

    // Reconnect check every 30s
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _checkReconnect();
    });

    // Cleanup old event IDs every 5 min to prevent memory leak
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (_processedEventIds.length > 500) {
        // Keep last 200 IDs instead of clearing all — prevents re-notification
        final keep = _processedEventIds.toList().sublist(_processedEventIds.length - 200);
        _processedEventIds.clear();
        _processedEventIds.addAll(keep);
        broLog('[RT] Trimmed processedEventIds to ${_processedEventIds.length}');
      }
    });
  }

  /// Stop listening
  void stop() {
    _isRunning = false;
    _reconnectTimer?.cancel();
    _cleanupTimer?.cancel();
    for (final channel in _connections.values) {
      try { channel.sink.close(); } catch (_) {}
    }
    _connections.clear();
    _processedEventIds.clear();
    broLog('[RT] OrderRealtimeService stopped');
  }

  void _connectAndSubscribe(String url) {
    if (_connections.containsKey(url)) return;
    if (_pubkey == null) return;

    try {
      final channel = WebSocketChannel.connect(Uri.parse(url));
      _connections[url] = channel;

      channel.stream.listen(
        (message) => _handleMessage(url, message),
        onError: (error) {
          broLog('[RT] Error on $url: $error');
          _connections.remove(url);
        },
        onDone: () {
          _connections.remove(url);
        },
      );

      // Subscribe to order events where I'm tagged (#p = my pubkey)
      final subId = 'rt_orders_${DateTime.now().millisecondsSinceEpoch}';
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

      // Filter 1: Events tagged to me (I'm buyer or provider)
      final filter1 = {
        'kinds': [_kindAccept, _kindPaymentProof, _kindComplete],
        '#p': [_pubkey],
        'since': now - 300, // Last 5 min to catch very recent + future
      };

      // Filter 2: Events authored by me (to see confirmations)
      final filter2 = {
        'kinds': [_kindAccept, _kindPaymentProof, _kindComplete],
        'authors': [_pubkey],
        'since': now - 300,
      };

      channel.sink.add(jsonEncode(['REQ', '${subId}_1', filter1]));
      channel.sink.add(jsonEncode(['REQ', '${subId}_2', filter2]));
    } catch (e) {
      broLog('[RT] Failed to connect to $url: $e');
    }
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
        final isRecentEvent = eventAge < 600; // 10 minutes

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
        String? status;
        try {
          final content = jsonDecode(eventData['content'] as String);
          eventType = content['type'] as String?;
          orderId = content['orderId'] as String?;
          status = content['status'] as String?;
        } catch (_) {}

        final kind = eventData['kind'] as int?;
        broLog('[RT] New order event from $relayUrl: kind=$kind type=$eventType orderId=${orderId?.substring(0, 8) ?? "?"} age=${eventAge}s');

        // Trigger sync callback (always — to update order data)
        onOrderEvent?.call();

        // Show local notification ONLY for recent events (< 10 min old)
        if (isRecentEvent) {
          _showNotificationForEvent(kind, eventType, status, orderId);
        } else {
          broLog('[RT] Skipping notification for old event (age=${eventAge}s)');
        }
      }
    } catch (_) {}
  }

  void _showNotificationForEvent(int? kind, String? eventType, String? status, String? orderId) {
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
    } else if (kind == _kindComplete || status == 'completed') {
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
      _showLocalNotificationDeduped(orderId.hashCode, title, body, 'rt_order:$oid', '$dedupType:$oid');
    }
  }

  Future<void> _showLocalNotificationDeduped(int id, String title, String body, String payload, String dedupKey) async {
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
      await prefs.setString('bro_notified_transitions', jsonEncode(notified.toList()));

      final plugin = FlutterLocalNotificationsPlugin();
      await plugin.show(
        id,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'bro_orders_rt', 'Order Updates',
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(),
        ),
        payload: payload,
      );
    } catch (_) {}
  }

  void _checkReconnect() {
    if (!_isRunning || _pubkey == null) return;

    for (final url in _relays) {
      if (!_connections.containsKey(url)) {
        broLog('[RT] Reconnecting to $url');
        _connectAndSubscribe(url);
      }
    }
  }
}
