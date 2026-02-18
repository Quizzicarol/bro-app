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
  // NOTA: nostr.wine REMOVIDO - causa rate limit 429 constante e timeouts
  final List<String> _relays = [
    'wss://relay.damus.io',
    'wss://nos.lol',
    'wss://relay.primal.net',
    // 'wss://relay.nostr.band', // DESABILITADO: Retorna 0 eventos e causa timeouts
    // 'wss://nostr.wine', // DESABILITADO: Rate limit 429 constante
    // 'wss://relay.snort.social', // DESABILITADO: Causando timeouts frequentes
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
      // CRÍTICO: userPubkey DEVE estar no content para identificar o dono original da ordem!
      final content = jsonEncode({
        'type': 'bro_order',
        'version': '1.0',
        'orderId': orderId,
        'userPubkey': keychain.public, // CRÍTICO: Identifica o dono original da ordem
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

      
      // Publicar em todos os relays
      int successCount = 0;
      for (final relay in _relays) {
        try {
          final success = await _publishToRelay(relay, event);
          if (success) successCount++;
        } catch (e) {
        }
      }

      
      return successCount > 0 ? event.id : null;
    } catch (e) {
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
      // NOTA: Removida tag 'e' pois orderId é UUID, não event ID hex de 64 chars
      final tags = [
        ['d', '${orderId}_${userPubkey.substring(0, 8)}_update'], // Tag única por usuário
        ['t', broTag],
        ['t', 'bro-update'],
        ['t', 'status-$newStatus'], // Tag pesquisável por status
        ['orderId', orderId], // Tag customizada para busca
      ];
      
      // CRÍTICO: Sempre adicionar tag p do provedor para que ele receba
      if (providerId != null && providerId.isNotEmpty) {
        tags.add(['p', providerId]); // Tag do provedor - CRÍTICO para notificação
      } else {
      }

      // IMPORTANTE: Usa kindBroPaymentProof (30080) para não substituir o evento original!
      final event = Event.from(
        kind: kindBroPaymentProof,
        tags: tags,
        content: content,
        privkey: keychain.private,
      );


      // Publicar em PARALELO para ser mais rápido
      final results = await Future.wait(
        _relays.map((relay) async {
          try {
            // Tentar até 2 vezes
            for (int attempt = 1; attempt <= 2; attempt++) {
              final success = await _publishToRelay(relay, event);
              if (success) {
                return true;
              }
              if (attempt < 2) {
                await Future.delayed(const Duration(milliseconds: 500));
              }
            }
            return false;
          } catch (e) {
            return false;
          }
        }),
      );

      final successCount = results.where((r) => r).length;
      return successCount > 0;
    } catch (e) {
      return false;
    }
  }

  /// Busca ordens aceitas por um provedor (raw)
  /// Busca em múltiplas fontes:
  /// 1. Ordens (kindBroOrder) onde tag #p = provedor
  /// 2. Eventos de aceitação (kindBroAccept) publicados pelo provedor
  /// 3. Eventos de comprovante (kindBroComplete) publicados pelo provedor
  Future<List<Map<String, dynamic>>> _fetchProviderOrdersRaw(String providerPubkey) async {
    final orders = <Map<String, dynamic>>[];
    final seenIds = <String>{};
    final orderIdsFromAccepts = <String>{};


    for (final relay in _relays.take(3)) {
      try {
        // 1. Buscar ordens com tag #p do provedor
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
        
        // 2. Buscar eventos de aceitação E updates publicados por este provedor
        // CORREÇÃO: Adicionar kindBroPaymentProof (30080) que contém providerId nos updates
        final acceptEvents = await _fetchFromRelay(
          relay,
          kinds: [kindBroAccept, kindBroPaymentProof, kindBroComplete], // 30079, 30080 e 30081
          authors: [providerPubkey],
          limit: 200,
        );
        
        
        // Extrair orderIds dos eventos de aceitação/update
        for (final event in acceptEvents) {
          try {
            final content = event['parsedContent'] ?? jsonDecode(event['content']);
            final orderId = content['orderId'] as String?;
            if (orderId != null && !orderIdsFromAccepts.contains(orderId)) {
              orderIdsFromAccepts.add(orderId);
            }
          } catch (_) {}
        }
        
        // 3. Buscar eventos de UPDATE globais com providerId no conteúdo
        // OTIMIZAÇÃO: Usar mesmo relay, mas filtrar por providerId no content
        // Isso é mais lento mas necessário para histórico completo
        // REMOVIDO: Causava timeout. Vamos buscar apenas por author (provedor que publicou)
      } catch (e) {
      }
    }
    
    // 3. Buscar as ordens originais pelos IDs encontrados nos eventos de aceitação
    if (orderIdsFromAccepts.isNotEmpty) {
      
      // CORREÇÃO: Aumentado de 20 para 100 para preservar histórico completo do provedor
      for (final orderId in orderIdsFromAccepts.take(100)) {
        if (seenIds.contains(orderId)) {
          continue;
        }
        
        final orderData = await fetchOrderFromNostr(orderId);
        if (orderData != null) {
          seenIds.add(orderId);
          // Adicionar providerId ao orderData
          orderData['providerId'] = providerPubkey;
          orders.add(orderData);
        } else {
        }
      }
    } else {
    }

    return orders;
  }

  /// Busca ordens aceitas por um provedor e retorna como List<Order>
  /// CORREÇÃO: Agora também busca eventos de UPDATE para obter status correto
  Future<List<Order>> fetchProviderOrders(String providerPubkey) async {
    final rawOrders = await _fetchProviderOrdersRaw(providerPubkey);
    
    // CORREÇÃO CRÍTICA: Buscar eventos de UPDATE para obter status correto
    // Sem isso, ordens completed apareciam como "pending" ou "accepted"
    final statusUpdates = await _fetchAllOrderStatusUpdates();
    
    final orders = <Order>[];
    for (final raw in rawOrders) {
      final rawId = raw['id']?.toString() ?? '';
      
      // Verificar se já é um Map com campos diretos (vindo de fetchOrderFromNostr)
      // ou se é um evento Nostr que precisa ser parseado
      Order? order;
      if (raw['amount'] != null && raw['amount'] != 0) {
        // É um Map já processado de fetchOrderFromNostr
        try {
          order = Order(
            id: raw['id']?.toString() ?? '',
            eventId: raw['eventId']?.toString(),
            userPubkey: raw['userPubkey']?.toString() ?? '',
            billType: raw['billType']?.toString() ?? 'pix',
            billCode: raw['billCode']?.toString() ?? '',
            amount: (raw['amount'] as num?)?.toDouble() ?? 0,
            btcAmount: (raw['btcAmount'] as num?)?.toDouble() ?? 0,
            btcPrice: (raw['btcPrice'] as num?)?.toDouble() ?? 0,
            providerFee: (raw['providerFee'] as num?)?.toDouble() ?? 0,
            platformFee: (raw['platformFee'] as num?)?.toDouble() ?? 0,
            total: (raw['total'] as num?)?.toDouble() ?? 0,
            status: raw['status']?.toString() ?? 'pending',
            providerId: raw['providerId']?.toString() ?? providerPubkey,
            createdAt: DateTime.tryParse(raw['createdAt']?.toString() ?? '') ?? DateTime.now(),
          );
        } catch (e) {
        }
      } else {
        // É um evento Nostr, usar eventToOrder
        order = eventToOrder(raw);
        if (order != null) {
        } else {
        }
      }
      
      if (order != null) {
        // CORREÇÃO CRÍTICA: Garantir que providerId seja setado para ordens do provedor
        if (order.providerId == null || order.providerId!.isEmpty) {
          order = order.copyWith(providerId: providerPubkey);
        }
        
        // CORREÇÃO CRÍTICA: Aplicar status atualizado dos eventos de UPDATE
        // Isso garante que ordens completed/awaiting_confirmation apareçam com status correto
        order = _applyStatusUpdate(order, statusUpdates);
        
        orders.add(order);
      }
    }
    
    return orders;
  }

  /// Publica evento em um relay específico
  /// Tenta WebSocket primeiro, com timeout maior para iOS
  Future<bool> _publishToRelay(String relayUrl, Event event) async {
    final completer = Completer<bool>();
    WebSocketChannel? channel;
    Timer? timeout;

    try {
      
      // Criar conexão WebSocket
      final uri = Uri.parse(relayUrl);
      channel = WebSocketChannel.connect(uri);
      
      // Aguardar conexão estar pronta
      // NOTA: Em iOS, channel.ready pode não funcionar bem, então usamos try/catch
      try {
        await channel.ready.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            throw TimeoutException('Connection timeout');
          },
        );
      } catch (e) {
        // Se channel.ready falhar, dar um pequeno delay e tentar assim mesmo
        await Future.delayed(const Duration(milliseconds: 500));
      }
      
      
      // Timeout de 8 segundos para resposta
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
              final success = response[2] == true;
              if (!completer.isCompleted) {
                completer.complete(success);
              }
              if (!success) {
              }
            }
          } catch (e) {
          }
        },
        onError: (e) {
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
    } on TimeoutException catch (e) {
      return false;
    } catch (e) {
      return false;
    } finally {
      timeout?.cancel();
      try {
        await channel?.sink.close();
      } catch (_) {}
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
      // CRÍTICO: Envolver connect em try-catch para capturar erros 429/HTTP
      try {
        channel = WebSocketChannel.connect(Uri.parse(relayUrl));
      } catch (e) {
        return events; // Retorna lista vazia em vez de propagar exceção
      }
      
      // Timeout de 8 segundos
      timeout = Timer(const Duration(seconds: 5), () {
        if (!completer.isCompleted) {
          completer.complete(events);
          try { channel?.sink.close(); } catch (_) {}
        }
      });

      // Escutar eventos - envolver em try-catch para capturar erros de conexão
      try {
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
          onError: (e) {
            if (!completer.isCompleted) completer.complete(events);
          },
          onDone: () {
            if (!completer.isCompleted) completer.complete(events);
          },
        );
      } catch (e) {
        if (!completer.isCompleted) completer.complete(events);
        return events;
      }

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
      
      final content = event['parsedContent'] ?? jsonDecode(rawContent ?? '{}');
      
      // Verificar se é um evento de update (não tem dados completos)
      final eventType = content['type'] as String?;
      if (eventType == 'bro_order_update') {
        return null; // Updates são tratados separadamente
      }
      
      // Log para debug
      final amount = (content['amount'] as num?)?.toDouble() ?? 0;
      final orderId = content['orderId'] ?? event['id'];
      
      // Se amount é 0, tentar pegar das tags
      double finalAmount = amount;
      if (finalAmount == 0) {
        final tags = event['tags'] as List<dynamic>?;
        if (tags != null) {
          for (final tag in tags) {
            if (tag is List && tag.length >= 2 && tag[0] == 'amount') {
              finalAmount = double.tryParse(tag[1].toString()) ?? 0;
              break;
            }
          }
        }
      }
      
      // VALIDAÇÃO CRÍTICA: Não aceitar ordens com amount=0
      if (finalAmount == 0) {
        return null;
      }
      
      // CRÍTICO: Determinar o userPubkey correto - APENAS do CONTENT!
      // SEGURANÇA: Não usar event.pubkey como fallback pois pode ser de quem republicou!
      final contentUserPubkey = content['userPubkey'] as String?;
      
      String? originalUserPubkey;
      if (contentUserPubkey != null && contentUserPubkey.isNotEmpty) {
        // Ordem nova com userPubkey no content - CONFIÁVEL
        originalUserPubkey = contentUserPubkey;
      } else {
        // SEGURANÇA CRÍTICA: Ordem legada sem userPubkey no content
        // NÃO usar event.pubkey como fallback - pode ser de quem republicou!
        // Isso pode ter causado ordens aparecerem no dispositivo errado
        return null; // REJEITAR - não temos como saber quem é o dono real
      }
      
      return Order(
        id: orderId,
        eventId: event['id'],
        userPubkey: originalUserPubkey,
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
    
    Map<String, dynamic>? orderData;
    
    for (final relay in _relays.take(3)) {
      try {
        // Estratégia 1: Buscar pelo d-tag (orderId)
        var events = await _fetchFromRelay(
          relay,
          kinds: [kindBroOrder],
          tags: {'#d': [orderId]},
          limit: 5,
        );
        
        // Estratégia 2: Se não encontrou, buscar pelo #t tag com orderId
        if (events.isEmpty) {
          events = await _fetchFromRelay(
            relay,
            kinds: [kindBroOrder],
            tags: {'#t': [orderId]},
            limit: 5,
          );
        }
        
        // Verificar se algum evento tem o orderId no content
        for (final event in events) {
          try {
            final content = event['parsedContent'] ?? jsonDecode(event['content']);
            final eventOrderId = content['orderId'] as String?;
            
            if (eventOrderId == orderId) {
              
              orderData = {
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
                'providerId': content['providerId'],
                'createdAt': content['createdAt'],
              };
              break;
            }
          } catch (_) {}
        }
        
        if (orderData != null) break;
        
        // Se encontrou eventos mas nenhum com orderId match, usar o primeiro
        if (events.isNotEmpty) {
          final event = events.first;
          final content = event['parsedContent'] ?? jsonDecode(event['content']);
          
          
          orderData = {
            'id': content['orderId'] ?? orderId,
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
            'providerId': content['providerId'],
            'createdAt': content['createdAt'],
          };
          break;
        }
      } catch (e) {
      }
    }
    
    if (orderData == null) {
      return null;
    }
    
    // NOTA: O status local é gerenciado pelo order_provider.dart
    // Não fazer busca extra aqui para evitar timeout
    
    return orderData;
  }
  
  /// Busca o status mais recente de uma ordem dos eventos de UPDATE (kind 30080) e COMPLETE (kind 30081)
  /// NOTA: Esta função é lenta e deve ser usada apenas quando necessário, não em batch
  Future<String?> _fetchLatestOrderStatus(String orderId) async {
    String? latestStatus;
    int latestTimestamp = 0;
    
    for (final relay in _relays.take(3)) {
      try {
        // Buscar eventos de PaymentProof e Complete para esta ordem
        final updateEvents = await _fetchFromRelay(
          relay,
          kinds: [kindBroPaymentProof, kindBroComplete],
          tags: {'#orderId': [orderId]},
          limit: 20,
        );
        
        // Também tentar buscar por #t tag
        final updateEventsT = await _fetchFromRelay(
          relay,
          kinds: [kindBroPaymentProof, kindBroComplete],
          tags: {'#t': [orderId]},
          limit: 20,
        );
        
        final allEvents = [...updateEvents, ...updateEventsT];
        
        for (final event in allEvents) {
          try {
            final content = event['parsedContent'] ?? jsonDecode(event['content']);
            final eventOrderId = content['orderId'] as String?;
            
            if (eventOrderId == orderId) {
              final eventTimestamp = event['created_at'] as int? ?? 0;
              final eventStatus = content['status'] as String?;
              
              if (eventStatus != null && eventTimestamp > latestTimestamp) {
                latestTimestamp = eventTimestamp;
                latestStatus = eventStatus;
              }
            }
          } catch (_) {}
        }
      } catch (e) {
      }
    }
    
    return latestStatus;
  }

  /// Busca o evento COMPLETE de uma ordem para obter o providerInvoice
  /// Retorna um Map com os dados do evento COMPLETE incluindo providerInvoice
  Future<Map<String, dynamic>?> fetchOrderCompleteEvent(String orderId) async {
    
    for (final relay in _relays.take(3)) {
      try {
        // Buscar eventos de Complete para esta ordem por orderId tag
        var completeEvents = await _fetchFromRelay(
          relay,
          kinds: [kindBroComplete],
          tags: {'#orderId': [orderId]},
          limit: 5,
        );
        
        // Também tentar por #d tag (pattern: orderId_complete)
        if (completeEvents.isEmpty) {
          completeEvents = await _fetchFromRelay(
            relay,
            kinds: [kindBroComplete],
            tags: {'#d': ['${orderId}_complete']},
            limit: 5,
          );
        }
        
        for (final event in completeEvents) {
          try {
            final content = event['parsedContent'] ?? jsonDecode(event['content']);
            final eventOrderId = content['orderId'] as String?;
            
            if (eventOrderId == orderId) {
              final providerInvoice = content['providerInvoice'] as String?;
              final providerId = content['providerId'] as String?;
              
              if (providerInvoice != null) {
              }
              
              return {
                'orderId': orderId,
                'providerId': providerId,
                'providerInvoice': providerInvoice,
                'completedAt': content['completedAt'],
              };
            }
          } catch (_) {}
        }
      } catch (e) {
      }
    }
    
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

      // Construir tags - só incluir 'e' se tivermos eventId válido (64 chars hex)
      final tags = [
        ['d', '${order.id}_accept'],
        ['p', order.userPubkey ?? ''], // Tag do usuário que criou a ordem
        ['t', broTag],
        ['t', 'bro-accept'],
        ['orderId', order.id],
      ];
      // Só adicionar tag 'e' se eventId for válido (64 chars hex)
      if (order.eventId != null && order.eventId!.length == 64) {
        tags.insert(1, ['e', order.eventId!]);
      }
      

      final event = Event.from(
        kind: kindBroAccept,
        tags: tags,
        content: content,
        privkey: keychain.private,
      );

      
      int successCount = 0;
      // Publicar em paralelo para maior velocidade
      final results = await Future.wait(
        _relays.map((relay) => _publishToRelay(relay, event).catchError((_) => false)),
      );
      successCount = results.where((s) => s).length;

      return successCount > 0;
    } catch (e, stack) {
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
    String? providerInvoice, // Invoice Lightning para o provedor receber pagamento
  }) async {
    try {
      final keychain = Keychain(providerPrivateKey);
      
      // NOTA: O comprovante é enviado em texto claro por enquanto
      // Para privacidade total, implementar NIP-17 ou enviar via canal separado
      // O evento é tagged com a pubkey do usuário para que ele possa encontrar
      final contentMap = {
        'type': 'bro_complete',
        'orderId': order.id,
        'orderEventId': order.eventId,
        'providerId': keychain.public,
        'proofImage': proofImageBase64, // Base64 do comprovante
        'recipientPubkey': order.userPubkey, // Para quem é destinado
        'completedAt': DateTime.now().toIso8601String(),
      };
      
      // Incluir invoice do provedor se fornecido
      if (providerInvoice != null && providerInvoice.isNotEmpty) {
        contentMap['providerInvoice'] = providerInvoice;
      }
      
      final content = jsonEncode(contentMap);

      // Construir tags - só incluir 'e' se tivermos eventId válido (64 chars hex)
      final tags = [
        ['d', '${order.id}_complete'],
        ['p', order.userPubkey ?? ''], // Tag do usuário que criou a ordem
        ['t', broTag],
        ['t', 'bro-complete'],
        ['orderId', order.id],
      ];
      // Só adicionar tag 'e' se eventId for válido (64 chars hex)
      if (order.eventId != null && order.eventId!.length == 64) {
        tags.insert(1, ['e', order.eventId!]);
      }

      final event = Event.from(
        kind: kindBroComplete,
        tags: tags,
        content: content,
        privkey: keychain.private,
      );

      
      int successCount = 0;
      // Publicar em paralelo para maior velocidade
      final results = await Future.wait(
        _relays.map((relay) => _publishToRelay(relay, event).catchError((_) => false)),
      );
      successCount = results.where((s) => s).length;

      return successCount > 0;
    } catch (e) {
      return false;
    }
  }

  /// Busca ordens pendentes e retorna como List<Order>
  /// Para modo Bro: retorna APENAS ordens que ainda não foram aceitas por nenhum Bro
  Future<List<Order>> fetchPendingOrders() async {
    
    final rawOrders = await _fetchPendingOrdersRaw();
    
    // Buscar eventos de UPDATE para saber quais ordens já foram aceitas
    final statusUpdates = await _fetchAllOrderStatusUpdates();
    
    // Converter para Orders COM DEDUPLICAÇÃO por orderId
    final seenOrderIds = <String>{};
    final allOrders = <Order>[];
    for (final e in rawOrders) {
      final order = eventToOrder(e);
      if (order == null) continue;
      
      // DEDUPLICAÇÃO: Só adicionar se ainda não vimos este orderId
      if (seenOrderIds.contains(order.id)) {
        continue;
      }
      seenOrderIds.add(order.id);
      allOrders.add(order);
    }
    
    
    // LOG DETALHADO de cada ordem
    for (var order in allOrders) {
      final hasUpdate = statusUpdates.containsKey(order.id);
      final update = statusUpdates[order.id];
    }
    
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
        availableOrders.add(order);
      } else {
        // Ordem já foi aceita por alguém
      }
    }
    
    
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
    // IMPORTANTE: Passar pubkey para bloquear status "completed" vindo do Nostr
    final orders = rawOrders
        .map((e) => eventToOrder(e))
        .whereType<Order>()
        .where((order) {
          // Verificar se a ordem realmente pertence ao usuário
          if (order.userPubkey != pubkey) {
            return false;
          }
          return true;
        })
        .map((order) => _applyStatusUpdate(order, statusUpdates))
        .toList();
    
    return orders;
  }
  
  /// Busca TODOS os eventos de UPDATE de status (kind 30080, 30081)
  /// Inclui: updates de status, conclusões de ordem
  /// CRÍTICO: Busca de TODOS os relays para garantir sincronização
  Future<Map<String, Map<String, dynamic>>> _fetchAllOrderStatusUpdates() async {
    final updates = <String, Map<String, dynamic>>{}; // orderId -> latest update
    
    
    // Buscar de TODOS os relays (sequencialmente para evitar sobrecarga)
    for (final relay in _relays) {
      try {
        // ESTRATÉGIA: Buscar com tag bro-order primeiro (mais preciso)
        // Se falhar ou retornar poucos resultados, fallback para busca por kind
        var events = await _fetchFromRelay(
          relay,
          kinds: [kindBroAccept, kindBroPaymentProof, kindBroComplete], // 30079, 30080 e 30081
          tags: {'#t': [broTag]}, // Filtra apenas eventos do app BRO
          limit: 300,
        ).timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            return <Map<String, dynamic>>[];
          },
        );
        
        
        // Fallback: se retornou poucos eventos, tentar sem tag
        // (para compatibilidade com eventos antigos publicados sem tag)
        if (events.length < 10) {
          final fallbackEvents = await _fetchFromRelay(
            relay,
            kinds: [kindBroAccept, kindBroPaymentProof, kindBroComplete],
            limit: 300,
          ).timeout(
            const Duration(seconds: 5),
            onTimeout: () => <Map<String, dynamic>>[],
          );
          
          // Mesclar eventos únicos do fallback
          final seenIds = events.map((e) => e['id']).toSet();
          for (final e in fallbackEvents) {
            if (!seenIds.contains(e['id'])) {
              events.add(e);
            }
          }
        }
        
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
              
              // PROTEÇÃO: Não regredir status mais avançado
              // Ordem de progressão: pending -> accepted -> awaiting_confirmation -> completed
              final existingStatus = existingUpdate?['status'] as String?;
              if (existingStatus != null) {
                const statusOrder = ['pending', 'accepted', 'awaiting_confirmation', 'completed', 'liquidated'];
                final existingIdx = statusOrder.indexOf(existingStatus);
                final newIdx = statusOrder.indexOf(status ?? 'pending');
                if (existingIdx >= 0 && newIdx >= 0 && newIdx < existingIdx) {
                  continue;
                }
              }
              
              // IMPORTANTE: Incluir proofImage do comprovante para o usuário ver
              final proofImage = content['proofImage'] as String?;
              
              // NOVO: Incluir providerInvoice para pagamento automático
              final providerInvoice = content['providerInvoice'] as String?;
              
              // providerId pode vir do content ou do pubkey do evento (para accepts)
              final providerId = content['providerId'] as String? ?? event['pubkey'] as String?;
              
              // IMPORTANTE: Guardar quem publicou o evento para verificar se foi o próprio usuário
              final eventAuthorPubkey = event['pubkey'] as String?;
              
              updates[orderId] = {
                'orderId': orderId,
                'status': status,
                'providerId': providerId,
                'eventAuthorPubkey': eventAuthorPubkey, // Quem publicou este update
                'proofImage': proofImage, // Comprovante enviado pelo Bro
                'providerInvoice': providerInvoice, // Invoice para pagar o Bro
                'completedAt': content['completedAt'],
                'created_at': createdAt,
              };
            }
          } catch (e) {
            // Ignorar eventos mal formatados
          }
        }
      } catch (e) {
      }
    }
    
    return updates;
  }
  
  /// Aplica o status mais recente de um update a uma ordem
  /// Aplica updates de status do Nostr a uma ordem
  Order _applyStatusUpdate(Order order, Map<String, Map<String, dynamic>> statusUpdates) {
    final update = statusUpdates[order.id];
    if (update == null) return order;
    
    final newStatus = update['status'] as String?;
    final providerId = update['providerId'] as String?;
    final proofImage = update['proofImage'] as String?;
    final completedAt = update['completedAt'] as String?;
    final providerInvoice = update['providerInvoice'] as String?; // CRÍTICO: Invoice do provedor
    
    // NOTA: Não bloqueamos mais "completed" do provedor porque:
    // 1. O pagamento ao provedor só acontece via invoice Lightning que ele gera
    // 2. O pagamento da taxa só acontece quando o USUÁRIO confirma localmente
    // 3. O provedor marcar "completed" não causa dano financeiro
    // 4. Bloquear causa problemas de sincronização entre dispositivos
    
    if (newStatus != null && newStatus != order.status) {
      
      // Mesclar metadata existente com novos dados do comprovante
      final updatedMetadata = Map<String, dynamic>.from(order.metadata ?? {});
      if (proofImage != null && proofImage.isNotEmpty) {
        updatedMetadata['proofImage'] = proofImage;
        updatedMetadata['paymentProof'] = proofImage; // Compatibilidade
      }
      if (completedAt != null) {
        updatedMetadata['proofReceivedAt'] = completedAt;
        updatedMetadata['receipt_submitted_at'] = completedAt; // Compatibilidade com auto-liquidação
      }
      // CRÍTICO: Incluir providerInvoice para pagamento automático
      if (providerInvoice != null && providerInvoice.isNotEmpty) {
        updatedMetadata['providerInvoice'] = providerInvoice;
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
  /// CRÍTICO: Busca em TODOS os relays para garantir sincronização entre dispositivos
  Future<List<Map<String, dynamic>>> _fetchPendingOrdersRaw() async {
    final orders = <Map<String, dynamic>>[];
    final seenIds = <String>{};

    for (final r in _relays) {
    }
    
    // IMPORTANTE: Buscar ordens dos últimos 45 dias (aumentado de 14)
    // Isso garante que ordens mais antigas ainda disponíveis sejam encontradas
    // Ordens de PIX/Boleto podem demorar para serem aceitas em períodos de baixa atividade
    final fourteenDaysAgo = DateTime.now().subtract(const Duration(days: 14));
    final sinceTimestamp = (fourteenDaysAgo.millisecondsSinceEpoch / 1000).floor();

    // ESTRATÉGIA: Buscar por KIND diretamente (mais confiável que tags)
    // Buscar de TODOS os relays em paralelo para maior velocidade
    final futures = <Future<List<Map<String, dynamic>>>>[];
    
    for (final relay in _relays) {
      futures.add(_fetchPendingFromRelay(relay, sinceTimestamp));
    }
    
    // Aguardar todas as buscas em paralelo
    final results = await Future.wait(futures, eagerError: false);
    
    // Processar resultados
    for (int i = 0; i < results.length; i++) {
      final relayOrders = results[i];
      final relay = _relays[i];
      
      for (final order in relayOrders) {
        final id = order['id'];
        if (!seenIds.contains(id)) {
          seenIds.add(id);
          orders.add(order);
        }
      }
    }
    return orders;
  }
  
  /// Helper: Busca ordens pendentes de um relay específico
  /// ROBUSTO: Retorna lista vazia em caso de QUALQUER erro (timeout, conexão, etc)
  /// CRÍTICO: Usa tag #t: ['bro-order'] para filtrar apenas eventos do app BRO
  /// (kind 30078 é usado por muitos apps, sem a tag retorna eventos irrelevantes)
  Future<List<Map<String, dynamic>>> _fetchPendingFromRelay(String relay, int sinceTimestamp) async {
    final orders = <Map<String, dynamic>>[];
    
    try {
      // CRÍTICO: Buscar por KIND 30078 COM tag 'bro-order' para filtrar apenas ordens BRO
      // Sem esta tag, o relay retorna eventos de outros apps (double-ratchet, drss, etc)
      // e as ordens BRO ficam "enterradas" no limit de 200
      final relayOrders = await _fetchFromRelayWithSince(
        relay,
        kinds: [kindBroOrder],
        tags: {'#t': [broTag]}, // CRÍTICO: Filtra apenas ordens do app BRO
        since: sinceTimestamp,
        limit: 200, // Aumentado para pegar mais ordens
      ).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          return <Map<String, dynamic>>[];
        },
      );
      
      
      for (final order in relayOrders) {
        // Verificar se é ordem do Bro app (verificando content)
        try {
          final content = order['parsedContent'] ?? jsonDecode(order['content'] ?? '{}');
          if (content['type'] == 'bro_order') {
            orders.add(order);
          }
        } catch (_) {}
      }
    } catch (e) {
    }
    
    return orders;
  }

  /// Busca ordens de um usuário (raw)
  Future<List<Map<String, dynamic>>> _fetchUserOrdersRaw(String pubkey) async {
    final orders = <Map<String, dynamic>>[];
    final seenIds = <String>{};


    // Buscar de TODOS os relays em paralelo
    final futures = <Future<List<Map<String, dynamic>>>>[];
    
    for (final relay in _relays) {
      futures.add(_fetchUserOrdersFromRelay(relay, pubkey));
    }
    
    // Aguardar todas as buscas em paralelo
    final results = await Future.wait(futures, eagerError: false);
    
    // Processar resultados
    for (int i = 0; i < results.length; i++) {
      final relayOrders = results[i];
      final relay = _relays[i];
      
      for (final order in relayOrders) {
        final id = order['id'];
        if (!seenIds.contains(id)) {
          seenIds.add(id);
          orders.add(order);
        }
      }
    }

    return orders;
  }
  
  /// Helper: Busca ordens de um usuário de um relay específico
  /// ROBUSTO: Retorna lista vazia em caso de QUALQUER erro
  Future<List<Map<String, dynamic>>> _fetchUserOrdersFromRelay(String relay, String pubkey) async {
    final orders = <Map<String, dynamic>>[];
    
    try {
      // ESTRATÉGIA 1: Buscar por author (com timeout)
      final relayOrders = await _fetchFromRelay(
        relay,
        kinds: [kindBroOrder],
        authors: [pubkey],
        limit: 100,
      ).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          return <Map<String, dynamic>>[];
        },
      );
      
      for (final order in relayOrders) {
        // Verificar se é ordem do Bro app
        try {
          final content = order['parsedContent'] ?? jsonDecode(order['content'] ?? '{}');
          if (content['type'] == 'bro_order') {
            orders.add(order);
          }
        } catch (_) {}
      }
    } catch (e) {
    }
    
    return orders;
  }

  /// Busca eventos de aceitação e comprovante direcionados a um usuário
  /// Isso permite que o usuário veja quando um Bro aceitou sua ordem ou enviou comprovante
  Future<Map<String, Map<String, dynamic>>> fetchOrderUpdatesForUser(String userPubkey, {List<String>? orderIds}) async {
    final updates = <String, Map<String, dynamic>>{}; // orderId -> latest update
    
    if (orderIds != null && orderIds.isNotEmpty) {
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
        
        
        // Se não encontrou eventos e temos IDs de ordens, buscar por tag #t (bro-accept, bro-complete)
        if (events.isEmpty) {
          final altEvents = await _fetchFromRelay(
            relay,
            kinds: [kindBroAccept, kindBroComplete],
            tags: {'#t': [broTag]}, // Todos os eventos bro
            limit: 100,
          );
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
              
            }
          } catch (e) {
          }
        }
      } catch (e) {
      }
    }

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
      return updates;
    }
    

    // Converter orderIds para Set para busca O(1)
    final orderIdSet = orderIds.toSet();

    for (final relay in _relays.take(3)) {
      try {
        
        // ESTRATÉGIA 1: Buscar por tag #p (eventos direcionados ao provedor)
        // Esta é a forma mais segura - só retorna eventos onde o provedor foi tagueado
        final pTagEvents = await _fetchFromRelay(
          relay,
          kinds: [kindBroPaymentProof], // 30080
          tags: {'#p': [providerPubkey]},
          limit: 100,
        );
        
        
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
            }
          } catch (_) {}
        }
        
        // ESTRATÉGIA 2: Buscar diretamente por cada orderId específico
        // Fallback para quando a tag #p não foi indexada
        // CORREÇÃO: Aumentado de 20 para 100 para preservar histórico completo
        for (final orderId in orderIds.take(100)) {
          try {
            // Buscar por tag #e (referência ao orderId)
            final eTagEvents = await _fetchFromRelay(
              relay,
              kinds: [kindBroPaymentProof],
              tags: {'#e': [orderId]},
              limit: 10,
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
                }
              } catch (_) {}
            }
          } catch (_) {}
        }
        
        // ESTRATÉGIA 3: Buscar todos os eventos bro-update e filtrar
        // CORREÇÃO: Rodar SEMPRE que houver ordens sem updates encontrados
        // (antes só rodava quando updates estava totalmente vazio)
        final missingOrderIds = orderIds.where((id) => !updates.containsKey(id)).toList();
        if (missingOrderIds.isNotEmpty) {
          try {
            final updateEvents = await _fetchFromRelay(
              relay,
              kinds: [kindBroPaymentProof],
              tags: {'#t': ['bro-update']},
              limit: 100,
            );
            
            
            for (final event in updateEvents) {
              try {
                final content = event['parsedContent'] ?? jsonDecode(event['content']);
                final eventOrderId = content['orderId'] as String?;
                final status = content['status'] as String?;
                final createdAt = event['created_at'] as int? ?? 0;
                
                if (eventOrderId == null || status == null) continue;
                
                // Verificar se esta ordem está na lista que buscamos
                if (!orderIdSet.contains(eventOrderId)) continue;
                
                final existingUpdate = updates[eventOrderId];
                final existingCreatedAt = existingUpdate?['created_at'] as int? ?? 0;
                
                if (existingUpdate == null || createdAt > existingCreatedAt) {
                  updates[eventOrderId] = {
                    'orderId': eventOrderId,
                    'status': status,
                    'created_at': createdAt,
                  };
                }
              } catch (_) {}
            }
          } catch (_) {}
        }
        
      } catch (e) {
      }
    }

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

      
      int successCount = 0;
      for (final relay in _relays) {
        try {
          final success = await _publishToRelay(relay, event);
          if (success) successCount++;
        } catch (e) {
        }
      }

      return successCount > 0;
    } catch (e) {
      return false;
    }
  }

  /// Busca os dados do tier do provedor no Nostr
  Future<Map<String, dynamic>?> fetchProviderTier(String providerPubkey) async {
    
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
      }
    }
    
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

      
      int successCount = 0;
      for (final relay in _relays.take(5)) {
        try {
          final success = await _publishToRelay(relay, event);
          if (success) {
            successCount++;
          }
        } catch (e) {
        }
      }

      return successCount > 0 ? offerId : null;
    } catch (e) {
      return null;
    }
  }

  /// Busca ofertas do marketplace
  Future<List<Map<String, dynamic>>> fetchMarketplaceOffers() async {
    final offers = <Map<String, dynamic>>[];
    final seenIds = <String>{};


    for (final relay in _relays.take(5)) {
      try {
        final events = await _fetchFromRelay(
          relay,
          kinds: [kindMarketplaceOffer],
          tags: {'#t': [marketplaceTag]},
          limit: 50,
        );
        
        
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
            }
          }
        }
      } catch (e) {
      }
    }

    return offers;
  }

  /// Busca ofertas de um usuário específico
  Future<List<Map<String, dynamic>>> fetchUserMarketplaceOffers(String pubkey) async {
    final offers = <Map<String, dynamic>>[];
    final seenIds = <String>{};


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
            }
          }
        }
      } catch (e) {
      }
    }

    return offers;
  }
}
