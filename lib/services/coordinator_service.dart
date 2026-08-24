import 'dart:async';
import 'dart:convert';
import 'package:nostr/nostr.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:bro_app/services/log_utils.dart';

/// Representa um "cartão de visita" (anúncio kind 30082) de um coordinator.
class CoordinatorCard {
  final String pubkey;
  final String name;
  final String fee; // ex: "0.02"
  final String lnAddress; // ex: "coordinator@coinos.io"
  final List<String> relays;
  final int createdAt;

  const CoordinatorCard({
    required this.pubkey,
    required this.name,
    required this.fee,
    required this.lnAddress,
    required this.relays,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'pubkey': pubkey,
        'name': name,
        'fee': fee,
        'lnAddress': lnAddress,
        'relays': relays,
        'createdAt': createdAt,
      };

  factory CoordinatorCard.fromJson(Map<String, dynamic> j) => CoordinatorCard(
        pubkey: j['pubkey'] as String? ?? '',
        name: j['name'] as String? ?? 'Coordinator',
        fee: j['fee'] as String? ?? '',
        lnAddress: j['lnAddress'] as String? ?? '',
        relays: (j['relays'] as List?)?.map((e) => e.toString()).toList() ?? const [],
        createdAt: j['createdAt'] as int? ?? 0,
      );
}

/// Serviço que lê os anúncios de coordinators (kind 30082, tag bro-coordinator)
/// dos relays Nostr e guarda a lista + a escolha do usuário.
///
/// ETAPA 1 (esta): apenas DESCOBRIR e LISTAR. O roteamento da taxa (Etapa 2)
/// usa `selectedCard()` para saber para qual endereço enviar a taxa.
class CoordinatorService {
  static final CoordinatorService _instance = CoordinatorService._internal();
  factory CoordinatorService() => _instance;
  CoordinatorService._internal();

  static const int kindCoordinatorAnnounce = 30082;
  static const String _selectedKey = 'selected_coordinator_pubkey'; // '' = Automático
  static const String _cachedListKey = 'coordinator_cards_cache';

  // Mesmos relays que o app já usa (a cópia caseira do PC antigo é bônus —
  // o celular lê dos públicos, onde o coordinator também publica o cartão).
  final List<String> _relays = [
    'wss://relay.damus.io',
    'wss://nos.lol',
    'wss://relay.primal.net',
  ];

  /// Pubkey do coordinator escolhido. '' (vazio) = Automático (Bro original).
  String _selectedPubkey = '';
  bool _loaded = false;

  // ── Persistência da escolha ──────────────────────────────────────────
  Future<void> loadSelection() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _selectedPubkey = prefs.getString(_selectedKey) ?? '';
      _loaded = true;
    } catch (e) {
      broLog('⚠️ CoordinatorService.loadSelection: $e');
    }
  }

  Future<void> setSelection(String pubkey) async {
    _selectedPubkey = pubkey;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_selectedKey, pubkey);
    } catch (e) {
      broLog('⚠️ CoordinatorService.setSelection: $e');
    }
  }

  String get selectedPubkey => _selectedPubkey;
  bool get isAutomatic => _selectedPubkey.isEmpty;

  /// Retorna o cartão do coordinator escolhido (null se Automático).
  /// Usado pela Etapa 2 (roteamento da taxa).
  CoordinatorCard? selectedCard(List<CoordinatorCard> cards) {
    if (isAutomatic) return null;
    for (final c in cards) {
      if (c.pubkey == _selectedPubkey) return c;
    }
    return null;
  }

  // ── Cache local da lista (para a tela abrir rápido) ─────────────────
  Future<List<CoordinatorCard>> loadCachedCards() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cachedListKey);
      if (raw == null) return [];
      final list = (jsonDecode(raw) as List)
          .map((e) => CoordinatorCard.fromJson(e as Map<String, dynamic>))
          .toList();
      return _sortCards(list);
    } catch (e) {
      broLog('⚠️ CoordinatorService.loadCachedCards: $e');
      return [];
    }
  }

  Future<void> _cacheCards(List<CoordinatorCard> cards) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          _cachedListKey, jsonEncode(cards.map((c) => c.toJson()).toList()));
    } catch (e) {
      broLog('⚠️ CoordinatorService._cacheCards: $e');
    }
  }

  /// Ordena: mais antigo (criação) primeiro; empate → mantém estável.
  /// A reputação (kind 30083) ainda não é usada — entra em fase posterior.
  List<CoordinatorCard> _sortCards(List<CoordinatorCard> cards) {
    final sorted = [...cards];
    sorted.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return sorted;
  }

  // ── Busca dos cartões nos relays ─────────────────────────────────────
  /// Busca os anúncios kind 30082 com tag bro-coordinator nos relays públicos.
  /// Retorna a lista (ordenada) e atualiza o cache. Falha tolerante: se um
  /// relay falhar, segue para o próximo.
  Future<List<CoordinatorCard>> fetchCoordinatorCards() async {
    final Map<String, CoordinatorCard> byPubkey = {};

    final filter = {
      'kinds': [kindCoordinatorAnnounce],
      '#t': ['bro-coordinator'],
      'limit': 50,
    };

    for (final relay in _relays) {
      try {
        final channel = WebSocketChannel.connect(Uri.parse(relay));
        final subId = 'coord_${DateTime.now().millisecondsSinceEpoch % 100000}';
        channel.sink.add(jsonEncode(['REQ', subId, filter]));

        await for (final msg in channel.stream.timeout(
          const Duration(seconds: 8),
          onTimeout: (sink) => sink.close(),
        )) {
          final data = jsonDecode(msg.toString());
          if (data is List && data.length >= 3 && data[0] == 'EVENT') {
            final eventData = data[2] as Map<String, dynamic>;
            final card = _parseCard(eventData);
            if (card != null) {
              final existing = byPubkey[card.pubkey];
              if (existing == null || card.createdAt > existing.createdAt) {
                byPubkey[card.pubkey] = card;
              }
            }
          }
          if (data is List && data.isNotEmpty && data[0] == 'EOSE') break;
        }
        try {
          channel.sink.close();
        } catch (_) {}
      } catch (e) {
        broLog('⚠️ CoordinatorService.fetch relay $relay: $e');
      }
    }

    final cards = _sortCards(byPubkey.values.toList());
    await _cacheCards(cards);
    broLog('🧭 CoordinatorService: ${cards.length} coordinator(s) descoberto(s)');
    return cards;
  }

  CoordinatorCard? _parseCard(Map<String, dynamic> eventData) {
    try {
      if ((eventData['kind'] as int?) != kindCoordinatorAnnounce) return null;
      final tags = eventData['tags'];
      if (tags is! List) return null;
      // Só cartões marcados como bro-coordinator
      final isBro = tags.any((t) => t is List && t.length >= 2 && t[0] == 't' && t[1] == 'bro-coordinator');
      if (!isBro) return null;

      // SEGURANÇA: verificar assinatura antes de confiar em qualquer tag
      try {
        Event.fromJson(eventData, verify: true);
      } catch (_) {
        return null;
      }

      final pubkey = eventData['pubkey'] as String? ?? '';
      if (pubkey.length != 64) return null;
      final createdAt = eventData['created_at'] as int? ?? 0;

      String name = 'Coordinator';
      String fee = '';
      String ln = '';
      final List<String> relays = [];
      for (final t in tags) {
        if (t is! List || t.length < 2) continue;
        switch (t[0]) {
          case 'name':
            name = t[1].toString();
            break;
          case 'fee':
            fee = t[1].toString();
            break;
          case 'ln':
            ln = t[1].toString();
            break;
          case 'relay':
            relays.add(t[1].toString());
            break;
        }
      }
      // Sem endereço Lightning não serve para rotear taxa — mas ainda listamos
      // (a Etapa 2 só habilita a escolha se lnAddress não estiver vazio).
      return CoordinatorCard(
        pubkey: pubkey,
        name: name,
        fee: fee,
        lnAddress: ln,
        relays: relays,
        createdAt: createdAt,
      );
    } catch (e) {
      broLog('⚠️ CoordinatorService._parseCard: $e');
      return null;
    }
  }
}
