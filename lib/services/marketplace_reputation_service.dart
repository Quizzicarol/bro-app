import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:nostr/nostr.dart';
import 'package:uuid/uuid.dart';
import '../models/marketplace_offer.dart';
import 'nostr_order_service.dart';

/// Serviço de reputação do Marketplace
/// Publica e busca avaliações via Nostr (kind 30085)
class MarketplaceReputationService {
  static final MarketplaceReputationService _instance =
      MarketplaceReputationService._internal();
  factory MarketplaceReputationService() => _instance;
  MarketplaceReputationService._internal();

  final NostrOrderService _nostrOrderService = NostrOrderService();

  // Kind personalizado para reviews do marketplace Bro
  static const int kindBroReview = 30085;
  static const String reviewTag = 'bro-review';

  // Cache de reviews por vendedor
  final Map<String, List<MarketplaceReview>> _reviewCache = {};
  // Cache de médias calculadas
  final Map<String, Map<String, double>> _avgCache = {};

  static const List<String> _relays = [
    'wss://relay.damus.io',
    'wss://nos.lol',
    'wss://relay.primal.net',
  ];

  /// Publica uma avaliação para um vendedor
  Future<bool> publishReview({
    required String privateKey,
    required String sellerPubkey,
    required int ratingAtendimento, // 1=ruim, 2=medio, 3=bom
    required int ratingProduto, // 1=ruim, 2=medio, 3=bom
    String? offerId,
    String? comment,
  }) async {
    try {
      final keychain = Keychain(privateKey);
      final reviewId = const Uuid().v4();

      final content = jsonEncode({
        'type': 'bro_review',
        'version': '1.0',
        'reviewId': reviewId,
        'sellerPubkey': sellerPubkey,
        'ratingAtendimento': ratingAtendimento,
        'ratingProduto': ratingProduto,
        'comment': comment,
        'createdAt': DateTime.now().toIso8601String(),
      });

      final tags = [
        ['d', reviewId],
        ['t', reviewTag],
        ['t', 'bro-app'],
        ['p', sellerPubkey],
        ['rating-atendimento', ratingAtendimento.toString()],
        ['rating-produto', ratingProduto.toString()],
      ];

      if (offerId != null && offerId.isNotEmpty) {
        tags.add(['e', offerId]);
      }

      final event = Event.from(
        kind: kindBroReview,
        tags: tags,
        content: content,
        privkey: keychain.private,
      );

      // Publicar em paralelo em todos os relays
      final results = await Future.wait(
        _relays.map((relay) =>
            _nostrOrderService.publishToRelayPublic(relay, event).catchError((_) => false)),
      );
      final successCount = results.where((s) => s).length;

      debugPrint(
          '⭐ Review publicada em $successCount/${_relays.length} relays (seller: ${sellerPubkey.substring(0, 8)})');

      // Limpar cache para forçar recarga
      _reviewCache.remove(sellerPubkey);
      _avgCache.remove(sellerPubkey);

      return successCount > 0;
    } catch (e) {
      debugPrint('❌ Erro ao publicar review: $e');
      return false;
    }
  }

  /// Busca todas as avaliações de um vendedor
  Future<List<MarketplaceReview>> fetchReviewsForSeller(String sellerPubkey) async {
    // Verificar cache
    if (_reviewCache.containsKey(sellerPubkey)) {
      return _reviewCache[sellerPubkey]!;
    }

    final reviews = <MarketplaceReview>[];
    final seenIds = <String>{};

    try {
      final relayResults = await Future.wait(
        _relays.map((relay) => _nostrOrderService
            .fetchFromRelayPublic(relay,
                kinds: [kindBroReview],
                tags: {
                  '#p': [sellerPubkey],
                  '#t': [reviewTag]
                },
                limit: 100)
            .catchError((_) => <Map<String, dynamic>>[])),
      );

      for (final events in relayResults) {
        for (final event in events) {
          final id = event['id'];
          if (id != null && !seenIds.contains(id)) {
            seenIds.add(id);
            try {
              reviews.add(MarketplaceReview.fromNostrEvent(event));
            } catch (e) {
              debugPrint('⚠️ Erro ao parsear review: $e');
            }
          }
        }
      }

      // Ordenar por data (mais recente primeiro)
      reviews.sort((a, b) => b.createdAt.compareTo(a.createdAt));

      // Cachear
      _reviewCache[sellerPubkey] = reviews;

      debugPrint(
          '⭐ ${reviews.length} reviews carregadas para seller ${sellerPubkey.substring(0, 8)}');
    } catch (e) {
      debugPrint('❌ Erro ao buscar reviews: $e');
    }

    return reviews;
  }

  /// Busca reviews de múltiplos vendedores em paralelo
  Future<Map<String, List<MarketplaceReview>>> fetchReviewsForSellers(
      List<String> sellerPubkeys) async {
    final uniquePubkeys = sellerPubkeys.toSet().toList();
    final result = <String, List<MarketplaceReview>>{};

    // Buscar todos em paralelo
    final futures = uniquePubkeys.map((pk) => fetchReviewsForSeller(pk));
    final results = await Future.wait(futures);

    for (int i = 0; i < uniquePubkeys.length; i++) {
      result[uniquePubkeys[i]] = results[i];
    }

    return result;
  }

  /// Calcula médias de avaliação de um vendedor
  Map<String, double> getAverageRatings(String sellerPubkey) {
    if (_avgCache.containsKey(sellerPubkey)) {
      return _avgCache[sellerPubkey]!;
    }

    final reviews = _reviewCache[sellerPubkey] ?? [];
    if (reviews.isEmpty) {
      return {'atendimento': 0, 'produto': 0, 'total': 0};
    }

    double sumAtendimento = 0;
    double sumProduto = 0;
    for (final review in reviews) {
      sumAtendimento += review.ratingAtendimento;
      sumProduto += review.ratingProduto;
    }

    final avg = {
      'atendimento': sumAtendimento / reviews.length,
      'produto': sumProduto / reviews.length,
      'total': reviews.length.toDouble(),
    };

    _avgCache[sellerPubkey] = avg;
    return avg;
  }

  /// Retorna label de rating (emoji + texto)
  static String ratingLabel(double avg) {
    if (avg >= 2.5) return '👍 Bom';
    if (avg >= 1.5) return '👌 Médio';
    if (avg > 0) return '👎 Ruim';
    return 'Sem avaliações';
  }

  /// Retorna cor do rating
  static int ratingColorValue(double avg) {
    if (avg >= 2.5) return 0xFF4CAF50; // Verde
    if (avg >= 1.5) return 0xFFFFA726; // Laranja
    if (avg > 0) return 0xFFEF5350; // Vermelho
    return 0xFF9E9E9E; // Cinza
  }

  /// Limpar cache
  void clearCache() {
    _reviewCache.clear();
    _avgCache.clear();
  }
}
