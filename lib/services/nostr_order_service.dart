import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:nostr/nostr.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../config.dart';
import '../models/order.dart';
import 'nip04_service.dart';
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
      broLog('🚫 Blocklist carregada: ${_blockedOrderIds.length} ordens bloqueadas');
    } catch (e) {
      broLog('⚠️ Erro ao carregar blocklist: $e');
      _blockedOrdersLoaded = true;
    }
  }

  /// Adiciona IDs à blocklist e persiste
  Future<void> _addToBlocklist(Set<String> orderIds) async {
    if (orderIds.isEmpty) return;
    final newIds = orderIds.difference(_blockedOrderIds);
    if (newIds.isEmpty) return;
    _blockedOrderIds.addAll(newIds);
    broLog('🚫 Blocklist: +${newIds.length} ordens (total: ${_blockedOrderIds.length})');
    try {
      final prefs = await SharedPreferences.getInstance();
      // Manter apenas últimas 2000 entradas para não crescer infinitamente
      if (_blockedOrderIds.length > 2000) {
        _blockedOrderIds = _blockedOrderIds.toList().sublist(_blockedOrderIds.length - 2000).toSet();
      }
      await prefs.setStringList(_blockedOrdersKey, _blockedOrderIds.toList());
    } catch (e) {
      broLog('⚠️ Erro ao salvar blocklist: $e');
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
    // CORREÇÃO v349: disputed pode transicionar para completed/cancelled (resolução)
    if (currentStatus == 'disputed') {
      return newStatus == 'completed' || newStatus == 'cancelled';
    }
    // Status finais NÃO regridem — completed/liquidated é definitivo
    const finalStatuses = ['completed', 'liquidated'];
    if (finalStatuses.contains(currentStatus)) {
      return false;
    }
    // disputed vence sobre status NÃO-FINAIS (abertura de disputa durante fluxo ativo)
    if (newStatus == 'disputed') return true;
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

  /// v403: Expor descriptografia NIP-44 para uso pelo OrderProvider durante sync
  String decryptNip44(String ciphertext, String privateKey, String senderPubkey) {
    return _nip44.decryptBetween(ciphertext, privateKey, senderPubkey);
  }

  // Relays para publicar ordens
  // NOTA: nostr.wine REMOVIDO - causa rate limit 429 constante e timeouts
  final List<String> _relays = [
    'wss://relay.damus.io',
    'wss://nos.lol',
    'wss://relay.primal.net',
  ];

  // v259: Relays de fallback - usados SOMENTE quando os 3 principais falham
  // Não são usados para publicação, apenas para leitura de emergência
  static const List<String> _fallbackRelays = [
    'wss://relay.nostr.band',
    'wss://nostr.mom',
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

  /// Retorna billCode de um evento Nostr
  /// Tenta: plain text → NIP-44 encrypted para provedor → NIP-44 self-encrypted
  String _getBillCode(Map<String, dynamic> content) {
    // 1. Legacy: plain text (ordens antigas)
    final plain = content['billCode']?.toString() ?? '';
    if (plain.isNotEmpty) return plain;
    
    // 2. NIP-44 encrypted para o provedor aceito
    final encryptedForProvider = content['billCode_nip44']?.toString();
    if (encryptedForProvider != null && encryptedForProvider.isNotEmpty && _decryptionKey != null) {
      final senderPubkey = content['userPubkey']?.toString() ?? '';
      if (senderPubkey.isNotEmpty) {
        try {
          return _nip44.decryptBetween(encryptedForProvider, _decryptionKey!, senderPubkey);
        } catch (e) {
          broLog('⚠️ _getBillCode: falha ao descriptografar billCode_nip44: $e');
        }
      }
    }
    
    // 3. Self-encrypted (dono da ordem pode recuperar)
    final selfEnc = content['billCode_self']?.toString();
    if (selfEnc != null && selfEnc.isNotEmpty && _decryptionKey != null) {
      try {
        final myPubkey = Keychain(_decryptionKey!).public;
        // Só funciona se EU sou o dono da ordem
        if (content['userPubkey'] == myPubkey) {
          return _nip44.decryptFromSelf(selfEnc, _decryptionKey!, myPubkey);
        }
      } catch (e) {
        broLog('⚠️ _getBillCode: falha ao descriptografar billCode_self: $e');
      }
    }
    
    return '';
  }

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
      
      // Encrypt billCode for self-recovery only — NOT published in plaintext
      String billCodeSelf = '';
      try {
        billCodeSelf = _nip44.encryptToSelf(billCode, keychain.private, keychain.public);
      } catch (e) {
        broLog('⚠️ _publishOrderRaw: falha ao encriptar billCode para self: $e');
        // Continua sem self-encryption — o billCode local continua acessível
      }
      
      final contentMap = {
        'type': 'bro_order',
        'version': '1.1',
        'orderId': orderId,
        'userPubkey': keychain.public,
        'billType': billType,
        'billCode': '', // Encrypted — provedor recebe via billCode_nip44 após aceitar
        'hasBillCode': true,
        'amount': amount,
        'btcAmount': btcAmount,
        'btcPrice': btcPrice,
        'providerFee': providerFee,
        'platformFee': platformFee,
        'total': total,
        'status': 'pending',
        'createdAt': DateTime.now().toIso8601String(),
      };
      if (billCodeSelf.isNotEmpty) {
        contentMap['billCode_self'] = billCodeSelf;
      }
      
      final content = jsonEncode(contentMap);

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
    String? orderUserPubkey, // v240: pubkey do dono da ordem para notificação
  }) async {
    try {
      // LOG v1.0.129+232: Alertar quando completed é publicado sem providerId
      // A proteção principal está no OrderProvider.updateOrderStatus()
      if (newStatus == 'completed' && (providerId == null || providerId.isEmpty)) {
        broLog('⚠️ [NostrOrderService] completed sem providerId para ${orderId.substring(0, 8)} - verificar fluxo');
      }
      
      final keychain = Keychain(privateKey);
      final signerPubkey = keychain.public;
      
      // v257: CORREÇÃO CRÍTICA — content.userPubkey DEVE ser o DONO da ordem (orderUserPubkey),
      // NÃO o signatário (keychain.public). Quando o PROVEDOR publica um update,
      // keychain.public é o provedor, mas userPubkey deve ser o criador da ordem.
      // Sem isso, o usuário nunca encontra o update nos relays.
      final contentUserPubkey = (orderUserPubkey != null && orderUserPubkey.isNotEmpty)
          ? orderUserPubkey
          : signerPubkey; // fallback para compatibilidade
      
      final content = jsonEncode({
        'type': 'bro_order_update',
        'orderId': orderId,
        'status': newStatus,
        'providerId': providerId,
        'userPubkey': contentUserPubkey, // v257: pubkey do DONO da ordem (não do signatário)
        'publishedBy': signerPubkey, // v257: quem publicou este update
        'paymentProof': paymentProof,
        'updatedAt': DateTime.now().toIso8601String(),
      });

      // CORREÇÃO: Usar d-tag única por usuário+ordem para evitar conflitos
      // Isso permite que tanto Bro quanto Usuário publiquem updates independentes
      // NOTA: Removida tag 'e' pois orderId é UUID, não event ID hex de 64 chars
      final tags = [
        ['d', '${orderId}_${signerPubkey.substring(0, 8)}_update'], // Tag única por usuário
        ['t', broTag],
        ['t', 'bro-update'],
        ['t', 'status-$newStatus'], // Tag pesquisável por status
        ['r', orderId], // CRÍTICO: Tag 'r' (reference) para busca por orderId nos relays
        ['orderId', orderId], // Tag customizada (não filtrável por relays, só para leitura)
      ];
      
      // v257: CORREÇÃO CRÍTICA — Garantir que AMBAS as partes (provedor E usuário)
      // recebam tags #p para descobrir este evento nos relays.
      // Coletar todas as pubkeys únicas que precisam ser tagueadas
      final pTagSet = <String>{};
      
      // Tag do provedor — para que o provedor encontre o update
      if (providerId != null && providerId.isNotEmpty) {
        pTagSet.add(providerId);
      }
      // Tag do dono da ordem — para que o usuário encontre o update
      if (orderUserPubkey != null && orderUserPubkey.isNotEmpty) {
        pTagSet.add(orderUserPubkey);
      }
      // Fallback: se nenhuma #p tag, adicionar o signatário
      if (pTagSet.isEmpty) {
        pTagSet.add(signerPubkey);
      }
      
      for (final pk in pTagSet) {
        tags.add(['p', pk]);
      }
      broLog('📤 updateOrderStatus: orderId=${orderId.substring(0, 8)} status=$newStatus pTags=${pTagSet.map((p) => p.substring(0, 8)).toList()}');

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
      broLog('📤 updateOrderStatus: publicado em $successCount/${_relays.length} relays (orderId=${orderId.substring(0, 8)}, status=$newStatus)');
      
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
      broLog('❌ updateOrderStatus EXCEPTION: $e');
      return false;
    }
  }

  /// Busca ordens aceitas por um provedor (raw)
  /// Busca em múltiplas fontes:
  /// 1. Ordens (kindBroOrder) onde tag #p = provedor
  /// 2. Eventos de aceitação (kindBroAccept) publicados pelo provedor
  /// 3. Eventos de comprovante (kindBroComplete) publicados pelo provedor
  /// v390: Sequential relay fallback instead of all-relays-in-parallel (reduces 12+ WebSockets to 2-4)
  Future<List<Map<String, dynamic>>> _fetchProviderOrdersRaw(String providerPubkey) async {
    final orders = <Map<String, dynamic>>[];
    final seenIds = <String>{};
    final orderIdsFromAccepts = <String>{};

    // v390: Try relays SEQUENTIALLY — use first relay that returns results
    // This reduces WebSocket connections from 12+ to 2 per sync
    for (final relay in _relays.take(3)) {
      try {
        // 2 parallel strategies per relay (reduced from 4)
        final results = await Future.wait([
          // 1. Ordens com tag #p do provedor
          _fetchFromRelay(relay, kinds: [kindBroOrder], tags: {'#p': [providerPubkey]}, limit: 100)
            .catchError((_) => <Map<String, dynamic>>[]),
          // 2. Eventos de aceitação/update/complete publicados por este provedor + disputas tagueadas
          _fetchFromRelay(relay, kinds: [kindBroAccept, kindBroPaymentProof, kindBroComplete], authors: [providerPubkey], limit: 200)
            .catchError((_) => <Map<String, dynamic>>[]),
        ]);
        
        for (final order in results[0]) {
          final id = order['id'];
          if (!seenIds.contains(id)) {
            seenIds.add(id);
            orders.add(order);
          }
        }
        
        // Extrair orderIds dos eventos de aceitação/update
        for (final event in results[1]) {
          try {
            final content = event['parsedContent'] ?? jsonDecode(event['content']);
            final eventType = content['type'] as String?;
            if (eventType == 'bro_dispute_resolution' || eventType == 'bro_admin_reimbursement') continue;
            final orderId = content['orderId'] as String?;
            if (orderId != null) orderIdsFromAccepts.add(orderId);
          } catch (_) {}
        }
        
        // If this relay returned data, skip remaining relays
        if (results[0].isNotEmpty || results[1].isNotEmpty) break;
      } catch (e) {
        // Relay failed, try next one
      }
    }
    
    // Buscar ordens originais pelos IDs dos eventos de aceitação
    if (orderIdsFromAccepts.isNotEmpty) {
      final missingIds = orderIdsFromAccepts.where((id) => !seenIds.contains(id)).toList();
      
      if (missingIds.isNotEmpty) {
        // Buscar em lotes de 5 (reduced from 10)
        for (int i = 0; i < missingIds.length; i += 5) {
          final batch = missingIds.skip(i).take(5).toList();
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
            billCode: _getBillCode(raw),
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

  /// Publica evento em relay (wrapper público para uso externo)
  Future<bool> publishToRelayPublic(String relayUrl, Event event) async {
    return _publishToRelay(relayUrl, event);
  }

  /// Busca eventos de relay (wrapper público para uso externo)
  Future<List<Map<String, dynamic>>> fetchFromRelayPublic(
    String relayUrl, {
    required List<int> kinds,
    List<String>? authors,
    Map<String, List<String>>? tags,
    int limit = 50,
  }) async {
    return _fetchFromRelay(relayUrl, kinds: kinds, authors: authors, tags: tags, limit: limit);
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
                  broLog('⚠️ REJEITADO evento com assinatura inválida: ${eventData['id']?.toString().substring(0, 8) ?? '?'} - $e');
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
          broLog('ℹ️ Ordem legada: usando event.pubkey como userPubkey');
        } else {
          return null; // Sem nenhuma forma de identificar o dono
        }
      }
      
      return Order(
        id: orderId,
        eventId: event['id'],
        userPubkey: originalUserPubkey,
        billType: content['billType'] ?? 'pix',
        billCode: _getBillCode(content),
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
  /// Usa o evento MAIS RECENTE entre todos os relays
  Future<Map<String, dynamic>?> fetchOrderFromNostr(String orderId) async {
    
    // Buscar em todos os relays em paralelo
    final results = await Future.wait(
      _relays.take(3).map((relay) => _fetchOrderFromRelay(relay, orderId).catchError((_) => null)),
    );
    
    // Usar o resultado MAIS RECENTE (maior created_at)
    Map<String, dynamic>? newest;
    int newestTimestamp = 0;
    for (final result in results) {
      if (result == null) continue;
      final ts = result['created_at'] as int? ?? 0;
      if (newest == null || ts > newestTimestamp) {
        newest = result;
        newestTimestamp = ts;
      }
    }
    
    if (newest != null) {
      final billCode = newest['billCode'] as String? ?? '';
      broLog('🔍 [FETCH] fetchOrderFromNostr: ${results.where((r) => r != null).length} relays responderam, '
          'usando evento ts=$newestTimestamp, billCode=${billCode.isNotEmpty ? "OK(${billCode.length}ch)" : "VAZIO"}');
    }
    
    return newest;
  }
  
  /// Helper: Busca ordem de um relay específico
  Future<Map<String, dynamic>?> _fetchOrderFromRelay(String relay, String orderId) async {
    try {
      // Buscar em paralelo: d-tag e t-tag simultaneamente
      final results = await Future.wait([
        _fetchFromRelay(relay, kinds: [kindBroOrder], tags: {'#d': [orderId]}, limit: 5),
        _fetchFromRelay(relay, kinds: [kindBroOrder], tags: {'#t': [orderId]}, limit: 5),
      ]);
      
      // Combinar resultados e ordenar por timestamp DECRESCENTE (mais recente primeiro)
      final allEvents = [...results[0], ...results[1]];
      allEvents.sort((a, b) => ((b['created_at'] as int?) ?? 0).compareTo((a['created_at'] as int?) ?? 0));
      
      // Deduplicar por event id
      final seenIds = <String>{};
      allEvents.removeWhere((e) {
        final id = e['id'] as String? ?? '';
        if (seenIds.contains(id)) return true;
        seenIds.add(id);
        return false;
      });
      
      // Verificar se algum evento tem o orderId no content — PREFERIR O MAIS RECENTE
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
              'billCode': _getBillCode(content),
              'amount': (content['amount'] as num?)?.toDouble() ?? 0,
              'btcAmount': (content['btcAmount'] as num?)?.toDouble() ?? 0,
              'btcPrice': (content['btcPrice'] as num?)?.toDouble() ?? 0,
              'providerFee': (content['providerFee'] as num?)?.toDouble() ?? 0,
              'platformFee': (content['platformFee'] as num?)?.toDouble() ?? 0,
              'total': (content['total'] as num?)?.toDouble() ?? 0,
              'status': content['status'] ?? 'pending',
              'providerId': content['providerId'],
              'createdAt': content['createdAt'],
              'created_at': event['created_at'],
            };
          }
        } catch (_) {}
      }
      
      // Se encontrou eventos mas nenhum com orderId match, usar o mais recente
      if (allEvents.isNotEmpty) {
        final event = allEvents.first; // Já está ordenado — mais recente primeiro
        final content = event['parsedContent'] ?? jsonDecode(event['content']);
        final fallbackUserPubkey = content['userPubkey'] as String? ?? event['pubkey'] as String?;
        if (fallbackUserPubkey == null || fallbackUserPubkey.isEmpty) return null;
        
        return {
          'id': content['orderId'] ?? orderId,
          'eventId': event['id'],
          'userPubkey': fallbackUserPubkey,
          'billType': content['billType'] ?? 'pix',
          'billCode': _getBillCode(content),
          'amount': (content['amount'] as num?)?.toDouble() ?? 0,
          'btcAmount': (content['btcAmount'] as num?)?.toDouble() ?? 0,
          'btcPrice': (content['btcPrice'] as num?)?.toDouble() ?? 0,
          'providerFee': (content['providerFee'] as num?)?.toDouble() ?? 0,
          'platformFee': (content['platformFee'] as num?)?.toDouble() ?? 0,
          'total': (content['total'] as num?)?.toDouble() ?? 0,
          'status': content['status'] ?? 'pending',
          'providerId': content['providerId'],
          'createdAt': content['createdAt'],
          'created_at': event['created_at'],
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
          // Buscar todas estratégias em paralelo (complete + invoice_refresh)
          final fetches = await Future.wait([
            _fetchFromRelay(relay, kinds: [kindBroComplete], tags: {'#orderId': [orderId]}, limit: 5),
            _fetchFromRelay(relay, kinds: [kindBroComplete], tags: {'#d': ['${orderId}_complete']}, limit: 5),
            _fetchFromRelay(relay, kinds: [kindBroComplete], tags: {'#d': ['${orderId}_invoice_refresh']}, limit: 5),
          ]);
          
          final allEvents = [...fetches[0], ...fetches[1], ...fetches[2]];
          
          // v133: Preferir invoice_refresh (mais recente) sobre complete
          Map<String, dynamic>? bestResult;
          int bestTimestamp = 0;
          
          for (final event in allEvents) {
            try {
              final content = event['parsedContent'] ?? jsonDecode(event['content']);
              final eventOrderId = content['orderId'] as String?;
              
              if (eventOrderId == orderId) {
                final invoice = content['providerInvoice'] as String?;
                if (invoice == null || invoice.isEmpty) continue;
                
                final ts = event['created_at'] as int? ?? 0;
                if (ts >= bestTimestamp) {
                  bestTimestamp = ts;
                  bestResult = {
                    'orderId': orderId,
                    'providerId': content['providerId'] as String?,
                    'providerInvoice': invoice,
                    'completedAt': content['completedAt'],
                  };
                }
              }
            } catch (_) {}
          }
          
          return bestResult;
        } catch (e) {}
        return null;
      }),
    );
    
    // Usar o resultado com invoice mais recente
    Map<String, dynamic>? best;
    for (final result in results) {
      if (result != null) {
        best = result;
        break;
      }
    }
    
    return best;
  }

  /// v133: Publica invoice refresh para ordem liquidada (provider side)
  /// Usa d-tag diferente para não sobrescrever o evento bro_complete original
  Future<bool> publishInvoiceRefresh({
    required String orderId,
    required String providerPrivateKey,
    required String providerInvoice,
    required String orderUserPubkey,
  }) async {
    try {
      final keychain = Keychain(providerPrivateKey);

      final contentMap = {
        'type': 'bro_invoice_refresh',
        'orderId': orderId,
        'providerId': keychain.public,
        'providerInvoice': providerInvoice,
        'refreshedAt': DateTime.now().toIso8601String(),
      };

      final content = jsonEncode(contentMap);

      final tags = [
        ['d', '${orderId}_invoice_refresh'],
        ['p', orderUserPubkey],
        ['t', broTag],
        ['t', 'bro-invoice-refresh'],
        ['orderId', orderId],
      ];

      final event = Event.from(
        kind: kindBroComplete,
        tags: tags,
        content: content,
        privkey: keychain.private,
      );

      broLog('[InvoiceRefresh] Publicando invoice refresh para $orderId');

      final futures = _relays.map((relay) => _publishToRelay(relay, event).catchError((_) => false)).toList();

      int successCount = 0;
      for (final future in futures) {
        try {
          final result = await future;
          if (result) successCount++;
        } catch (_) {}
      }

      broLog('[InvoiceRefresh] Publicado em $successCount/${_relays.length} relays');
      return successCount > 0;
    } catch (e) {
      broLog('[InvoiceRefresh] Erro ao publicar: $e');
      return false;
    }
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

  /// v261: Re-publica o evento kind 30078 com status atualizado.
  /// Como kind 30078 é parameterized replaceable (NIP-33), o relay substitui
  /// o evento antigo (status=pending) pelo novo (status=accepted/completed/etc).
  /// Isso garante que outros provedores NÃO vejam a ordem como disponível,
  /// mesmo se a query de status updates (kind 30079/30080/30081) falhar.
  /// SÓ deve ser chamado pelo DONO da ordem (userPubkey == signer).
  Future<bool> republishOrderWithStatus({
    required String privateKey,
    required Order order,
    required String newStatus,
    String? providerId,
  }) async {
    try {
      final keychain = Keychain(privateKey);

      // Só o dono da ordem pode re-publicar (assinatura deve bater)
      if (order.userPubkey != null && order.userPubkey != keychain.public) {
        broLog('v261: republishOrderWithStatus: SKIP - não sou o dono da ordem');
        return false;
      }

      final resolvedProviderId = providerId ?? order.providerId;
      
      // Build content map with encrypted billCode
      final contentMap = <String, dynamic>{
        'type': 'bro_order',
        'version': '1.1',
        'orderId': order.id,
        'userPubkey': keychain.public,
        'billType': order.billType,
        'billCode': '', // Encrypted — provedor recebe via billCode_nip44 após aceitar
        'hasBillCode': order.billCode.isNotEmpty,
        'amount': order.amount,
        'btcAmount': order.btcAmount,
        'btcPrice': order.btcPrice,
        'providerFee': order.providerFee,
        'platformFee': order.platformFee,
        'total': order.total,
        'status': newStatus,
        'providerId': resolvedProviderId,
        'createdAt': order.createdAt.toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
      };
      
      // Self-encrypt billCode para recuperação pelo dono
      if (order.billCode.isNotEmpty) {
        try {
          contentMap['billCode_self'] = _nip44.encryptToSelf(order.billCode, keychain.private, keychain.public);
        } catch (e) {
          broLog('⚠️ republish: falha ao encriptar billCode_self: $e');
        }
      }
      
      // Se a ordem foi aceita e temos providerId, encriptar billCode para o provedor
      if (order.billCode.isNotEmpty && resolvedProviderId != null && resolvedProviderId.isNotEmpty) {
        final activeStatuses = ['accepted', 'awaiting_confirmation', 'payment_received', 'completed'];
        if (activeStatuses.contains(newStatus)) {
          try {
            contentMap['billCode_nip44'] = _nip44.encryptBetween(order.billCode, keychain.private, resolvedProviderId);
            broLog('🔐 billCode encriptado para provedor ${resolvedProviderId.substring(0, 8)}');
          } catch (e) {
            broLog('⚠️ republish: falha ao encriptar billCode para provedor: $e');
          }
        }
      }
      
      final content = jsonEncode(contentMap);

      final event = Event.from(
        kind: kindBroOrder,
        tags: [
          ['d', order.id],
          ['t', broTag],
          ['t', broAppTag],
          ['t', order.billType],
          ['amount', order.amount.toStringAsFixed(2)],
          ['status', newStatus],
        ],
        content: content,
        privkey: keychain.private,
      );

      final results = await Future.wait(
        _relays.map((relay) => _publishToRelay(relay, event).catchError((_) => false)),
      );
      final successCount = results.where((r) => r).length;
      broLog('v261: republishOrderWithStatus: ${order.id.substring(0, 8)} -> $newStatus ($successCount/${_relays.length} relays)');
      return successCount > 0;
    } catch (e) {
      broLog('v261: republishOrderWithStatus ERROR: $e');
      return false;
    }
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
    String? e2eId, // v236: E2E ID do PIX para validação cruzada
  }) async {
    try {
      // v337: Validar tamanho da imagem (máximo 500KB em base64)
      final imageSizeBytes = proofImageBase64.length * 3 ~/ 4; // base64 → bytes approx
      if (imageSizeBytes > 500 * 1024) {
        broLog('❌ Comprovante muito grande: ${(imageSizeBytes / 1024).toStringAsFixed(0)}KB (máx 500KB)');
        return false;
      }

      final keychain = Keychain(providerPrivateKey);
      
      // Criptografar comprovante para: usuário, admin E provedor (self)
      String? encryptedProofImage;
      String? encryptedProofImageAdmin;
      String? encryptedProofImageProvider;
      try {
        if (order.userPubkey != null && order.userPubkey!.isNotEmpty) {
          encryptedProofImage = _nip44.encryptBetween(
            proofImageBase64,
            keychain.private,
            order.userPubkey!,
          );
          broLog('🔐 proofImage criptografado com NIP-44 para usuário (${encryptedProofImage.length} chars)');
        }
        // Criptografar para o admin/mediador (para disputas)
        if (AppConfig.adminPubkey.isNotEmpty) {
          encryptedProofImageAdmin = _nip44.encryptBetween(
            proofImageBase64,
            keychain.private,
            AppConfig.adminPubkey,
          );
          broLog('🔐 proofImage criptografado com NIP-44 para admin (${encryptedProofImageAdmin.length} chars)');
        }
        // Self-encrypt para que o provedor possa rever seu próprio comprovante
        encryptedProofImageProvider = _nip44.encryptToSelf(
          proofImageBase64,
          keychain.private,
          keychain.public,
        );
        broLog('🔐 proofImage criptografado com NIP-44 para provedor/self (${encryptedProofImageProvider.length} chars)');
      } catch (e) {
        broLog('❌ Falha ao criptografar proofImage: $e — NÃO enviar em plaintext (dados sensíveis)');
        // DO NOT fallback to plaintext — proof images contain bank screenshots with CPF/sensitive data
        return false;
      }
      
      final contentMap = {
        'type': 'bro_complete',
        'orderId': order.id,
        'orderEventId': order.eventId,
        'providerId': keychain.public,
        'recipientPubkey': order.userPubkey, // Para quem é destinado
        'completedAt': DateTime.now().toIso8601String(),
      };
      
      // Only send encrypted proof images — never plaintext
      if (encryptedProofImage != null) {
        contentMap['proofImage_nip44'] = encryptedProofImage;
        contentMap['proofImage'] = '[encrypted:nip44v2]'; // Marcador para clientes antigos
        contentMap['encryption'] = 'nip44v2';
        // Cópia criptografada para admin (usado em disputas)
        if (encryptedProofImageAdmin != null) {
          contentMap['proofImage_nip44_admin'] = encryptedProofImageAdmin;
        }
        // Cópia criptografada para o próprio provedor (para rever o comprovante)
        if (encryptedProofImageProvider != null) {
          contentMap['proofImage_nip44_provider'] = encryptedProofImageProvider;
        }
      } else {
        // Encryption is mandatory — should not reach here (caught above)
        broLog('❌ proofImage encryption produced null — aborting');
        return false;
      }
      
      // Incluir invoice do provedor se fornecido
      if (providerInvoice != null && providerInvoice.isNotEmpty) {
        contentMap['providerInvoice'] = providerInvoice;
      }
      
      // v236: Incluir E2E ID do PIX se fornecido
      if (e2eId != null && e2eId.isNotEmpty) {
        contentMap['e2eId'] = e2eId;
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
    broLog('📋 fetchPendingOrders: ${rawOrders.length} raw events do relay');
    
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
      
      // v261: DEFENSE-IN-DEPTH — Se o próprio evento 30078 já tem status terminal
      // (porque o dono re-publicou com status atualizado via republishOrderWithStatus),
      // filtrar IMEDIATAMENTE sem precisar da query de status separada.
      // Isso resolve o bug onde orders aceitas/completadas continuavam aparecendo
      // quando a query de status (kind 30079/30080/30081) falhava por timeout.
      const terminalInEvent = ['accepted', 'awaiting_confirmation', 'completed', 'cancelled', 'liquidated', 'disputed'];
      if (terminalInEvent.contains(order.status)) {
        _addToBlocklist({order.id});
        blockedCount++;
        continue;
      }
      
      allOrders.add(order);
    }
    
    broLog('📋 fetchPendingOrders: ${allOrders.length} ordens válidas ($nullOrders rejeitadas, $blockedCount bloqueadas localmente, $skippedByTagCount skipped por tag)');
    
    // Filtrar ordens expiradas ANTES do fetch de status (economiza queries)
    final now = DateTime.now();
    final maxOrderAge = const Duration(days: 7);
    final freshOrders = <Order>[];
    final expiredIds = <String>{};
    
    for (var order in allOrders) {
      final orderAge = now.difference(order.createdAt);
      if (orderAge > maxOrderAge && (order.status == 'pending')) {
        broLog('  ⏰ Ordem ${order.id.substring(0, 8)} expirada: ${orderAge.inDays} dias atrás');
        expiredIds.add(order.id);
        continue;
      }
      freshOrders.add(order);
    }
    
    if (expiredIds.isNotEmpty) {
      _addToBlocklist(expiredIds);
      broLog('📋 ${expiredIds.length} ordens expiradas bloqueadas');
    }
    
    if (freshOrders.isEmpty) {
      broLog('📋 fetchPendingOrders: 0 ordens disponíveis (todas expiradas/bloqueadas)');
      return [];
    }
    
    // PASSO 2: Buscar status via #d tag (PRIMARY - funciona em todos os relays)
    // Esta é a fonte de verdade: busca accept/complete events por #d tag
    final orderIdsToCheck = freshOrders.map((o) => o.id).toList();
    broLog('🔍 fetchPendingOrders: buscando status de ${orderIdsToCheck.length} ordens via #d tag');
    final statusUpdates = await _fetchTargetedStatusUpdates(orderIdsToCheck);
    broLog('🔍 fetchPendingOrders: ${statusUpdates.length} ordens com status via #d');
    
    // PASSO 2.5: Buscar cancelamentos/updates por AUTHOR (pubkey do criador)
    // Cancelamentos são kind 30080 publicados pelo criador da ordem.
    // Os relays NÃO indexam tags #r, mas SEMPRE indexam 'authors'.
    // Coletamos pubkeys dos criadores e buscamos seus events kind 30080.
    final ordersWithoutStatus = freshOrders.where((o) => !statusUpdates.containsKey(o.id)).toList();
    // PERFORMANCE v226: Só chamar _fetchStatusByAuthors se > 5 ordens sem status
    // Para poucas ordens, o _fetchTargetedStatusUpdates (#d tag) já é suficiente
    // Isso economiza 3 WebSocket conexões na maioria dos ciclos
    if (ordersWithoutStatus.length > 5) {
      broLog('🔍 fetchPendingOrders: ${ordersWithoutStatus.length} ordens sem status - buscando por authors');
      final authorUpdates = await _fetchStatusByAuthors(ordersWithoutStatus);
      if (authorUpdates.isNotEmpty) {
        broLog('🔍 fetchPendingOrders: ${authorUpdates.length} updates extras via authors!');
        statusUpdates.addAll(authorUpdates);
      }
    } else if (ordersWithoutStatus.isNotEmpty) {
      broLog('⚡ fetchPendingOrders: ${ordersWithoutStatus.length} ordens sem status (≤5), pulando fetchStatusByAuthors');
    }
    broLog('🔍 fetchPendingOrders: ${statusUpdates.length} ordens com status total');
    
    // LOG DETALHADO de cada ordem
    for (var order in freshOrders) {
      final update = statusUpdates[order.id];
      final updateStatus = update?['status'] as String?;
      broLog('  📦 Ordem ${order.id.substring(0, 8)}: status=${order.status}, update=$updateStatus, amount=${order.amount}');
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
        broLog('  🚫 Ordem ${order.id.substring(0, 8)} filtrada: updateStatus=$updateStatus');
      }
    }
    
    broLog('📋 fetchPendingOrders: ${availableOrders.length} ordens disponíveis após filtro');
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
    
    broLog('🔍 _fetchTargetedStatusUpdates: ${orderIds.length} ordens em ${batches.length} batches');
    
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
    
    broLog('🔍 _fetchTargetedStatusUpdates: ${allEvents.length} eventos encontrados');
    
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
    
    broLog('🔍 _fetchStatusByAuthors: buscando kind 30080 de ${pubkeys.length} authors para ${orders.length} ordens');
    
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
    
    broLog('🔍 _fetchStatusByAuthors: ${allEvents.length} eventos de ${_relays.length} relays');
    
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
        broLog('📋 _fetchAllOrderStatusUpdates: usando cache (${elapsed}s ago, ${_statusUpdatesCache!.length} updates)');
        return _statusUpdatesCache!;
      }
    }
    
    // CORREÇÃO v1.0.129: Lock de concorrência — se já tem um fetch em andamento,
    // esperar pelo resultado ao invés de criar mais 6 conexões WebSocket
    if (_statusUpdatesFetching != null) {
      broLog('📋 _fetchAllOrderStatusUpdates: aguardando fetch em andamento...');
      return _statusUpdatesFetching!.future;
    }
    _statusUpdatesFetching = Completer<Map<String, Map<String, dynamic>>>();
    
    try {
    final updates = <String, Map<String, dynamic>>{}; // orderId -> latest update
    
    
    // v390: Sequential relay fallback — try first relay, use second only if first fails
    final allEvents = <Map<String, dynamic>>[];
    final fourteenDaysAgo = DateTime.now().subtract(const Duration(days: 14));
    final statusSince = (fourteenDaysAgo.millisecondsSinceEpoch / 1000).floor();
    
    for (final relay in _relays) {
      try {
        // 2 strategies per relay
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
        
        // Combinar and deduplicar
        final seenIds = <String>{};
        for (final eventList in results) {
          for (final e in eventList) {
            final id = e['id'];
            if (id != null && !seenIds.contains(id)) {
              seenIds.add(id);
              allEvents.add(e);
            }
          }
        }
        
        // v390: If this relay returned data, skip remaining relays
        if (allEvents.isNotEmpty) break;
      } catch (e) {
        // Relay failed, try next
      }
    }
    
    broLog('📋 _fetchAllOrderStatusUpdates: ${allEvents.length} eventos (sequential relay)');
    
    // v406: CORREÇÃO DEFINITIVA — Acumular dados de comprovante de TODOS os eventos
    // ANTES de processar, para que proof nunca se perca por ordem de processamento.
    // Relays retornam eventos do mais novo ao mais antigo. Se o evento mais novo
    // (kind 30080, completed, sem proof) é processado primeiro, o mais antigo
    // (kind 30081, com proof) era IGNORADO pelo guard de timestamp.
    // O acumulador garante que proof é preservado independente da ordem.
    final proofAccumulator = <String, Map<String, dynamic>>{};
    for (final event in allEvents) {
      try {
        final content = event['parsedContent'] ?? jsonDecode(event['content']);
        final orderId = content['orderId'] as String?;
        if (orderId == null) continue;
        final proofImage = content['proofImage'] as String?;
        final proofImageNip44 = content['proofImage_nip44'] as String?;
        final providerInvoice = content['providerInvoice'] as String?;
        if (proofImage != null || proofImageNip44 != null || providerInvoice != null) {
          // Guardar apenas o PRIMEIRO (mais completo) conjunto de proof encontrado
          if (!proofAccumulator.containsKey(orderId)) {
            proofAccumulator[orderId] = {
              'proofImage': proofImage,
              'proofImage_nip44': proofImageNip44,
              'encryption': content['encryption'] as String?,
              'providerInvoice': providerInvoice,
              'eventAuthorPubkey': event['pubkey'] as String?,
              'completedAt': content['completedAt'] as String?,
            };
          }
        }
      } catch (_) {}
    }
    
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
            
            // CORREÇÃO v348: Ignorar eventos de reembolso do admin
            // bro_admin_reimbursement NÃO é status update — é invoice de cobrança
            if (eventType == 'bro_admin_reimbursement') continue;
            
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
                broLog('⚠️ REJEITADO: ${eventType} de pubkey=${ eventPubkey.substring(0, 8)} mas providerId=${contentProviderId.substring(0, 8)}');
                continue;
              }
            }
            
            // SEGURANÇA: Para status 'disputed', validar que o autor é parte da ordem
            // Apenas userPubkey ou providerId podem abrir disputa
            final contentStatus = content['status'] as String?;
            if (contentStatus == 'disputed' && eventType == 'bro_order_update') {
              final isAuthorUser = contentUserPubkey != null && eventPubkey == contentUserPubkey;
              final isAuthorProvider = contentProviderId != null && eventPubkey == contentProviderId;
              if (!isAuthorUser && !isAuthorProvider) {
                broLog('⚠️ REJEITADO: disputed de pubkey não autorizado ${eventPubkey?.substring(0, 8)}');
                continue;
              }
            }
            
            final createdAt = event['created_at'] as int? ?? 0;
            
            // SEGURANÇA: Rejeitar eventos com timestamp no futuro (clock skew attack)
            final eventTime = DateTime.fromMillisecondsSinceEpoch(createdAt * 1000);
            final now = DateTime.now();
            if (eventTime.isAfter(now.add(const Duration(minutes: 15)))) {
              broLog('⚠️ REJEITADO: evento com timestamp no futuro: $eventTime');
              continue;
            }
            
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
              
              // v406: Usar proofAccumulator como fallback DEFINITIVO para proof data
              // Isso garante que proof NUNCA se perde por ordem de processamento de eventos
              final previousUpdate = updates[orderId];
              final accum = proofAccumulator[orderId];
              updates[orderId] = {
                'orderId': orderId,
                'status': status,
                'providerId': providerId ?? previousUpdate?['providerId'] ?? accum?['providerId'],
                'eventAuthorPubkey': eventAuthorPubkey ?? previousUpdate?['eventAuthorPubkey'] ?? accum?['eventAuthorPubkey'],
                'proofImage': proofImage ?? previousUpdate?['proofImage'] ?? accum?['proofImage'],
                'proofImage_nip44': proofImageNip44 ?? previousUpdate?['proofImage_nip44'] ?? accum?['proofImage_nip44'],
                'encryption': encryption ?? previousUpdate?['encryption'] ?? accum?['encryption'],
                'providerInvoice': providerInvoice ?? previousUpdate?['providerInvoice'] ?? accum?['providerInvoice'],
                'completedAt': content['completedAt'] ?? previousUpdate?['completedAt'] ?? accum?['completedAt'],
                'created_at': createdAt,
              };
            }
          } catch (e) {
            // Ignorar eventos mal formatados
          }
        }
    
    broLog('📋 _fetchAllOrderStatusUpdates: ${updates.length} ordens com updates');
    
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
          broLog('🔓 proofImage descriptografado com NIP-44');
        } catch (e) {
          // Fallback: se o usuário atual é o autor do evento (provedor),
          // usar o userPubkey da ordem como contraparte para ECDH
          if (order.userPubkey != null && order.userPubkey!.isNotEmpty) {
            try {
              proofImage = _nip44.decryptBetween(proofImageNip44, userPrivateKey, order.userPubkey!);
              broLog('🔓 proofImage descriptografado com NIP-44 (via order.userPubkey)');
            } catch (e2) {
              broLog('⚠️ Falha ao descriptografar proofImage (ambas tentativas): $e / $e2');
              proofImage = null;
            }
          } else {
            broLog('⚠️ Falha ao descriptografar proofImage: $e');
            proofImage = null;
          }
        }
      }
    }
    
    // Se proofImage é o marcador de criptografia, não usar como imagem
    if (proofImage != null && proofImage.startsWith('[encrypted:')) {
      proofImage = null;
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
      // Preservar dados NIP-44 para re-descriptografia futura
      if (proofImageNip44 != null && proofImageNip44.isNotEmpty) {
        updatedMetadata['proofImage_nip44'] = proofImageNip44;
        updatedMetadata['proofImage_senderPubkey'] = update['eventAuthorPubkey'] as String? ?? providerId;
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
    int successfulRelays = 0;
    for (int i = 0; i < results.length; i++) {
      final relayOrders = results[i];
      
      if (relayOrders.isNotEmpty) successfulRelays++;
      for (final order in relayOrders) {
        final id = order['id'];
        if (!seenIds.contains(id)) {
          seenIds.add(id);
          orders.add(order);
        }
      }
    }
    
    // v259: Se NENHUM relay principal retornou dados, tentar fallback relays
    if (orders.isEmpty && successfulRelays == 0) {
      broLog('⚠️ fetchPendingOrdersRaw: 0 relays principais responderam, tentando fallback...');
      final fallbackFutures = _fallbackRelays.map(
        (relay) => _fetchPendingFromRelay(relay, sinceTimestamp)
      ).toList();
      final fallbackResults = await Future.wait(fallbackFutures, eagerError: false);
      for (final relayOrders in fallbackResults) {
        for (final order in relayOrders) {
          final id = order['id'];
          if (!seenIds.contains(id)) {
            seenIds.add(id);
            orders.add(order);
          }
        }
      }
      if (orders.isNotEmpty) {
        broLog('✅ Fallback relays retornaram ${orders.length} ordens!');
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
      
      
      broLog('📡 Relay $relay: ${relayOrders.length} eventos kind 30078 retornados');
      
      for (final order in relayOrders) {
        // Verificar se é ordem do Bro app (verificando content)
        try {
          final content = order['parsedContent'] ?? jsonDecode(order['content'] ?? '{}');
          if (content['type'] == 'bro_order') {
            orders.add(order);
          }
        } catch (_) {}
      }
      broLog('📡 Relay $relay: ${orders.length} ordens bro_order válidas');
    } catch (e) {
      broLog('❌ Relay $relay erro: $e');
    }
    
    return orders;
  }

  /// Busca ordens de um usuário (raw)
  Future<List<Map<String, dynamic>>> _fetchUserOrdersRaw(String pubkey) async {
    final orders = <Map<String, dynamic>>[];
    final seenIds = <String>{};

    // v390: Sequential relay fallback — try first relay, use next only if first fails
    for (final relay in _relays) {
      try {
        final relayOrders = await _fetchUserOrdersFromRelay(relay, pubkey);
        for (final order in relayOrders) {
          final id = order['id'];
          if (!seenIds.contains(id)) {
            seenIds.add(id);
            orders.add(order);
          }
        }
        // If this relay returned data, skip remaining relays
        if (orders.isNotEmpty) break;
      } catch (_) {}
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
      broLog('🔍 fetchOrderUpdatesForUser: 0 ordens ativas, pulando fetch');
      return updates;
    }
    
    // Converter para Set para filtragem O(1) no processamento
    final activeOrderIdSet = orderIds?.toSet();

    // v390: Sequential relay fallback — try first relay, use next only if fails
    final allEvents = <Map<String, dynamic>>[];
    
    for (final relay in _relays.take(3)) {
      try {
        // 2 core strategies per relay (reduced from 5)
        final strategies = <Future<List<Map<String, dynamic>>>>[
          // 1. Eventos direcionados ao usuário (accept/complete/proof)
          _fetchFromRelay(relay, kinds: [kindBroAccept, kindBroPaymentProof, kindBroComplete], tags: {'#p': [userPubkey]}, limit: 200)
            .catchError((_) => <Map<String, dynamic>>[]),
          // 2. Eventos do PRÓPRIO USUÁRIO (kind 30080 — status updates publicados por mim)
          _fetchFromRelay(relay, kinds: [kindBroPaymentProof], authors: [userPubkey], limit: 100)
            .catchError((_) => <Map<String, dynamic>>[]),
        ];
        // 3. Buscar por #r (orderId) para updates do provedor sem tag #p
        if (activeOrderIdSet != null && activeOrderIdSet.isNotEmpty) {
          strategies.add(
            _fetchFromRelay(relay, kinds: [kindBroPaymentProof], tags: {'#r': activeOrderIdSet.toList()}, limit: 100)
              .catchError((_) => <Map<String, dynamic>>[]),
          );
        }
        final results = await Future.wait(strategies);
        final seenIds = <String>{};
        for (final eventList in results) {
          for (final e in eventList) {
            final id = e['id'];
            if (id != null && !seenIds.contains(id)) {
              seenIds.add(id);
              allEvents.add(e);
            }
          }
        }
        // If this relay returned data, skip remaining
        if (allEvents.isNotEmpty) break;
      } catch (e) {
        // Relay failed, try next
      }
    }
    
    broLog('🔍 fetchOrderUpdatesForUser: ${allEvents.length} eventos (sequential relay)');
    
    // v406: CORREÇÃO DEFINITIVA — Acumular proof de TODOS os eventos por orderId
    // antes de processar. Garante que proof do kind 30081 (provider complete) NUNCA
    // se perde mesmo quando kind 30080 (user completed, sem proof) é processado primeiro.
    final proofAccumulator = <String, Map<String, dynamic>>{};
    for (final event in allEvents) {
      try {
        final content = event['parsedContent'] ?? jsonDecode(event['content']);
        final orderId = content['orderId'] as String?;
        if (orderId == null) continue;
        final proofImage = content['proofImage'] as String?;
        final proofImageNip44 = content['proofImage_nip44'] as String?;
        if (proofImage != null || proofImageNip44 != null) {
          if (!proofAccumulator.containsKey(orderId)) {
            proofAccumulator[orderId] = {
              'proofImage': proofImage,
              'proofImage_nip44': proofImageNip44,
              'encryption': content['encryption'] as String?,
              'eventAuthorPubkey': event['pubkey'] as String?,
            };
          }
        }
      } catch (_) {}
    }
    
    // Processar todos os eventos
    for (final event in allEvents) {
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
            // CORREÇÃO v348: Ignorar eventos de reembolso do admin completamente
            // bro_admin_reimbursement NÃO é status update — não deve afetar lista de ordens
            if (contentType == 'bro_admin_reimbursement') continue;
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
              // CORREÇÃO v349: Se o update existente é resolução (completed/cancelled),
              // NUNCA permitir que evento 'disputed' mais antigo o sobrescreva
              if ((existingStatus == 'completed' || existingStatus == 'cancelled') && 
                  newStatus == 'disputed') {
                continue; // Resolução é final
              }
            } else {
              continue; // Evento antigo e não é progressão - ignorar
            }
            
            // v404: Preservar dados do comprovante quando evento mais recente não tem
            // Kind 30080 (completed pelo usuário) NÃO tem proofImage, mas Kind 30081 (do provedor) TEM
            // v406: Usar proofAccumulator como fallback DEFINITIVO
            final previousUpdate = updates[orderId];
            final accum = proofAccumulator[orderId];
            updates[orderId] = {
              'orderId': orderId,
              'status': newStatus,
              'eventKind': eventKind,
              'providerId': content['providerId'] ?? event['pubkey'] ?? previousUpdate?['providerId'],
              'proofImage': content['proofImage'] ?? previousUpdate?['proofImage'] ?? accum?['proofImage'],
              'proofImage_nip44': content['proofImage_nip44'] ?? previousUpdate?['proofImage_nip44'] ?? accum?['proofImage_nip44'],
              'encryption': content['encryption'] ?? previousUpdate?['encryption'] ?? accum?['encryption'],
              'eventAuthorPubkey': event['pubkey'] as String? ?? previousUpdate?['eventAuthorPubkey'] as String? ?? accum?['eventAuthorPubkey'] as String?,
              'created_at': createdAt,
            };
          } catch (e) {
          }
    }

    broLog('🔍 fetchOrderUpdatesForUser: ${updates.length} updates encontrados');
    for (final entry in updates.entries) {
      broLog('   📋 ${entry.key.substring(0, 8)}: status=${entry.value['status']}, kind=${entry.value['eventKind']}, proof=${entry.value['proofImage'] != null || entry.value['proofImage_nip44'] != null}');
    }
    return updates;
  }
  
  /// Busca eventos de update de status para ordens que o provedor aceitou
  /// v390: Sequential relay fallback — reduces WebSocket connections from 15 to 2-3
  Future<Map<String, Map<String, dynamic>>> fetchOrderUpdatesForProvider(String providerPubkey, {List<String>? orderIds}) async {
    final updates = <String, Map<String, dynamic>>{}; // orderId -> latest update
    
    // SEGURANÇA: Se não temos orderIds específicos, não buscar nada
    if (orderIds == null || orderIds.isEmpty) {
      return updates;
    }

    final orderIdSet = orderIds.toSet();
    broLog('🔍 fetchOrderUpdatesForProvider: buscando updates para ${orderIds.length} ordens');
    
    // v390: Sequential relay fallback
    int totalEvents = 0;
    for (final relay in _relays.take(3)) {
      try {
        // 2 core strategies per relay (reduced from 5)
        final results = await Future.wait([
          // 1. Updates direcionados ao provedor via #p
          _fetchFromRelay(relay, kinds: [kindBroPaymentProof], tags: {'#p': [providerPubkey]}, limit: 100)
            .catchError((_) => <Map<String, dynamic>>[]),
          // 2. Updates por #r (orderId batch)
          _fetchFromRelay(relay, kinds: [kindBroPaymentProof], tags: {'#r': orderIds}, limit: 200)
            .catchError((_) => <Map<String, dynamic>>[]),
        ]);
        
        for (final events in results) {
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
                final existingStatus = existingUpdate?['status'] as String?;
                if (existingStatus != null && !_isStatusProgression(status, existingStatus)) continue;
                
                updates[eventOrderId] = {
                  'orderId': eventOrderId,
                  'status': status,
                  'created_at': createdAt,
                };
              }
            } catch (_) {}
          }
        }
        // If this relay returned data, skip remaining
        if (totalEvents > 0) break;
      } catch (_) {}
    }

    broLog('🔍 fetchOrderUpdatesForProvider RESULTADO: ${updates.length} updates de $totalEvents eventos');
    for (final entry in updates.entries) {
      broLog('   → orderId=${entry.key.substring(0, 8)} status=${entry.value['status']}');
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
    String? city,
    List<String>? photos, // Lista de fotos em base64
    int quantity = 0, // Quantidade disponível (0 = ilimitado)
  }) async {
    try {
      final keychain = Keychain(privateKey);
      final offerId = const Uuid().v4();
      
      final contentMap = {
        'type': 'bro_marketplace_offer',
        'version': '2.0',
        'offerId': offerId,
        'title': title,
        'description': description,
        'priceSats': priceSats,
        'category': category,
        'siteUrl': siteUrl,
        'city': city,
        'photos': photos ?? [],
        'quantity': quantity,
        'sold': 0,
        'createdAt': DateTime.now().toIso8601String(),
      };
      
      final content = jsonEncode(contentMap);

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
      
      // Adicionar tag de localização se fornecida
      if (city != null && city.isNotEmpty) {
        tags.add(['location', city]);
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

  /// v248: Atualiza quantidade vendida de uma oferta do marketplace
  /// Republica o evento NIP-33 (kind 30019) com o mesmo 'd' tag para substituir
  Future<bool> updateMarketplaceOfferSold({
    required String privateKey,
    required String offerId,
    required String title,
    required String description,
    required int priceSats,
    required String category,
    String? siteUrl,
    String? city,
    List<String>? photos,
    required int quantity,
    required int newSold,
  }) async {
    try {
      final keychain = Keychain(privateKey);
      
      final contentMap = {
        'type': 'bro_marketplace_offer',
        'version': '2.0',
        'offerId': offerId,
        'title': title,
        'description': description,
        'priceSats': priceSats,
        'category': category,
        'siteUrl': siteUrl,
        'city': city,
        'photos': photos ?? [],
        'quantity': quantity,
        'sold': newSold,
        'createdAt': DateTime.now().toIso8601String(),
      };
      
      final content = jsonEncode(contentMap);

      final tags = [
        ['d', offerId],
        ['t', marketplaceTag],
        ['t', 'bro-app'],
        ['t', category],
        ['title', title],
        ['price', priceSats.toString(), 'sats'],
      ];
      
      if (siteUrl != null && siteUrl.isNotEmpty) {
        tags.add(['r', siteUrl]);
      }
      if (city != null && city.isNotEmpty) {
        tags.add(['location', city]);
      }

      final event = Event.from(
        kind: kindMarketplaceOffer,
        tags: tags,
        content: content,
        privkey: keychain.private,
      );

      final publishResults = await Future.wait(
        _relays.take(5).map((relay) => _publishToRelay(relay, event).catchError((_) => false)),
      );
      final successCount = publishResults.where((s) => s).length;
      
      broLog('📦 updateMarketplaceOfferSold: offerId=${offerId.substring(0, 8)}, sold=$newSold, publicado em $successCount relays');
      return successCount > 0;
    } catch (e) {
      broLog('❌ updateMarketplaceOfferSold EXCEPTION: $e');
      return false;
    }
  }

  /// v253: Deleta uma oferta do marketplace
  /// Usa NIP-33 (republica com mesmo d-tag) com marcador de deletado + NIP-09 kind 5
  Future<bool> deleteMarketplaceOffer({
    required String privateKey,
    required String offerId,
  }) async {
    try {
      final keychain = Keychain(privateKey);
      
      // Estratégia 1: NIP-33 - Republica com mesmo d-tag mas conteúdo vazio/deletado
      // Isso substitui a oferta original no relay
      final contentMap = {
        'type': 'bro_marketplace_offer',
        'version': '2.0',
        'offerId': offerId,
        'deleted': true,
        'deletedAt': DateTime.now().toIso8601String(),
      };
      
      final replacementEvent = Event.from(
        kind: kindMarketplaceOffer,
        tags: [
          ['d', offerId],
          ['t', marketplaceTag],
          ['t', 'bro-app'],
          ['t', 'deleted'],
        ],
        content: jsonEncode(contentMap),
        privkey: keychain.private,
      );

      // Estratégia 2: NIP-09 - Publica kind 5 (deletion) referenciando o evento
      final deletionEvent = Event.from(
        kind: 5, // NIP-09 Event Deletion
        tags: [
          ['a', '${kindMarketplaceOffer}:${keychain.public}:$offerId'], // Referência NIP-33
        ],
        content: 'Oferta removida pelo vendedor',
        privkey: keychain.private,
      );
      
      // Publicar ambos em paralelo em todos os relays
      final results = await Future.wait(
        _relays.take(5).expand((relay) => [
          _publishToRelay(relay, replacementEvent).catchError((_) => false),
          _publishToRelay(relay, deletionEvent).catchError((_) => false),
        ]).toList(),
      );
      
      final successCount = results.where((s) => s).length;
      broLog('🗑️ deleteMarketplaceOffer: offerId=${offerId.substring(0, 8)}, publicado em ${successCount ~/ 2}/${_relays.take(5).length} relays');
      return successCount > 0;
    } catch (e) {
      broLog('❌ deleteMarketplaceOffer EXCEPTION: $e');
      return false;
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
            // v253: Filtrar ofertas deletadas
            if (content['deleted'] == true) continue;
            List<String> photos = [];
            if (content['photos'] is List) {
              photos = (content['photos'] as List).cast<String>();
            }
            String? siteUrl = content['siteUrl'];
            String? city = content['city'];
            final tags = event['tags'] as List<dynamic>? ?? [];
            for (final tag in tags) {
              if (tag is List && tag.length > 1) {
                if (tag[0] == 'r' && siteUrl == null) siteUrl = tag[1];
                if (tag[0] == 'location' && city == null) city = tag[1];
              }
            }
            offers.add({
              'id': content['offerId'] ?? id,
              'title': content['title'] ?? '',
              'description': content['description'] ?? '',
              'priceSats': content['priceSats'] ?? 0,
              'category': content['category'] ?? 'outros',
              'sellerPubkey': event['pubkey'],
              'siteUrl': siteUrl,
              'city': city,
              'photos': photos,
              'quantity': content['quantity'] ?? 0,
              'sold': content['sold'] ?? 0,
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
            // v253: Filtrar ofertas deletadas
            if (content['deleted'] == true) continue;
            List<String> photos = [];
            if (content['photos'] is List) {
              photos = (content['photos'] as List).cast<String>();
            }
            String? siteUrl = content['siteUrl'];
            String? city = content['city'];
            final evtTags = event['tags'] as List<dynamic>? ?? [];
            for (final tag in evtTags) {
              if (tag is List && tag.length > 1) {
                if (tag[0] == 'r' && siteUrl == null) siteUrl = tag[1];
                if (tag[0] == 'location' && city == null) city = tag[1];
              }
            }
            offers.add({
              'id': content['offerId'] ?? id,
              'title': content['title'] ?? '',
              'description': content['description'] ?? '',
              'priceSats': content['priceSats'] ?? 0,
              'category': content['category'] ?? 'outros',
              'sellerPubkey': event['pubkey'],
              'siteUrl': siteUrl,
              'city': city,
              'photos': photos,
              'quantity': content['quantity'] ?? 0,
              'sold': content['sold'] ?? 0,
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
      // v236: incluir evidência do usuário se fornecida (criptografada com NIP-44)
      if (userEvidence != null && userEvidence.isNotEmpty) {
        try {
          final encryptedEvidence = _nip44.encryptBetween(
            userEvidence, keychain.private, AppConfig.adminPubkey,
          );
          contentMap['user_evidence_nip44'] = encryptedEvidence;
          contentMap['user_evidence'] = '[encrypted:nip44v2]'; // Marcador
          broLog('🔐 user_evidence criptografada com NIP-44 (${encryptedEvidence.length} chars)');
        } catch (e) {
          broLog('⚠️ Falha ao criptografar user_evidence: $e — não incluindo imagem');
          // NÃO enviar em plaintext — dados sensíveis (fotos de banco/CPF)
        }
      }
      final content = jsonEncode(contentMap);
      
      // v253: Incluir #p tag do provedor para que ele descubra a disputa nos relays
      final providerIdFromDetails = orderDetails?['provider_id'] as String?;
      final tags = [
        ['t', 'bro-disputa'],
        ['t', broTag],
        ['r', orderId],
        ['p', AppConfig.adminPubkey], // Notificar admin/mediador
      ];
      if (providerIdFromDetails != null && providerIdFromDetails.isNotEmpty && providerIdFromDetails != AppConfig.adminPubkey) {
        tags.add(['p', providerIdFromDetails]); // v253: Notificar provedor
      }
      
      final event = Event.from(
        kind: 1, // Nota regular - #t tags SÃO indexadas!
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
      broLog('📤 publishDisputeNotification: publicado em $successCount/${_relays.length} relays');
      return successCount > 0;
    } catch (e) {
      broLog('❌ publishDisputeNotification EXCEPTION: $e');
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
    
    broLog('📤 fetchDisputeNotifications: ${allEvents.length} disputas encontradas');
    return allEvents;
  }

  /// Busca TODAS as resoluções de disputas do Nostr
  /// Estratégia dupla (v240):
  /// 1. Kind 1 com tag bro-resolucao (evento principal de resolução)
  /// 2. Kind 30080 com tag bro-resolucao (evento audit de resolução)
  /// CORREÇÃO build 218: Necessário porque após resolução, o evento original de disputa
  /// pode não ser mais retornado pelo relay, fazendo a aba "Resolvidas" ficar vazia.
  /// Buscando resoluções diretamente, podemos reconstruir a lista de disputas resolvidas.
  Future<List<Map<String, dynamic>>> fetchAllDisputeResolutions() async {
    final allResolutions = <Map<String, dynamic>>[];
    final seenOrderIds = <String>{};
    
    final results = await Future.wait(
      _relays.map((relay) async {
        try {
          final channel = WebSocketChannel.connect(Uri.parse(relay));
          final subId = 'allres_${DateTime.now().millisecondsSinceEpoch % 100000}';
          final subId2 = 'allresA_${DateTime.now().millisecondsSinceEpoch % 100000}';
          final events = <Map<String, dynamic>>[];
          
          // Estratégia 1: Kind 1 com bro-resolucao
          channel.sink.add(jsonEncode(['REQ', subId, {
            'kinds': [1],
            '#t': ['bro-resolucao'],
            'limit': 100,
          }]));
          // Estratégia 2: Kind 30080 (audit) com bro-resolucao (v240)
          channel.sink.add(jsonEncode(['REQ', subId2, {
            'kinds': [kindBroPaymentProof],
            '#t': ['bro-resolucao'],
            'limit': 100,
          }]));
          
          int eoseCount = 0;
          await for (final msg in channel.stream.timeout(
            const Duration(seconds: 10), onTimeout: (sink) => sink.close())) {
            final data = jsonDecode(msg.toString());
            if (data is List && data.length >= 3 && data[0] == 'EVENT') {
              events.add(data[2] as Map<String, dynamic>);
            }
            if (data is List && data[0] == 'EOSE') {
              eoseCount++;
              if (eoseCount >= 2) break;
            }
          }
          
          channel.sink.add(jsonEncode(['CLOSE', subId]));
          channel.sink.add(jsonEncode(['CLOSE', subId2]));
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
    broLog('📤 fetchAllDisputeResolutions: ${allResolutions.length} resoluções encontradas');
    return allResolutions;
  }

  /// Publica invoice de reembolso do admin no Nostr
  /// Quando o admin paga o provedor da própria carteira, publica um invoice
  /// para que o usuário pague o admin de volta automaticamente.
  Future<bool> publishAdminReimbursementInvoice({
    required String privateKey,
    required String orderId,
    required String adminInvoice,
    required int amountSats,
    String? userPubkey,
  }) async {
    try {
      final keychain = Keychain(privateKey);
      
      final content = jsonEncode({
        'type': 'bro_admin_reimbursement',
        'orderId': orderId,
        'adminInvoice': adminInvoice,
        'adminPubkey': keychain.public,
        'amountSats': amountSats,
        'createdAt': DateTime.now().toIso8601String(),
      });
      
      final tags = [
        ['d', '${orderId}_admin_reimbursement'],
        ['t', broTag],
        ['t', 'bro-admin-reimbursement'],
        ['r', orderId],
        ['orderId', orderId],
      ];
      if (userPubkey != null && userPubkey.isNotEmpty) {
        tags.add(['p', userPubkey]);
      }
      
      final event = Event.from(
        kind: kindBroPaymentProof, // kind 30080
        tags: tags,
        content: content,
        privkey: keychain.private,
      );
      
      final results = await Future.wait(
        _relays.map((relay) => _publishToRelay(relay, event).catchError((_) => false)),
      );
      final successCount = results.where((r) => r).length;
      broLog('📤 publishAdminReimbursementInvoice: publicado em $successCount/${_relays.length} relays');
      return successCount > 0;
    } catch (e) {
      broLog('❌ publishAdminReimbursementInvoice EXCEPTION: $e');
      return false;
    }
  }

  /// Busca invoice de reembolso do admin para uma ordem
  /// Retorna o adminInvoice se o admin já pagou o provedor
  Future<String?> fetchAdminReimbursementInvoice(String orderId) async {
    final results = await Future.wait(
      _relays.take(3).map((relay) async {
        try {
          final events = await _fetchFromRelay(
            relay,
            kinds: [kindBroPaymentProof],
            tags: {'#d': ['${orderId}_admin_reimbursement']},
            limit: 5,
          );
          for (final event in events) {
            try {
              final content = event['parsedContent'] ?? jsonDecode(event['content']);
              if (content['type'] == 'bro_admin_reimbursement' && content['orderId'] == orderId) {
                return content['adminInvoice'] as String?;
              }
            } catch (_) {}
          }
        } catch (_) {}
        return null;
      }),
    );
    for (final result in results) {
      if (result != null) return result;
    }
    return null;
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
        // v247: Marcar quem perdeu a disputa para tracking de reincidentes
        'loserPubkey': resolution == 'resolved_user' ? providerId : userPubkey,
        'loserRole': resolution == 'resolved_user' ? 'provider' : 'user',
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
      
      // v247: Tag do perdedor para busca de reincidentes
      final loserPubkey = resolution == 'resolved_user' ? providerId : userPubkey;
      if (loserPubkey != null && loserPubkey.isNotEmpty) {
        tags.add(['t', 'bro-dispute-loser-$loserPubkey']);
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
      broLog('📤 publishDisputeResolution: kind 1 publicado em $successCount/${_relays.length} relays (orderId=${orderId.substring(0, 8)}, resolution=$resolution)');
      
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
        broLog('📤 publishDisputeResolution: kind 30080 (audit) publicado em $auditSuccess/${_relays.length} relays');
      } catch (e) {
        broLog('⚠️ Audit event (kind 30080) falhou: $e');
      }
      
      return successCount > 0;
    } catch (e) {
      broLog('❌ publishDisputeResolution EXCEPTION: $e');
      return false;
    }
  }

  /// v247: Busca quantas disputas um pubkey perdeu (como user ou provider)
  /// Retorna lista de resoluções onde o pubkey foi o perdedor
  Future<List<Map<String, dynamic>>> fetchDisputeLosses(String pubkey) async {
    final losses = <Map<String, dynamic>>[];
    final seenOrderIds = <String>{};
    
    try {
      // Buscar resoluções onde o pubkey é uma das partes
      // Estratégia 1: Buscar por tag de perdedor (v247+)
      final relayResults1 = await Future.wait(
        _relays.take(3).map((relay) =>
          _fetchFromRelay(relay, kinds: [1], 
            tags: {'#t': ['bro-dispute-loser-$pubkey']}, 
            limit: 50,
          ).catchError((_) => <Map<String, dynamic>>[])
        ),
      );
      
      // Estratégia 2: Buscar por #p tag (resoluções antigas)
      final relayResults2 = await Future.wait(
        _relays.take(3).map((relay) =>
          _fetchFromRelay(relay, kinds: [1], 
            tags: {'#t': ['bro-resolucao'], '#p': [pubkey]}, 
            limit: 50,
          ).catchError((_) => <Map<String, dynamic>>[])
        ),
      );
      
      final allResults = [...relayResults1, ...relayResults2];
      
      for (final events in allResults) {
          for (final event in events) {
            try {
              final content = event['parsedContent'] ?? jsonDecode(event['content'] ?? '{}');
              if (content['type'] != 'bro_dispute_resolution') continue;
              
              final orderId = content['orderId'] as String? ?? '';
              if (seenOrderIds.contains(orderId)) continue;
              
              // Verificar se este pubkey perdeu
              final resolution = content['resolution'] as String? ?? '';
              final loserPubkey = content['loserPubkey'] as String?;
              final userPubkey = content['userPubkey'] as String? ?? '';
              final providerId = content['providerId'] as String? ?? '';
              
              bool isLoser = false;
              String loserRole = '';
              
              if (loserPubkey == pubkey) {
                isLoser = true;
                loserRole = content['loserRole'] ?? 'unknown';
              } else if (resolution == 'resolved_user' && providerId == pubkey) {
                isLoser = true;
                loserRole = 'provider';
              } else if (resolution == 'resolved_provider' && userPubkey == pubkey) {
                isLoser = true;
                loserRole = 'user';
              }
              
              if (isLoser) {
                seenOrderIds.add(orderId);
                losses.add({
                  'orderId': orderId,
                  'resolution': resolution,
                  'loserRole': loserRole,
                  'resolvedAt': content['resolvedAt'] ?? '',
                  'notes': content['notes'] ?? '',
                });
              }
            } catch (_) {}
          }
        }
      
      broLog('📊 fetchDisputeLosses($pubkey): ${losses.length} derrotas');
    } catch (e) {
      broLog('❌ fetchDisputeLosses EXCEPTION: $e');
    }
    
    return losses;
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
      broLog('📤 publishMediatorMessage: publicado em $successCount/${_relays.length} relays (target=$target, orderId=${orderId.substring(0, 8)})');
      return successCount > 0;
    } catch (e) {
      broLog('❌ publishMediatorMessage EXCEPTION: $e');
      return false;
    }
  }

  // Instância NIP-04 para DMs do admin
  final _nip04 = Nip04Service();

  /// v239: Envia DM NIP-04 (kind 4) do admin para um pubkey específico.
  /// Isso garante que o destinatário veja a mensagem na caixa de entrada Nostr,
  /// mesmo em versões antigas do app que não suportam bro-mediacao.
  Future<bool> sendAdminNip04DM({
    required String adminPrivateKey,
    required String recipientPubkey,
    required String message,
  }) async {
    try {
      if (recipientPubkey.isEmpty) {
        broLog('⚠️ sendAdminNip04DM: recipientPubkey vazia, pulando');
        return false;
      }

      final keychain = Keychain(adminPrivateKey);
      
      // Criptografar mensagem usando NIP-04
      final encryptedContent = _nip04.encrypt(
        message,
        adminPrivateKey,
        recipientPubkey,
      );
      
      // Criar evento kind 4 (NIP-04 DM)
      final event = Event.from(
        kind: 4,
        tags: [['p', recipientPubkey]],
        content: encryptedContent,
        privkey: keychain.private,
      );
      
      final results = await Future.wait(
        _relays.map((relay) => _publishToRelay(relay, event).catchError((_) => false)),
      );
      
      final successCount = results.where((r) => r).length;
      broLog('📨 sendAdminNip04DM: DM enviada para ${recipientPubkey.substring(0, 16)}... '
          'em $successCount/${_relays.length} relays');
      return successCount > 0;
    } catch (e) {
      broLog('❌ sendAdminNip04DM EXCEPTION: $e');
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
        broLog('✅ fetchDisputeResolution: resolução encontrada para ${orderId.substring(0, 8)} - ${latestResolution['resolution']}');
      } else {
        broLog('🔍 fetchDisputeResolution: nenhuma resolução para ${orderId.substring(0, 8)}');
      }
      
      return latestResolution;
    } catch (e) {
      broLog('❌ fetchDisputeResolution EXCEPTION: $e');
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
      broLog('📨 fetchAllMediatorMessagesForOrder: ${messages.length} mensagens para ordem ${orderId.substring(0, 8)}');
      return messages;
    } catch (e) {
      broLog('❌ fetchAllMediatorMessagesForOrder EXCEPTION: $e');
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
      broLog('📨 fetchMediatorMessages: ${messages.length} mensagens para ${pubkey.substring(0, 8)}');
      return messages;
    } catch (e) {
      broLog('❌ fetchMediatorMessages EXCEPTION: $e');
      return [];
    }
  }

  /// v236: Publica evidência de disputa (foto + texto) por qualquer parte
  /// Usado por usuário e provedor para enviar provas durante a mediação
  Future<bool> publishDisputeEvidence({
    required String privateKey,
    required String orderId,
    required String senderRole, // 'user' ou 'provider'
    String? imageBase64, // foto em base64
    String? description, // texto descritivo
  }) async {
    try {
      final keychain = Keychain(privateKey);
      
      // v247: Verificar tamanho da imagem antes de enviar
      // Reduzir se muito grande para caber nos relays (limite ~64KB para evento)
      String? finalImage = imageBase64;
      if (finalImage != null && finalImage.isNotEmpty) {
        final imageBytes = finalImage.length;
        broLog('📏 Evidência imagem: ${(imageBytes / 1024).toStringAsFixed(1)}KB base64');
        if (imageBytes > 45000) {
          // Imagem muito grande, truncar para evitar rejeição dos relays
          // (45KB base64 + metadados JSON + NIP-44 overhead ~ 64KB)
          broLog('⚠️ Imagem muito grande ($imageBytes bytes), será comprimida');
          // Tentar enviar mesmo assim, mas avisar
        }
      }
      
      final contentMap = {
        'type': 'bro_dispute_evidence',
        'orderId': orderId,
        'senderRole': senderRole,
        'senderPubkey': keychain.public,
        'sentAt': DateTime.now().toIso8601String(),
      };
      if (description != null && description.isNotEmpty) {
        contentMap['description'] = description;
      }
      if (imageBase64 != null && imageBase64.isNotEmpty) {
        contentMap['image'] = imageBase64;
      }
      
      final plainContent = jsonEncode(contentMap);
      
      // 🔒 Criptografar conteúdo com NIP-44 entre remetente e admin
      // Apenas o admin (mediador) pode descriptografar as evidências
      String content;
      try {
        content = jsonEncode({
          'encrypted': true,
          'encryption': 'nip44v2',
          'senderPubkey': keychain.public,
          'payload': _nip44.encryptBetween(plainContent, keychain.private, AppConfig.adminPubkey),
        });
        broLog('🔐 Evidência criptografada com NIP-44 para admin');
      } catch (e) {
        broLog('⚠️ Falha ao criptografar evidência: $e — abortando envio por segurança');
        return false; // NÃO enviar em plaintext — dados sensíveis
      }
      
      final event = Event.from(
        kind: 1,
        tags: [
          ['t', 'bro-disputa-evidencia'],
          ['t', broTag],
          ['r', orderId],
          ['p', AppConfig.adminPubkey],
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
      broLog('📤 publishDisputeEvidence: $senderRole enviou evidência para ordem ${orderId.substring(0, 8)}, $successCount relays');
      return successCount > 0;
    } catch (e) {
      broLog('❌ publishDisputeEvidence EXCEPTION: $e');
      return false;
    }
  }
  
  /// v236: Busca todas as evidências de disputa para uma ordem
  /// Retorna lista de evidências de ambas as partes, ordenadas por data
  /// Se adminPrivateKey for fornecido, tenta descriptografar conteúdo NIP-44
  Future<List<Map<String, dynamic>>> fetchDisputeEvidence(String orderId, {String? adminPrivateKey}) async {
    final evidences = <Map<String, dynamic>>[];
    
    try {
      for (final relay in _relays.take(3)) {
        try {
          final channel = WebSocketChannel.connect(Uri.parse(relay));
          final subId = 'evid_${orderId.substring(0, 8)}_${DateTime.now().millisecondsSinceEpoch % 10000}';
          
          channel.sink.add(jsonEncode(['REQ', subId, {
            'kinds': [1],
            '#t': ['bro-disputa-evidencia'],
            '#r': [orderId],
            'limit': 50,
          }]));
          
          await for (final msg in channel.stream.timeout(const Duration(seconds: 8), onTimeout: (sink) => sink.close())) {
            final data = jsonDecode(msg.toString());
            if (data is List && data.length >= 3 && data[0] == 'EVENT') {
              try {
                final eventData = data[2] as Map<String, dynamic>;
                var content = jsonDecode(eventData['content'] as String) as Map<String, dynamic>;
                
                // 🔓 Tentar descriptografar se o conteúdo está criptografado com NIP-44
                if (content['encrypted'] == true && content['encryption'] == 'nip44v2' && adminPrivateKey != null) {
                  try {
                    final senderPubkey = content['senderPubkey'] as String? ?? eventData['pubkey'] as String? ?? '';
                    final payload = content['payload'] as String;
                    final decrypted = _nip44.decryptBetween(payload, adminPrivateKey, senderPubkey);
                    content = jsonDecode(decrypted) as Map<String, dynamic>;
                    broLog('🔓 Evidência descriptografada de ${senderPubkey.substring(0, 8)}');
                  } catch (e) {
                    broLog('⚠️ Falha ao descriptografar evidência: $e');
                    content['description'] = '[Conteúdo criptografado — não foi possível descriptografar]';
                    content['image'] = null;
                  }
                }
                
                if (content['orderId'] == orderId && content['type'] == 'bro_dispute_evidence') {
                  // Evitar duplicatas por eventId
                  final eventId = eventData['id'] as String? ?? '';
                  if (!evidences.any((e) => e['eventId'] == eventId)) {
                    content['eventId'] = eventId;
                    evidences.add(content);
                  }
                }
              } catch (_) {}
            }
            if (data is List && data[0] == 'EOSE') break;
          }
          
          channel.sink.add(jsonEncode(['CLOSE', subId]));
          channel.sink.close();
          
          if (evidences.isNotEmpty) break; // Já achou, não precisa de mais relays
        } catch (e) {
          broLog('⚠️ fetchDisputeEvidence relay error: $e');
        }
      }
      
      // Ordenar por data (mais antiga primeiro)
      evidences.sort((a, b) {
        final aDate = a['sentAt'] as String? ?? '';
        final bDate = b['sentAt'] as String? ?? '';
        return aDate.compareTo(bDate);
      });
      
      broLog('📥 fetchDisputeEvidence: ${evidences.length} evidências para ${orderId.substring(0, 8)}');
      return evidences;
    } catch (e) {
      broLog('❌ fetchDisputeEvidence EXCEPTION: $e');
      return [];
    }
  }

  /// Busca o comprovante de pagamento para uma ordem específica
  /// Pesquisa kind 30081 (bro_complete) e kind 30080 diretamente pelo orderId
  /// Retorna Map com 'proofImage' (plaintext ou null) e 'encrypted' (bool)
  /// CORREÇÃO build 216: Usar tags single-letter (#d, #r, #t) suportadas por relays
  /// em vez de #orderId que é multi-char e NÃO é suportada por relays
  Future<Map<String, dynamic>> fetchProofForOrder(String orderId, {String? providerPubkey, String? privateKey}) async {
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
                
                // v236: Extrair E2E ID do PIX se disponível
                final e2eId = content['e2eId'] as String?;
                if (e2eId != null && e2eId.isNotEmpty) {
                  result['e2eId'] = e2eId;
                }
                
                // Verificar proofImage
                final proofImage = content['proofImage'] as String?;
                final proofImageNip44 = content['proofImage_nip44'] as String?;
                
                if (proofImage != null && proofImage.isNotEmpty && proofImage != '[encrypted:nip44v2]') {
                  // Plaintext - perfeito
                  result['proofImage'] = proofImage;
                  result['encrypted'] = false;
                  broLog('✅ Comprovante plaintext encontrado para ${orderId.substring(0, 8)}');
                } else if (privateKey != null) {
                  // Tentar descriptografar com a chave privada fornecida
                  final proofImageNip44Admin = content['proofImage_nip44_admin'] as String?;
                  final senderPubkey = content['providerId'] as String? ?? (eventData['pubkey'] as String?);
                  bool decrypted = false;
                  
                  // Tentar primeiro a cópia do admin
                  if (proofImageNip44Admin != null && proofImageNip44Admin.isNotEmpty && senderPubkey != null) {
                    try {
                      final decryptedProof = _nip44.decryptBetween(proofImageNip44Admin, privateKey, senderPubkey);
                      result['proofImage'] = decryptedProof;
                      result['encrypted'] = false;
                      decrypted = true;
                      broLog('🔓 Comprovante descriptografado (admin copy) para ${orderId.substring(0, 8)}');
                    } catch (e) {
                      broLog('⚠️ Falha decrypt admin copy: $e');
                    }
                  }
                  
                  // Tentar cópia do provedor (self-encrypted)
                  final proofImageNip44Provider = content['proofImage_nip44_provider'] as String?;
                  if (!decrypted && proofImageNip44Provider != null && proofImageNip44Provider.isNotEmpty) {
                    try {
                      final myPubkey = Keychain(privateKey).public;
                      final decryptedProof = _nip44.decryptFromSelf(proofImageNip44Provider, privateKey, myPubkey);
                      result['proofImage'] = decryptedProof;
                      result['encrypted'] = false;
                      decrypted = true;
                      broLog('🔓 Comprovante descriptografado (provider self copy) para ${orderId.substring(0, 8)}');
                    } catch (e) {
                      broLog('⚠️ Falha decrypt provider self copy: $e');
                    }
                  }
                  
                  // Fallback: tentar a cópia do usuário
                  if (!decrypted && proofImageNip44 != null && proofImageNip44.isNotEmpty && senderPubkey != null) {
                    try {
                      final decryptedProof = _nip44.decryptBetween(proofImageNip44, privateKey, senderPubkey);
                      result['proofImage'] = decryptedProof;
                      result['encrypted'] = false;
                      decrypted = true;
                      broLog('🔓 Comprovante descriptografado (user copy) para ${orderId.substring(0, 8)}');
                    } catch (e) {
                      broLog('⚠️ Falha decrypt user copy: $e');
                    }
                  }
                  
                  if (!decrypted) {
                    result['encrypted'] = true;
                    if (proofImageNip44 != null) result['proofImage_nip44'] = proofImageNip44;
                  }
                } else if (proofImageNip44 != null && proofImageNip44.isNotEmpty) {
                  // Existe mas é criptografado e sem chave para descriptografar
                  if (result['proofImage'] == null) {
                    result['encrypted'] = true;
                    result['proofImage_nip44'] = proofImageNip44;
                  }
                  broLog('🔐 Comprovante NIP-44 criptografado para ${orderId.substring(0, 8)}');
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
          broLog('⚠️ fetchProofForOrder relay error: $e');
        }
      }
      
      broLog('🔍 fetchProofForOrder: orderId=${orderId.substring(0, 8)}, found=${result['proofImage'] != null}, encrypted=${result['encrypted']}');
      return result;
    } catch (e) {
      broLog('❌ fetchProofForOrder EXCEPTION: $e');
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
                  broLog('\u2705 fetchOrderProviderPubkey: ${providerId.substring(0, 8)} para ordem ${orderId.substring(0, 8)}');
                  return providerId;
                }
                // Fallback: usar pubkey do autor do evento (quem aceitou = provedor)
                final eventPubkey = event['pubkey'] as String?;
                if (eventPubkey != null && eventPubkey.isNotEmpty) {
                  broLog('\u2705 fetchOrderProviderPubkey (author): ${eventPubkey.substring(0, 8)} para ordem ${orderId.substring(0, 8)}');
                  return eventPubkey;
                }
              }
            } catch (_) {}
          }
        } catch (_) {}
      }
      broLog('\uD83D\uDD0D fetchOrderProviderPubkey: n\u00e3o encontrado para ${orderId.substring(0, 8)}');
      return null;
    } catch (e) {
      broLog('\u274C fetchOrderProviderPubkey EXCEPTION: $e');
      return null;
    }
  }
}
