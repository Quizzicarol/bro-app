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
    'wss://nostr.wine',
    'wss://relay.primal.net',
    'wss://relay.snort.social',
  ];

  // Kind para ordens Bro (usando addressable event para poder atualizar)
  static const int kindBroOrder = 30078;
  static const int kindBroAccept = 30079;
  static const int kindBroPaymentProof = 30080;
  static const int kindBroComplete = 30081;
  static const int kindBroProviderTier = 30082; // Tier do provedor

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
      final userPubkey = keychain.public;
      
      final content = jsonEncode({
        'type': 'bro_order_update',
        'orderId': orderId,
        'status': newStatus,
        'providerId': providerId,
        'userPubkey': userPubkey, // Quem publicou este update
        'paymentProof': paymentProof,
        'updatedAt': DateTime.now().toIso8601String(),
      });

      // CORREÇÃO: Usar d-tag única por usuário+ordem para evitar conflitos
      // Isso permite que tanto Bro quanto Usuário publiquem updates independentes
      final tags = [
        ['d', '${orderId}_${userPubkey.substring(0, 8)}_update'], // Tag única por usuário
        ['e', orderId], // Referência ao orderId
        ['t', broTag],
        ['t', 'bro-update'],
        ['t', 'status-$newStatus'], // Tag pesquisável por status
        ['orderId', orderId], // Tag customizada para busca
      ];
      
      // CRÍTICO: Sempre adicionar tag p do provedor para que ele receba
      if (providerId != null && providerId.isNotEmpty) {
        tags.add(['p', providerId]); // Tag do provedor - CRÍTICO para notificação
        debugPrint('📤 Adicionando tag p=$providerId ao evento de status $newStatus');
      } else {
        debugPrint('⚠️ AVISO: Publicando update sem tag p (providerId ausente)');
      }

      // IMPORTANTE: Usa kindBroPaymentProof (30080) para não substituir o evento original!
      final event = Event.from(
        kind: kindBroPaymentProof,
        tags: tags,
        content: content,
        privkey: keychain.private,
      );

      debugPrint('📤 Publicando evento kind=${event.kind} com ${tags.length} tags');
      debugPrint('   orderId: $orderId');
      debugPrint('   status: $newStatus');
      debugPrint('   providerId: ${providerId ?? "NENHUM"}');

      int successCount = 0;
      for (final relay in _relays) {
        try {
          final success = await _publishToRelay(relay, event);
          if (success) {
            successCount++;
            debugPrint('   ✅ Publicado em $relay');
          }
        } catch (e) {
          debugPrint('   ⚠️ Falha em $relay: $e');
        }
      }

      debugPrint('📤 Evento publicado em $successCount/${_relays.length} relays');
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

    debugPrint('🔍 Buscando ordens do provedor ${providerPubkey.substring(0, 16)}...');

    for (final relay in _relays.take(3)) {
      try {
        final relayOrders = await _fetchFromRelay(
          relay,
          kinds: [kindBroOrder],
          tags: {'#p': [providerPubkey]},
          limit: 100,
        );
        
        debugPrint('   $relay retornou ${relayOrders.length} ordens do provedor');
        
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

    debugPrint('✅ Encontradas ${orders.length} ordens do provedor');
    return orders;
  }

  /// Busca ordens aceitas por um provedor e retorna como List<Order>
  Future<List<Order>> fetchProviderOrders(String providerPubkey) async {
    final rawOrders = await _fetchProviderOrdersRaw(providerPubkey);
    return rawOrders
        .map((e) => eventToOrder(e))
        .whereType<Order>()
        .toList();
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
    return _fetchFromRelayWithSince(
      relayUrl,
      kinds: kinds,
      authors: authors,
      tags: tags,
      limit: limit,
      since: null,
    );
  }
  
  /// Busca eventos de um relay com suporte a 'since' timestamp
  /// CRÍTICO para sincronização entre dispositivos - o 'since' permite
  /// que relays retornem apenas eventos recentes, melhorando consistência
  Future<List<Map<String, dynamic>>> _fetchFromRelayWithSince(
    String relayUrl, {
    required List<int> kinds,
    List<String>? authors,
    Map<String, List<String>>? tags,
    int? since,
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
      
      // CRÍTICO: Adicionar 'since' para melhor sincronização entre dispositivos
      if (since != null) {
        filter['since'] = since;
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

  /// Busca uma ordem específica do Nostr pelo ID
  Future<Map<String, dynamic>?> fetchOrderFromNostr(String orderId) async {
    debugPrint('🔍 Buscando ordem $orderId no Nostr...');
    
    for (final relay in _relays) {
      try {
        final events = await _fetchFromRelay(
          relay,
          kinds: [kindBroOrder],
          tags: {'#d': [orderId]}, // Buscar pelo d-tag (orderId)
          limit: 1,
        );
        
        if (events.isNotEmpty) {
          final event = events.first;
          final content = event['parsedContent'] ?? jsonDecode(event['content']);
          
          debugPrint('✅ Ordem $orderId encontrada no relay $relay');
          
          return {
            'id': orderId,
            'eventId': event['id'],
            'userPubkey': event['pubkey'],
            'billType': content['billType'] ?? 'pix',
            'billCode': content['billCode'] ?? '',
            'amount': (content['amount'] as num?)?.toDouble() ?? 0,
            'btcAmount': (content['btcAmount'] as num?)?.toDouble() ?? 0,
            'btcPrice': (content['btcPrice'] as num?)?.toDouble() ?? 0,
            'providerFee': (content['providerFee'] as num?)?.toDouble() ?? 0,
            'platformFee': (content['platformFee'] as num?)?.toDouble() ?? 0,
            'total': (content['total'] as num?)?.toDouble() ?? 0,
            'status': content['status'] ?? 'pending',
            'createdAt': content['createdAt'],
          };
        }
      } catch (e) {
        debugPrint('⚠️ Falha ao buscar ordem de $relay: $e');
      }
    }
    
    debugPrint('❌ Ordem $orderId não encontrada no Nostr');
    return null;
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
  /// Para modo Bro: retorna APENAS ordens que ainda não foram aceitas por nenhum Bro
  Future<List<Order>> fetchPendingOrders() async {
    final rawOrders = await _fetchPendingOrdersRaw();
    
    // Buscar eventos de UPDATE para saber quais ordens já foram aceitas
    final statusUpdates = await _fetchAllOrderStatusUpdates();
    
    // Converter para Orders
    final allOrders = rawOrders
        .map((e) => eventToOrder(e))
        .whereType<Order>()
        .toList();
    
    debugPrint('📦 Total de ordens RAW encontradas: ${allOrders.length}');
    
    // FILTRAR: Mostrar apenas ordens que NÃO foram aceitas por nenhum Bro
    // OU que têm status pending/payment_received
    final availableOrders = <Order>[];
    for (var order in allOrders) {
      final update = statusUpdates[order.id];
      final updateStatus = update?['status'] as String?;
      final updateProviderId = update?['providerId'] as String?;
      
      // Se não tem update OU se o update não é de accept/complete, está disponível
      final isAccepted = updateStatus == 'accepted' || updateStatus == 'awaiting_confirmation' || updateStatus == 'completed';
      
      if (!isAccepted) {
        // Ordem ainda não foi aceita - DISPONÍVEL para Bros
        debugPrint('   ✅ ${order.id.substring(0, 8)}: status=${order.status} - DISPONÍVEL');
        availableOrders.add(order);
      } else {
        // Ordem já foi aceita por alguém
        debugPrint('   ❌ ${order.id.substring(0, 8)}: já aceita (status=$updateStatus, providerId=${updateProviderId?.substring(0, 8) ?? "?"})');
      }
    }
    
    debugPrint('📦 Ordens disponíveis para Bros: ${availableOrders.length}/${allOrders.length}');
    
    return availableOrders;
  }

  /// Busca ordens de um usuário específico e retorna como List<Order>
  /// INCLUI merge com eventos de UPDATE para obter status correto
  Future<List<Order>> fetchUserOrders(String pubkey) async {
    final rawOrders = await _fetchUserOrdersRaw(pubkey);
    
    // Buscar eventos de UPDATE para obter status mais recente
    final statusUpdates = await _fetchAllOrderStatusUpdates();
    
    // Converter para Orders e aplicar status atualizado
    // SEGURANÇA CRÍTICA: Filtrar novamente para garantir que só retorne ordens deste usuário
    // (alguns relays podem ignorar o filtro 'authors')
    final orders = rawOrders
        .map((e) => eventToOrder(e))
        .whereType<Order>()
        .where((order) {
          // Verificar se a ordem realmente pertence ao usuário
          if (order.userPubkey != pubkey) {
            debugPrint('🚫 SEGURANÇA: Ordem ${order.id.substring(0, 8)} é de ${order.userPubkey?.substring(0, 8) ?? "null"}, esperado $pubkey - REMOVENDO');
            return false;
          }
          return true;
        })
        .map((order) => _applyStatusUpdate(order, statusUpdates))
        .toList();
    
    debugPrint('✅ fetchUserOrders: ${orders.length} ordens VERIFICADAS para $pubkey');
    return orders;
  }
  
  /// Busca TODOS os eventos de UPDATE de status (kind 30080, 30081)
  /// Inclui: updates de status, conclusões de ordem
  Future<Map<String, Map<String, dynamic>>> _fetchAllOrderStatusUpdates() async {
    final updates = <String, Map<String, dynamic>>{}; // orderId -> latest update
    
    debugPrint('🔄 Buscando eventos de UPDATE de status...');
    
    for (final relay in _relays.take(3)) {
      try {
        // Buscar TODOS os tipos de update: 30079 (accept), 30080 (update), 30081 (complete)
        final events = await _fetchFromRelay(
          relay,
          kinds: [kindBroAccept, kindBroPaymentProof, kindBroComplete], // 30079, 30080 e 30081
          tags: {'#t': [broTag]}, // Buscar por bro-order tag genérica
          limit: 200,
        );
        
        for (final event in events) {
          try {
            final content = event['parsedContent'] ?? jsonDecode(event['content']);
            final eventType = content['type'] as String?;
            final eventKind = event['kind'] as int?;
            
            // Processar eventos de accept, update OU complete
            if (eventType != 'bro_accept' && 
                eventType != 'bro_order_update' && 
                eventType != 'bro_complete') continue;
            
            final orderId = content['orderId'] as String?;
            if (orderId == null) continue;
            
            final createdAt = event['created_at'] as int? ?? 0;
            
            // Manter apenas o update mais recente para cada ordem
            final existingUpdate = updates[orderId];
            final existingCreatedAt = existingUpdate?['created_at'] as int? ?? 0;
            
            if (existingUpdate == null || createdAt > existingCreatedAt) {
              // Determinar status baseado no tipo de evento
              String? status = content['status'] as String?;
              if (eventType == 'bro_accept' || eventKind == kindBroAccept) {
                status = 'accepted';
              } else if (eventType == 'bro_complete' || eventKind == kindBroComplete) {
                status = 'awaiting_confirmation'; // Bro pagou, aguardando confirmação do usuário
              }
              
              // IMPORTANTE: Incluir proofImage do comprovante para o usuário ver
              final proofImage = content['proofImage'] as String?;
              
              // providerId pode vir do content ou do pubkey do evento (para accepts)
              final providerId = content['providerId'] as String? ?? event['pubkey'] as String?;
              
              updates[orderId] = {
                'orderId': orderId,
                'status': status,
                'providerId': providerId,
                'proofImage': proofImage, // Comprovante enviado pelo Bro
                'completedAt': content['completedAt'],
                'created_at': createdAt,
              };
              debugPrint('   📥 Update: $orderId -> status=$status, providerId=${providerId?.substring(0, 8) ?? "null"} (type=$eventType)');
            }
          } catch (e) {
            // Ignorar eventos mal formatados
          }
        }
      } catch (e) {
        debugPrint('⚠️ Falha ao buscar updates de $relay: $e');
      }
    }
    
    debugPrint('✅ ${updates.length} updates de status encontrados');
    return updates;
  }
  
  /// Aplica o status mais recente de um update a uma ordem
  Order _applyStatusUpdate(Order order, Map<String, Map<String, dynamic>> statusUpdates) {
    final update = statusUpdates[order.id];
    if (update == null) return order;
    
    final newStatus = update['status'] as String?;
    final providerId = update['providerId'] as String?;
    final proofImage = update['proofImage'] as String?;
    final completedAt = update['completedAt'] as String?;
    
    if (newStatus != null && newStatus != order.status) {
      debugPrint('   🔄 Aplicando status: ${order.id.substring(0, 8)} ${order.status} -> $newStatus (hasProof=${proofImage != null})');
      
      // Mesclar metadata existente com novos dados do comprovante
      final updatedMetadata = Map<String, dynamic>.from(order.metadata ?? {});
      if (proofImage != null && proofImage.isNotEmpty) {
        updatedMetadata['proofImage'] = proofImage;
        updatedMetadata['paymentProof'] = proofImage; // Compatibilidade
      }
      if (completedAt != null) {
        updatedMetadata['proofReceivedAt'] = completedAt;
      }
      
      return Order(
        id: order.id,
        eventId: order.eventId,
        userPubkey: order.userPubkey,
        billType: order.billType,
        billCode: order.billCode,
        amount: order.amount,
        btcAmount: order.btcAmount,
        btcPrice: order.btcPrice,
        providerFee: order.providerFee,
        platformFee: order.platformFee,
        total: order.total,
        status: newStatus,
        providerId: providerId ?? order.providerId,
        createdAt: order.createdAt,
        metadata: updatedMetadata, // IMPORTANTE: Incluir metadata com proofImage!
      );
    }
    
    return order;
  }

  /// Busca ordens pendentes (raw) - todas as ordens disponíveis para Bros
  Future<List<Map<String, dynamic>>> _fetchPendingOrdersRaw() async {
    final orders = <Map<String, dynamic>>[];
    final seenIds = <String>{};

    debugPrint('🔍 Buscando ordens disponíveis para Bros nos relays...');
    debugPrint('   Relays: ${_relays.join(", ")}');
    
    // IMPORTANTE: Buscar ordens dos últimos 7 dias apenas
    // Isso melhora a sincronização entre dispositivos e evita ordens antigas
    final sevenDaysAgo = DateTime.now().subtract(const Duration(days: 7));
    final sinceTimestamp = (sevenDaysAgo.millisecondsSinceEpoch / 1000).floor();
    debugPrint('   Since: ${sevenDaysAgo.toIso8601String()} (timestamp: $sinceTimestamp)');

    // ESTRATÉGIA 1: Buscar com tag #t (mais eficiente quando funciona)
    for (final relay in _relays) {
      debugPrint('   [TAG] Tentando relay: $relay');
      try {
        final relayOrders = await _fetchFromRelayWithSince(
          relay,
          kinds: [kindBroOrder],
          tags: {'#t': [broTag]},
          since: sinceTimestamp,
          limit: 100,
        );
        
        debugPrint('   [TAG] $relay retornou ${relayOrders.length} eventos');
        
        for (final order in relayOrders) {
          final id = order['id'];
          if (!seenIds.contains(id)) {
            seenIds.add(id);
            orders.add(order);
          }
        }
      } catch (e) {
        debugPrint('⚠️ [TAG] Falha ao buscar de $relay: $e');
      }
    }
    
    // ESTRATÉGIA 2: Se não encontrou ordens com tag, buscar por kind apenas
    // Isso é um fallback para relays que não suportam bem filtro por tag
    if (orders.isEmpty) {
      debugPrint('⚠️ Nenhuma ordem encontrada com tag, tentando busca por kind...');
      for (final relay in _relays) {
        debugPrint('   [KIND] Tentando relay: $relay');
        try {
          final relayOrders = await _fetchFromRelayWithSince(
            relay,
            kinds: [kindBroOrder],
            since: sinceTimestamp,
            limit: 100,
          );
          
          debugPrint('   [KIND] $relay retornou ${relayOrders.length} eventos');
          
          for (final order in relayOrders) {
            final id = order['id'];
            // Verificar se é ordem do Bro app (verificando content)
            try {
              final content = order['parsedContent'] ?? jsonDecode(order['content'] ?? '{}');
              if (content['type'] == 'bro_order') {
                if (!seenIds.contains(id)) {
                  seenIds.add(id);
                  orders.add(order);
                }
              }
            } catch (_) {}
          }
        } catch (e) {
          debugPrint('⚠️ [KIND] Falha ao buscar de $relay: $e');
        }
      }
    }

    debugPrint('✅ Encontradas ${orders.length} ordens totais nos relays');
    return orders;
  }

  /// Busca ordens de um usuário (raw)
  Future<List<Map<String, dynamic>>> _fetchUserOrdersRaw(String pubkey) async {
    final orders = <Map<String, dynamic>>[];
    final seenIds = <String>{};

    debugPrint('🔍 Buscando ordens do usuário ${pubkey.substring(0, 16)}...');
    debugPrint('   Relays: ${_relays.join(", ")}');

    for (final relay in _relays) {
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
  
  /// Busca eventos de update de status para ordens que o provedor aceitou
  /// Isso permite que o Bro veja quando o usuário confirmou o pagamento (completed)
  /// SEGURANÇA: Só retorna updates para ordens específicas do provedor
  Future<Map<String, Map<String, dynamic>>> fetchOrderUpdatesForProvider(String providerPubkey, {List<String>? orderIds}) async {
    final updates = <String, Map<String, dynamic>>{}; // orderId -> latest update
    
    // SEGURANÇA: Se não temos orderIds específicos, não buscar nada
    // Isso previne vazamento de ordens de outros usuários
    if (orderIds == null || orderIds.isEmpty) {
      debugPrint('⚠️ [BUSCA UPDATES] Nenhum orderId fornecido, retornando vazio (segurança)');
      return updates;
    }
    
    debugPrint('🔍 [BUSCA UPDATES] Buscando atualizações para provedor ${providerPubkey.substring(0, 16)}...');
    debugPrint('   Ordens a verificar (${orderIds.length}): ${orderIds.map((id) => id.substring(0, 8)).join(", ")}');

    // Converter orderIds para Set para busca O(1)
    final orderIdSet = orderIds.toSet();

    for (final relay in _relays.take(3)) {
      try {
        debugPrint('   🔍 Buscando em $relay...');
        
        // ESTRATÉGIA 1: Buscar por tag #p (eventos direcionados ao provedor)
        // Esta é a forma mais segura - só retorna eventos onde o provedor foi tagueado
        final pTagEvents = await _fetchFromRelay(
          relay,
          kinds: [kindBroPaymentProof], // 30080
          tags: {'#p': [providerPubkey]},
          limit: 100,
        );
        
        debugPrint('   📥 $relay: ${pTagEvents.length} eventos via #p');
        
        for (final event in pTagEvents) {
          try {
            final content = event['parsedContent'] ?? jsonDecode(event['content']);
            final eventOrderId = content['orderId'] as String?;
            final status = content['status'] as String?;
            final createdAt = event['created_at'] as int? ?? 0;
            
            if (eventOrderId == null || status == null) continue;
            
            // SEGURANÇA: Só processar se a ordem está na lista que buscamos
            if (!orderIdSet.contains(eventOrderId)) continue;
            
            final existingUpdate = updates[eventOrderId];
            final existingCreatedAt = existingUpdate?['created_at'] as int? ?? 0;
            
            if (existingUpdate == null || createdAt > existingCreatedAt) {
              updates[eventOrderId] = {
                'orderId': eventOrderId,
                'status': status,
                'created_at': createdAt,
              };
              debugPrint('   ✅ Update via #p: ${eventOrderId.substring(0, 8)} -> $status');
            }
          } catch (_) {}
        }
        
        // ESTRATÉGIA 2: Buscar diretamente por cada orderId específico
        // Fallback para quando a tag #p não foi indexada
        for (final orderId in orderIds.take(5)) {
          try {
            // Buscar por tag #e (referência ao orderId)
            final eTagEvents = await _fetchFromRelay(
              relay,
              kinds: [kindBroPaymentProof],
              tags: {'#e': [orderId]},
              limit: 5,
            );
            
            for (final event in eTagEvents) {
              try {
                final content = event['parsedContent'] ?? jsonDecode(event['content']);
                final eventOrderId = content['orderId'] as String?;
                final status = content['status'] as String?;
                final createdAt = event['created_at'] as int? ?? 0;
                
                // SEGURANÇA: Verificar se é a ordem correta
                if (eventOrderId == null || eventOrderId != orderId) continue;
                if (status == null) continue;
                
                final existingUpdate = updates[eventOrderId];
                final existingCreatedAt = existingUpdate?['created_at'] as int? ?? 0;
                
                if (existingUpdate == null || createdAt > existingCreatedAt) {
                  updates[eventOrderId] = {
                    'orderId': eventOrderId,
                    'status': status,
                    'created_at': createdAt,
                  };
                  debugPrint('   ✅ Update via #e: ${eventOrderId.substring(0, 8)} -> $status');
                }
              } catch (_) {}
            }
          } catch (_) {}
        }
        
      } catch (e) {
        debugPrint('   ⚠️ Falha em $relay: $e');
      }
    }

    debugPrint('🔍 [BUSCA UPDATES] Total: ${updates.length} updates encontrados');
    return updates;
  }

  // ============================================
  // TIER/COLLATERAL - Persistência no Nostr
  // ============================================
  
  /// Kind para dados do provedor (tier, collateral, etc)
  static const int kindBroProviderData = 30082;
  static const String providerDataTag = 'bro-provider-data';
  
  /// Publica os dados do tier/collateral do provedor no Nostr
  Future<bool> publishProviderTier({
    required String privateKey,
    required String tierId,
    required String tierName,
    required int depositedSats,
    required int maxOrderValue,
    required String activatedAt,
  }) async {
    try {
      final keychain = Keychain(privateKey);
      
      final content = jsonEncode({
        'type': 'bro_provider_tier',
        'version': '1.0',
        'tierId': tierId,
        'tierName': tierName,
        'depositedSats': depositedSats,
        'maxOrderValue': maxOrderValue,
        'activatedAt': activatedAt,
        'updatedAt': DateTime.now().toIso8601String(),
      });

      // Usar evento replaceable (kind 30082) com 'd' tag = pubkey do provedor
      // Isso permite atualizar o tier sem criar múltiplos eventos
      final event = Event.from(
        kind: kindBroProviderTier,
        tags: [
          ['d', 'tier_${keychain.public}'], // Identificador único por provedor
          ['t', providerDataTag],
          ['t', broAppTag],
          ['tierId', tierId],
        ],
        content: content,
        privkey: keychain.private,
      );

      debugPrint('📤 Publicando tier $tierId do provedor nos relays...');
      
      int successCount = 0;
      for (final relay in _relays) {
        try {
          final success = await _publishToRelay(relay, event);
          if (success) successCount++;
        } catch (e) {
          debugPrint('⚠️ Falha ao publicar tier em $relay: $e');
        }
      }

      debugPrint('✅ Tier publicado em $successCount/${_relays.length} relays');
      return successCount > 0;
    } catch (e) {
      debugPrint('❌ Erro ao publicar tier: $e');
      return false;
    }
  }

  /// Busca os dados do tier do provedor no Nostr
  Future<Map<String, dynamic>?> fetchProviderTier(String providerPubkey) async {
    debugPrint('🔍 Buscando tier do provedor $providerPubkey...');
    
    for (final relay in _relays) {
      try {
        final events = await _fetchFromRelay(
          relay,
          kinds: [kindBroProviderTier],
          tags: {'#d': ['tier_$providerPubkey']},
          limit: 1,
        );
        
        if (events.isNotEmpty) {
          final event = events.first;
          final content = event['parsedContent'] ?? jsonDecode(event['content']);
          
          debugPrint('✅ Tier encontrado: ${content['tierName']}');
          
          return {
            'tierId': content['tierId'],
            'tierName': content['tierName'],
            'depositedSats': content['depositedSats'],
            'maxOrderValue': content['maxOrderValue'],
            'activatedAt': content['activatedAt'],
            'updatedAt': content['updatedAt'],
          };
        }
      } catch (e) {
        debugPrint('⚠️ Falha ao buscar tier de $relay: $e');
      }
    }
    
    debugPrint('❌ Tier não encontrado no Nostr');
    return null;
  }

  // ============================================
  // MARKETPLACE - Ofertas NIP-15 like
  // ============================================
  
  static const int kindMarketplaceOffer = 30019; // NIP-15 Classifieds
  static const String marketplaceTag = 'bro-marketplace';

  /// Publica uma oferta no marketplace
  Future<String?> publishMarketplaceOffer({
    required String privateKey,
    required String title,
    required String description,
    required int priceSats,
    required String category,
    String? siteUrl,
  }) async {
    try {
      final keychain = Keychain(privateKey);
      final offerId = const Uuid().v4();
      
      final content = jsonEncode({
        'type': 'bro_marketplace_offer',
        'version': '1.0',
        'offerId': offerId,
        'title': title,
        'description': description,
        'priceSats': priceSats,
        'category': category,
        'siteUrl': siteUrl,
        'createdAt': DateTime.now().toIso8601String(),
      });

      final tags = [
        ['d', offerId],
        ['t', marketplaceTag],
        ['t', 'bro-app'],
        ['t', category],
        ['title', title],
        ['price', priceSats.toString(), 'sats'],
      ];
      
      // Adicionar tag de site se fornecido
      if (siteUrl != null && siteUrl.isNotEmpty) {
        tags.add(['r', siteUrl]); // NIP-12 reference tag
      }

      final event = Event.from(
        kind: kindMarketplaceOffer,
        tags: tags,
        content: content,
        privkey: keychain.private,
      );

      debugPrint('📤 Publicando oferta "$title" nos relays...');
      
      int successCount = 0;
      for (final relay in _relays.take(5)) {
        try {
          final success = await _publishToRelay(relay, event);
          if (success) {
            successCount++;
            debugPrint('✅ Publicado em $relay');
          }
        } catch (e) {
          debugPrint('⚠️ Falha em $relay: $e');
        }
      }

      debugPrint('✅ Oferta publicada em $successCount relays');
      return successCount > 0 ? offerId : null;
    } catch (e) {
      debugPrint('❌ Erro ao publicar oferta: $e');
      return null;
    }
  }

  /// Busca ofertas do marketplace
  Future<List<Map<String, dynamic>>> fetchMarketplaceOffers() async {
    final offers = <Map<String, dynamic>>[];
    final seenIds = <String>{};

    debugPrint('🔍 Buscando ofertas do marketplace...');

    for (final relay in _relays.take(5)) {
      try {
        final events = await _fetchFromRelay(
          relay,
          kinds: [kindMarketplaceOffer],
          tags: {'#t': [marketplaceTag]},
          limit: 50,
        );
        
        debugPrint('   $relay: ${events.length} ofertas');
        
        for (final event in events) {
          final id = event['id'];
          if (!seenIds.contains(id)) {
            seenIds.add(id);
            
            // Parse content
            try {
              final content = event['parsedContent'] ?? jsonDecode(event['content']);
              offers.add({
                'id': content['offerId'] ?? id,
                'title': content['title'] ?? '',
                'description': content['description'] ?? '',
                'priceSats': content['priceSats'] ?? 0,
                'category': content['category'] ?? 'outros',
                'sellerPubkey': event['pubkey'],
                'createdAt': DateTime.fromMillisecondsSinceEpoch(
                  (event['created_at'] as int) * 1000,
                ).toIso8601String(),
              });
            } catch (e) {
              debugPrint('⚠️ Erro ao parsear oferta: $e');
            }
          }
        }
      } catch (e) {
        debugPrint('⚠️ Falha ao buscar de $relay: $e');
      }
    }

    debugPrint('✅ Total: ${offers.length} ofertas do marketplace');
    return offers;
  }

  /// Busca ofertas de um usuário específico
  Future<List<Map<String, dynamic>>> fetchUserMarketplaceOffers(String pubkey) async {
    final offers = <Map<String, dynamic>>[];
    final seenIds = <String>{};

    debugPrint('🔍 Buscando ofertas do usuário ${pubkey.substring(0, 8)}...');

    for (final relay in _relays.take(3)) {
      try {
        final events = await _fetchFromRelay(
          relay,
          kinds: [kindMarketplaceOffer],
          authors: [pubkey],
          tags: {'#t': [marketplaceTag]},
          limit: 50,
        );
        
        for (final event in events) {
          final id = event['id'];
          if (!seenIds.contains(id)) {
            seenIds.add(id);
            
            try {
              final content = event['parsedContent'] ?? jsonDecode(event['content']);
              offers.add({
                'id': content['offerId'] ?? id,
                'title': content['title'] ?? '',
                'description': content['description'] ?? '',
                'priceSats': content['priceSats'] ?? 0,
                'category': content['category'] ?? 'outros',
                'sellerPubkey': event['pubkey'],
                'createdAt': DateTime.fromMillisecondsSinceEpoch(
                  (event['created_at'] as int) * 1000,
                ).toIso8601String(),
              });
            } catch (e) {
              debugPrint('⚠️ Erro ao parsear oferta: $e');
            }
          }
        }
      } catch (e) {
        debugPrint('⚠️ Falha ao buscar de $relay: $e');
      }
    }

    debugPrint('✅ ${offers.length} ofertas do usuário');
    return offers;
  }
}
