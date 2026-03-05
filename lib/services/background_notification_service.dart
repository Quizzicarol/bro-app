import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nostr/nostr.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:bro_app/services/log_utils.dart';
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
  
  // Se nunca verificou, usar "1 hora atras" para nao inundar com notificacoes antigas
  final sinceTimestamp = lastCheck > 0 ? lastCheck : (now - 3600);
  
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
  
  // 5b. Se provedor: verificar novas ordens disponiveis
  if (isProvider) {
    final orderEvents = await _queryRelaysForEvents(
      kinds: [_kindBroOrder],
      tags: {'#t': ['bro-order']}, // NAO usar #status — relays nao indexam tags longas
      since: sinceTimestamp,
    );
    // Filtrar: nao ser do proprio provedor + status pending
    for (final event in orderEvents) {
      final authorPubkey = event['pubkey']?.toString() ?? '';
      if (authorPubkey == userPubkey) continue; // Pular ordens proprias
      
      // Verificar status pending (filtro em memoria)
      final content = event['parsedContent'] as Map<String, dynamic>? ?? {};
      final status = content['status']?.toString() ?? _getTagValue(event, 'status') ?? 'pending';
      if (status != 'pending') continue; // Pular ordens ja aceitas/completadas
      
      newEvents.add(event);
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
      broLog('[BRO-BG] Kind desconhecido: $kind — ignorando');
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
    final ordersKey = 'orders_$userPubkey';
    final ordersJson = prefs.getString(ordersKey);
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
    if (successCount > 0) {
      await prefs.setString(ordersKey, jsonEncode(ordersList));
      
      // Manter apenas ultimos 200 IDs
      final recentDone = doneIds.toList();
      if (recentDone.length > 200) {
        recentDone.removeRange(0, recentDone.length - 200);
      }
      await prefs.setString(_bgAutoLiqKey, jsonEncode(recentDone));
      
      // 9. Notificacao local
      await _initNotifications();
      await _bgNotifications?.show(
        'auto_liq'.hashCode % 2147483647,
        '⚡ Auto-liquidação concluída',
        '$successCount ordem(ns) liquidada(s) automaticamente. Seus ganhos foram liberados.',
        const NotificationDetails(
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
