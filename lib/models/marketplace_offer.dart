import 'dart:convert';

/// Modelo de oferta do Marketplace
class MarketplaceOffer {
  final String id;
  final String title;
  final String description;
  final int priceSats;
  final int priceDiscount;
  final String category;
  final String sellerPubkey;
  final String sellerName;
  final DateTime createdAt;
  final String? imageUrl;
  final String? siteUrl;
  final List<String> photoBase64List; // Fotos do produto em base64
  final String? city;
  final double? avgRatingAtendimento; // Média de avaliações do vendedor
  final double? avgRatingProduto;
  final int totalReviews;

  MarketplaceOffer({
    required this.id,
    required this.title,
    required this.description,
    required this.priceSats,
    required this.priceDiscount,
    required this.category,
    required this.sellerPubkey,
    required this.sellerName,
    required this.createdAt,
    this.imageUrl,
    this.siteUrl,
    this.photoBase64List = const [],
    this.city,
    this.avgRatingAtendimento,
    this.avgRatingProduto,
    this.totalReviews = 0,
  });

  /// Cria cópia com novos campos de reputação
  MarketplaceOffer copyWith({
    double? avgRatingAtendimento,
    double? avgRatingProduto,
    int? totalReviews,
  }) {
    return MarketplaceOffer(
      id: id,
      title: title,
      description: description,
      priceSats: priceSats,
      priceDiscount: priceDiscount,
      category: category,
      sellerPubkey: sellerPubkey,
      sellerName: sellerName,
      createdAt: createdAt,
      imageUrl: imageUrl,
      siteUrl: siteUrl,
      photoBase64List: photoBase64List,
      city: city,
      avgRatingAtendimento: avgRatingAtendimento ?? this.avgRatingAtendimento,
      avgRatingProduto: avgRatingProduto ?? this.avgRatingProduto,
      totalReviews: totalReviews ?? this.totalReviews,
    );
  }

  factory MarketplaceOffer.fromNostrEvent(Map<String, dynamic> event) {
    final tags = event['tags'] as List<dynamic>? ?? [];
    String title = '';
    String description = '';
    int priceSats = 0;
    String category = 'outros';
    String? siteUrl;
    String? city;
    List<String> photos = [];

    for (final tag in tags) {
      if (tag is List && tag.isNotEmpty) {
        switch (tag[0]) {
          case 'title':
            title = tag.length > 1 ? tag[1] : '';
            break;
          case 'summary':
            description = tag.length > 1 ? tag[1] : '';
            break;
          case 'price':
            priceSats = int.tryParse(tag.length > 1 ? tag[1] : '0') ?? 0;
            break;
          case 't':
            if (tag.length > 1 && tag[1] != 'bro-marketplace' && tag[1] != 'bro-app') {
              category = tag[1];
            }
            break;
          case 'r':
            siteUrl = tag.length > 1 ? tag[1] : null;
            break;
          case 'location':
            city = tag.length > 1 ? tag[1] : null;
            break;
        }
      }
    }

    // Tentar extrair fotos do content JSON
    try {
      final content = jsonDecode(event['content'] ?? '{}');
      if (content is Map) {
        if (content['photos'] is List) {
          photos = (content['photos'] as List).cast<String>();
        }
        if (title.isEmpty) title = content['title'] ?? '';
        if (description.isEmpty) description = content['description'] ?? '';
        if (priceSats == 0) priceSats = content['priceSats'] ?? 0;
        if (category == 'outros') category = content['category'] ?? 'outros';
        if (siteUrl == null) siteUrl = content['siteUrl'];
        if (city == null) city = content['city'];
      }
    } catch (_) {
      if (description.isEmpty) description = event['content'] ?? '';
    }

    return MarketplaceOffer(
      id: event['id'] ?? '',
      title: title,
      description: description,
      priceSats: priceSats,
      priceDiscount: 0,
      category: category,
      sellerPubkey: event['pubkey'] ?? '',
      sellerName: 'Usuário ${(event['pubkey'] ?? '??????').toString().substring(0, 6)}',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        ((event['created_at'] ?? 0) as int) * 1000,
      ),
      siteUrl: siteUrl,
      city: city,
      photoBase64List: photos,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'description': description,
        'priceSats': priceSats,
        'priceDiscount': priceDiscount,
        'category': category,
        'sellerPubkey': sellerPubkey,
        'sellerName': sellerName,
        'createdAt': createdAt.toIso8601String(),
        'imageUrl': imageUrl,
        'siteUrl': siteUrl,
        'photos': photoBase64List,
        'city': city,
      };
}

/// Modelo de avaliação do marketplace
class MarketplaceReview {
  final String id;
  final String reviewerPubkey;
  final String sellerPubkey;
  final String? offerId;
  final int ratingAtendimento; // 1=ruim, 2=medio, 3=bom
  final int ratingProduto; // 1=ruim, 2=medio, 3=bom
  final String? comment;
  final DateTime createdAt;

  MarketplaceReview({
    required this.id,
    required this.reviewerPubkey,
    required this.sellerPubkey,
    this.offerId,
    required this.ratingAtendimento,
    required this.ratingProduto,
    this.comment,
    required this.createdAt,
  });

  factory MarketplaceReview.fromNostrEvent(Map<String, dynamic> event) {
    final tags = event['tags'] as List<dynamic>? ?? [];
    String sellerPubkey = '';
    String? offerId;
    int ratingAtendimento = 2;
    int ratingProduto = 2;
    String? comment;

    for (final tag in tags) {
      if (tag is List && tag.length > 1) {
        switch (tag[0]) {
          case 'p':
            sellerPubkey = tag[1];
            break;
          case 'e':
            offerId = tag[1];
            break;
          case 'rating-atendimento':
            ratingAtendimento = int.tryParse(tag[1]) ?? 2;
            break;
          case 'rating-produto':
            ratingProduto = int.tryParse(tag[1]) ?? 2;
            break;
        }
      }
    }

    try {
      final content = jsonDecode(event['content'] ?? '{}');
      if (content is Map) {
        comment = content['comment'];
        if (sellerPubkey.isEmpty) sellerPubkey = content['sellerPubkey'] ?? '';
      }
    } catch (_) {
      comment = event['content'];
    }

    return MarketplaceReview(
      id: event['id'] ?? '',
      reviewerPubkey: event['pubkey'] ?? '',
      sellerPubkey: sellerPubkey,
      offerId: offerId,
      ratingAtendimento: ratingAtendimento,
      ratingProduto: ratingProduto,
      comment: comment,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        ((event['created_at'] ?? 0) as int) * 1000,
      ),
    );
  }

  String get ratingAtendimentoLabel {
    switch (ratingAtendimento) {
      case 3:
        return 'Bom';
      case 2:
        return 'Médio';
      case 1:
        return 'Ruim';
      default:
        return 'N/A';
    }
  }

  String get ratingProdutoLabel {
    switch (ratingProduto) {
      case 3:
        return 'Bom';
      case 2:
        return 'Médio';
      case 1:
        return 'Ruim';
      default:
        return 'N/A';
    }
  }
}
