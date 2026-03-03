import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:workmanager/workmanager.dart';

/// v262: Servico de notificacoes em background
/// Roda em isolate separado via workmanager — NAO toca no fluxo principal do app.
/// Apenas LE dos relays Nostr e dispara notificacoes locais.

// Constantes
const String _taskName = 'bro_check_nostr_notifications';
const String _taskTag = 'bro_notifications';
const String _lastCheckKey = 'bro_bg_last_check_timestamp';
const String _seenEventsKey = 'bro_bg_seen_event_ids';

// Nostr event kinds (mesmos valores do nostr_order_service.dart)
const int _kindBroOrder = 30078;
const int _kindBroAccept = 30079;
const int _kindBroPaymentProof = 30080;
const int _kindBroComplete = 30081;

// Relays para consulta (somente leitura)
const List<String> _relays = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
  'wss://relay.nostr.band', // fallback
];

/// Callback top-level que o workmanager chama em background isolate
@pragma('vm:entry-point')
void broBackgroundCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    try {
      debugPrint('[BRO-BG] Task iniciada: $taskName');
      
      if (taskName == _taskName || taskName == Workmanager.iOSBackgroundTask) {
        await _checkNostrForNewEvents();
      }
      
      debugPrint('[BRO-BG] Task concluida com sucesso');
      return true;
    } catch (e) {
      debugPrint('[BRO-BG] Erro na task: $e');
      return true; // Retorna true para nao cancelar a task periodica
    }
  });
}

/// Inicializa o workmanager e registra a task periodica
/// Chamado UMA VEZ no main() do app
Future<void> initBackgroundNotifications() async {
  try {
    await Workmanager().initialize(
      broBackgroundCallbackDispatcher,
      isInDebugMode: kDebugMode,
    );
    
    // Registrar task periodica (minimo 15 min no Android)
    await Workmanager().registerPeriodicTask(
      _taskName,
      _taskName,
      tag: _taskTag,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(
        networkType: NetworkType.connected, // So roda com internet
      ),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep, // Nao duplicar
      backoffPolicy: BackoffPolicy.linear,
      backoffPolicyDelay: const Duration(minutes: 5),
    );
    
    debugPrint('[BRO-BG] Background notifications inicializado (polling 15min)');
  } catch (e) {
    debugPrint('[BRO-BG] Erro ao inicializar background: $e');
  }
}

/// Cancela todas as tasks de background (ex: no logout)
Future<void> cancelBackgroundNotifications() async {
  try {
    await Workmanager().cancelByTag(_taskTag);
    debugPrint('[BRO-BG] Background notifications cancelado');
  } catch (e) {
    debugPrint('[BRO-BG] Erro ao cancelar: $e');
  }
}

// ============================================================
// IMPLEMENTACAO INTERNA (roda no isolate de background)
// ============================================================

/// Verifica relays Nostr por novos eventos e dispara notificacoes
Future<void> _checkNostrForNewEvents() async {
  // 1. Recuperar pubkey do storage seguro
  const secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );
  
  final userPubkey = await secureStorage.read(key: 'nostr_public_key');
  if (userPubkey == null || userPubkey.isEmpty) {
    debugPrint('[BRO-BG] Sem pubkey — usuario nao logado, abortando');
    return;
  }
  
  // 2. Verificar modo provedor
  final shortKey = userPubkey.length > 16 ? userPubkey.substring(0, 16) : userPubkey;
  final providerModeKey = 'is_provider_mode_$shortKey';
  final providerModeValue = await secureStorage.read(key: providerModeKey);
  // Fallback: verificar chave legada
  final legacyProviderMode = await secureStorage.read(key: 'is_provider_mode');
  final isProvider = providerModeValue == 'true' || legacyProviderMode == 'true';
  
  // 3. Recuperar timestamp da ultima verificacao
  final prefs = await SharedPreferences.getInstance();
  final lastCheck = prefs.getInt(_lastCheckKey) ?? 0;
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  
  // Se nunca verificou, usar "1 hora atras" para nao inundar com notificacoes antigas
  final sinceTimestamp = lastCheck > 0 ? lastCheck : (now - 3600);
  
  // 4. Carregar IDs de eventos ja vistos (para evitar duplicatas)
  final seenIdsJson = prefs.getString(_seenEventsKey) ?? '[]';
  final seenIds = Set<String>.from(jsonDecode(seenIdsJson) as List);
  
  debugPrint('[BRO-BG] Verificando eventos desde ${DateTime.fromMillisecondsSinceEpoch(sinceTimestamp * 1000)} para ${userPubkey.substring(0, 16)}... (provider=$isProvider)');
  
  // 5. Consultar relays
  final newEvents = <Map<String, dynamic>>[];
  
  // 5a. Eventos DIRECIONADOS ao usuario (alguem aceitou/pagou/completou)
  final userEvents = await _queryRelaysForEvents(
    kinds: [_kindBroAccept, _kindBroPaymentProof, _kindBroComplete],
    tags: {'#p': [userPubkey]},
    since: sinceTimestamp,
  );
  newEvents.addAll(userEvents);
  
  // 5b. Se provedor: verificar novas ordens disponiveis
  if (isProvider) {
    final orderEvents = await _queryRelaysForEvents(
      kinds: [_kindBroOrder],
      tags: {'#t': ['bro-order'], '#status': ['pending']},
      since: sinceTimestamp,
    );
    // Filtrar ordens que nao sao do proprio provedor
    for (final event in orderEvents) {
      final authorPubkey = event['pubkey']?.toString() ?? '';
      if (authorPubkey != userPubkey) {
        newEvents.add(event);
      }
    }
  }
  
  // 6. Filtrar eventos ja vistos
  final unseenEvents = <Map<String, dynamic>>[];
  for (final event in newEvents) {
    final eventId = event['id']?.toString() ?? '';
    if (eventId.isNotEmpty && !seenIds.contains(eventId)) {
      unseenEvents.add(event);
      seenIds.add(eventId);
    }
  }
  
  debugPrint('[BRO-BG] ${newEvents.length} eventos encontrados, ${unseenEvents.length} novos');
  
  // 7. Disparar notificacoes para eventos novos
  if (unseenEvents.isNotEmpty) {
    await _initNotifications();
    
    for (final event in unseenEvents) {
      await _showNotificationForEvent(event, userPubkey);
    }
  }
  
  // 8. Salvar timestamp e IDs vistos
  await prefs.setInt(_lastCheckKey, now);
  
  // Manter apenas os ultimos 500 IDs para nao crescer infinitamente
  final recentIds = seenIds.toList();
  if (recentIds.length > 500) {
    recentIds.removeRange(0, recentIds.length - 500);
  }
  await prefs.setString(_seenEventsKey, jsonEncode(recentIds));
}

/// Consulta relays Nostr e retorna eventos encontrados
Future<List<Map<String, dynamic>>> _queryRelaysForEvents({
  required List<int> kinds,
  Map<String, List<String>>? tags,
  required int since,
}) async {
  // Tentar cada relay ate conseguir algum resultado
  for (final relay in _relays) {
    try {
      final events = await _fetchFromRelay(relay, kinds: kinds, tags: tags, since: since);
      if (events.isNotEmpty) {
        debugPrint('[BRO-BG] $relay retornou ${events.length} eventos');
        return events;
      }
    } catch (e) {
      debugPrint('[BRO-BG] Falha em $relay: $e');
    }
  }
  return [];
}

/// Busca eventos de um relay via WebSocket (versao simplificada para background)
Future<List<Map<String, dynamic>>> _fetchFromRelay(
  String relayUrl, {
  required List<int> kinds,
  Map<String, List<String>>? tags,
  required int since,
}) async {
  final events = <Map<String, dynamic>>[];
  final subscriptionId = 'bg_${DateTime.now().millisecondsSinceEpoch}';
  
  WebSocketChannel? channel;
  
  try {
    channel = WebSocketChannel.connect(Uri.parse(relayUrl));
    
    // Aguardar conexao
    try {
      await channel.ready.timeout(const Duration(seconds: 5));
    } catch (_) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    
    final completer = Completer<List<Map<String, dynamic>>>();
    
    // Timeout de 8 segundos
    final timer = Timer(const Duration(seconds: 8), () {
      if (!completer.isCompleted) completer.complete(events);
    });
    
    // Escutar eventos
    channel.stream.listen(
      (message) {
        try {
          final response = jsonDecode(message);
          if (response[0] == 'EVENT' && response[1] == subscriptionId) {
            final eventData = response[2] as Map<String, dynamic>;
            // Parsear content
            try {
              eventData['parsedContent'] = jsonDecode(eventData['content'] ?? '{}');
            } catch (_) {}
            events.add(eventData);
          } else if (response[0] == 'EOSE') {
            if (!completer.isCompleted) completer.complete(events);
          }
        } catch (_) {}
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete(events);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(events);
      },
    );
    
    // Montar filtro
    final filter = <String, dynamic>{
      'kinds': kinds,
      'since': since,
      'limit': 50,
    };
    if (tags != null) filter.addAll(tags);
    
    // Enviar request
    channel.sink.add(jsonEncode(['REQ', subscriptionId, filter]));
    
    final result = await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => events,
    );
    
    timer.cancel();
    return result;
  } catch (e) {
    debugPrint('[BRO-BG] WebSocket error em $relayUrl: $e');
    return events;
  } finally {
    try { channel?.sink.close(); } catch (_) {}
  }
}

// ============================================================
// NOTIFICACOES LOCAIS (background isolate)
// ============================================================

FlutterLocalNotificationsPlugin? _bgNotifications;

Future<void> _initNotifications() async {
  if (_bgNotifications != null) return;
  
  _bgNotifications = FlutterLocalNotificationsPlugin();
  
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosSettings = DarwinInitializationSettings(
    requestAlertPermission: false, // Nao pedir permissao em background
    requestBadgePermission: false,
    requestSoundPermission: false,
  );
  
  await _bgNotifications!.initialize(
    const InitializationSettings(android: androidSettings, iOS: iosSettings),
  );
}

Future<void> _showNotificationForEvent(Map<String, dynamic> event, String userPubkey) async {
  if (_bgNotifications == null) return;
  
  final kind = event['kind'] as int? ?? 0;
  final content = event['parsedContent'] as Map<String, dynamic>? ?? {};
  final orderId = content['orderId']?.toString() ?? 
                  _getTagValue(event, 'd') ?? 
                  _getTagValue(event, 'orderId') ??
                  '';
  final shortOrderId = orderId.length > 8 ? orderId.substring(0, 8) : orderId;
  
  String title;
  String body;
  String payload;
  Importance importance = Importance.high;
  
  switch (kind) {
    case _kindBroAccept: // 30079 - Alguem aceitou minha ordem
      title = 'Bro Encontrado!';
      body = 'Um Bro aceitou sua ordem $shortOrderId. Abra o app para acompanhar.';
      payload = 'order_accepted:$orderId';
      importance = Importance.max;
      break;
      
    case _kindBroPaymentProof: // 30080 - Comprovante de pagamento
      final amount = content['amount']?.toString() ?? '';
      title = 'Comprovante Recebido!';
      body = amount.isNotEmpty 
        ? 'Comprovante de R\$ $amount recebido. Verifique e confirme.'
        : 'Comprovante recebido para ordem $shortOrderId. Verifique e confirme.';
      payload = 'payment_received:$orderId';
      importance = Importance.max;
      break;
      
    case _kindBroComplete: // 30081 - Ordem completada
      title = 'Troca Concluida!';
      body = 'Sua ordem $shortOrderId foi concluida com sucesso.';
      payload = 'order_completed:$orderId';
      break;
      
    case _kindBroOrder: // 30078 - Nova ordem disponivel (para provedores)
      final amount = content['amount']?.toString() ?? '?';
      final billType = content['billType']?.toString() ?? 'pix';
      title = 'Nova Ordem Disponivel!';
      body = 'Ordem de R\$ $amount ($billType) aguardando. Toque para aceitar.';
      payload = 'new_order:$orderId';
      importance = Importance.high;
      break;
      
    default:
      debugPrint('[BRO-BG] Kind desconhecido: $kind — ignorando');
      return;
  }
  
  final androidDetails = AndroidNotificationDetails(
    'bro_app_channel',
    'Bro App',
    channelDescription: 'Notificacoes do Bro App',
    importance: importance,
    priority: importance == Importance.max ? Priority.max : Priority.high,
    icon: '@mipmap/ic_launcher',
    color: const Color(0xFFFF6B6B),
    styleInformation: BigTextStyleInformation(body),
  );
  
  const iosDetails = DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: true,
    presentSound: true,
  );
  
  final details = NotificationDetails(android: androidDetails, iOS: iosDetails);
  
  final notificationId = (orderId.hashCode + kind) % 2147483647; // Max int32
  
  await _bgNotifications!.show(notificationId, title, body, details, payload: payload);
  debugPrint('[BRO-BG] Notificacao enviada: $title — $body');
}

/// Extrai valor de uma tag Nostr (ex: ['d', 'abc123'] -> 'abc123')
String? _getTagValue(Map<String, dynamic> event, String tagName) {
  final tags = event['tags'] as List<dynamic>?;
  if (tags == null) return null;
  for (final tag in tags) {
    if (tag is List && tag.length >= 2 && tag[0] == tagName) {
      return tag[1]?.toString();
    }
  }
  return null;
}
