import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:nostr/nostr.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:bro_app/services/order_reminder_service.dart';
import 'package:bro_app/services/orders_storage.dart';
import 'package:bro_app/models/notification_item.dart';
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
      broLog('[BRO-BG] Task iniciada: $taskName');
      
      if (taskName == _taskName || taskName == Workmanager.iOSBackgroundTask) {
        await _checkNostrForNewEvents();
        await _checkAutoLiquidationBackground();
        await _checkOrderRemindersBackground();
        await _refreshFcmToken();
      }
      
      broLog('[BRO-BG] Task concluida com sucesso');
      return true;
    } catch (e) {
      broLog('[BRO-BG] Erro na task: $e');
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
    
    broLog('[BRO-BG] Background notifications inicializado (polling 15min)');
  } catch (e) {
    broLog('[BRO-BG] Erro ao inicializar background: $e');
  }
}

/// Cancela todas as tasks de background (ex: no logout)
Future<void> cancelBackgroundNotifications() async {
  try {
    await Workmanager().cancelByTag(_taskTag);
    broLog('[BRO-BG] Background notifications cancelado');
  } catch (e) {
    broLog('[BRO-BG] Erro ao cancelar: $e');
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
    broLog('[BRO-BG] Sem pubkey — usuario nao logado, abortando');
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
  
  // Clamp: nunca buscar eventos com mais de 2 horas — evita notificacoes atrasadas
  // quando Android Doze atrasa o WorkManager por dias
  final maxAge = now - 7200; // 2 horas
  final sinceTimestamp = lastCheck > maxAge ? lastCheck : maxAge;
  
  // 4. Carregar IDs de eventos ja vistos (para evitar duplicatas)
  final seenIdsJson = prefs.getString(_seenEventsKey) ?? '[]';
  final seenIds = Set<String>.from(jsonDecode(seenIdsJson) as List);
  
  broLog('[BRO-BG] Verificando eventos desde ${DateTime.fromMillisecondsSinceEpoch(sinceTimestamp * 1000)} para ${userPubkey.substring(0, 16)}... (provider=$isProvider)');
  
  // 5. Consultar relays
  final newEvents = <Map<String, dynamic>>[];
  
  // 5a. Eventos DIRECIONADOS ao usuario (alguem aceitou/pagou/completou)
  final userEvents = await _queryRelaysForEvents(
    kinds: [_kindBroAccept, _kindBroPaymentProof, _kindBroComplete],
    tags: {'#p': [userPubkey]},
    since: sinceTimestamp,
  );
  newEvents.addAll(userEvents);
  
  // 5b. Se provedor: NAO buscar novas ordens aqui. v545: o backend watchtower\n  // ja envia FCM push quando detecta kind 30078, e o provider_orders_screen\n  // mostra a lista via Nostr sync normal. Buscar aqui causava notificacao\n  // local DUPLICADA em cima da FCM.\n  // (isProvider era usado antes; agora ignorado para evitar triplicacao.)
  
  // 6. Filtrar eventos ja vistos + eventos publicados pelo proprio usuario.
  // v529: FIX self-notify. O query #p:userPubkey tambem casa com eventos que
  // Carol publica tagueando ela mesma (updateOrderStatus inclui ['p', me]).
  // Antes, kind 30080 'completed' publicado pela propria Carol disparava
  // "Comprovante Recebido!" localmente no celular dela.
  final unseenEvents = <Map<String, dynamic>>[];
  for (final event in newEvents) {
    final eventId = event['id']?.toString() ?? '';
    final authorPubkey = event['pubkey']?.toString() ?? '';
    if (authorPubkey == userPubkey) continue; // v529: pular eventos proprios
    if (eventId.isNotEmpty && !seenIds.contains(eventId)) {
      unseenEvents.add(event);
      seenIds.add(eventId);
    }
  }
  
  broLog('[BRO-BG] ${newEvents.length} eventos encontrados, ${unseenEvents.length} novos');
  
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
        broLog('[BRO-BG] $relay retornou ${events.length} eventos');
        return events;
      }
    } catch (e) {
      broLog('[BRO-BG] Falha em $relay: $e');
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
            // SEGURANCA v274: Verificar assinatura do evento antes de aceitar
            try {
              Event.fromJson(eventData, verify: true);
            } catch (e) {
              broLog('[BRO-BG] REJEITADO evento com assinatura invalida: ${eventData['id']?.toString().substring(0, 8) ?? '?'}');
              return; // Ignorar evento com assinatura invalida
            }
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
    broLog('[BRO-BG] WebSocket error em $relayUrl: $e');
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
      
    case _kindBroPaymentProof: // 30080 - bro-update (todos os status transitions)
      // v529: kind 30080 eh generico para TODAS as mudancas de status
      // (accepted/payment_submitted/awaiting_confirmation/completed/cancelled).
      // Antes disparava "Comprovante Recebido!" para todos, incluindo 'completed'
      // publicado pela propria Carol ou pelo provedor — mensagem errada.
      final status = content['status']?.toString() ?? '';
      switch (status) {
        case 'awaiting_confirmation':
          final amount = content['amount']?.toString() ?? '';
          title = 'Comprovante Recebido!';
          body = amount.isNotEmpty
            ? 'Comprovante de R\$ $amount recebido. Verifique e confirme.'
            : 'Comprovante recebido para ordem $shortOrderId. Verifique e confirme.';
          payload = 'payment_received:$orderId';
          importance = Importance.max;
          break;
        case 'completed':
          title = 'Ordem Concluida!';
          body = 'Ordem $shortOrderId foi finalizada com sucesso.';
          payload = 'order_completed:$orderId';
          break;
        case 'cancelled':
          title = 'Ordem Cancelada';
          body = 'A ordem $shortOrderId foi cancelada.';
          payload = 'order_cancelled:$orderId';
          break;
        case 'disputed':
          title = 'Disputa Aberta';
          body = 'Uma disputa foi aberta na ordem $shortOrderId.';
          payload = 'order_disputed:$orderId';
          importance = Importance.max;
          break;
        default:
          broLog('[BRO-BG] kind 30080 status=$status — sem notificacao local');
          return;
      }
      break;
      
    case _kindBroComplete: // 30081 - Ordem completada
      title = 'Troca Concluida!';
      body = 'Sua ordem $shortOrderId foi concluida com sucesso.';
      payload = 'order_completed:$orderId';
      break;
      
    case _kindBroOrder: // 30078 - Nova ordem disponivel
      // v545: NAO disparamos notificacao local aqui. O backend watchtower
      // envia FCM push automaticamente via getProviderPubkeys() (v544).
      // Antes, esta branch + foreground polling + FCM = 3 notificacoes
      // para a mesma ordem.
      broLog('[BRO-BG] kind 30078 ignorado — FCM push cuida disso');
      return;
      
    default:
      broLog('[BRO-BG] Kind desconhecido: $kind — ignorando');
      return;
  }
  
  // Shared dedup with foreground NotificationService
  if (payload.isNotEmpty) {
    final prefs = await SharedPreferences.getInstance();
    const notifiedKey = 'bro_notified_transitions';
    final notifiedJson = prefs.getString(notifiedKey) ?? '[]';
    final notified = Set<String>.from(jsonDecode(notifiedJson) as List);
    if (notified.contains(payload)) {
      broLog('[BRO-BG] Notificacao duplicada ignorada: $payload');
      return;
    }
    notified.add(payload);
    final list = notified.toList();
    if (list.length > 300) list.removeRange(0, list.length - 300);
    await prefs.setString(notifiedKey, jsonEncode(list));
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
  await NotificationInbox.addRaw(title: title, body: body, payload: payload);
  broLog('[BRO-BG] Notificacao enviada: $title — $body');
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

// ============================================================
// FCM TOKEN REFRESH EM BACKGROUND
// v396: Renova token FCM e re-registra no BRIX a cada 15min
// Garante que usuarios offline por semanas mantenham token valido
// ============================================================

const String _brixServerUrl = 'https://brix.brostr.app';

// v538: HARDCODED - Codemagic estava injetando valor errado via env
const String _backendUrl = 'https://api.brostr.app';

/// Validate that a URL uses HTTPS and belongs to a trusted domain
bool _isValidSecureUrl(String url) {
  try {
    final uri = Uri.parse(url);
    if (uri.scheme != 'https') return false;
    final host = uri.host;
    return host.endsWith('.brostr.app') || host == 'brostr.app';
  } catch (_) {
    return false;
  }
}

Future<void> _refreshFcmToken() async {
  try {
    // 1. Recuperar pubkey e private key do storage seguro
    const secureStorage = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
      iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    );

    final userPubkey = await secureStorage.read(key: 'nostr_public_key');
    if (userPubkey == null || userPubkey.isEmpty) {
      broLog('[BRO-BG-FCM] Sem pubkey — abortando refresh');
      return;
    }

    final privateKey = await secureStorage.read(key: 'nostr_private_key');
    if (privateKey == null || privateKey.isEmpty) {
      broLog('[BRO-BG-FCM] Sem private key — abortando refresh (NIP-98 required)');
      return;
    }

    // 2. Inicializar Firebase e obter token FCM
    await Firebase.initializeApp();
    final fcmToken = await FirebaseMessaging.instance.getToken();
    if (fcmToken == null || fcmToken.isEmpty) {
      broLog('[BRO-BG-FCM] Sem FCM token — abortando');
      return;
    }

    // 3. Validate URLs before making requests
    final url = '$_brixServerUrl/brix/register-push';
    if (!_isValidSecureUrl(url)) {
      broLog('[BRO-BG-FCM] REJECTED insecure BRIX URL: $url');
      return;
    }

    // 4. Criar NIP-98 auth header (kind 27235) com payload tag (v566)
    final brixBody = jsonEncode({'fcm_token': fcmToken});
    final brixPayloadHash = crypto.sha256.convert(utf8.encode(brixBody)).toString();
    final nip98Event = Event.from(
      kind: 27235,
      tags: [
        ['u', url],
        ['method', 'POST'],
        ['payload', brixPayloadHash],
      ],
      content: '',
      privkey: privateKey,
    );
    final eventMap = {
      'id': nip98Event.id,
      'pubkey': nip98Event.pubkey,
      'created_at': nip98Event.createdAt,
      'kind': nip98Event.kind,
      'tags': nip98Event.tags,
      'content': nip98Event.content,
      'sig': nip98Event.sig,
    };
    final authHeader = 'Nostr ${base64Encode(utf8.encode(jsonEncode(eventMap)))}';

    // 4. Registrar token no BRIX server com NIP-98 auth
    final response = await http.post(
      Uri.parse(url),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': authHeader,
      },
      body: brixBody,
    ).timeout(const Duration(seconds: 10));

    if (response.statusCode == 200) {
      broLog('[BRO-BG-FCM] Token FCM re-registrado com sucesso (BRIX)');
    } else if (response.statusCode == 404) {
      // vSEC-fix: 404 = esta pubkey NÃO tem conta BRIX (permanente). NÃO é
      // falha — é simplesmente um usuário que não usa BRIX. Não logar como
      // erro nem fazer retry (era ruído a cada background wake).
      broLog('[BRO-BG-FCM] BRIX: sem conta (404) — ok, nada a registrar');
    } else {
      broLog('[BRO-BG-FCM] Falha ao registrar token BRIX: ${response.statusCode}');
      // Retry once after 3s
      await Future.delayed(const Duration(seconds: 3));
      try {
        final retryResp = await http.post(
          Uri.parse(url),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': authHeader,
          },
          body: brixBody,
        ).timeout(const Duration(seconds: 10));
        broLog('[BRO-BG-FCM] BRIX retry: ${retryResp.statusCode == 200 ? "OK" : "FAIL ${retryResp.statusCode}"}');
      } catch (e2) {
        broLog('[BRO-BG-FCM] BRIX retry error: $e2');
      }
    }

    // v500: Also register with main backend for order_update push notifications
    try {
      final backendUrl = '$_backendUrl/push/register-token';
      if (!_isValidSecureUrl(backendUrl)) {
        broLog('[BRO-BG-FCM] REJECTED insecure backend URL: $backendUrl');
        return;
      }
      final backendBody = jsonEncode({'fcm_token': fcmToken});
      final backendPayloadHash = crypto.sha256.convert(utf8.encode(backendBody)).toString();
      final backendNip98 = Event.from(
        kind: 27235,
        tags: [
          ['u', backendUrl],
          ['method', 'POST'],
          ['payload', backendPayloadHash],
        ],
        content: '',
        privkey: privateKey,
      );
      final backendEventMap = {
        'id': backendNip98.id,
        'pubkey': backendNip98.pubkey,
        'created_at': backendNip98.createdAt,
        'kind': backendNip98.kind,
        'tags': backendNip98.tags,
        'content': backendNip98.content,
        'sig': backendNip98.sig,
      };
      final backendAuth = 'Nostr ${base64Encode(utf8.encode(jsonEncode(backendEventMap)))}';

      final backendResp = await http.post(
        Uri.parse(backendUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': backendAuth,
        },
        body: backendBody,
      ).timeout(const Duration(seconds: 10));

      if (backendResp.statusCode == 200) {
        broLog('[BRO-BG-FCM] Token FCM re-registrado com sucesso (backend)');
      } else {
        broLog('[BRO-BG-FCM] Falha ao registrar token backend: ${backendResp.statusCode}');
        // Retry once after 3s
        await Future.delayed(const Duration(seconds: 3));
        try {
          final retryResp = await http.post(
            Uri.parse(backendUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': backendAuth,
            },
            body: jsonEncode({'fcm_token': fcmToken}),
          ).timeout(const Duration(seconds: 10));
          broLog('[BRO-BG-FCM] Backend retry: ${retryResp.statusCode == 200 ? "OK" : "FAIL ${retryResp.statusCode}"}');
        } catch (e2) {
          broLog('[BRO-BG-FCM] Backend retry error: $e2');
        }
      }
    } catch (e) {
      broLog('[BRO-BG-FCM] Erro ao registrar token backend: $e');
    }
  } catch (e) {
    broLog('[BRO-BG-FCM] Erro no refresh: $e');
  }
}

// ============================================================
// AUTO-LIQUIDACAO EM BACKGROUND
// v274: Verifica ordens awaiting_confirmation com 36h expirado
// e publica status 'liquidated' no Nostr automaticamente
// ============================================================

const String _bgAutoLiqKey = 'bro_bg_auto_liq_done';
const String _bgAutoLiqLockKey = 'bro_bg_auto_liq_lock';

/// Verifica ordens locais e executa auto-liquidacao para expiradas
Future<void> _checkAutoLiquidationBackground() async {
  try {
    // SEGURANCA v274: Lock para evitar race condition entre foreground e background
    final lockPrefs = await SharedPreferences.getInstance();
    final lockTimestamp = lockPrefs.getInt(_bgAutoLiqLockKey) ?? 0;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    // Se lock foi adquirido ha menos de 2 minutos, outra instancia esta rodando
    if (nowMs - lockTimestamp < 120000) {
      broLog('[BRO-BG-LIQ] Lock ativo — outra instancia rodando, abortando');
      return;
    }
    // Adquirir lock
    await lockPrefs.setInt(_bgAutoLiqLockKey, nowMs);
    
    // 1. Recuperar chaves do storage seguro
    const secureStorage = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
      iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    );
    
    final userPubkey = await secureStorage.read(key: 'nostr_public_key');
    final privateKey = await secureStorage.read(key: 'nostr_private_key');
    
    if (userPubkey == null || userPubkey.isEmpty || privateKey == null || privateKey.isEmpty) {
      broLog('[BRO-BG-LIQ] Sem chaves — abortando auto-liquidacao');
      return;
    }
    
    // 2. Verificar se é provedor
    final shortKey = userPubkey.length > 16 ? userPubkey.substring(0, 16) : userPubkey;
    final providerModeKey = 'is_provider_mode_$shortKey';
    final providerModeValue = await secureStorage.read(key: providerModeKey);
    final legacyProviderMode = await secureStorage.read(key: 'is_provider_mode');
    final isProvider = providerModeValue == 'true' || legacyProviderMode == 'true';
    
    if (!isProvider) {
      broLog('[BRO-BG-LIQ] Nao e provedor — pulando auto-liquidacao');
      return;
    }
    
    // 3. Ler ordens do SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    // v578: read via OrdersStorage (transparently decrypts).
    final ordersJson = await OrdersStorage.read(prefs, userPubkey);
    if (ordersJson == null || ordersJson.isEmpty) {
      broLog('[BRO-BG-LIQ] Sem ordens locais');
      return;
    }
    
    // 4. Carregar IDs ja auto-liquidados em bg (evitar duplicatas)
    final doneIdsJson = prefs.getString(_bgAutoLiqKey) ?? '[]';
    final doneIds = Set<String>.from(jsonDecode(doneIdsJson) as List);
    
    // 5. Parsear ordens e filtrar expiradas
    final ordersList = jsonDecode(ordersJson) as List;
    final now = DateTime.now();
    const deadline = Duration(hours: 36);
    
    final expiredOrders = <Map<String, dynamic>>[];
    
    for (final orderJson in ordersList) {
      final order = orderJson as Map<String, dynamic>;
      final status = order['status'] as String? ?? '';
      final orderId = order['id'] as String? ?? '';
      
      if (status != 'awaiting_confirmation') continue;
      if (orderId.isEmpty) continue;
      if (doneIds.contains(orderId)) continue;
      
      // Verificar se é provedor desta ordem
      final providerId = order['providerId'] as String? ?? '';
      final metadata = order['metadata'] as Map<String, dynamic>? ?? {};
      final metaProviderId = metadata['providerId'] as String? ?? metadata['provider_id'] as String? ?? '';
      final isOrderProvider = providerId == userPubkey || metaProviderId == userPubkey;
      final isOrderCreator = (order['userPubkey'] as String? ?? '') == userPubkey;
      if (!isOrderProvider && !isOrderCreator) continue;
      
      // Ja auto-liquidada?
      if (metadata['autoLiquidated'] == true) continue;
      
      // Verificar timestamp do comprovante
      final proofTimestamp = metadata['receipt_submitted_at'] as String?
          ?? metadata['proofReceivedAt'] as String?
          ?? metadata['proofSentAt'] as String?
          ?? metadata['completedAt'] as String?
          ?? order['completedAt'] as String?;
      
      if (proofTimestamp == null) continue;
      
      try {
        final proofTime = DateTime.parse(proofTimestamp);
        if (now.difference(proofTime) > deadline) {
          expiredOrders.add(order);
        }
      } catch (_) {}
    }
    
    if (expiredOrders.isEmpty) {
      broLog('[BRO-BG-LIQ] Nenhuma ordem expirada para auto-liquidar');
      return;
    }
    
    broLog('[BRO-BG-LIQ] ${expiredOrders.length} ordens expiradas encontradas');
    
    // 6. Publicar status 'liquidated' no Nostr para cada ordem
    int successCount = 0;
    
    for (final order in expiredOrders) {
      final orderId = order['id'] as String;
      final orderUserPubkey = order['userPubkey'] as String? ?? '';

      // v569b: SAFETY GUARD — Before publishing liquidation, query Nostr for
      // the current canonical status of this order. If the order is already
      // in a terminal/locked state (liquidated, completed, cancelled, disputed)
      // we MUST NOT re-publish 'liquidated', otherwise:
      //   - watchtower re-pushes auto-liquidation notifications periodically
      //   - the local cache may be stale (status='awaiting_confirmation')
      //     because the app hasn't been opened to sync since the dispute.
      // Mark as done either way so we don't retry every 15min.
      try {
        final terminalStatus = await _fetchTerminalStatusFromNostr(orderId);
        if (terminalStatus != null) {
          broLog('[BRO-BG-LIQ] ⏭️  ${orderId.substring(0, 8)} já está $terminalStatus no Nostr — pulando');
          doneIds.add(orderId);
          // Reflect remote status locally so future bg runs and UI agree.
          order['status'] = terminalStatus;
          continue;
        }
      } catch (e) {
        broLog('[BRO-BG-LIQ] ⚠️ Falha ao verificar status remoto de ${orderId.substring(0, 8)}: $e — abortando publish para evitar duplicata');
        continue; // Conservative: don't publish if we can't verify.
      }

      try {
        final success = await _publishAutoLiquidation(
          privateKey: privateKey,
          providerPubkey: userPubkey,
          orderId: orderId,
          orderUserPubkey: orderUserPubkey,
        );
        
        if (success) {
          doneIds.add(orderId);
          successCount++;
          broLog('[BRO-BG-LIQ] ✅ Auto-liquidada: ${orderId.substring(0, 8)}');
          
          // 7. Atualizar ordem localmente
          order['status'] = 'liquidated';
          final metadata = Map<String, dynamic>.from(order['metadata'] as Map<String, dynamic>? ?? {});
          metadata['autoLiquidated'] = true;
          metadata['liquidatedAt'] = now.toIso8601String();
          metadata['reason'] = 'Auto-liquidacao background (36h)';
          order['metadata'] = metadata;
        }
      } catch (e) {
        broLog('[BRO-BG-LIQ] ❌ Erro ao liquidar ${orderId.substring(0, 8)}: $e');
      }
    }
    
    // 8. Salvar ordens atualizadas e IDs processados
    // v569b: Persist doneIds even when nothing was published, to skip
    // already-terminal orders on subsequent runs.
    if (doneIds.isNotEmpty) {
      // Manter apenas ultimos 200 IDs
      final recentDone = doneIds.toList();
      if (recentDone.length > 200) {
        recentDone.removeRange(0, recentDone.length - 200);
      }
      await prefs.setString(_bgAutoLiqKey, jsonEncode(recentDone));
    }

    if (successCount > 0) {
      // v578: persist via OrdersStorage so the rewrite stays encrypted.
      await OrdersStorage.write(prefs, userPubkey, jsonEncode(ordersList));

      // 9. Notificacao local
      await _initNotifications();
      await _bgNotifications?.show(
        'auto_liq'.hashCode % 2147483647,
        '⚡ Auto-liquidação concluída',
        '$successCount ordem(ns) liquidada(s) automaticamente. Seus ganhos foram liberados.',        const NotificationDetails(
          android: AndroidNotificationDetails(
            'bro_app_channel',
            'Bro App',
            channelDescription: 'Notificacoes do Bro App',
            importance: Importance.high,
            priority: Priority.high,
            icon: '@mipmap/ic_launcher',
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBadge: true,
            presentSound: true,
          ),
        ),
      );
      await NotificationInbox.addRaw(
        title: '⚡ Auto-liquidação concluída',
        body: '$successCount ordem(ns) liquidada(s) automaticamente. Seus ganhos foram liberados.',
        payload: 'liquidated:auto_liq_${DateTime.now().millisecondsSinceEpoch}',
      );
      
      broLog('[BRO-BG-LIQ] $successCount ordens auto-liquidadas com sucesso');
    }
  } catch (e) {
    broLog('[BRO-BG-LIQ] Erro geral: $e');
  } finally {
    // Liberar lock
    try {
      final lockPrefs = await SharedPreferences.getInstance();
      await lockPrefs.remove(_bgAutoLiqLockKey);
    } catch (_) {}
  }
}

/// v550: Lembretes progressivos em background (24h / 30h / 35h antes do
/// deadline de 36h). Cobre ambos os cenarios: provedor pendente de comprovante
/// (status=accepted) e usuario pendente de confirmacao (status=awaiting_confirmation).
Future<void> _checkOrderRemindersBackground() async {
  try {
    const secureStorage = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
      iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    );
    final userPubkey = await secureStorage.read(key: 'nostr_public_key');
    if (userPubkey == null || userPubkey.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    // v578: read via OrdersStorage (transparently decrypts).
    final ordersJson = await OrdersStorage.read(prefs, userPubkey);
    if (ordersJson == null || ordersJson.isEmpty) return;

    final rawList = jsonDecode(ordersJson);
    if (rawList is! List) return;
    final orders = rawList
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();

    await OrderReminderService().checkAndNotify(
      orders: orders,
      currentPubkey: userPubkey,
    );
  } catch (e) {
    broLog('[BRO-BG-REMINDER] Erro: $e');
  }
}

/// v569b: Verifica no Nostr se uma ordem já está em estado terminal
/// (liquidated, completed, cancelled, disputed). Retorna o status terminal
/// encontrado, ou null se nenhum evento terminal foi encontrado.
///
/// Usado pelo bg isolate ANTES de publicar auto-liquidação para evitar
/// re-publicar quando a ordem já foi disputada/concluída por outro caminho.
/// Cache local pode estar stale se o app não foi aberto desde então.
Future<String?> _fetchTerminalStatusFromNostr(String orderId) async {
  const terminalStatuses = {'liquidated', 'completed', 'cancelled', 'disputed'};
  for (final relay in _relays.take(3)) {
    try {
      final channel = WebSocketChannel.connect(Uri.parse(relay));
      try {
        await channel.ready.timeout(const Duration(seconds: 3));
      } catch (_) {
        try { channel.sink.close(); } catch (_) {}
        continue;
      }

      final subId = 'bg-tstatus-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
      // Query para eventos kind 30080/30081 desta orderId.
      final filter = {
        'kinds': [_kindBroPaymentProof, _kindBroComplete],
        '#orderId': [orderId],
        'limit': 30,
      };
      channel.sink.add(jsonEncode(['REQ', subId, filter]));

      String? foundStatus;
      try {
        await for (final msg in channel.stream.timeout(
          const Duration(seconds: 4),
          onTimeout: (sink) => sink.close(),
        )) {
          try {
            final response = jsonDecode(msg.toString());
            if (response is! List || response.isEmpty) continue;
            if (response[0] == 'EOSE') break;
            if (response[0] != 'EVENT' || response.length < 3) continue;
            final eventData = response[2];
            if (eventData is! Map) continue;
            final contentRaw = eventData['content'];
            if (contentRaw is! String) continue;
            try {
              final content = jsonDecode(contentRaw);
              if (content is! Map) continue;
              final status = content['status'] as String?;
              if (status != null && terminalStatuses.contains(status)) {
                foundStatus = status;
                break;
              }
            } catch (_) {}
          } catch (_) {}
        }
      } catch (_) {}

      try { channel.sink.add(jsonEncode(['CLOSE', subId])); } catch (_) {}
      try { channel.sink.close(); } catch (_) {}

      if (foundStatus != null) return foundStatus;
    } catch (_) {
      // tenta próximo relay
    }
  }
  return null;
}

/// Publica evento Nostr kind 30080 com status 'liquidated'
/// Versao standalone para background isolate (sem depender de NostrOrderService)
Future<bool> _publishAutoLiquidation({
  required String privateKey,
  required String providerPubkey,
  required String orderId,
  required String orderUserPubkey,
}) async {
  try {
    final keychain = Keychain(privateKey);
    
    final content = jsonEncode({
      'type': 'bro_order_update',
      'orderId': orderId,
      'status': 'liquidated',
      'providerId': providerPubkey,
      'userPubkey': orderUserPubkey.isNotEmpty ? orderUserPubkey : providerPubkey,
      'publishedBy': providerPubkey,
      'updatedAt': DateTime.now().toIso8601String(),
      'autoLiquidated': true,
    });
    
    final tags = [
      ['d', '${orderId}_${providerPubkey.substring(0, 8)}_update'],
      ['t', 'bro-order'],
      ['t', 'bro-update'],
      ['t', 'status-liquidated'],
      ['r', orderId],
      ['orderId', orderId],
    ];
    
    // Tags #p para ambas as partes
    final pTags = <String>{providerPubkey};
    if (orderUserPubkey.isNotEmpty) pTags.add(orderUserPubkey);
    for (final pk in pTags) {
      tags.add(['p', pk]);
    }
    
    final event = Event.from(
      kind: _kindBroPaymentProof, // 30080
      tags: tags,
      content: content,
      privkey: keychain.private,
    );
    
    // Publicar em pelo menos 1 relay
    for (final relay in _relays.take(3)) {
      try {
        final channel = WebSocketChannel.connect(Uri.parse(relay));
        try {
          await channel.ready.timeout(const Duration(seconds: 5));
        } catch (_) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
        
        channel.sink.add(jsonEncode(['EVENT', event.toJson()]));
        
        // Esperar OK do relay
        bool accepted = false;
        await for (final msg in channel.stream.timeout(
          const Duration(seconds: 5),
          onTimeout: (sink) => sink.close(),
        )) {
          final response = jsonDecode(msg.toString());
          if (response is List && response[0] == 'OK') {
            accepted = response[2] == true;
            break;
          }
        }
        
        try { channel.sink.close(); } catch (_) {}
        
        if (accepted) return true;
      } catch (e) {
        broLog('[BRO-BG-LIQ] Relay $relay erro: $e');
      }
    }
    
    return false;
  } catch (e) {
    broLog('[BRO-BG-LIQ] Erro ao publicar evento: $e');
    return false;
  }
}
