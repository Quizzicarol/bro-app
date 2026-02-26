import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:nostr/nostr.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../config.dart';
import '../models/order.dart';
import 'nip44_service.dart';

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

  // Serviço de criptografia NIP-44
  final _nip44 = Nip44Service();

  // Chave privada para descriptografia (configurada pelo order_provider)
  String? _decryptionKey;
  
  // PERFORMANCE: Cache de _fetchAllOrderStatusUpdates com TTL de 15s
  // O Completer lock já previne chamadas paralelas, então TTL curto é seguro
  // e garante dados mais frescos entre polls (45s)
  Map<String, Map<String, dynamic>>? _statusUpdatesCache;
  DateTime? _statusUpdatesCacheTime;
  // PERFORMANCE v226: TTL aumentado de 15s para 40s
  // O timer de provider é 45s, então cache sobrevive entre ciclos
  // Cache é invalidado em escritas (_statusUpdatesCache = null), então dados mutados são sempre frescos
  static const _statusUpdatesCacheTtlSeconds = 40;
  // CORREÇÃO v1.0.129: Lock para evitar chamadas simultâneas de _fetchAllOrderStatusUpdates
  // Quando 3 funções chamam em paralelo, a primeira faz o fetch real,
  // as outras esperam pelo mesmo resultado sem criar novas conexões
  Completer<Map<String, Map<String, dynamic>>>? _statusUpdatesFetching;

  // BLOCKLIST LOCAL: IDs de ordens em estado terminal (completed, cancelled, etc)
  // Persistida em SharedPreferences para sobreviver a reinicializações
  // Resolve: relay não retorna evento de status → ordem aparece como disponível
  static const String _blockedOrdersKey = 'blocked_order_ids';
  Set<String> _blockedOrderIds = {};
  bool _blockedOrdersLoaded = false;

  /// Carrega blocklist do SharedPreferences (chamado 1x na inicialização)
  Future<void> _loadBlockedOrders() async {
    if (_blockedOrdersLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_blockedOrdersKey) ?? [];
      _blockedOrderIds = list.toSet();
      _blockedOrdersLoaded = true;
      debugPrint('🚫 Blocklist carregada: ${_blockedOrderIds.length} ordens bloqueadas');
    } catch (e) {
      debugPrint('⚠️ Erro ao carregar blocklist: $e');
      _blockedOrdersLoaded = true;
    }
  }

  /// Adiciona IDs à blocklist e persiste
  Future<void> _addToBlocklist(Set<String> orderIds) async {
    if (orderIds.isEmpty) return;
    final newIds = orderIds.difference(_blockedOrderIds);
    if (newIds.isEmpty) return;
    _blockedOrderIds.addAll(newIds);
    debugPrint('🚫 Blocklist: +${newIds.length} ordens (total: ${_blockedOrderIds.length})');
    try {
      final prefs = await SharedPreferences.getInstance();
      // Manter apenas últimas 2000 entradas para não crescer infinitamente
      if (_blockedOrderIds.length > 2000) {
        _blockedOrderIds = _blockedOrderIds.toList().sublist(_blockedOrderIds.length - 2000).toSet();
      }
      await prefs.setStringList(_blockedOrdersKey, _blockedOrderIds.toList());
    } catch (e) {
      debugPrint('⚠️ Erro ao salvar blocklist: $e');
    }
  }

  /// Helper: Verifica se newStatus é progressão válida em relação a currentStatus
  /// Mesma lógica de _isStatusMoreRecent do OrderProvider, mas local
  /// REGRA DE OURO: Status NUNCA regride. cancelled/completed/liquidated/disputed são terminais.
  static bool _isStatusProgression(String newStatus, String currentStatus) {
    if (newStatus == currentStatus) return false;
    // cancelled é TERMINAL ABSOLUTO - só disputed pode sobrescrever
    if (currentStatus == 'cancelled') return newStatus == 'disputed';
    // cancelled SEMPRE vence (ação explícita do usuário)
    if (newStatus == 'cancelled') return true;
    // disputed SEMPRE vence sobre qualquer status não-terminal
    // CORREÇÃO: 'disputed' não estava no statusOrder linear, causando rejeição
    // quando processado depois de 'awaiting_confirmation' em fetchOrderUpdatesForUser
    if (newStatus == 'disputed') return true;
    // CORREÇÃO v233: disputed pode transicionar para completed/cancelled (resolução de disputa)
    if (currentStatus == 'disputed') {
      return newStatus == 'completed' || newStatus == 'cancelled';
    }
    // Status finais - só disputed pode seguir
    const finalStatuses = ['completed', 'liquidated'];
    if (finalStatuses.contains(currentStatus)) {
      return newStatus == 'disputed';
    }
    // Progressão linear
    const statusOrder = [
      'draft', 'pending', 'payment_received', 'accepted', 'processing',
      'awaiting_confirmation', 'completed', 'liquidated',
    ];
    final newIdx = statusOrder.indexOf(newStatus);
    final currentIdx = statusOrder.indexOf(currentStatus);
    if (newIdx == -1 || currentIdx == -1) return false;
    return newIdx > currentIdx;
  }
  
  /// Configura a chave privada para descriptografia de campos NIP-44
  /// Chamado pelo OrderProvider quando as chaves estão disponíveis
  void setDecryptionKey(String? privateKey) {
    _decryptionKey = privateKey;
  }

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
      
      // Conteúdo da ordem — inclui billCode para que o provedor possa pagar
      // NOTA: billCode (chave PIX) é necessário em plaintext para que provedores
      // possam avaliar e aceitar a ordem. A proteção de PII do PIX será feita
      // via NIP-17 Gift Wraps em versão futura (requer redesign do fluxo).
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

      
      // Publicar em todos os relays EM PARALELO
      final results = await Future.wait(
        _relays.map((relay) => _publishToRelay(relay, event).catchError((_) => false)),
      );
      final successCount = results.where((r) => r).length;

      
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
      // LOG v1.0.129+232: Alertar quando completed é publicado sem providerId
      // A proteção principal está no OrderProvider.updateOrderStatus()
      if (newStatus == 'completed' && (providerId == null || providerId.isEmpty)) {
        debugPrint('⚠️ [NostrOrderService] completed sem providerId para ${orderId.substring(0, 8)} - verificar fluxo');
      }
      
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
        ['r', orderId], // CRÍTICO: Tag 'r' (reference) para busca por orderId nos relays
        ['orderId', orderId], // Tag customizada (não filtrável por relays, só para leitura)
      ];
      
      // CRÍTICO: Sempre adicionar tag p do provedor para que ele receba
      if (providerId != null && providerId.isNotEmpty) {
        tags.add(['p', providerId]); // Tag do provedor - CRÍTICO para notificação
        debugPrint('📤 updateOrderStatus: orderId=${orderId.substring(0, 8)} status=$newStatus providerId=${providerId.substring(0, 16)}');
      } else {
        debugPrint('⚠️ updateOrderStatus: orderId=${orderId.substring(0, 8)} status=$newStatus SEM providerId!');
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
            final success = await _publishToRelay(relay, event);
            if (success) return true;
            // Uma única tentativa de retry após delay curto
            await Future.delayed(const Duration(milliseconds: 300));
            return await _publishToRelay(relay, event);
          } catch (e) {
            return false;
          }
        }),
      );

      final successCount = results.where((r) => r).length;
      debugPrint('📤 updateOrderStatus: publicado em $successCount/${_relays.length} relays (orderId=${orderId.substring(0, 8)}, status=$newStatus)');
      
      // Adicionar à blocklist se status é terminal
      if (successCount > 0) {
        const terminalStatuses = ['accepted', 'awaiting_confirmation', 'completed', 'cancelled', 'liquidated', 'disputed'];
        if (terminalStatuses.contains(newStatus)) {
          _addToBlocklist({orderId});
          _statusUpdatesCache = null;
          _statusUpdatesCacheTime = null;
        }
      }
      
      return successCount > 0;
    } catch (e) {
      debugPrint('❌ updateOrderStatus EXCEPTION: $e');
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

    // PERFORMANCE: Buscar de todos os relays EM PARALELO
    // CORREÇÃO v1.0.128: Adicionada estratégia 3 com tag #t para maior cobertura
    final relayResults = await Future.wait(
      _relays.take(3).map((relay) async {
        final relayOrders = <Map<String, dynamic>>[];
        final relayAcceptIds = <String>{};
        try {
          // PARALELO: 3 estratégias simultâneas por relay
          final results = await Future.wait([
            // 1. Ordens com tag #p do provedor
            _fetchFromRelay(relay, kinds: [kindBroOrder], tags: {'#p': [providerPubkey]}, limit: 100)
              .catchError((_) => <Map<String, dynamic>>[]),
            // 2. Eventos de aceitação/update/complete publicados por este provedor
            _fetchFromRelay(relay, kinds: [kindBroAccept, kindBroPaymentProof, kindBroComplete], authors: [providerPubkey], limit: 200)
              .catchError((_) => <Map<String, dynamic>>[]),
            // 3. NOVO: Buscar eventos bro-accept com tag #t (fallback se #p falhar)
            _fetchFromRelay(relay, kinds: [kindBroAccept, kindBroComplete], tags: {'#t': ['bro-accept']}, limit: 100)
              .catchError((_) => <Map<String, dynamic>>[]),
          ]);
          
          relayOrders.addAll(results[0]);
          
          // Extrair orderIds dos eventos de aceitação/update (estratégia 2 + 3)
          for (final eventList in [results[1], results[2]]) {
            for (final event in eventList) {
              try {
                // Filtrar eventos da estratégia 3 para apenas os do provedor
                final eventPubkey = event['pubkey'] as String?;
                if (eventPubkey != providerPubkey && !results[1].contains(event)) continue;
                
                final content = event['parsedContent'] ?? jsonDecode(event['content']);
                
                // CORREÇÃO v1.0.129: Ignorar eventos de resolução de disputa
                // Mediador publica kind 30080 com type=bro_dispute_resolution
                // que NÃO deve ser tratado como atividade de provedor
                final eventType = content['type'] as String?;
                if (eventType == 'bro_dispute_resolution') continue;
                
                final orderId = content['orderId'] as String?;
                if (orderId != null) relayAcceptIds.add(orderId);
              } catch (_) {}
            }
          }
        } catch (e) {}
        return {'orders': relayOrders, 'acceptIds': relayAcceptIds};
      }),
    );
    
    // Consolidar resultados de todos os relays
    for (final result in relayResults) {
      for (final order in result['orders'] as List<Map<String, dynamic>>) {
        final id = order['id'];
        if (!seenIds.contains(id)) {
          seenIds.add(id);
          orders.add(order);
        }
      }
      orderIdsFromAccepts.addAll(result['acceptIds'] as Set<String>);
    }
    
    // 3. Buscar as ordens originais pelos IDs encontrados nos eventos de aceitação
    // PERFORMANCE: Buscar EM PARALELO em lotes de 10
    if (orderIdsFromAccepts.isNotEmpty) {
      final missingIds = orderIdsFromAccepts.where((id) => !seenIds.contains(id)).toList();
      
      if (missingIds.isNotEmpty) {
        // Buscar em lotes paralelos de 10 para não sobrecarregar
        for (int i = 0; i < missingIds.length; i += 10) {
          final batch = missingIds.skip(i).take(10).toList();
          final batchResults = await Future.wait(
            batch.map((orderId) => fetchOrderFromNostr(orderId).catchError((_) => null)),
          );
          
          for (int j = 0; j < batchResults.length; j++) {
            final orderData = batchResults[j];
            if (orderData != null) {
              seenIds.add(batch[j]);
              orderData['providerId'] = providerPubkey;
              orders.add(orderData);
            }
          }
        }
      }
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
            // CORREÇÃO v1.0.129: Usar timestamp Nostr como fallback em vez de DateTime.now()
            // DateTime.now() fazia TODAS as ordens sem createdAt ficarem com a mesma data (do sync)
            createdAt: DateTime.tryParse(raw['createdAt']?.toString() ?? '') ?? 
                       (raw['created_at'] != null 
                         ? DateTime.fromMillisecondsSinceEpoch((raw['created_at'] as int) * 1000)
                         : DateTime.now()),
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
        // CORREÇÃO CRÍTICA: Excluir ordens onde o usuário é o próprio dono
        // Quando user == provider (mesmo device), os status updates do usuário
        // são capturados como "provider events" causando contaminação
        if (order.userPubkey == providerPubkey) {
          continue; // Pular ordens próprias — não sou meu próprio Bro!
        }
        
        // CORREÇÃO CRÍTICA: Garantir que providerId seja setado para ordens do provedor
        if (order.providerId == null || order.providerId!.isEmpty) {
          order = order.copyWith(providerId: providerPubkey);
        }
        
        // CORREÇÃO CRÍTICA: Aplicar status atualizado dos eventos de UPDATE
        // Isso garante que ordens completed/awaiting_confirmation apareçam com status correto
        order = _applyStatusUpdate(order, statusUpdates, userPrivateKey: _decryptionKey);
        
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
          const Duration(seconds: 4),
          onTimeout: () {
            throw TimeoutException('Connection timeout');
          },
        );
      } catch (e) {
        // Se channel.ready falhar, dar um pequeno delay e tentar assim mesmo
        await Future.delayed(const Duration(milliseconds: 500));
      }
      
      
      // Timeout de 15 segundos para resposta (aumentado de 8 para melhor confiabilidade)
      timeout = Timer(const Duration(seconds: 15), () {
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
    final subscriptionId = const Uuid().v4().substring(0, 8);

    // CORREÇÃO v1.0.128: Usar runZonedGuarded para capturar TODOS os erros assíncronos
    // de WebSocket (DNS failures, HTTP 502, connection refused, etc.)
    // Sem isso, erros de conexão lazy propagam como "Unhandled Exception" no console
    final zoneCompleter = Completer<List<Map<String, dynamic>>>();

    runZonedGuarded(() async {
      WebSocketChannel? channel;
      Timer? timeout;
      final completer = Completer<List<Map<String, dynamic>>>();

      try {
        // Conectar ao relay
        channel = WebSocketChannel.connect(Uri.parse(relayUrl));
        final ch = channel!; // Capturar referência não-nula

        // Timeout de 8 segundos
        timeout = Timer(const Duration(seconds: 8), () {
          if (!completer.isCompleted) {
            completer.complete(events);
            try { ch.sink.close(); } catch (_) {}
          }
        });

        // Escutar eventos
        ch.stream.listen(
          (message) {
            try {
              final response = jsonDecode(message);
              if (response[0] == 'EVENT' && response[1] == subscriptionId) {
                final eventData = response[2] as Map<String, dynamic>;

                // SEGURANÇA: Verificar assinatura do evento
                try {
                  Event.fromJson(eventData, verify: true);
                } catch (e) {
                  debugPrint('⚠️ REJEITADO evento com assinatura inválida: ${eventData['id']?.toString().substring(0, 8) ?? '?'} - $e');
                  return;
                }

                // Parsear conteúdo JSON se possível
                try {
                  final content = jsonDecode(eventData['content']);
                  eventData['parsedContent'] = content;
                } catch (_) {}

                events.add(eventData);
              } else if (response[0] == 'EOSE') {
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
        if (since != null) {
          filter['since'] = since;
        }

        // Enviar requisição
        ch.sink.add(jsonEncode(['REQ', subscriptionId, filter]));

        // Aguardar resultado
        final result = await completer.future;
        if (!zoneCompleter.isCompleted) zoneCompleter.complete(result);
      } catch (e) {
        if (!zoneCompleter.isCompleted) zoneCompleter.complete(events);
      } finally {
        timeout?.cancel();
        try { channel?.sink.add(jsonEncode(['CLOSE', subscriptionId])); } catch (_) {}
        try { channel?.sink.close(); } catch (_) {}
      }
    }, (error, stack) {
      // Capturar erros de zona (WebSocket DNS, 502, etc.) silenciosamente
      if (!zoneCompleter.isCompleted) zoneCompleter.complete(events);
    });

    // Timeout de segurança
    return zoneCompleter.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => events,
    );
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
      
      // CRÍTICO: Determinar o userPubkey correto
      // Preferência: content.userPubkey (mais explícito)
      // Fallback: event.pubkey (seguro pois assinatura Nostr garante autenticidade do autor)
      final contentUserPubkey = content['userPubkey'] as String?;
      
      String? originalUserPubkey;
      if (contentUserPubkey != null && contentUserPubkey.isNotEmpty) {
        // Ordem nova com userPubkey no content - CONFIÁVEL
        originalUserPubkey = contentUserPubkey;
      } else {
        // Ordem legada (v1.0) sem userPubkey no content
        // SEGURO usar event.pubkey porque a assinatura criptográfica (sig)
        // garante que o pubkey é do autor original — relays não podem falsificar
        final eventPubkey = event['pubkey'] as String?;
        if (eventPubkey != null && eventPubkey.isNotEmpty) {
          originalUserPubkey = eventPubkey;
          debugPrint('ℹ️ Ordem legada: usando event.pubkey como userPubkey');
        } else {
          return null; // Sem nenhuma forma de identificar o dono
        }
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
  /// PERFORMANCE: Busca em todos os relays EM PARALELO e usa o primeiro resultado
  Future<Map<String, dynamic>?> fetchOrderFromNostr(String orderId) async {
    
    // Buscar em todos os relays em paralelo
    final results = await Future.wait(
      _relays.take(3).map((relay) => _fetchOrderFromRelay(relay, orderId).catchError((_) => null)),
    );
    
    // Usar o primeiro resultado não-null
    for (final result in results) {
      if (result != null) return result;
    }
    
    return null;
  }
  
  /// Helper: Busca ordem de um relay específico
  Future<Map<String, dynamic>?> _fetchOrderFromRelay(String relay, String orderId) async {
    try {
      // Buscar em paralelo: d-tag e t-tag simultaneamente
      final results = await Future.wait([
        _fetchFromRelay(relay, kinds: [kindBroOrder], tags: {'#d': [orderId]}, limit: 5),
        _fetchFromRelay(relay, kinds: [kindBroOrder], tags: {'#t': [orderId]}, limit: 5),
      ]);
      
      // Combinar resultados
      final allEvents = [...results[0], ...results[1]];
      
      // Verificar se algum evento tem o orderId no content
      for (final event in allEvents) {
        try {
          final content = event['parsedContent'] ?? jsonDecode(event['content']);
          final eventOrderId = content['orderId'] as String?;
          
          if (eventOrderId == orderId) {
            final contentUserPubkey = content['userPubkey'] as String? ?? event['pubkey'] as String?;
            if (contentUserPubkey == null || contentUserPubkey.isEmpty) continue;
            
            return {
              'id': orderId,
              'eventId': event['id'],
              'userPubkey': contentUserPubkey,
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
              'created_at': event['created_at'], // Timestamp Nostr como fallback
            };
          }
        } catch (_) {}
      }
      
      // Se encontrou eventos mas nenhum com orderId match, usar o primeiro
      if (allEvents.isNotEmpty) {
        final event = allEvents.first;
        final content = event['parsedContent'] ?? jsonDecode(event['content']);
        final fallbackUserPubkey = content['userPubkey'] as String? ?? event['pubkey'] as String?;
        if (fallbackUserPubkey == null || fallbackUserPubkey.isEmpty) return null;
        
        return {
          'id': content['orderId'] ?? orderId,
          'eventId': event['id'],
          'userPubkey': fallbackUserPubkey,
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
          'created_at': event['created_at'], // Timestamp Nostr como fallback
        };
      }
    } catch (e) {}
    
    return null;
  }
  
  /// Busca o status mais recente de uma ordem dos eventos de UPDATE (kind 30080) e COMPLETE (kind 30081)
  /// NOTA: Esta função é lenta e deve ser usada apenas quando necessário, não em batch
  Future<String?> _fetchLatestOrderStatus(String orderId) async {
    String? latestStatus;
    int latestTimestamp = 0;
    
    // PERFORMANCE: Buscar em todos os relays EM PARALELO
    final relayResults = await Future.wait(
      _relays.take(3).map((relay) async {
        try {
          // Buscar ambas estratégias em paralelo dentro do relay
          final fetches = await Future.wait([
            _fetchFromRelay(relay, kinds: [kindBroPaymentProof, kindBroComplete], tags: {'#orderId': [orderId]}, limit: 20),
            _fetchFromRelay(relay, kinds: [kindBroPaymentProof, kindBroComplete], tags: {'#t': [orderId]}, limit: 20),
          ]);
          return [...fetches[0], ...fetches[1]];
        } catch (e) {
          return <Map<String, dynamic>>[];
        }
      }),
    );
    
    // Processar todos os resultados
    for (final events in relayResults) {
      for (final event in events) {
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
    }
    
    return latestStatus;
  }

  /// Busca o evento COMPLETE de uma ordem para obter o providerInvoice
  /// Retorna um Map com os dados do evento COMPLETE incluindo providerInvoice
  Future<Map<String, dynamic>?> fetchOrderCompleteEvent(String orderId) async {
    
    // PERFORMANCE: Buscar em todos os relays EM PARALELO
    final results = await Future.wait(
      _relays.take(3).map((relay) async {
        try {
          // Buscar ambas estratégias em paralelo
          final fetches = await Future.wait([
            _fetchFromRelay(relay, kinds: [kindBroComplete], tags: {'#orderId': [orderId]}, limit: 5),
            _fetchFromRelay(relay, kinds: [kindBroComplete], tags: {'#d': ['${orderId}_complete']}, limit: 5),
          ]);
          
          final allEvents = [...fetches[0], ...fetches[1]];
          
          for (final event in allEvents) {
            try {
              final content = event['parsedContent'] ?? jsonDecode(event['content']);
              final eventOrderId = content['orderId'] as String?;
              
              if (eventOrderId == orderId) {
                return {
                  'orderId': orderId,
                  'providerId': content['providerId'] as String?,
                  'providerInvoice': content['providerInvoice'] as String?,
                  'completedAt': content['completedAt'],
                };
              }
            } catch (_) {}
          }
        } catch (e) {}
        return null;
      }),
    );
    
    // Usar o primeiro resultado não-null
    for (final result in results) {
      if (result != null) return result;
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

      
      // Publicar em paralelo - retornar assim que pelo menos 1 relay aceitar
      // Não esperar todos os relays (evita timeout quando um relay é lento)
      final futures = _relays.map((relay) => _publishToRelay(relay, event).catchError((_) => false)).toList();
      
      // Esperar o primeiro sucesso ou todos falharem
      bool anySuccess = false;
      for (final future in futures) {
        try {
          final result = await future;
          if (result) {
            anySuccess = true;
            break;
          }
        } catch (_) {}
      }
      
      // Se nenhum retornou true via loop (pode ter saído cedo), verificar os restantes em background
      if (!anySuccess) {
        final results = await Future.wait(
          futures.map((f) => f.catchError((_) => false)),
        );
        anySuccess = results.any((s) => s);
      }

      // Adicionar à blocklist local imediatamente (não esperar próximo sync)
      if (anySuccess) {
        _addToBlocklist({order.id});
        // Invalidar cache de status updates para forçar re-fetch
        _statusUpdatesCache = null;
        _statusUpdatesCacheTime = null;
      }

      return anySuccess;
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
      
      // NOTA: O comprovante é criptografado via NIP-44 entre provedor e usuário
      // Apenas o destinatário (userPubkey) pode descriptografar
      String? encryptedProofImage;
      try {
        if (order.userPubkey != null && order.userPubkey!.isNotEmpty) {
          encryptedProofImage = _nip44.encryptBetween(
            proofImageBase64,
            keychain.private,
            order.userPubkey!,
          );
          debugPrint('🔐 proofImage criptografado com NIP-44 (${encryptedProofImage.length} chars)');
        }
      } catch (e) {
        debugPrint('⚠️ Falha ao criptografar proofImage: $e — enviando em plaintext');
      }
      
      final contentMap = {
        'type': 'bro_complete',
        'orderId': order.id,
        'orderEventId': order.eventId,
        'providerId': keychain.public,
        'recipientPubkey': order.userPubkey, // Para quem é destinado
        'completedAt': DateTime.now().toIso8601String(),
      };
      
      // Adicionar proofImage (criptografado ou plaintext como fallback)
      if (encryptedProofImage != null) {
        contentMap['proofImage_nip44'] = encryptedProofImage;
        contentMap['proofImage'] = '[encrypted:nip44v2]'; // Marcador para clientes antigos
        contentMap['encryption'] = 'nip44v2';
      } else {
        contentMap['proofImage'] = proofImageBase64;
      }
      
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

      
      // Publicar em paralelo - retornar assim que pelo menos 1 relay aceitar
      final futures = _relays.map((relay) => _publishToRelay(relay, event).catchError((_) => false)).toList();
      
      bool anySuccess = false;
      for (final future in futures) {
        try {
          final result = await future;
          if (result) {
            anySuccess = true;
            break;
          }
        } catch (_) {}
      }
      
      if (!anySuccess) {
        final results = await Future.wait(
          futures.map((f) => f.catchError((_) => false)),
        );
        anySuccess = results.any((s) => s);
      }

      // Adicionar à blocklist local + invalidar cache
      if (anySuccess) {
        _addToBlocklist({order.id});
        _statusUpdatesCache = null;
        _statusUpdatesCacheTime = null;
      }

      return anySuccess;
    } catch (e) {
      return false;
    }
  }

  /// Busca ordens pendentes e retorna como List<Order>
  /// Para modo Bro: retorna APENAS ordens que ainda não foram aceitas por nenhum Bro
  /// v1.0.129+205: Usa blocklist local + re-fetch direcionado por #d tag
  /// NOTA: _fetchAllOrderStatusUpdates retorna 0 na maioria dos relays porque
  /// tags #t e queries sem authors não são suportadas para events kind 30000+
  /// Por isso usamos _fetchTargetedStatusUpdates (que usa #d tag) como PRIMARY
  Future<List<Order>> fetchPendingOrders() async {
    
    // PASSO 0: Garantir que blocklist local está carregada
    await _loadBlockedOrders();
    
    final rawOrders = await _fetchPendingOrdersRaw();
    debugPrint('📋 fetchPendingOrders: ${rawOrders.length} raw events do relay');
    
    // Converter para Orders COM DEDUPLICAÇÃO por orderId
    // PERFORMANCE v226: Verificar blocklist ANTES de eventToOrder() usando tag 'd'
    // Isso evita JSON decode + construção de Order para ~94% dos eventos (que são bloqueados)
    final seenOrderIds = <String>{};
    final allOrders = <Order>[];
    int nullOrders = 0;
    int blockedCount = 0;
    int skippedByTagCount = 0;
    for (final e in rawOrders) {
      // PERFORMANCE v226: Extrair orderId da tag 'd' ANTES do parsing pesado
      // Tags já estão parseadas pelo WebSocket handler (são List<dynamic>)
      String? tagOrderId;
      final tags = e['tags'] as List<dynamic>?;
      if (tags != null) {
        for (final tag in tags) {
          if (tag is List && tag.length >= 2 && tag[0] == 'd') {
            tagOrderId = tag[1]?.toString();
            break;
          }
        }
      }
      
      // Se temos orderId da tag, verificar blocklist e dedup ANTES de eventToOrder
      if (tagOrderId != null && tagOrderId.isNotEmpty) {
        if (seenOrderIds.contains(tagOrderId)) {
          skippedByTagCount++;
          continue;
        }
        if (_blockedOrderIds.contains(tagOrderId)) {
          seenOrderIds.add(tagOrderId);
          blockedCount++;
          continue;
        }
      }
      
      final order = eventToOrder(e);
      if (order == null) { nullOrders++; continue; }
      
      // DEDUPLICAÇÃO: Só adicionar se ainda não vimos este orderId
      if (seenOrderIds.contains(order.id)) {
        continue;
      }
      seenOrderIds.add(order.id);
      
      // BLOCKLIST: Verificação final (para eventos sem tag 'd')
      if (_blockedOrderIds.contains(order.id)) {
        blockedCount++;
        continue;
      }
      
      allOrders.add(order);
    }
    
    debugPrint('📋 fetchPendingOrders: ${allOrders.length} ordens válidas ($nullOrders rejeitadas, $blockedCount bloqueadas localmente, $skippedByTagCount skipped por tag)');
    
    // Filtrar ordens expiradas ANTES do fetch de status (economiza queries)
    final now = DateTime.now();
    final maxOrderAge = const Duration(days: 7);
    final freshOrders = <Order>[];
    final expiredIds = <String>{};
    
    for (var order in allOrders) {
      final orderAge = now.difference(order.createdAt);
      if (orderAge > maxOrderAge && (order.status == 'pending')) {
        debugPrint('  ⏰ Ordem ${order.id.substring(0, 8)} expirada: ${orderAge.inDays} dias atrás');
        expiredIds.add(order.id);
        continue;
      }
      freshOrders.add(order);
    }
    
    if (expiredIds.isNotEmpty) {
      _addToBlocklist(expiredIds);
      debugPrint('📋 ${expiredIds.length} ordens expiradas bloqueadas');
    }
    
    if (freshOrders.isEmpty) {
      debugPrint('📋 fetchPendingOrders: 0 ordens disponíveis (todas expiradas/bloqueadas)');
      return [];
    }
    
    // PASSO 2: Buscar status via #d tag (PRIMARY - funciona em todos os relays)
    // Esta é a fonte de verdade: busca accept/complete events por #d tag
    final orderIdsToCheck = freshOrders.map((o) => o.id).toList();
    debugPrint('🔍 fetchPendingOrders: buscando status de ${orderIdsToCheck.length} ordens via #d tag');
    final statusUpdates = await _fetchTargetedStatusUpdates(orderIdsToCheck);
    debugPrint('🔍 fetchPendingOrders: ${statusUpdates.length} ordens com status via #d');
    
    // PASSO 2.5: Buscar cancelamentos/updates por AUTHOR (pubkey do criador)
    // Cancelamentos são kind 30080 publicados pelo criador da ordem.
    // Os relays NÃO indexam tags #r, mas SEMPRE indexam 'authors'.
    // Coletamos pubkeys dos criadores e buscamos seus events kind 30080.
    final ordersWithoutStatus = freshOrders.where((o) => !statusUpdates.containsKey(o.id)).toList();
    // PERFORMANCE v226: Só chamar _fetchStatusByAuthors se > 5 ordens sem status
    // Para poucas ordens, o _fetchTargetedStatusUpdates (#d tag) já é suficiente
    // Isso economiza 3 WebSocket conexões na maioria dos ciclos
    if (ordersWithoutStatus.length > 5) {
      debugPrint('🔍 fetchPendingOrders: ${ordersWithoutStatus.length} ordens sem status - buscando por authors');
      final authorUpdates = await _fetchStatusByAuthors(ordersWithoutStatus);
      if (authorUpdates.isNotEmpty) {
        debugPrint('🔍 fetchPendingOrders: ${authorUpdates.length} updates extras via authors!');
        statusUpdates.addAll(authorUpdates);
      }
    } else if (ordersWithoutStatus.isNotEmpty) {
      debugPrint('⚡ fetchPendingOrders: ${ordersWithoutStatus.length} ordens sem status (≤5), pulando fetchStatusByAuthors');
    }
    debugPrint('🔍 fetchPendingOrders: ${statusUpdates.length} ordens com status total');
    
    // LOG DETALHADO de cada ordem
    for (var order in freshOrders) {
      final update = statusUpdates[order.id];
      final updateStatus = update?['status'] as String?;
      debugPrint('  📦 Ordem ${order.id.substring(0, 8)}: status=${order.status}, update=$updateStatus, amount=${order.amount}');
    }
    
    // PASSO 3: Salvar ordens com status terminal na blocklist local
    final newBlockedIds = <String>{};
    for (final entry in statusUpdates.entries) {
      final status = entry.value['status'] as String?;
      if (status == 'accepted' || status == 'awaiting_confirmation' || 
          status == 'completed' || status == 'liquidated' || 
          status == 'cancelled' || status == 'disputed') {
        newBlockedIds.add(entry.key);
      }
    }
    if (newBlockedIds.isNotEmpty) {
      _addToBlocklist(newBlockedIds);
    }
    
    // PASSO 4: FILTRAR ordens disponíveis
    final availableOrders = <Order>[];
    
    for (var order in freshOrders) {
      final update = statusUpdates[order.id];
      final updateStatus = update?['status'] as String?;
      
      // Se tem update com status avançado, NÃO está disponível
      final isUnavailable = updateStatus == 'accepted' || updateStatus == 'awaiting_confirmation' || updateStatus == 'completed' || updateStatus == 'liquidated' || updateStatus == 'cancelled' || updateStatus == 'disputed';
      
      if (!isUnavailable) {
        availableOrders.add(order);
      } else {
        debugPrint('  🚫 Ordem ${order.id.substring(0, 8)} filtrada: updateStatus=$updateStatus');
      }
    }
    
    debugPrint('📋 fetchPendingOrders: ${availableOrders.length} ordens disponíveis após filtro');
    return availableOrders;
  }
  
  /// Re-fetch direcionado de status updates para ordens específicas
  /// Usa tags single-letter (#d e #r) que são indexadas pelos relays
  /// #d: orderId_accept / orderId_complete (para accept/complete events)
  /// #r: orderId puro (para cancellation/update events via updateOrderStatus)
  /// NOTA: Tags multi-letter como #orderId NÃO são indexadas pelos relays
  Future<Map<String, Map<String, dynamic>>> _fetchTargetedStatusUpdates(List<String> orderIds) async {
    final updates = <String, Map<String, dynamic>>{};
    if (orderIds.isEmpty) return updates;
    
    // Dividir em batches de 15 ordens para não sobrecarregar o relay
    const batchSize = 15;
    final batches = <List<String>>[];
    for (var i = 0; i < orderIds.length; i += batchSize) {
      batches.add(orderIds.sublist(i, i + batchSize > orderIds.length ? orderIds.length : i + batchSize));
    }
    
    debugPrint('🔍 _fetchTargetedStatusUpdates: ${orderIds.length} ordens em ${batches.length} batches');
    
    // Processar todos os batches
    final allEvents = <Map<String, dynamic>>[];
    
    for (final batch in batches) {
      // Construir lista de #d values: orderId_accept + orderId_complete
      final dTags = <String>[];
      for (final id in batch) {
        dTags.add('${id}_accept');
        dTags.add('${id}_complete');
      }
      
      // Buscar de todos os relays em paralelo com DUAS estratégias
      final relayFutures = _relays.map((relay) async {
        try {
          final results = await Future.wait([
            // Estratégia 1: #d tag para accept/complete events (kind 30079, 30081)
            _fetchFromRelayWithSince(
              relay,
              kinds: [kindBroAccept, kindBroComplete],
              tags: {'#d': dTags},
              since: null,
              limit: batch.length * 2,
            ).timeout(const Duration(seconds: 8), onTimeout: () => <Map<String, dynamic>>[]),
            // Estratégia 2: #r tag para updates/cancellations (kind 30080)
            // updateOrderStatus usa tag ['r', orderId] que é indexada como #r
            _fetchFromRelayWithSince(
              relay,
              kinds: [kindBroPaymentProof],
              tags: {'#r': batch}, // orderId direto na tag #r
              since: null,
              limit: batch.length * 3,
            ).timeout(const Duration(seconds: 8), onTimeout: () => <Map<String, dynamic>>[]),
          ]);
          
          final combined = <Map<String, dynamic>>[];
          for (final eventList in results) {
            combined.addAll(eventList);
          }
          return combined;
        } catch (e) {
          return <Map<String, dynamic>>[];
        }
      }).toList();
      
      final results = await Future.wait(relayFutures);
      final seenIds = <String>{};
      for (final relayEvents in results) {
        for (final e in relayEvents) {
          final id = e['id'];
          if (id != null && !seenIds.contains(id)) {
            seenIds.add(id);
            allEvents.add(e);
          }
        }
      }
    }
    
    debugPrint('🔍 _fetchTargetedStatusUpdates: ${allEvents.length} eventos encontrados');
    
    // Processar eventos
    for (final event in allEvents) {
      try {
        final content = event['parsedContent'] ?? jsonDecode(event['content']);
        final eventType = content['type'] as String?;
        if (eventType != 'bro_accept' && eventType != 'bro_order_update' && eventType != 'bro_complete') continue;
        
        final orderId = content['orderId'] as String?;
        if (orderId == null || !orderIds.contains(orderId)) continue;
        
        final createdAt = event['created_at'] as int? ?? 0;
        final existingUpdate = updates[orderId];
        final existingCreatedAt = existingUpdate?['created_at'] as int? ?? 0;
        
        if (existingUpdate == null || createdAt >= existingCreatedAt) {
          String? status = content['status'] as String?;
          final eventKind = event['kind'] as int?;
          if (eventType == 'bro_accept' || eventKind == kindBroAccept) {
            status = 'accepted';
          } else if (eventType == 'bro_complete' || eventKind == kindBroComplete) {
            status = 'awaiting_confirmation';
          }
          
          final providerId = content['providerId'] as String? ?? event['pubkey'] as String?;
          final providerInvoice = content['providerInvoice'] as String?;
          final proofImage = content['proofImage'] as String?;
          final proofImageNip44 = content['proofImage_nip44'] as String?;
          final encryption = content['encryption'] as String?;
          
          updates[orderId] = {
            'orderId': orderId,
            'status': status,
            'providerId': providerId,
            'eventAuthorPubkey': event['pubkey'] as String?,
            'proofImage': proofImage,
            'proofImage_nip44': proofImageNip44,
            'encryption': encryption,
            'providerInvoice': providerInvoice,
            'completedAt': content['completedAt'],
            'created_at': createdAt,
          };
        }
      } catch (_) {}
    }
    
    return updates;
  }

  /// Busca status updates por AUTHOR (pubkey do criador da ordem)
  /// Resolve: cancelamentos (kind 30080) publicados pelo criador não são encontráveis
  /// por #d ou #r tags, mas SEMPRE por 'authors' (filtro nativo do relay)
  Future<Map<String, Map<String, dynamic>>> _fetchStatusByAuthors(List<Order> orders) async {
    final updates = <String, Map<String, dynamic>>{};
    if (orders.isEmpty) return updates;
    
    // Coletar pubkeys únicos dos criadores
    final pubkeys = orders
        .where((o) => o.userPubkey != null && o.userPubkey!.isNotEmpty)
        .map((o) => o.userPubkey!)
        .toSet()
        .toList();
    
    if (pubkeys.isEmpty) return updates;
    
    // Mapeamento orderId -> set de orderIds que queremos
    final orderIdSet = orders.map((o) => o.id).toSet();
    
    debugPrint('🔍 _fetchStatusByAuthors: buscando kind 30080 de ${pubkeys.length} authors para ${orders.length} ordens');
    
    // Buscar de todos os relays em paralelo
    final allEvents = <Map<String, dynamic>>[];
    final seenIds = <String>{};
    
    // Buscar desde 8 dias atrás (cobre janela de 7 dias das ordens + margem)
    final sinceSecs = DateTime.now().subtract(const Duration(days: 8)).millisecondsSinceEpoch ~/ 1000;
    
    final relayFutures = _relays.map((relay) async {
      try {
        // Buscar events kind 30080 publicados pelos criadores das ordens
        // authors é SEMPRE indexado por todos os relays
        final events = await _fetchFromRelayWithSince(
          relay,
          kinds: [kindBroPaymentProof],
          authors: pubkeys,
          since: sinceSecs,
          limit: pubkeys.length * 50, // ~50 updates por author (margem ampla)
        ).timeout(const Duration(seconds: 8), onTimeout: () => <Map<String, dynamic>>[]);
        return events;
      } catch (e) {
        return <Map<String, dynamic>>[];
      }
    }).toList();
    
    final results = await Future.wait(relayFutures);
    for (final relayEvents in results) {
      for (final e in relayEvents) {
        final id = e['id'];
        if (id != null && !seenIds.contains(id)) {
          seenIds.add(id);
          allEvents.add(e);
        }
      }
    }
    
    debugPrint('🔍 _fetchStatusByAuthors: ${allEvents.length} eventos de ${_relays.length} relays');
    
    // Processar: filtrar apenas eventos relevantes para nossas ordens
    for (final event in allEvents) {
      try {
        final content = event['parsedContent'] ?? jsonDecode(event['content']);
        final eventType = content['type'] as String?;
        if (eventType != 'bro_order_update' && eventType != 'bro_complete') continue;
        
        final orderId = content['orderId'] as String?;
        if (orderId == null || !orderIdSet.contains(orderId)) continue;
        
        final status = content['status'] as String?;
        if (status == null) continue;
        
        final createdAt = event['created_at'] as int? ?? 0;
        final existingUpdate = updates[orderId];
        final existingCreatedAt = existingUpdate?['created_at'] as int? ?? 0;
        
        // cancelled SEMPRE vence
        final isCancel = status == 'cancelled';
        final existingIsCancelled = existingUpdate?['status'] == 'cancelled';
        if (existingIsCancelled) continue;
        
        if (existingUpdate == null || isCancel || createdAt >= existingCreatedAt) {
          updates[orderId] = {
            'orderId': orderId,
            'status': status,
            'providerId': content['providerId'] as String?,
            'eventAuthorPubkey': event['pubkey'] as String?,
            'created_at': createdAt,
          };
        }
      } catch (_) {}
    }
    
    return updates;
  }

  /// Pre-fetch status updates para preencher o cache ANTES de chamadas paralelas
  /// Deve ser chamado ANTES de Future.wait([fetchPendingOrders, fetchUserOrders, fetchProviderOrders])
  Future<void> prefetchStatusUpdates() async {
    await _fetchAllOrderStatusUpdates();
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
        .map((order) => _applyStatusUpdate(order, statusUpdates, userPrivateKey: _decryptionKey))
        .toList();
    
    return orders;
  }
  
  /// Busca TODOS os eventos de UPDATE de status (kind 30080, 30081)
  /// Inclui: updates de status, conclusões de ordem
  /// CRÍTICO: Busca de TODOS os relays para garantir sincronização
  /// PERFORMANCE: Resultado cacheado por 15s para evitar chamadas redundantes
  Future<Map<String, Map<String, dynamic>>> _fetchAllOrderStatusUpdates() async {
    // PERFORMANCE: Retornar cache se ainda válido (evita 3x chamadas idênticas por sync)
    if (_statusUpdatesCache != null && _statusUpdatesCacheTime != null) {
      final elapsed = DateTime.now().difference(_statusUpdatesCacheTime!).inSeconds;
      if (elapsed < _statusUpdatesCacheTtlSeconds) {
        debugPrint('📋 _fetchAllOrderStatusUpdates: usando cache (${elapsed}s ago, ${_statusUpdatesCache!.length} updates)');
        return _statusUpdatesCache!;
      }
    }
    
    // CORREÇÃO v1.0.129: Lock de concorrência — se já tem um fetch em andamento,
    // esperar pelo resultado ao invés de criar mais 6 conexões WebSocket
    if (_statusUpdatesFetching != null) {
      debugPrint('📋 _fetchAllOrderStatusUpdates: aguardando fetch em andamento...');
      return _statusUpdatesFetching!.future;
    }
    _statusUpdatesFetching = Completer<Map<String, Map<String, dynamic>>>();
    
    try {
    final updates = <String, Map<String, dynamic>>{}; // orderId -> latest update
    
    
    // PERFORMANCE: Buscar de todos os relays EM PARALELO
    // Para cada relay, buscar AMBAS as estratégias em paralelo (com e sem tag)
    final allEvents = <Map<String, dynamic>>[];
    // Usar mesmo window de 14 dias das ordens para garantir cobertura completa
    final fourteenDaysAgo = DateTime.now().subtract(const Duration(days: 14));
    final statusSince = (fourteenDaysAgo.millisecondsSinceEpoch / 1000).floor();
    
    final relayFutures = _relays.map((relay) async {
      try {
        // Buscar ambas estratégias em paralelo dentro do mesmo relay
        // COM since para evitar truncagem por limit em volumes altos
        // PERFORMANCE v1.0.129+218: Reduzido limit de 2000→500 por estratégia
        // Com a filtragem de ordens terminais no caller, não precisamos mais
        // buscar o histórico completo de 14 dias — apenas ordens ativas recentes
        final results = await Future.wait([
          _fetchFromRelayWithSince(
            relay,
            kinds: [kindBroAccept, kindBroPaymentProof, kindBroComplete],
            tags: {'#t': [broTag]},
            since: statusSince,
            limit: 500,
          ).timeout(const Duration(seconds: 8), onTimeout: () => <Map<String, dynamic>>[]),
          _fetchFromRelayWithSince(
            relay,
            kinds: [kindBroAccept, kindBroPaymentProof, kindBroComplete],
            since: statusSince,
            limit: 500,
          ).timeout(const Duration(seconds: 8), onTimeout: () => <Map<String, dynamic>>[]),
        ]);
        
        // Combinar e deduplicar
        final combined = <Map<String, dynamic>>[];
        final seenIds = <String>{};
        for (final eventList in results) {
          for (final e in eventList) {
            final id = e['id'];
            if (id != null && !seenIds.contains(id)) {
              seenIds.add(id);
              combined.add(e);
            }
          }
        }
        
        return combined;
      } catch (e) {
        return <Map<String, dynamic>>[];
      }
    }).toList();
    
    final results = await Future.wait(relayFutures);
    for (final relayEvents in results) {
      allEvents.addAll(relayEvents);
    }
    
    debugPrint('📋 _fetchAllOrderStatusUpdates: ${allEvents.length} eventos de ${_relays.length} relays (paralelo)');
    
    // Processar todos os eventos coletados
    for (final event in allEvents) {
          try {
            final content = event['parsedContent'] ?? jsonDecode(event['content']);
            final eventType = content['type'] as String?;
            final eventKind = event['kind'] as int?;
            
            // Processar eventos de accept, update, complete OU resolução de disputa
            // CORREÇÃO v1.0.129: Incluir bro_dispute_resolution para que as partes
            // envolvidas recebam a atualização de status da resolução do mediador
            if (eventType != 'bro_accept' && 
                eventType != 'bro_order_update' && 
                eventType != 'bro_complete' &&
                eventType != 'bro_dispute_resolution') continue;
            
            final orderId = content['orderId'] as String?;
            if (orderId == null) continue;
            
            // CORREÇÃO v1.0.129: Para eventos de resolução de disputa,
            // o pubkey do evento é do mediador, não do provedor/usuário.
            // Não validar papel do pubkey para estes eventos.
            if (eventType == 'bro_dispute_resolution') {
              // Extrair status da resolução
              final resolutionStatus = content['status'] as String?;
              if (resolutionStatus == null) continue;
              
              final createdAt = event['created_at'] as int? ?? 0;
              final existingUpdate = updates[orderId];
              final existingCreatedAt = existingUpdate?['created_at'] as int? ?? 0;
              
              if (existingUpdate == null || createdAt >= existingCreatedAt) {
                final providerId = content['providerId'] as String?;
                updates[orderId] = {
                  'orderId': orderId,
                  'status': resolutionStatus,
                  'providerId': providerId,
                  'eventAuthorPubkey': event['pubkey'] as String?,
                  'created_at': createdAt,
                };
              }
              continue;
            }
            
            // SEGURANÇA: Validar papel do pubkey do evento
            // Após verificação de assinatura (em _fetchFromRelayWithSince),
            // sabemos que event.pubkey é autêntico. Agora validamos o papel:
            // - bro_accept: pubkey deve ser o providerId (quem aceita)
            // - bro_complete: pubkey deve ser o providerId (quem completa)
            // - bro_order_update: pubkey deve ser providerId OU userPubkey
            final eventPubkey = event['pubkey'] as String?;
            final contentProviderId = content['providerId'] as String?;
            final contentUserPubkey = content['userPubkey'] as String?;
            
            if (eventType == 'bro_accept' || eventType == 'bro_complete') {
              // Apenas o provedor pode aceitar/completar
              if (contentProviderId != null && eventPubkey != null && 
                  eventPubkey != contentProviderId) {
                debugPrint('⚠️ REJEITADO: ${eventType} de pubkey=${ eventPubkey.substring(0, 8)} mas providerId=${contentProviderId.substring(0, 8)}');
                continue;
              }
            }
            
            final createdAt = event['created_at'] as int? ?? 0;
            
            // Manter apenas o update mais recente para cada ordem
            final existingUpdate = updates[orderId];
            final existingCreatedAt = existingUpdate?['created_at'] as int? ?? 0;
            
            // CORREÇÃO: Usar >= para timestamps iguais, permitindo que status mais avançado vença
            // Antes usava > (estritamente maior), o que fazia o primeiro evento processado ganhar
            // em caso de empate, mesmo que tivesse status menos avançado
            // CORREÇÃO CRÍTICA: 'cancelled' SEMPRE vence independente de timestamp
            final isCancel = (content['status'] as String?) == 'cancelled';
            final existingIsCancelled = existingUpdate?['status'] == 'cancelled';
            
            // Se existente já é cancelled, NADA pode sobrescrever
            if (existingIsCancelled) continue;
            
            if (existingUpdate == null || isCancel || createdAt >= existingCreatedAt) {
              // Determinar status baseado no tipo de evento
              String? status = content['status'] as String?;
              if (eventType == 'bro_accept' || eventKind == kindBroAccept) {
                status = 'accepted';
              } else if (eventType == 'bro_complete' || eventKind == kindBroComplete) {
                // SEGURANÇA: bro_complete SEMPRE resulta em 'awaiting_confirmation'
                // O provedor NÃO pode completar unilateralmente — o usuário deve confirmar manualmente
                // Isso evita que um provedor malicioso marque ordens como completed sem o pagamento real
                status = 'awaiting_confirmation'; // Bro pagou, aguardando confirmação do usuário
              }
              
              // PROTEÇÃO: Não regredir status mais avançado
              // CORREÇÃO CRÍTICA: 'cancelled' é estado TERMINAL - não pode ser sobrescrito
              // por nenhum outro status (exceto 'disputed')
              final existingStatus = existingUpdate?['status'] as String?;
              if (existingStatus != null) {
                // Se já está cancelado, NUNCA sobrescrever
                if (existingStatus == 'cancelled') {
                  continue;
                }
                // Se novo status é cancelled, SEMPRE sobrescrever (cancelamento é ação explícita)
                // (não entra aqui, cai no update abaixo)
                
                // Progressão linear — usar lista COMPLETA de status
                // CORREÇÃO v1.0.129: Lista incompleta causava bypass do guard
                const statusOrder = ['draft', 'pending', 'payment_received', 'accepted', 'processing', 'awaiting_confirmation', 'completed', 'liquidated'];
                final existingIdx = statusOrder.indexOf(existingStatus);
                final newIdx = statusOrder.indexOf(status ?? 'pending');
                if (existingIdx >= 0 && newIdx >= 0 && newIdx < existingIdx) {
                  continue;
                }
              }
              
              // IMPORTANTE: Incluir proofImage do comprovante para o usuário ver
              // Se criptografado com NIP-44, incluir versão encriptada para descriptografia posterior
              final proofImage = content['proofImage'] as String?;
              final proofImageNip44 = content['proofImage_nip44'] as String?;
              final encryption = content['encryption'] as String?;
              
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
                'proofImage': proofImage, // Comprovante enviado pelo Bro (pode ser marcador se encriptado)
                'proofImage_nip44': proofImageNip44, // Versão NIP-44 encriptada (se houver)
                'encryption': encryption, // Flag de criptografia
                'providerInvoice': providerInvoice, // Invoice para pagar o Bro
                'completedAt': content['completedAt'],
                'created_at': createdAt,
              };
            }
          } catch (e) {
            // Ignorar eventos mal formatados
          }
        }
    
    debugPrint('📋 _fetchAllOrderStatusUpdates: ${updates.length} ordens com updates');
    
    // PERFORMANCE: Salvar no cache para evitar chamadas redundantes
    _statusUpdatesCache = updates;
    _statusUpdatesCacheTime = DateTime.now();
    
    // Completar o lock para liberar chamadores concorrentes
    if (_statusUpdatesFetching != null && !_statusUpdatesFetching!.isCompleted) {
      _statusUpdatesFetching!.complete(updates);
    }
    _statusUpdatesFetching = null;
    
    return updates;
    } catch (e) {
      // Em caso de erro, liberar o lock e retornar cache ou vazio
      final fallback = _statusUpdatesCache ?? <String, Map<String, dynamic>>{};
      if (_statusUpdatesFetching != null && !_statusUpdatesFetching!.isCompleted) {
        _statusUpdatesFetching!.complete(fallback);
      }
      _statusUpdatesFetching = null;
      return fallback;
    }
  }
  
  /// Aplica o status mais recente de um update a uma ordem
  /// Aplica updates de status do Nostr a uma ordem
  /// [userPrivateKey]: Se fornecido, descriptografa proofImage NIP-44
  Order _applyStatusUpdate(Order order, Map<String, Map<String, dynamic>> statusUpdates, {String? userPrivateKey}) {
    final update = statusUpdates[order.id];
    if (update == null) return order;
    
    final newStatus = update['status'] as String?;
    final providerId = update['providerId'] as String?;
    var proofImage = update['proofImage'] as String?;
    final proofImageNip44 = update['proofImage_nip44'] as String?;
    final encryption = update['encryption'] as String?;
    final completedAt = update['completedAt'] as String?;
    final providerInvoice = update['providerInvoice'] as String?; // CRÍTICO: Invoice do provedor
    
    // NIP-44: Descriptografar proofImage se criptografado
    if (proofImageNip44 != null && proofImageNip44.isNotEmpty && 
        encryption == 'nip44v2' && userPrivateKey != null) {
      final senderPubkey = update['eventAuthorPubkey'] as String? ?? providerId;
      if (senderPubkey != null) {
        try {
          proofImage = _nip44.decryptBetween(proofImageNip44, userPrivateKey, senderPubkey);
          debugPrint('🔓 proofImage descriptografado com NIP-44');
        } catch (e) {
          debugPrint('⚠️ Falha ao descriptografar proofImage: $e');
          // Manter marcador [encrypted:nip44v2] como fallback
        }
      }
    }
    
    // NOTA: Não bloqueamos mais "completed" do provedor porque:
    // 1. O pagamento ao provedor só acontece via invoice Lightning que ele gera
    // 2. O pagamento da taxa só acontece quando o USUÁRIO confirma localmente
    // 3. O provedor marcar "completed" não causa dano financeiro
    // 4. Bloquear causa problemas de sincronização entre dispositivos
    
    if (newStatus != null && newStatus != order.status) {
      
      // CORREÇÃO v1.0.129: NUNCA regredir status
      // Se o status atual é mais avançado que o novo, manter o atual
      // Mas ainda atualizar metadata (proofImage, etc)
      final isProgression = _isStatusProgression(newStatus, order.status);
      final statusToApply = isProgression ? newStatus : order.status;
      
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
        status: statusToApply,
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
        const Duration(seconds: 8),
        onTimeout: () {
          return <Map<String, dynamic>>[];
        },
      );
      
      
      debugPrint('📡 Relay $relay: ${relayOrders.length} eventos kind 30078 retornados');
      
      for (final order in relayOrders) {
        // Verificar se é ordem do Bro app (verificando content)
        try {
          final content = order['parsedContent'] ?? jsonDecode(order['content'] ?? '{}');
          if (content['type'] == 'bro_order') {
            orders.add(order);
          }
        } catch (_) {}
      }
      debugPrint('📡 Relay $relay: ${orders.length} ordens bro_order válidas');
    } catch (e) {
      debugPrint('❌ Relay $relay erro: $e');
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
        const Duration(seconds: 8),
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
  /// PERFORMANCE: Busca em todos os relays EM PARALELO
  Future<Map<String, Map<String, dynamic>>> fetchOrderUpdatesForUser(String userPubkey, {List<String>? orderIds}) async {
    final updates = <String, Map<String, dynamic>>{}; // orderId -> latest update
    
    // PERFORMANCE v1.0.129+218: Se não há ordens ativas para buscar, retornar vazio
    // Isso evita abrir 12 conexões WebSocket desnecessárias
    if (orderIds != null && orderIds.isEmpty) {
      debugPrint('🔍 fetchOrderUpdatesForUser: 0 ordens ativas, pulando fetch');
      return updates;
    }
    
    // Converter para Set para filtragem O(1) no processamento
    final activeOrderIdSet = orderIds?.toSet();

    // PERFORMANCE: Buscar de todos os relays EM PARALELO
    // CORREÇÃO v1.0.128: Também buscar eventos do PRÓPRIO USUÁRIO (kind 30080)
    // para encontrar status 'completed' publicado quando o usuário confirmou o pagamento
    final allRelayEvents = await Future.wait(
      _relays.take(3).map((relay) async {
        try {
          // PERFORMANCE: Buscar TODAS as estratégias em paralelo
          final results = await Future.wait([
            // Estratégia 1: Eventos do Bro direcionados ao usuário (accept/complete)
            _fetchFromRelay(relay, kinds: [kindBroAccept, kindBroComplete], tags: {'#p': [userPubkey]}, limit: 100)
              .catchError((_) => <Map<String, dynamic>>[]),
            // Estratégia 2: Eventos com tag bro (fallback)
            _fetchFromRelay(relay, kinds: [kindBroAccept, kindBroComplete], tags: {'#t': [broTag]}, limit: 100)
              .catchError((_) => <Map<String, dynamic>>[]),
            // Estratégia 3: Eventos do PRÓPRIO USUÁRIO (kind 30080)
            // Quando o usuário confirma pagamento, publica kind 30080 com status 'completed'
            _fetchFromRelay(relay, kinds: [kindBroPaymentProof], authors: [userPubkey], limit: 100)
              .catchError((_) => <Map<String, dynamic>>[]),
            // Estratégia 4: Eventos kind 30080 DIRECIONADOS a este usuário via tag #p
            // Isso captura disputas/updates publicados pela OUTRA parte (ex: usuário publica 'disputed', provedor recebe)
            _fetchFromRelay(relay, kinds: [kindBroPaymentProof], tags: {'#p': [userPubkey]}, limit: 100)
              .catchError((_) => <Map<String, dynamic>>[]),
          ]);
          return [...results[0], ...results[1], ...results[2], ...results[3]];
        } catch (e) {
          return <Map<String, dynamic>>[];
        }
      }),
    );
    
    // LOG: Total de eventos recebidos dos relays
    final totalEvents = allRelayEvents.fold<int>(0, (sum, list) => sum + list.length);
    debugPrint('🔍 fetchOrderUpdatesForUser: $totalEvents eventos de ${_relays.take(3).length} relays');
    
    // Processar todos os eventos de todos os relays
    for (final events in allRelayEvents) {
      for (final event in events) {
          try {
            final content = event['parsedContent'] ?? jsonDecode(event['content']);
            final orderId = content['orderId'] as String?;
            final eventKind = event['kind'] as int?;
            final createdAt = event['created_at'] as int? ?? 0;
            
            if (orderId == null) continue;
            
            // PERFORMANCE v1.0.129+218: Ignorar eventos de ordens que não estão na lista ativa
            // Isso filtra eventos de ordens já terminais (completed/cancelled/liquidated)
            if (activeOrderIdSet != null && !activeOrderIdSet.contains(orderId)) continue;
            
            // CORREÇÃO v1.0.129: Ignorar eventos de resolução de disputa publicados pelo PRÓPRIO
            // usuário (quando ele é o mediador). Estes eventos não devem criar/atualizar ordens
            // na lista do mediador, pois ele não é parte da transação.
            final contentType = content['type'] as String?;
            if (contentType == 'bro_dispute_resolution') {
              // Se este usuário é o mediador (adminPubkey == userPubkey),
              // ignorar o evento para não poluir a lista do mediador
              final adminPubkey = content['adminPubkey'] as String?;
              if (adminPubkey == userPubkey) continue;
              // Se o usuário é uma das PARTES da disputa, processar normalmente
              // (o status da resolução é relevante para eles)
            }
            
            // SEGURANÇA: Validar papel baseado no tipo de evento
            final eventPubkey = event['pubkey'] as String?;
            final contentProviderId = content['providerId'] as String?;
            
            // Para eventos de accept/complete (do Bro): pubkey deve ser o providerId
            // Para eventos kind 30080: aceitar do PRÓPRIO USUÁRIO ou de OUTRA PARTE se tagged #p
            if (eventKind == kindBroAccept || eventKind == kindBroComplete) {
              // Apenas provedor pode aceitar/completar
              if (contentProviderId != null && eventPubkey != null &&
                  eventPubkey != contentProviderId) {
                continue;
              }
            } else if (eventKind == kindBroPaymentProof) {
              // Aceitar eventos kind 30080 se:
              // 1. Publicado pelo próprio usuário (nosso update)
              // 2. OU publicado pela outra parte E contém orderId válido (disputa/update direcionado)
              // A validação de orderId é feita abaixo (content['orderId'])
              // Não filtrar mais por pubkey - confiar na assinatura verificada pelo relay
            }
            
            // Determinar o novo status baseado no tipo de evento
            String newStatus;
            if (eventKind == kindBroAccept) {
              newStatus = 'accepted';
            } else if (eventKind == kindBroComplete) {
              newStatus = 'awaiting_confirmation';
            } else if (eventKind == kindBroPaymentProof) {
              final contentStatus = content['status'] as String?;
              if (contentStatus != null && contentStatus.isNotEmpty) {
                newStatus = contentStatus;
              } else {
                continue;
              }
            } else {
              continue;
            }
            
            // Verificar se este evento deve atualizar o existente
            final existingUpdate = updates[orderId];
            final existingCreatedAt = existingUpdate?['created_at'] as int? ?? 0;
            final existingStatus = existingUpdate?['status'] as String?;
            
            // CORREÇÃO CRÍTICA: Considerar tanto timestamp quanto progressão de status
            // Antes, eventos com createdAt menor eram IGNORADOS mesmo sendo progressão válida
            // Isso causava 'disputed' (kind 30080) ser rejeitado quando kind 30081
            // tinha timestamp mais recente (publicado por outra parte)
            final isNewer = existingUpdate == null || createdAt > existingCreatedAt;
            final isValidProgression = existingStatus != null && _isStatusProgression(newStatus, existingStatus);
            
            if (isNewer) {
              // Evento mais recente: aceitar se não regredir
              if (existingStatus != null && !_isStatusProgression(newStatus, existingStatus)) {
                continue; // Não regredir
              }
            } else if (isValidProgression) {
              // Evento mais antigo MAS progressão válida de status
              // Ex: 'disputed' (kind 30080, older) supera 'awaiting_confirmation' (kind 30081, newer)
            } else {
              continue; // Evento antigo e não é progressão - ignorar
            }
            
            updates[orderId] = {
              'orderId': orderId,
              'status': newStatus,
              'eventKind': eventKind,
              'providerId': content['providerId'] ?? event['pubkey'],
              'proofImage': content['proofImage'],
              'proofImage_nip44': content['proofImage_nip44'],
              'encryption': content['encryption'],
              'created_at': createdAt,
            };
          } catch (e) {
          }
      }
    }

    debugPrint('🔍 fetchOrderUpdatesForUser: ${updates.length} updates encontrados');
    for (final entry in updates.entries) {
      debugPrint('   📋 ${entry.key.substring(0, 8)}: status=${entry.value['status']}, kind=${entry.value['eventKind']}');
    }
    return updates;
  }
  
  /// Busca eventos de update de status para ordens que o provedor aceitou
  /// Isso permite que o Bro veja quando o usuário confirmou o pagamento (completed)
  /// SEGURANÇA: Só retorna updates para ordens específicas do provedor
  /// PERFORMANCE: Todas as estratégias rodam em PARALELO em todos os relays
  Future<Map<String, Map<String, dynamic>>> fetchOrderUpdatesForProvider(String providerPubkey, {List<String>? orderIds}) async {
    final updates = <String, Map<String, dynamic>>{}; // orderId -> latest update
    
    // SEGURANÇA: Se não temos orderIds específicos, não buscar nada
    if (orderIds == null || orderIds.isEmpty) {
      return updates;
    }

    final orderIdSet = orderIds.toSet();
    debugPrint('🔍 fetchOrderUpdatesForProvider: buscando updates para ${orderIds.length} ordens');
    
    // Construir d-tags para Estratégia 4
    final dTagsToSearch = orderIds.map((id) => '${id}_complete').toList();
    
    // PERFORMANCE: Rodar TODAS as estratégias em TODOS os relays EM PARALELO
    // Antes: 4 estratégias × 3 relays = 12 chamadas SEQUENCIAIS (até 96s)
    // Agora: todas em paralelo (máximo ~8s, tempo de um único timeout)
    final allEventsFutures = <Future<List<Map<String, dynamic>>>>[];
    
    for (final relay in _relays.take(3)) {
      // Estratégia 1: #p tag
      allEventsFutures.add(
        _fetchFromRelay(relay, kinds: [kindBroPaymentProof], tags: {'#p': [providerPubkey]}, limit: 100)
          .catchError((_) => <Map<String, dynamic>>[])
      );
      // Estratégia 2: #r tag batch
      allEventsFutures.add(
        _fetchFromRelay(relay, kinds: [kindBroPaymentProof], tags: {'#r': orderIds}, limit: 200)
          .catchError((_) => <Map<String, dynamic>>[])
      );
      // Estratégia 2b: #e tag batch (legado)
      allEventsFutures.add(
        _fetchFromRelay(relay, kinds: [kindBroPaymentProof], tags: {'#e': orderIds}, limit: 200)
          .catchError((_) => <Map<String, dynamic>>[])
      );
      // Estratégia 3: #t bro-update
      allEventsFutures.add(
        _fetchFromRelay(relay, kinds: [kindBroPaymentProof], tags: {'#t': ['bro-update']}, limit: 100)
          .catchError((_) => <Map<String, dynamic>>[])
      );
      // Estratégia 4: #d tag batch
      allEventsFutures.add(
        _fetchFromRelay(relay, kinds: [kindBroPaymentProof, kindBroComplete], tags: {'#d': dTagsToSearch}, limit: 200)
          .catchError((_) => <Map<String, dynamic>>[])
      );
    }
    
    // Executar TUDO em paralelo
    final allResults = await Future.wait(allEventsFutures);
    
    // Processar todos os eventos de todas as estratégias
    int totalEvents = 0;
    for (final events in allResults) {
      totalEvents += events.length;
      for (final event in events) {
        try {
          final content = event['parsedContent'] ?? jsonDecode(event['content']);
          final eventOrderId = content['orderId'] as String?;
          final status = content['status'] as String?;
          final createdAt = event['created_at'] as int? ?? 0;
          
          if (eventOrderId == null || status == null) continue;
          if (!orderIdSet.contains(eventOrderId)) continue;
          
          final existingUpdate = updates[eventOrderId];
          final existingCreatedAt = existingUpdate?['created_at'] as int? ?? 0;
          
          if (existingUpdate == null || createdAt > existingCreatedAt) {
            // PROTEÇÃO: Não regredir status — usar _isStatusProgression com lista COMPLETA
            final existingStatus = existingUpdate?['status'] as String?;
            if (existingStatus != null) {
              if (!_isStatusProgression(status, existingStatus)) continue;
            }
            
            updates[eventOrderId] = {
              'orderId': eventOrderId,
              'status': status,
              'created_at': createdAt,
            };
          }
        } catch (_) {}
      }
    }

    debugPrint('🔍 fetchOrderUpdatesForProvider RESULTADO: ${updates.length} updates de $totalEvents eventos');
    for (final entry in updates.entries) {
      debugPrint('   → orderId=${entry.key.substring(0, 8)} status=${entry.value['status']}');
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

      
      // PERFORMANCE: Publicar em todos os relays EM PARALELO
      final publishResults = await Future.wait(
        _relays.map((relay) => _publishToRelay(relay, event).catchError((_) => false)),
      );
      final successCount = publishResults.where((s) => s).length;

      return successCount > 0;
    } catch (e) {
      return false;
    }
  }

  /// Busca os dados do tier do provedor no Nostr
  Future<Map<String, dynamic>?> fetchProviderTier(String providerPubkey) async {
    
    // PERFORMANCE: Buscar em todos os relays EM PARALELO
    final results = await Future.wait(
      _relays.map((relay) async {
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
        } catch (e) {}
        return null;
      }),
    );
    
    for (final result in results) {
      if (result != null) return result;
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

      
      // PERFORMANCE: Publicar em todos os relays EM PARALELO
      final publishResults = await Future.wait(
        _relays.take(5).map((relay) => _publishToRelay(relay, event).catchError((_) => false)),
      );
      final successCount = publishResults.where((s) => s).length;

      return successCount > 0 ? offerId : null;
    } catch (e) {
      return null;
    }
  }

  /// Busca ofertas do marketplace
  Future<List<Map<String, dynamic>>> fetchMarketplaceOffers() async {
    final offers = <Map<String, dynamic>>[];
    final seenIds = <String>{};


    // PERFORMANCE: Buscar de todos os relays EM PARALELO
    final relayResults = await Future.wait(
      _relays.take(5).map((relay) =>
        _fetchFromRelay(relay, kinds: [kindMarketplaceOffer], tags: {'#t': [marketplaceTag]}, limit: 50)
          .catchError((_) => <Map<String, dynamic>>[])
      ),
    );
    for (final events in relayResults) {
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
          } catch (e) {}
        }
      }
    }

    return offers;
  }

  /// Busca ofertas de um usuário específico
  Future<List<Map<String, dynamic>>> fetchUserMarketplaceOffers(String pubkey) async {
    final offers = <Map<String, dynamic>>[];
    final seenIds = <String>{};


    // PERFORMANCE: Buscar de todos os relays EM PARALELO
    final relayResults = await Future.wait(
      _relays.take(3).map((relay) =>
        _fetchFromRelay(relay, kinds: [kindMarketplaceOffer], authors: [pubkey], tags: {'#t': [marketplaceTag]}, limit: 50)
          .catchError((_) => <Map<String, dynamic>>[])
      ),
    );
    for (final events in relayResults) {
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
          } catch (e) {}
        }
      }
    }

    return offers;
  }

  /// Publica uma notificação de disputa no Nostr como kind 1 (nota)
  /// Kind 1 NÃO é addressable, então #t tags SÃO indexadas pelos relays
  /// Isso permite que o admin busque todas as disputas de qualquer dispositivo
  Future<bool> publishDisputeNotification({
    required String privateKey,
    required String orderId,
    required String reason,
    required String description,
    required String openedBy,
    Map<String, dynamic>? orderDetails,
    String? userEvidence, // v236: foto de evidência do usuário (base64)
  }) async {
    try {
      final keychain = Keychain(privateKey);
      
      final contentMap = {
        'type': 'bro_dispute',
        'orderId': orderId,
        'reason': reason,
        'description': description,
        'openedBy': openedBy,
        'userPubkey': keychain.public,
        'amount_brl': orderDetails?['amount_brl'],
        'amount_sats': orderDetails?['amount_sats'],
        'payment_type': orderDetails?['payment_type'],
        'pix_key': orderDetails?['pix_key'],
        'previous_status': orderDetails?['status'],
        'provider_id': orderDetails?['provider_id'],
        'createdAt': DateTime.now().toIso8601String(),
      };
      // v236: incluir evidência do usuário se fornecida
      if (userEvidence != null && userEvidence.isNotEmpty) {
        contentMap['user_evidence'] = userEvidence;
      }
      final content = jsonEncode(contentMap);
      
      final event = Event.from(
        kind: 1, // Nota regular - #t tags SÃO indexadas!
        tags: [
          ['t', 'bro-disputa'],
          ['t', broTag],
          ['r', orderId],
          ['p', AppConfig.adminPubkey], // Notificar admin/mediador
        ],
        content: content,
        privkey: keychain.private,
      );
      
      final results = await Future.wait(
        _relays.map((relay) async {
          try {
            return await _publishToRelay(relay, event);
          } catch (_) {
            return false;
          }
        }),
      );
      
      final successCount = results.where((r) => r).length;
      debugPrint('📤 publishDisputeNotification: publicado em $successCount/${_relays.length} relays');
      return successCount > 0;
    } catch (e) {
      debugPrint('❌ publishDisputeNotification EXCEPTION: $e');
      return false;
    }
  }

  /// Busca notificações de disputa do Nostr
  /// Estratégia dupla:
  /// 1. Kind 1 com tag bro-disputa (notificações explícitas, build 207+)
  /// 2. Kind 30080 com tag status-disputed (updates de status 'disputed', qualquer build)
  /// Usado pelo admin para ver TODAS as disputas de qualquer dispositivo
  Future<List<Map<String, dynamic>>> fetchDisputeNotifications() async {
    final allEvents = <Map<String, dynamic>>[];
    final seenIds = <String>{};
    final seenOrderIds = <String>{}; // Para deduplicar por orderId
    
    final results = await Future.wait(
      _relays.map((relay) async {
        try {
          // Buscar AMBAS as fontes em paralelo
          final fetches = await Future.wait([
            // Estratégia 1: Kind 1 - notificações explícitas de disputa (build 207+)
            _fetchFromRelay(
              relay,
              kinds: [1],
              tags: {'#t': ['bro-disputa']},
              limit: 100,
            ).timeout(const Duration(seconds: 8), onTimeout: () => <Map<String, dynamic>>[]),
            // Estratégia 2: Kind 30080 com tag status-disputed (qualquer build)
            _fetchFromRelay(
              relay,
              kinds: [kindBroPaymentProof],
              tags: {'#t': ['status-disputed']},
              limit: 100,
            ).timeout(const Duration(seconds: 8), onTimeout: () => <Map<String, dynamic>>[]),
          ]);
          return [...fetches[0], ...fetches[1]];
        } catch (_) {
          return <Map<String, dynamic>>[];
        }
      }),
    );
    
    for (final events in results) {
      for (final e in events) {
        final id = e['id'] as String?;
        if (id != null && !seenIds.contains(id)) {
          seenIds.add(id);
          allEvents.add(e);
        }
      }
    }
    
    debugPrint('📤 fetchDisputeNotifications: ${allEvents.length} disputas encontradas');
    return allEvents;
  }

  /// Busca TODAS as resoluções de disputas do Nostr (kind 1 com bro-resolucao)
  /// CORREÇÃO build 218: Necessário porque após resolução, o evento original de disputa
  /// pode não ser mais retornado pelo relay, fazendo a aba "Resolvidas" ficar vazia.
  /// Buscando resoluções diretamente, podemos reconstruir a lista de disputas resolvidas.
  Future<List<Map<String, dynamic>>> fetchAllDisputeResolutions() async {
    final allResolutions = <Map<String, dynamic>>[];
    final seenOrderIds = <String>{};
    
    final results = await Future.wait(
      _relays.take(3).map((relay) async {
        try {
          final channel = WebSocketChannel.connect(Uri.parse(relay));
          final subId = 'allres_${DateTime.now().millisecondsSinceEpoch % 100000}';
          final events = <Map<String, dynamic>>[];
          
          channel.sink.add(jsonEncode(['REQ', subId, {
            'kinds': [1],
            '#t': ['bro-resolucao'],
            'limit': 100,
          }]));
          
          await for (final msg in channel.stream.timeout(
            const Duration(seconds: 8), onTimeout: (sink) => sink.close())) {
            final data = jsonDecode(msg.toString());
            if (data is List && data.length >= 3 && data[0] == 'EVENT') {
              events.add(data[2] as Map<String, dynamic>);
            }
            if (data is List && data[0] == 'EOSE') break;
          }
          
          channel.sink.add(jsonEncode(['CLOSE', subId]));
          channel.sink.close();
          return events;
        } catch (_) {
          return <Map<String, dynamic>>[];
        }
      }),
    );
    
    // Deduplicar por orderId, mantendo o mais recente
    final bestByOrderId = <String, Map<String, dynamic>>{};
    
    for (final events in results) {
      for (final event in events) {
        try {
          final content = jsonDecode(event['content'] as String) as Map<String, dynamic>;
          if (content['type'] != 'bro_dispute_resolution') continue;
          final orderId = content['orderId'] as String? ?? '';
          if (orderId.isEmpty) continue;
          
          final createdAt = event['created_at'] as int? ?? 0;
          final existing = bestByOrderId[orderId];
          if (existing == null || createdAt > (existing['_createdAt'] as int? ?? 0)) {
            bestByOrderId[orderId] = {
              ...content,
              '_createdAt': createdAt,
              '_eventId': event['id'],
            };
          }
        } catch (_) {}
      }
    }
    
    allResolutions.addAll(bestByOrderId.values);
    debugPrint('📤 fetchAllDisputeResolutions: ${allResolutions.length} resoluções encontradas');
    return allResolutions;
  }

  /// Publica resolução de disputa no Nostr (kind 1 com tag bro-resolucao)
  /// Chamado pelo admin ao resolver uma disputa a favor de uma das partes
  Future<bool> publishDisputeResolution({
    required String privateKey,
    required String orderId,
    required String resolution, // 'resolved_user' ou 'resolved_provider'
    required String notes,
    String? userPubkey,
    String? providerId,
  }) async {
    try {
      final keychain = Keychain(privateKey);
      
      final content = jsonEncode({
        'type': 'bro_dispute_resolution',
        'orderId': orderId,
        'resolution': resolution,
        'resolvedBy': 'admin',
        'adminPubkey': keychain.public,
        'notes': notes,
        'userPubkey': userPubkey,
        'providerId': providerId,
        'resolvedAt': DateTime.now().toIso8601String(),
      });
      
      final tags = [
        ['t', 'bro-resolucao'],
        ['t', broTag],
        ['r', orderId],
      ];
      
      // Notificar ambas as partes
      if (userPubkey != null && userPubkey.isNotEmpty) {
        tags.add(['p', userPubkey]);
      }
      if (providerId != null && providerId.isNotEmpty) {
        tags.add(['p', providerId]);
      }
      
      final event = Event.from(
        kind: 1,
        tags: tags,
        content: content,
        privkey: keychain.private,
      );
      
      final results = await Future.wait(
        _relays.map((relay) async {
          try {
            return await _publishToRelay(relay, event);
          } catch (_) {
            return false;
          }
        }),
      );
      
      final successCount = results.where((r) => r).length;
      debugPrint('📤 publishDisputeResolution: kind 1 publicado em $successCount/${_relays.length} relays (orderId=${orderId.substring(0, 8)}, resolution=$resolution)');
      
      // AUDITABILIDADE: Publicar também como kind 30080 com tags de status
      // Isso permite que QUALQUER pessoa busque a resolução pela cadeia de eventos da ordem
      try {
        final auditContent = jsonEncode({
          'type': 'bro_dispute_resolution',
          'orderId': orderId,
          'resolution': resolution,
          'resolvedBy': 'admin',
          'adminPubkey': keychain.public,
          'notes': notes,
          'userPubkey': userPubkey,
          'providerId': providerId,
          'resolvedAt': DateTime.now().toIso8601String(),
          'status': resolution == 'resolved_user' ? 'cancelled' : 'completed',
        });
        
        final auditTags = [
          ['d', '${orderId}_resolution'],
          ['t', broTag],
          ['t', 'bro-resolucao'],
          ['t', 'status-${resolution == 'resolved_user' ? 'cancelled' : 'completed'}'],
          ['r', orderId],
          ['orderId', orderId],
        ];
        if (userPubkey != null && userPubkey.isNotEmpty) auditTags.add(['p', userPubkey]);
        if (providerId != null && providerId.isNotEmpty) auditTags.add(['p', providerId]);
        
        final auditEvent = Event.from(
          kind: kindBroPaymentProof, // kind 30080 - na cadeia de eventos da ordem
          tags: auditTags,
          content: auditContent,
          privkey: keychain.private,
        );
        
        final auditResults = await Future.wait(
          _relays.map((relay) => _publishToRelay(relay, auditEvent).catchError((_) => false)),
        );
        final auditSuccess = auditResults.where((r) => r).length;
        debugPrint('📤 publishDisputeResolution: kind 30080 (audit) publicado em $auditSuccess/${_relays.length} relays');
      } catch (e) {
        debugPrint('⚠️ Audit event (kind 30080) falhou: $e');
      }
      
      return successCount > 0;
    } catch (e) {
      debugPrint('❌ publishDisputeResolution EXCEPTION: $e');
      return false;
    }
  }

  /// Publica mensagem do mediador no Nostr (kind 1, tag bro-mediacao)
  /// Permite o admin enviar mensagem direta para user, provider ou ambos
  Future<bool> publishMediatorMessage({
    required String privateKey,
    required String orderId,
    required String message,
    required String target, // 'user', 'provider', 'both'
    String? userPubkey,
    String? providerId,
  }) async {
    try {
      final keychain = Keychain(privateKey);
      
      final content = jsonEncode({
        'type': 'bro_mediator_message',
        'orderId': orderId,
        'message': message,
        'target': target,
        'adminPubkey': keychain.public,
        'userPubkey': userPubkey,
        'providerId': providerId,
        'sentAt': DateTime.now().toIso8601String(),
      });
      
      final tags = [
        ['t', 'bro-mediacao'],
        ['t', broTag],
        ['r', orderId],
      ];
      
      if ((target == 'user' || target == 'both') && userPubkey != null && userPubkey.isNotEmpty) {
        tags.add(['p', userPubkey]);
      }
      if ((target == 'provider' || target == 'both') && providerId != null && providerId.isNotEmpty) {
        tags.add(['p', providerId]);
      }
      
      final event = Event.from(kind: 1, tags: tags, content: content, privkey: keychain.private);
      
      final results = await Future.wait(
        _relays.map((relay) => _publishToRelay(relay, event).catchError((_) => false)),
      );
      
      final successCount = results.where((r) => r).length;
      debugPrint('📤 publishMediatorMessage: publicado em $successCount/${_relays.length} relays (target=$target, orderId=${orderId.substring(0, 8)})');
      return successCount > 0;
    } catch (e) {
      debugPrint('❌ publishMediatorMessage EXCEPTION: $e');
      return false;
    }
  }

  /// Busca resolução de disputa para uma ordem específica (kind 1, tag bro-resolucao)
  /// Retorna o mapa de resolução ou null se não encontrada
  Future<Map<String, dynamic>?> fetchDisputeResolution(String orderId) async {
    try {
      final filter = {
        'kinds': [1],
        '#t': ['bro-resolucao'],
        '#r': [orderId],
        'limit': 5,
      };
      
      Map<String, dynamic>? latestResolution;
      int latestTimestamp = 0;
      
      for (final relay in _relays.take(3)) {
        try {
          final channel = WebSocketChannel.connect(Uri.parse(relay));
          final subId = 'res_${orderId.substring(0, 8)}_${DateTime.now().millisecondsSinceEpoch % 10000}';
          
          channel.sink.add(jsonEncode(['REQ', subId, filter]));
          
          await for (final msg in channel.stream.timeout(const Duration(seconds: 8), onTimeout: (sink) => sink.close())) {
            final data = jsonDecode(msg.toString());
            if (data is List && data.length >= 3 && data[0] == 'EVENT') {
              final eventData = data[2] as Map<String, dynamic>;
              final createdAt = eventData['created_at'] as int? ?? 0;
              
              if (createdAt > latestTimestamp) {
                try {
                  final contentMap = jsonDecode(eventData['content'] as String) as Map<String, dynamic>;
                  if (contentMap['type'] == 'bro_dispute_resolution') {
                    latestResolution = contentMap;
                    latestTimestamp = createdAt;
                  }
                } catch (_) {}
              }
            }
            if (data is List && data[0] == 'EOSE') break;
          }
          
          channel.sink.add(jsonEncode(['CLOSE', subId]));
          channel.sink.close();
        } catch (_) {}
      }
      
      if (latestResolution != null) {
        debugPrint('✅ fetchDisputeResolution: resolução encontrada para ${orderId.substring(0, 8)} - ${latestResolution['resolution']}');
      } else {
        debugPrint('🔍 fetchDisputeResolution: nenhuma resolução para ${orderId.substring(0, 8)}');
      }
      
      return latestResolution;
    } catch (e) {
      debugPrint('❌ fetchDisputeResolution EXCEPTION: $e');
      return null;
    }
  }

  /// Busca TODAS as mensagens de mediação de uma ordem (admin vê tudo)
  /// Diferente de fetchMediatorMessages que filtra por pubkey do destinatário
  Future<List<Map<String, dynamic>>> fetchAllMediatorMessagesForOrder(String orderId) async {
    try {
      final filter = <String, dynamic>{
        'kinds': [1],
        '#t': ['bro-mediacao'],
        '#r': [orderId],
        'limit': 50,
      };
      
      final messages = <Map<String, dynamic>>[];
      
      for (final relay in _relays.take(3)) {
        try {
          final channel = WebSocketChannel.connect(Uri.parse(relay));
          final subId = 'medord_${orderId.substring(0, 8)}_${DateTime.now().millisecondsSinceEpoch % 10000}';
          
          channel.sink.add(jsonEncode(['REQ', subId, filter]));
          
          await for (final msg in channel.stream.timeout(const Duration(seconds: 8), onTimeout: (sink) => sink.close())) {
            final data = jsonDecode(msg.toString());
            if (data is List && data.length >= 3 && data[0] == 'EVENT') {
              final eventData = data[2] as Map<String, dynamic>;
              try {
                final content = jsonDecode(eventData['content'] as String) as Map<String, dynamic>;
                if (content['type'] == 'bro_mediator_message') {
                  content['eventCreatedAt'] = eventData['created_at'];
                  content['eventId'] = eventData['id'];
                  final existing = messages.any((m) => m['sentAt'] == content['sentAt'] && m['message'] == content['message']);
                  if (!existing) messages.add(content);
                }
              } catch (_) {}
            }
            if (data is List && data[0] == 'EOSE') break;
          }
          
          channel.sink.add(jsonEncode(['CLOSE', subId]));
          channel.sink.close();
        } catch (_) {}
      }
      
      // Ordenar por data (mais antiga primeiro para exibir como chat)
      messages.sort((a, b) => (a['eventCreatedAt'] as int? ?? 0).compareTo(b['eventCreatedAt'] as int? ?? 0));
      debugPrint('📨 fetchAllMediatorMessagesForOrder: ${messages.length} mensagens para ordem ${orderId.substring(0, 8)}');
      return messages;
    } catch (e) {
      debugPrint('❌ fetchAllMediatorMessagesForOrder EXCEPTION: $e');
      return [];
    }
  }

  /// Busca mensagens do mediador para um usuário ou provedor específico
  /// Retorna lista de mensagens relevantes
  Future<List<Map<String, dynamic>>> fetchMediatorMessages(String pubkey, {String? orderId}) async {
    try {
      final filter = <String, dynamic>{
        'kinds': [1],
        '#t': ['bro-mediacao'],
        '#p': [pubkey],
        'limit': 20,
      };
      if (orderId != null) {
        filter['#r'] = [orderId];
      }
      
      final messages = <Map<String, dynamic>>[];
      
      for (final relay in _relays.take(3)) {
        try {
          final channel = WebSocketChannel.connect(Uri.parse(relay));
          final subId = 'med_${pubkey.substring(0, 8)}_${DateTime.now().millisecondsSinceEpoch % 10000}';
          
          channel.sink.add(jsonEncode(['REQ', subId, filter]));
          
          await for (final msg in channel.stream.timeout(const Duration(seconds: 8), onTimeout: (sink) => sink.close())) {
            final data = jsonDecode(msg.toString());
            if (data is List && data.length >= 3 && data[0] == 'EVENT') {
              final eventData = data[2] as Map<String, dynamic>;
              try {
                final content = jsonDecode(eventData['content'] as String) as Map<String, dynamic>;
                if (content['type'] == 'bro_mediator_message') {
                  content['eventCreatedAt'] = eventData['created_at'];
                  final existing = messages.any((m) => m['sentAt'] == content['sentAt'] && m['orderId'] == content['orderId']);
                  if (!existing) messages.add(content);
                }
              } catch (_) {}
            }
            if (data is List && data[0] == 'EOSE') break;
          }
          
          channel.sink.add(jsonEncode(['CLOSE', subId]));
          channel.sink.close();
        } catch (_) {}
      }
      
      messages.sort((a, b) => (b['eventCreatedAt'] as int? ?? 0).compareTo(a['eventCreatedAt'] as int? ?? 0));
      debugPrint('📨 fetchMediatorMessages: ${messages.length} mensagens para ${pubkey.substring(0, 8)}');
      return messages;
    } catch (e) {
      debugPrint('❌ fetchMediatorMessages EXCEPTION: $e');
      return [];
    }
  }

  /// Busca o comprovante de pagamento para uma ordem específica
  /// Pesquisa kind 30081 (bro_complete) e kind 30080 diretamente pelo orderId
  /// Retorna Map com 'proofImage' (plaintext ou null) e 'encrypted' (bool)
  /// CORREÇÃO build 216: Usar tags single-letter (#d, #r, #t) suportadas por relays
  /// em vez de #orderId que é multi-char e NÃO é suportada por relays
  Future<Map<String, dynamic>> fetchProofForOrder(String orderId, {String? providerPubkey}) async {
    try {
      final result = <String, dynamic>{
        'proofImage': null,
        'encrypted': false,
        'providerPubkey': providerPubkey,
      };
      
      for (final relay in _relays.take(3)) {
        try {
          final channel = WebSocketChannel.connect(Uri.parse(relay));
          final subId = 'proof_${orderId.substring(0, 8)}_${DateTime.now().millisecondsSinceEpoch % 10000}';
          
          // Buscar kind 30081 (complete) e kind 30080 (payment proof)
          final filters = <Map<String, dynamic>>[];
          
          // Filter 1: kind 30081 complete por #d tag = '{orderId}_complete'
          filters.add({
            'kinds': [kindBroComplete],
            '#d': ['${orderId}_complete'],
            'limit': 10,
          });
          
          // Filter 2: kind 30080 por #r tag (reference ao orderId) - funciona!
          filters.add({
            'kinds': [kindBroPaymentProof],
            '#r': [orderId],
            'limit': 10,
          });
          
          // Filter 3: por #t bro-complete (fallback mais amplo, filtrar por content)
          filters.add({
            'kinds': [kindBroComplete],
            '#t': ['bro-complete'],
            'limit': 20,
          });
          
          // Filter 4: se conhecemos o provedor, buscar por autor
          if (providerPubkey != null && providerPubkey.isNotEmpty) {
            filters.add({
              'kinds': [kindBroComplete, kindBroPaymentProof],
              'authors': [providerPubkey],
              'limit': 20,
            });
          }
          
          // Enviar todos os filters
          for (int i = 0; i < filters.length; i++) {
            channel.sink.add(jsonEncode(['REQ', '${subId}_$i', filters[i]]));
          }
          
          int eoseCount = 0;
          await for (final msg in channel.stream.timeout(const Duration(seconds: 10), onTimeout: (sink) => sink.close())) {
            final data = jsonDecode(msg.toString());
            if (data is List && data.length >= 3 && data[0] == 'EVENT') {
              final eventData = data[2] as Map<String, dynamic>;
              try {
                final content = jsonDecode(eventData['content'] as String) as Map<String, dynamic>;
                final eventOrderId = content['orderId'] as String?;
                
                // Filtrar pelo orderId correto
                if (eventOrderId != orderId) continue;
                
                // Extrair providerId se disponível
                final eventProviderId = content['providerId'] as String?;
                if (eventProviderId != null && eventProviderId.isNotEmpty) {
                  result['providerPubkey'] = eventProviderId;
                }
                
                // Verificar proofImage
                final proofImage = content['proofImage'] as String?;
                final proofImageNip44 = content['proofImage_nip44'] as String?;
                
                if (proofImage != null && proofImage.isNotEmpty && proofImage != '[encrypted:nip44v2]') {
                  // Plaintext - perfeito
                  result['proofImage'] = proofImage;
                  result['encrypted'] = false;
                  debugPrint('✅ Comprovante plaintext encontrado para ${orderId.substring(0, 8)}');
                } else if (proofImageNip44 != null && proofImageNip44.isNotEmpty) {
                  // Existe mas é criptografado
                  if (result['proofImage'] == null) {
                    result['encrypted'] = true;
                    result['proofImage_nip44'] = proofImageNip44;
                  }
                  debugPrint('🔐 Comprovante NIP-44 criptografado para ${orderId.substring(0, 8)}');
                } else if (proofImage == '[encrypted:nip44v2]') {
                  if (result['proofImage'] == null) {
                    result['encrypted'] = true;
                  }
                }
              } catch (_) {}
            }
            if (data is List && data[0] == 'EOSE') {
              eoseCount++;
              if (eoseCount >= filters.length) break;
            }
          }
          
          for (int i = 0; i < filters.length; i++) {
            channel.sink.add(jsonEncode(['CLOSE', '${subId}_$i']));
          }
          channel.sink.close();
          
          // Se já encontrou plaintext, parar
          if (result['proofImage'] != null && result['encrypted'] == false) break;
        } catch (e) {
          debugPrint('⚠️ fetchProofForOrder relay error: $e');
        }
      }
      
      debugPrint('🔍 fetchProofForOrder: orderId=${orderId.substring(0, 8)}, found=${result['proofImage'] != null}, encrypted=${result['encrypted']}');
      return result;
    } catch (e) {
      debugPrint('❌ fetchProofForOrder EXCEPTION: $e');
      return {'proofImage': null, 'encrypted': false};
    }
  }

  /// Busca o provedor que aceitou uma ordem (via kind 30079 accept event)
  /// Retorna o pubkey do provedor ou null
  /// CORREÇÃO build 216: Usar #d tag (single-letter, suportada por relays)
  /// em vez de #orderId (multi-char, NÃO suportada por relays)
  Future<String?> fetchOrderProviderPubkey(String orderId) async {
    try {
      for (final relay in _relays.take(3)) {
        try {
          // Estratégia 1: Buscar por #d tag = '{orderId}_accept' (accept event padrão)
          var events = await _fetchFromRelay(
            relay,
            kinds: [kindBroAccept],
            tags: {'#d': ['${orderId}_accept']},
            limit: 5,
          ).timeout(const Duration(seconds: 8), onTimeout: () => <Map<String, dynamic>>[]);
          
          // Estratégia 2: Se não encontrou, buscar por #t bro-accept e filtrar por content
          if (events.isEmpty) {
            events = await _fetchFromRelay(
              relay,
              kinds: [kindBroAccept],
              tags: {'#t': ['bro-accept']},
              limit: 30,
            ).timeout(const Duration(seconds: 8), onTimeout: () => <Map<String, dynamic>>[]);
          }
          
          // Estratégia 3: Buscar por #r (updates que têm referência ao orderId)
          if (events.isEmpty) {
            events = await _fetchFromRelay(
              relay,
              kinds: [kindBroPaymentProof, kindBroComplete],
              tags: {'#r': [orderId]},
              limit: 10,
            ).timeout(const Duration(seconds: 8), onTimeout: () => <Map<String, dynamic>>[]);
          }
          
          for (final event in events) {
            try {
              final content = event['parsedContent'] ?? jsonDecode(event['content']);
              if (content['orderId'] == orderId) {
                // Tentar providerId do content
                final providerId = content['providerId'] as String?;
                if (providerId != null && providerId.isNotEmpty) {
                  debugPrint('\u2705 fetchOrderProviderPubkey: ${providerId.substring(0, 8)} para ordem ${orderId.substring(0, 8)}');
                  return providerId;
                }
                // Fallback: usar pubkey do autor do evento (quem aceitou = provedor)
                final eventPubkey = event['pubkey'] as String?;
                if (eventPubkey != null && eventPubkey.isNotEmpty) {
                  debugPrint('\u2705 fetchOrderProviderPubkey (author): ${eventPubkey.substring(0, 8)} para ordem ${orderId.substring(0, 8)}');
                  return eventPubkey;
                }
              }
            } catch (_) {}
          }
        } catch (_) {}
      }
      debugPrint('\uD83D\uDD0D fetchOrderProviderPubkey: n\u00e3o encontrado para ${orderId.substring(0, 8)}');
      return null;
    } catch (e) {
      debugPrint('\u274C fetchOrderProviderPubkey EXCEPTION: $e');
      return null;
    }
  }
}
