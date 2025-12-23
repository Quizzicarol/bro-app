import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:nostr/nostr.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/order.dart';

/// Serviço para publicar e buscar ordens via Nostr Relays
/// 
/// Kinds usados:
/// - 30078: Ordem de pagamento (replaceable event)
/// - 30079: Aceite de ordem pelo provedor
/// - 30080: Confirmação de pagamento
/// - 30081: Conclusão da ordem
class NostrOrderService {
  static final NostrOrderService _instance = NostrOrderService._internal();
  factory NostrOrderService() => _instance;
  NostrOrderService._internal();

  // Relays para publicar ordens
  final List<String> _relays = [
    'wss://relay.damus.io',
    'wss://nos.lol',
    'wss://relay.nostr.band',
    'wss://nostr.wine',
    'wss://relay.primal.net',
  ];

  // Kind para ordens Bro (usando addressable event para poder atualizar)
  static const int kindBroOrder = 30078;
  static const int kindBroAccept = 30079;
  static const int kindBroPaymentProof = 30080;
  static const int kindBroComplete = 30081;

  // Tag para identificar ordens do app
  static const String broTag = 'bro-order';
  static const String broAppTag = 'bro-app';

  /// Publica uma ordem nos relays (raw)
  Future<String?> _publishOrderRaw({
    required String privateKey,
    required String orderId,
    required String billType,
    required String billCode,
    required double amount,
    required double btcAmount,
    required double btcPrice,
    required double providerFee,
    required double platformFee,
    required double total,
  }) async {
    try {
      final keychain = Keychain(privateKey);
      
      // Conteúdo da ordem - inclui billCode para que o provedor possa pagar
      // NOTA: eventos kind 30078 são específicos do Bro app e não aparecem em clientes Nostr normais
      final content = jsonEncode({
        'type': 'bro_order',
        'version': '1.0',
        'orderId': orderId,
        'billType': billType,
        'billCode': billCode, // Código PIX/Boleto para o provedor pagar
        'amount': amount,
        'btcAmount': btcAmount,
        'btcPrice': btcPrice,
        'providerFee': providerFee,
        'platformFee': platformFee,
        'total': total,
        'status': 'pending',
        'createdAt': DateTime.now().toIso8601String(),
      });

      // Criar evento Nostr
      final event = Event.from(
        kind: kindBroOrder,
        tags: [
          ['d', orderId], // Identificador único (permite atualizar)
          ['t', broTag],
          ['t', broAppTag],
          ['t', billType],
          ['amount', amount.toStringAsFixed(2)],
          ['status', 'pending'],
        ],
        content: content,
        privkey: keychain.private,
      );

      debugPrint('📤 Publicando ordem $orderId nos relays...');
      
      // Publicar em todos os relays
      int successCount = 0;
      for (final relay in _relays) {
        try {
          final success = await _publishToRelay(relay, event);
          if (success) successCount++;
        } catch (e) {
          debugPrint('⚠️ Falha ao publicar em $relay: $e');
        }
      }

      debugPrint('✅ Ordem publicada em $successCount/${_relays.length} relays');
      
      return successCount > 0 ? event.id : null;
    } catch (e) {
      debugPrint('❌ Erro ao publicar ordem: $e');
      return null;
    }
  }

  /// Atualiza status de uma ordem nos relays
  /// NOTA: Usa kind 30080 (não 30078) para NÃO substituir o evento original!
  Future<bool> updateOrderStatus({
    required String privateKey,
    required String orderId,
    required String newStatus,
    String? providerId,
    String? paymentProof,
  }) async {
    try {
      final keychain = Keychain(privateKey);
      
      final content = jsonEncode({
        'type': 'bro_order_update',
        'orderId': orderId,
        'status': newStatus,
        'providerId': providerId,
        'paymentProof': paymentProof,
        'updatedAt': DateTime.now().toIso8601String(),
      });

      final tags = [
        ['d', '${orderId}_update'], // Tag diferente para não substituir o original
        ['e', orderId], // Referência ao orderId
        ['t', broTag],
        ['t', 'bro-update'],
        ['status', newStatus],
        ['orderId', orderId],
      ];
      
      if (providerId != null) {
        tags.add(['p', providerId]); // Tag do provedor
      }

      // IMPORTANTE: Usa kindBroPaymentProof (30080) para não substituir o evento original!
      final event = Event.from(
        kind: kindBroPaymentProof,
        tags: tags,
        content: content,
        privkey: keychain.private,
      );

      int successCount = 0;
      for (final relay in _relays) {
        try {
          final success = await _publishToRelay(relay, event);
          if (success) successCount++;
        } catch (e) {
          debugPrint('⚠️ Falha ao atualizar em $relay: $e');
        }
      }

      return successCount > 0;
    } catch (e) {
      debugPrint('❌ Erro ao atualizar ordem: $e');
      return false;
    }
  }

  /// Busca ordens aceitas por um provedor (raw)
  Future<List<Map<String, dynamic>>> _fetchProviderOrdersRaw(String providerPubkey) async {
    final orders = <Map<String, dynamic>>[];
    final seenIds = <String>{};

    for (final relay in _relays.take(3)) {
      try {
        final relayOrders = await _fetchFromRelay(
          relay,
          kinds: [kindBroOrder],
          tags: {'#p': [providerPubkey]},
          limit: 100,
        );
        
        for (final order in relayOrders) {
          final id = order['id'];
          if (!seenIds.contains(id)) {
            seenIds.add(id);
            orders.add(order);
          }
        }
      } catch (e) {
        debugPrint('⚠️ Falha ao buscar de $relay: $e');
      }
    }

    return orders;
  }

  /// Publica evento em um relay específico
  Future<bool> _publishToRelay(String relayUrl, Event event) async {
    final completer = Completer<bool>();
    WebSocketChannel? channel;
    Timer? timeout;

    try {
      channel = WebSocketChannel.connect(Uri.parse(relayUrl));
      
      // Timeout de 5 segundos
      timeout = Timer(const Duration(seconds: 5), () {
        if (!completer.isCompleted) {
          completer.complete(false);
          channel?.sink.close();
        }
      });

      // Escutar resposta
      channel.stream.listen(
        (message) {
          try {
            final response = jsonDecode(message);
            if (response[0] == 'OK' && response[1] == event.id) {
              if (!completer.isCompleted) {
                completer.complete(response[2] == true);
              }
            }
          } catch (_) {}
        },
        onError: (_) {
          if (!completer.isCompleted) completer.complete(false);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(false);
        },
      );

      // Enviar evento
      final eventJson = ['EVENT', event.toJson()];
      channel.sink.add(jsonEncode(eventJson));

      return await completer.future;
    } catch (e) {
      return false;
    } finally {
      timeout?.cancel();
      channel?.sink.close();
    }
  }

  /// Busca eventos de um relay
  Future<List<Map<String, dynamic>>> _fetchFromRelay(
    String relayUrl, {
    required List<int> kinds,
    List<String>? authors,
    Map<String, List<String>>? tags,
    int limit = 50,
  }) async {
    final events = <Map<String, dynamic>>[];
    final completer = Completer<List<Map<String, dynamic>>>();
    WebSocketChannel? channel;
    Timer? timeout;
    final subscriptionId = const Uuid().v4().substring(0, 8);

    try {
      channel = WebSocketChannel.connect(Uri.parse(relayUrl));
      
      // Timeout de 8 segundos
      timeout = Timer(const Duration(seconds: 8), () {
        if (!completer.isCompleted) {
          completer.complete(events);
          channel?.sink.close();
        }
      });

      // Escutar eventos
      channel.stream.listen(
        (message) {
          try {
            final response = jsonDecode(message);
            if (response[0] == 'EVENT' && response[1] == subscriptionId) {
              final eventData = response[2] as Map<String, dynamic>;
              
              // Parsear conteúdo JSON se possível
              try {
                final content = jsonDecode(eventData['content']);
                eventData['parsedContent'] = content;
              } catch (_) {}
              
              events.add(eventData);
            } else if (response[0] == 'EOSE') {
              // End of stored events
              if (!completer.isCompleted) {
                completer.complete(events);
              }
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
        'limit': limit,
      };
      
      if (authors != null && authors.isNotEmpty) {
        filter['authors'] = authors;
      }
      
      if (tags != null) {
        filter.addAll(tags);
      }

      // Enviar requisição
      final req = ['REQ', subscriptionId, filter];
      channel.sink.add(jsonEncode(req));

      return await completer.future;
    } catch (e) {
      debugPrint('❌ Erro ao buscar de $relayUrl: $e');
      return events;
    } finally {
      timeout?.cancel();
      // Fechar subscription
      try {
        channel?.sink.add(jsonEncode(['CLOSE', subscriptionId]));
      } catch (_) {}
      channel?.sink.close();
    }
  }

  /// Converte evento Nostr para Order model
  /// RETORNA NULL se ordem inválida (amount=0 e não é evento de update)
  Order? eventToOrder(Map<String, dynamic> event) {
    try {
      final rawContent = event['content'];
      debugPrint('📋 RAW CONTENT: $rawContent');
      
      final content = event['parsedContent'] ?? jsonDecode(rawContent ?? '{}');
      
      // Verificar se é um evento de update (não tem dados completos)
      final eventType = content['type'] as String?;
      if (eventType == 'bro_order_update') {
        debugPrint('⚠️ Evento é um UPDATE, não uma ordem completa - ignorando');
        return null; // Updates são tratados separadamente
      }
      
      // Log para debug
      final amount = (content['amount'] as num?)?.toDouble() ?? 0;
      final orderId = content['orderId'] ?? event['id'];
      debugPrint('📋 eventToOrder: $orderId -> amount=$amount, btcAmount=${content['btcAmount']}');
      
      // Se amount é 0, tentar pegar das tags
      double finalAmount = amount;
      if (finalAmount == 0) {
        final tags = event['tags'] as List<dynamic>?;
        if (tags != null) {
          for (final tag in tags) {
            if (tag is List && tag.length >= 2 && tag[0] == 'amount') {
              finalAmount = double.tryParse(tag[1].toString()) ?? 0;
              debugPrint('📋 eventToOrder: amount from tags = $finalAmount');
              break;
            }
          }
        }
      }
      
      // VALIDAÇÃO CRÍTICA: Não aceitar ordens com amount=0
      if (finalAmount == 0) {
        debugPrint('⚠️ REJEITANDO ordem ${orderId} com amount=0 (dados corrompidos)');
        return null;
      }
      
      return Order(
        id: orderId,
        eventId: event['id'],
        userPubkey: event['pubkey'],
        billType: content['billType'] ?? 'pix',
        billCode: content['billCode'] ?? '', // Pode estar vazio por privacidade
        amount: finalAmount,
        btcAmount: (content['btcAmount'] as num?)?.toDouble() ?? 0,
        btcPrice: (content['btcPrice'] as num?)?.toDouble() ?? 0,
        providerFee: (content['providerFee'] as num?)?.toDouble() ?? 0,
        platformFee: (content['platformFee'] as num?)?.toDouble() ?? 0,
        total: (content['total'] as num?)?.toDouble() ?? 0,
        status: content['status'] ?? _getStatusFromTags(event['tags']),
        providerId: content['providerId'],
        createdAt: DateTime.tryParse(content['createdAt'] ?? '') ?? 
                   DateTime.fromMillisecondsSinceEpoch((event['created_at'] ?? 0) * 1000),
      );
    } catch (e) {
      debugPrint('⚠️ Erro ao converter evento para Order: $e');
      return null;
    }
  }

  String _getStatusFromTags(List<dynamic>? tags) {
    if (tags == null) return 'pending';
    for (final tag in tags) {
      if (tag is List && tag.length >= 2 && tag[0] == 'status') {
        return tag[1].toString();
      }
    }
    return 'pending';
  }

  /// Publica uma ordem usando objeto Order
  Future<String?> publishOrder({
    required Order order,
    required String privateKey,
  }) async {
    return await _publishOrderRaw(
      privateKey: privateKey,
      orderId: order.id,
      billType: order.billType,
      billCode: order.billCode,
      amount: order.amount,
      btcAmount: order.btcAmount,
      btcPrice: order.btcPrice,
      providerFee: order.providerFee,
      platformFee: order.platformFee,
      total: order.total,
    );
  }

  /// Provider aceita uma ordem
  Future<bool> acceptOrderOnNostr({
    required Order order,
    required String providerPrivateKey,
  }) async {
    try {
      final keychain = Keychain(providerPrivateKey);
      
      final content = jsonEncode({
        'type': 'bro_accept',
        'orderId': order.id,
        'orderEventId': order.eventId,
        'providerId': keychain.public,
        'acceptedAt': DateTime.now().toIso8601String(),
      });

      final event = Event.from(
        kind: kindBroAccept,
        tags: [
          ['d', '${order.id}_accept'],
          ['e', order.eventId ?? order.id], // Referência ao evento original
          ['p', order.userPubkey ?? ''], // Tag do usuário que criou a ordem
          ['t', broTag],
          ['t', 'bro-accept'],
          ['orderId', order.id],
        ],
        content: content,
        privkey: keychain.private,
      );

      debugPrint('📤 Publicando aceite da ordem ${order.id}...');
      
      int successCount = 0;
      for (final relay in _relays) {
        try {
          final success = await _publishToRelay(relay, event);
          if (success) successCount++;
        } catch (e) {
          debugPrint('⚠️ Falha ao publicar aceite em $relay: $e');
        }
      }

      debugPrint('✅ Aceite publicado em $successCount/${_relays.length} relays');
      return successCount > 0;
    } catch (e) {
      debugPrint('❌ Erro ao publicar aceite: $e');
      return false;
    }
  }

  /// Provider completa uma ordem (com prova de pagamento)
  /// NOTA: A prova é enviada em base64. Para privacidade total, 
  /// considerar implementar NIP-17 (Gift Wraps) ou enviar via DM separado
  Future<bool> completeOrderOnNostr({
    required Order order,
    required String providerPrivateKey,
    required String proofImageBase64,
  }) async {
    try {
      final keychain = Keychain(providerPrivateKey);
      
      // NOTA: O comprovante é enviado em texto claro por enquanto
      // Para privacidade total, implementar NIP-17 ou enviar via canal separado
      // O evento é tagged com a pubkey do usuário para que ele possa encontrar
      final content = jsonEncode({
        'type': 'bro_complete',
        'orderId': order.id,
        'orderEventId': order.eventId,
        'providerId': keychain.public,
        'proofImage': proofImageBase64, // Base64 do comprovante
        'recipientPubkey': order.userPubkey, // Para quem é destinado
        'completedAt': DateTime.now().toIso8601String(),
      });

      final event = Event.from(
        kind: kindBroComplete,
        tags: [
          ['d', '${order.id}_complete'],
          ['e', order.eventId ?? order.id], // Referência ao evento original
          ['p', order.userPubkey ?? ''], // Tag do usuário que criou a ordem
          ['t', broTag],
          ['t', 'bro-complete'],
          ['orderId', order.id],
        ],
        content: content,
        privkey: keychain.private,
      );

      debugPrint('📤 Publicando conclusão da ordem ${order.id}...');
      
      int successCount = 0;
      for (final relay in _relays) {
        try {
          final success = await _publishToRelay(relay, event);
          if (success) successCount++;
        } catch (e) {
          debugPrint('⚠️ Falha ao publicar conclusão em $relay: $e');
        }
      }

      debugPrint('✅ Conclusão publicada em $successCount/${_relays.length} relays');
      return successCount > 0;
    } catch (e) {
      debugPrint('❌ Erro ao publicar conclusão: $e');
      return false;
    }
  }

  /// Busca ordens pendentes e retorna como List<Order>
  Future<List<Order>> fetchPendingOrders() async {
    final rawOrders = await _fetchPendingOrdersRaw();
    return rawOrders
        .map((e) => eventToOrder(e))
        .whereType<Order>()
        .toList();
  }

  /// Busca ordens de um usuário específico e retorna como List<Order>
  Future<List<Order>> fetchUserOrders(String pubkey) async {
    final rawOrders = await _fetchUserOrdersRaw(pubkey);
    return rawOrders
        .map((e) => eventToOrder(e))
        .whereType<Order>()
        .toList();
  }

  /// Busca ordens pendentes (raw)
  Future<List<Map<String, dynamic>>> _fetchPendingOrdersRaw() async {
    final orders = <Map<String, dynamic>>[];
    final seenIds = <String>{};

    debugPrint('🔍 Buscando ordens pendentes nos relays...');

    for (final relay in _relays.take(3)) {
      try {
        final relayOrders = await _fetchFromRelay(
          relay,
          kinds: [kindBroOrder],
          tags: {'#t': [broTag], '#status': ['pending']},
          limit: 50,
        );
        
        for (final order in relayOrders) {
          final id = order['id'];
          if (!seenIds.contains(id)) {
            seenIds.add(id);
            orders.add(order);
          }
        }
      } catch (e) {
        debugPrint('⚠️ Falha ao buscar de $relay: $e');
      }
    }

    debugPrint('✅ Encontradas ${orders.length} ordens pendentes');
    return orders;
  }

  /// Busca ordens de um usuário (raw)
  Future<List<Map<String, dynamic>>> _fetchUserOrdersRaw(String pubkey) async {
    final orders = <Map<String, dynamic>>[];
    final seenIds = <String>{};

    debugPrint('🔍 Buscando ordens do usuário ${pubkey.substring(0, 16)}...');
    debugPrint('   Relays: ${_relays.take(3).join(", ")}');

    for (final relay in _relays.take(3)) {
      debugPrint('   Tentando relay: $relay');
      try {
        final relayOrders = await _fetchFromRelay(
          relay,
          kinds: [kindBroOrder],
          authors: [pubkey],
          tags: {'#t': [broTag]},
          limit: 100,
        );
        
        debugPrint('   $relay retornou ${relayOrders.length} eventos');
        
        for (final order in relayOrders) {
          final id = order['id'];
          if (!seenIds.contains(id)) {
            seenIds.add(id);
            orders.add(order);
          }
        }
      } catch (e) {
        debugPrint('⚠️ Falha ao buscar de $relay: $e');
      }
    }

    debugPrint('✅ Total: ${orders.length} ordens únicas do usuário');
    return orders;
  }

  /// Busca eventos de aceitação e comprovante direcionados a um usuário
  /// Isso permite que o usuário veja quando um Bro aceitou sua ordem ou enviou comprovante
  Future<Map<String, Map<String, dynamic>>> fetchOrderUpdatesForUser(String userPubkey, {List<String>? orderIds}) async {
    final updates = <String, Map<String, dynamic>>{}; // orderId -> latest update
    
    debugPrint('🔍 Buscando atualizações de ordens para ${userPubkey.substring(0, 16)}...');
    if (orderIds != null && orderIds.isNotEmpty) {
      debugPrint('   IDs das ordens: ${orderIds.join(", ")}');
    }

    for (final relay in _relays.take(3)) {
      try {
        // Buscar eventos de aceitação (kind 30079) e comprovante (kind 30081) onde o usuário é tagged
        var events = await _fetchFromRelay(
          relay,
          kinds: [kindBroAccept, kindBroComplete],
          tags: {'#p': [userPubkey]}, // Eventos direcionados ao usuário
          limit: 100,
        );
        
        debugPrint('   $relay: ${events.length} eventos via #p');
        
        // Se não encontrou eventos e temos IDs de ordens, buscar por tag #t (bro-accept, bro-complete)
        if (events.isEmpty) {
          final altEvents = await _fetchFromRelay(
            relay,
            kinds: [kindBroAccept, kindBroComplete],
            tags: {'#t': [broTag]}, // Todos os eventos bro
            limit: 100,
          );
          debugPrint('   $relay: ${altEvents.length} eventos via #t (fallback)');
          events = altEvents;
        }
        
        for (final event in events) {
          try {
            final content = event['parsedContent'] ?? jsonDecode(event['content']);
            final orderId = content['orderId'] as String?;
            final eventKind = event['kind'] as int?;
            final createdAt = event['created_at'] as int? ?? 0;
            
            if (orderId == null) continue;
            
            // Verificar se este evento é mais recente que o atual
            final existingUpdate = updates[orderId];
            final existingCreatedAt = existingUpdate?['created_at'] as int? ?? 0;
            
            if (existingUpdate == null || createdAt > existingCreatedAt) {
              // Determinar o novo status baseado no tipo de evento
              String newStatus;
              if (eventKind == kindBroAccept) {
                newStatus = 'accepted';
              } else if (eventKind == kindBroComplete) {
                newStatus = 'awaiting_confirmation';
              } else {
                continue;
              }
              
              updates[orderId] = {
                'orderId': orderId,
                'status': newStatus,
                'eventKind': eventKind,
                'providerId': content['providerId'] ?? event['pubkey'],
                'proofImage': content['proofImage'], // Pode ser null para aceites
                'created_at': createdAt,
              };
              
              debugPrint('   📥 Ordem $orderId: status=$newStatus (kind=$eventKind)');
            }
          } catch (e) {
            debugPrint('   ⚠️ Erro ao processar evento: $e');
          }
        }
      } catch (e) {
        debugPrint('⚠️ Falha ao buscar de $relay: $e');
      }
    }

    debugPrint('✅ ${updates.length} atualizações encontradas');
    return updates;
  }
}
