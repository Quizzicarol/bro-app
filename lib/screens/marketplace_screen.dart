import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/marketplace_offer.dart';
import '../services/nostr_service.dart';
import '../services/nostr_order_service.dart';
import '../services/bitcoin_price_service.dart';
import '../services/content_moderation_service.dart';
import '../services/marketplace_reputation_service.dart';
import '../config.dart';
import '../services/chat_service.dart';
import 'marketplace_chat_screen.dart';
import 'nostr_conversations_screen.dart';
import 'offer_screen.dart';
import '../l10n/app_localizations.dart';

/// Tela do Marketplace para ver ofertas publicadas no Nostr
/// Utiliza NIP-15 (kind 30019) para listagem de classificados
class MarketplaceScreen extends StatefulWidget {
  const MarketplaceScreen({super.key});

  @override
  State<MarketplaceScreen> createState() => _MarketplaceScreenState();
}

class _MarketplaceScreenState extends State<MarketplaceScreen> with SingleTickerProviderStateMixin {
  final NostrService _nostrService = NostrService();
  final NostrOrderService _nostrOrderService = NostrOrderService();
  final ContentModerationService _moderationService = ContentModerationService();
  final MarketplaceReputationService _reputationService = MarketplaceReputationService();
  
  late TabController _tabController;
  
  List<MarketplaceOffer> _offers = [];
  List<MarketplaceOffer> _myOffers = [];
  bool _isLoading = true;
  String? _error;
  double _btcPrice = 0;
  bool _disclaimerDismissed = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      _btcPrice = await BitcoinPriceService.getBitcoinPriceInBRL() ?? 480558;
      await _loadOffers();
      
      if (mounted) {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadOffers() async {
    try {
      final myPubkey = _nostrService.publicKey;
      broLog('🔍 Carregando ofertas do marketplace...');
      
      await _moderationService.loadFromCache();
      final nostrOffers = await _nostrOrderService.fetchMarketplaceOffers();
      broLog('📦 ${nostrOffers.length} ofertas do Nostr');
      
      final allOffers = nostrOffers.map((data) {
        List<String> photos = [];
        if (data['photos'] is List) {
          photos = (data['photos'] as List).whereType<String>().toList();
        }
        return MarketplaceOffer(
          id: data['id'] ?? '',
          title: data['title'] ?? '',
          description: data['description'] ?? '',
          priceSats: data['priceSats'] ?? 0,
          priceDiscount: 0,
          category: data['category'] ?? 'outros',
          sellerPubkey: data['sellerPubkey'] ?? '',
          sellerName: 'Usuário ${(data['sellerPubkey'] ?? '??????').toString().substring(0, 6)}',
          createdAt: DateTime.tryParse(data['createdAt'] ?? '') ?? DateTime.now(),
          siteUrl: data['siteUrl'],
          city: data['city'],
          photoBase64List: photos,
          quantity: data['quantity'] ?? 0,
          sold: data['sold'] ?? 0,
        );
      }).toList();
      
      final eventIds = allOffers.map((o) => o.id).where((id) => id.isNotEmpty).toList();
      await _moderationService.fetchGlobalReports(eventIds);
      
      final filteredOffers = allOffers.where((offer) {
        return !_moderationService.shouldHideOffer(
          title: offer.title,
          description: offer.description,
          sellerPubkey: offer.sellerPubkey,
          eventId: offer.id,
        );
      }).toList();
      
      // Buscar reputação de todos os vendedores em paralelo
      final sellerPubkeys = filteredOffers.map((o) => o.sellerPubkey).toSet().toList();
      if (sellerPubkeys.isNotEmpty) {
        await _reputationService.fetchReviewsForSellers(sellerPubkeys);
      }
      
      // Enriquecer ofertas com dados de reputação
      final enrichedOffers = filteredOffers.map((offer) {
        final avg = _reputationService.getAverageRatings(offer.sellerPubkey);
        return offer.copyWith(
          avgRatingAtendimento: avg['atendimento'],
          avgRatingProduto: avg['produto'],
          totalReviews: avg['total']?.toInt() ?? 0,
        );
      }).toList();
      
      // Ordenar
      enrichedOffers.sort((a, b) {
        final trustA = _moderationService.getTrustScore(a.sellerPubkey);
        final trustB = _moderationService.getTrustScore(b.sellerPubkey);
        if (trustA != trustB) return trustB.compareTo(trustA);
        return b.createdAt.compareTo(a.createdAt);
      });
      
      final finalOffers = enrichedOffers.isEmpty && allOffers.isEmpty 
          ? _generateSampleOffers() 
          : enrichedOffers;
      
      if (mounted) {
        setState(() {
          _offers = finalOffers.toList();
          _myOffers = finalOffers.where((o) => o.sellerPubkey == myPubkey).toList();
        });
      }
    } catch (e) {
      broLog('❌ Erro ao carregar ofertas: $e');
    }
  }

  List<MarketplaceOffer> _generateSampleOffers() {
    return [
      MarketplaceOffer(
        id: '1',
        title: AppLocalizations.of(context).t('market_sample_title_1'),
        description: AppLocalizations.of(context).t('market_sample_desc_1'),
        priceSats: 50000,
        priceDiscount: 0,
        category: 'servicos',
        sellerPubkey: 'npub1example1......',
        sellerName: 'Bitcoin Coach',
        createdAt: DateTime.now().subtract(const Duration(hours: 2)),
      ),
      MarketplaceOffer(
        id: '2',
        title: AppLocalizations.of(context).t('market_sample_title_2'),
        description: AppLocalizations.of(context).t('market_sample_desc_2'),
        priceSats: 200000,
        priceDiscount: 0,
        category: 'produtos',
        sellerPubkey: 'npub1example2......',
        sellerName: 'BTC Store',
        createdAt: DateTime.now().subtract(const Duration(hours: 5)),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Text(AppLocalizations.of(context).t('market_title')),
        actions: [
          IconButton(
            icon: const Icon(Icons.chat_bubble_outline),
            onPressed: () => Navigator.pushNamed(context, '/nostr-messages'),
            tooltip: AppLocalizations.of(context).t('home_messages'),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const OfferScreen()),
              ).then((_) => _loadOffers());
            },
            tooltip: AppLocalizations.of(context).t('market_create_offer'),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.orange,
          labelColor: Colors.orange,
          unselectedLabelColor: Colors.white60,
          tabs: [
            Tab(text: AppLocalizations.of(context).t('market_tab_offers'), icon: const Icon(Icons.storefront)),
            Tab(text: AppLocalizations.of(context).t('market_tab_my_offers'), icon: const Icon(Icons.sell)),
          ],
        ),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            // Disclaimer banner
            if (!_disclaimerDismissed) _buildDisclaimerBanner(),
            // Content
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFFFF6B6B)))
                  : _error != null
                      ? _buildErrorView()
                      : TabBarView(
                          controller: _tabController,
                          children: [
                            _buildOffersTab(),
                            _buildMyOffersTab(),
                          ],
                        ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================
  // DISCLAIMER BANNER
  // ============================================

  Widget _buildDisclaimerBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.red.shade900.withOpacity(0.9),
            Colors.red.shade800.withOpacity(0.7),
          ],
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              AppLocalizations.of(context).t('market_disclaimer_full'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                height: 1.3,
              ),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _disclaimerDismissed = true),
            child: const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Icon(Icons.close, color: Colors.white54, size: 18),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================
  // OFFERS TABS
  // ============================================

  Widget _buildOffersTab() {
    if (_offers.isEmpty) {
      return _buildEmptyView(
        AppLocalizations.of(context).t('market_no_offers'),
        AppLocalizations.of(context).t('market_be_first'),
        Icons.storefront_outlined,
      );
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      color: Colors.orange,
      child: GridView.builder(
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 6,
          mainAxisSpacing: 6,
          childAspectRatio: 0.55, // Retangular vertical
        ),
        itemCount: _offers.length,
        itemBuilder: (context, index) => _buildOfferCardGrid(_offers[index]),
      ),
    );
  }

  Widget _buildMyOffersTab() {
    if (_myOffers.isEmpty) {
      return _buildEmptyView(
        AppLocalizations.of(context).t('market_no_my_offers'),
        AppLocalizations.of(context).t('market_create_offer_cta'),
        Icons.sell_outlined,
      );
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      color: Colors.orange,
      child: GridView.builder(
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 6,
          mainAxisSpacing: 6,
          childAspectRatio: 0.55,
        ),
        itemCount: _myOffers.length,
        itemBuilder: (context, index) => _buildOfferCardGrid(_myOffers[index], isMine: true),
      ),
    );
  }

  // ============================================
  // v253: OFFER CARD GRID (compacto, 3 colunas)
  // ============================================

  Widget _buildOfferCardGrid(MarketplaceOffer offer, {bool isMine = false}) {
    final categoryInfo = _getCategoryInfo(offer.category, ctx: context);
    final priceInBrl = offer.priceSats > 0 && _btcPrice > 0
        ? (offer.priceSats / 100000000) * _btcPrice
        : 0.0;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isMine ? Colors.orange.withOpacity(0.5) : Colors.white12,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _showOfferDetail(offer),
          borderRadius: BorderRadius.circular(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Foto ou placeholder
              ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
                child: SizedBox(
                  height: 80,
                  width: double.infinity,
                  child: offer.photoBase64List.isNotEmpty
                      ? _buildBase64Image(offer.photoBase64List.first, fit: BoxFit.cover)
                      : Container(
                          color: (categoryInfo['color'] as Color).withOpacity(0.15),
                          child: Center(
                            child: Icon(
                              categoryInfo['icon'] as IconData,
                              color: (categoryInfo['color'] as Color).withOpacity(0.5),
                              size: 28,
                            ),
                          ),
                        ),
                ),
              ),
              // Conteúdo
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Badge MINHA + Categoria
                      Row(
                        children: [
                          if (isMine)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                              margin: const EdgeInsets.only(right: 3),
                              decoration: BoxDecoration(
                                color: Colors.orange.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(3),
                                border: Border.all(color: Colors.orange, width: 0.5),
                              ),
                              child: Text(
                                AppLocalizations.of(context).t('market_mine_badge'),
                                style: const TextStyle(color: Colors.orange, fontSize: 7, fontWeight: FontWeight.bold),
                              ),
                            ),
                          Expanded(
                            child: Text(
                              categoryInfo['label'] as String,
                              style: TextStyle(
                                color: categoryInfo['color'] as Color,
                                fontSize: 8,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      // Título
                      Text(
                        offer.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          height: 1.2,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const Spacer(),
                      // Preço em sats
                      if (offer.priceSats > 0) ...[
                        Row(
                          children: [
                            const Icon(Icons.bolt, color: Colors.amber, size: 12),
                            Expanded(
                              child: Text(
                                '${_formatSats(offer.priceSats)}',
                                style: const TextStyle(
                                  color: Colors.amber,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        if (priceInBrl > 0)
                          Text(
                            'R\$ ${priceInBrl.toStringAsFixed(2)}',
                            style: const TextStyle(color: Colors.white38, fontSize: 8),
                            maxLines: 1,
                          ),
                      ] else
                        Text(
                          AppLocalizations.of(context).t('market_price_on_request'),
                          style: const TextStyle(color: Colors.white38, fontSize: 9),
                        ),
                      // Estoque
                      if (offer.quantity > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            offer.isOutOfStock ? AppLocalizations.of(context).t('market_out_of_stock') : '${offer.remaining} un.',
                            style: TextStyle(
                              color: offer.isOutOfStock ? Colors.red : Colors.blue.shade300,
                              fontSize: 8,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================
  // REPUTATION BADGE (compact)
  // ============================================

  Widget _buildReputationBadge(MarketplaceOffer offer) {
    final avgAtend = offer.avgRatingAtendimento ?? 0;
    final avgProd = offer.avgRatingProduto ?? 0;
    final total = offer.totalReviews;
    
    if (total == 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.star_border, size: 14, color: Colors.white38),
            const SizedBox(width: 4),
            Text(
              AppLocalizations.of(context).t('market_no_reviews'),
              style: const TextStyle(fontSize: 11, color: Colors.white38),
            ),
          ],
        ),
      );
    }
    
    final avgTotal = (avgAtend + avgProd) / 2;
    final color = Color(MarketplaceReputationService.ratingColorValue(avgTotal));
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.star, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            AppLocalizations.of(context).tp('market_reputation_summary', {'atend': _ratingEmoji(avgAtend), 'produto': _ratingEmoji(avgProd), 'total': total.toString()}),
            style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  String _ratingEmoji(double avg) {
    if (avg >= 2.5) return '👍';
    if (avg >= 1.5) return '👌';
    if (avg > 0) return '👎';
    return '—';
  }

  // ============================================
  // CHECK FOR UPDATE
  // ============================================

  // ============================================
  // OFFER DETAIL (Bottom Sheet)
  // ============================================

  void _showOfferDetail(MarketplaceOffer offer) {
    final categoryInfo = _getCategoryInfo(offer.category, ctx: context);
    final priceInBrl = offer.priceSats > 0 && _btcPrice > 0
        ? (offer.priceSats / 100000000) * _btcPrice
        : 0.0;
    final isMine = offer.sellerPubkey == _nostrService.publicKey;
    final shortId = _generateShortId(offer.id);

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => SafeArea(
          top: false,
          child: ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 40),
          children: [
            // Handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            
            // Fotos do produto (carrossel)
            if (offer.photoBase64List.isNotEmpty) ...[
              SizedBox(
                height: 220,
                child: PageView.builder(
                  itemCount: offer.photoBase64List.length,
                  itemBuilder: (context, index) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: _buildBase64Image(offer.photoBase64List[index], fit: BoxFit.cover),
                      ),
                    );
                  },
                ),
              ),
              if (offer.photoBase64List.length > 1)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Center(
                    child: Text(
                      AppLocalizations.of(context).tp('market_photos_swipe', {'count': offer.photoBase64List.length.toString()}),
                      style: const TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
            ],
            
            // Categoria
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: (categoryInfo['color'] as Color).withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(categoryInfo['icon'] as IconData, color: categoryInfo['color'] as Color, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    categoryInfo['label'] as String,
                    style: TextStyle(
                      color: categoryInfo['color'] as Color,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            
            // Título
            Text(
              offer.title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            // v248: ID do anúncio
            Text(
              AppLocalizations.of(context).tp('market_listing_id', {'id': shortId}),
              style: const TextStyle(color: Colors.white38, fontSize: 12, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 16),
            
            // Descrição
            Text(AppLocalizations.of(context).t('market_description'), style: const TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 4),
            Text(
              offer.description,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
            const SizedBox(height: 20),
            
            // Preço
            if (offer.priceSats > 0) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.amber.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.bolt, color: Colors.amber, size: 32),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_formatSats(offer.priceSats)} sats',
                          style: const TextStyle(
                            color: Colors.amber,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (priceInBrl > 0)
                          Text(
                            '≈ R\$ ${priceInBrl.toStringAsFixed(2)}',
                            style: const TextStyle(color: Colors.white54, fontSize: 14),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
            
            // Estoque (se o produto tem quantidade definida)
            if (offer.quantity > 0) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: offer.isOutOfStock
                      ? Colors.red.withOpacity(0.1)
                      : Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: offer.isOutOfStock
                        ? Colors.red.withOpacity(0.3)
                        : Colors.blue.withOpacity(0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      offer.isOutOfStock ? Icons.remove_shopping_cart : Icons.inventory_2,
                      color: offer.isOutOfStock ? Colors.red : Colors.blue,
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          offer.isOutOfStock
                              ? AppLocalizations.of(context).t('market_out_of_stock')
                              : AppLocalizations.of(context).tp('market_units_available', {'count': offer.remaining.toString()}),
                          style: TextStyle(
                            color: offer.isOutOfStock ? Colors.red : Colors.blue,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          AppLocalizations.of(context).tp('market_sold_of', {'sold': offer.sold.toString(), 'total': offer.quantity.toString()}),
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            
            // Reputação do vendedor (detalhada)
            _buildReputationSection(offer),
            const SizedBox(height: 16),
            
            // Site ou Referências
            if (offer.siteUrl != null && offer.siteUrl!.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.blue.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.link, color: Colors.blue, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(AppLocalizations.of(context).t('market_site_references'), style: const TextStyle(color: Colors.white54, fontSize: 12)),
                          const SizedBox(height: 4),
                          Text(
                            offer.siteUrl!,
                            style: const TextStyle(color: Colors.blue, fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: offer.siteUrl!));
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(AppLocalizations.of(context).t('market_link_copied'))),
                        );
                      },
                      icon: const Icon(Icons.copy, color: Colors.blue),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            
            // BTCMap link
            _buildBtcMapSection(offer),
            const SizedBox(height: 16),
            
            // Vendedor
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: Colors.orange.withOpacity(0.2),
                    child: const Icon(Icons.person, color: Colors.orange),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          offer.sellerName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${offer.sellerPubkey.length > 20 ? offer.sellerPubkey.substring(0, 20) : offer.sellerPubkey}...',
                          style: const TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: offer.sellerPubkey));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(AppLocalizations.of(context).t('market_pubkey_copied'))),
                      );
                    },
                    icon: const Icon(Icons.copy, color: Colors.white54),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            
            // Disclaimer inline
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.withOpacity(0.2)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: Colors.redAccent, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      AppLocalizations.of(context).t('market_disclaimer_full'),
                      style: const TextStyle(color: Colors.redAccent, fontSize: 11, height: 1.3),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            
            // Botões de ação
            if (isMine) ...[
              // v248: Botões específicos do vendedor
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    _showOfferMessages(offer);
                  },
                  icon: const Icon(Icons.message),
                  label: Text(AppLocalizations.of(context).t('market_view_messages')),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: AppLocalizations.of(context).tp('market_listing_id', {'id': shortId})));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(AppLocalizations.of(context).tp('market_id_copied', {'id': shortId}))),
                    );
                  },
                  icon: const Icon(Icons.copy, color: Colors.white54, size: 18),
                  label: Text(AppLocalizations.of(context).tp('market_copy_id', {'id': shortId}), style: const TextStyle(color: Colors.white54)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.white24),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              // v253: Botão de excluir oferta
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _confirmDeleteOffer(offer),
                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                  label: Text(AppLocalizations.of(context).t('market_delete_offer'), style: const TextStyle(color: Colors.redAccent)),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Colors.redAccent.withOpacity(0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
            ] else ...[
            // 1. Contato via DM
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  _contactSeller(offer);
                },
                icon: const Icon(Icons.message),
                label: Text(AppLocalizations.of(context).t('market_contact')),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(height: 10),
            
            // 2. Pagar com Lightning
            if (offer.priceSats > 0)
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    _showPaymentFlow(offer);
                  },
                  icon: const Icon(Icons.bolt, color: Colors.black),
                  label: Text(AppLocalizations.of(context).t('market_pay_lightning'), style: const TextStyle(color: Colors.black)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            const SizedBox(height: 10),
            
            // 3. Avaliar vendedor
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  _showReviewDialog(offer);
                },
                icon: const Icon(Icons.star_border, color: Colors.amber),
                label: Text(AppLocalizations.of(context).t('market_rate_seller'), style: const TextStyle(color: Colors.amber)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.amber),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            ],
            const SizedBox(height: 12),
            
            // Compartilhar e Reportar
            Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed: () {
                      final l = AppLocalizations.of(context);
                      Clipboard.setData(ClipboardData(
                        text: l.tp('market_share_text', {
                          'title': offer.title,
                          'price': _formatSats(offer.priceSats),
                          'seller': offer.sellerName,
                          'pubkey': offer.sellerPubkey,
                        }) + (offer.siteUrl != null ? l.tp('market_share_text_site', {'site': offer.siteUrl!}) : ''),
                      ));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(l.t('market_offer_copied'))),
                      );
                    },
                    icon: const Icon(Icons.share, size: 16),
                    label: Text(AppLocalizations.of(context).t('market_share')),
                    style: TextButton.styleFrom(foregroundColor: Colors.white70),
                  ),
                ),
                Expanded(
                  child: TextButton.icon(
                    onPressed: () => _showReportDialog(offer),
                    icon: const Icon(Icons.flag_outlined, color: Colors.red, size: 16),
                    label: Text(AppLocalizations.of(context).t('market_report'), style: const TextStyle(color: Colors.red)),
                  ),
                ),
              ],
            ),
          ],
        ),
        ),
      ),
    );
  }

  // ============================================
  // REPUTATION SECTION (detailed in offer detail)
  // ============================================
  // ============================================

  Widget _buildReputationSection(MarketplaceOffer offer) {
    final avgAtend = offer.avgRatingAtendimento ?? 0;
    final avgProd = offer.avgRatingProduto ?? 0;
    final total = offer.totalReviews;
    
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.star, color: Colors.amber, size: 20),
              const SizedBox(width: 8),
              Text(
                AppLocalizations.of(context).t('market_seller_reputation'),
                style: TextStyle(
                  color: Colors.amber.shade300,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              Text(
                AppLocalizations.of(context).tp('market_reviews_count', {'total': total.toString()}),
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
          if (total > 0) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildRatingBar(AppLocalizations.of(context).t('market_service_rating'), avgAtend),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildRatingBar(AppLocalizations.of(context).t('market_product_rating'), avgProd),
                ),
              ],
            ),
          ] else ...[
            const SizedBox(height: 8),
            Text(
              AppLocalizations.of(context).t('market_no_reviews_be_first'),
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRatingBar(String label, double avg) {
    final color = Color(MarketplaceReputationService.ratingColorValue(avg));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(
              MarketplaceReputationService.ratingLabel(avg),
              style: TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: avg / 3.0,
            backgroundColor: Colors.white.withOpacity(0.1),
            valueColor: AlwaysStoppedAnimation(color),
            minHeight: 6,
          ),
        ),
      ],
    );
  }

  // ============================================
  // BTCMAP SECTION
  // ============================================

  Widget _buildBtcMapSection(MarketplaceOffer offer) {
    final city = offer.city ?? '';
    final hasCity = city.isNotEmpty && !city.startsWith('📍');
    final cleanCity = city.replaceAll('📍', '').trim();
    
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A3A2A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.map, color: Colors.green, size: 20),
              const SizedBox(width: 8),
              Text(
                AppLocalizations.of(context).t('market_btcmap_title'),
                style: const TextStyle(
                  color: Colors.green,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            hasCity
                ? AppLocalizations.of(context).tp('market_btcmap_near', {'city': cleanCity})
                : AppLocalizations.of(context).t('market_btcmap_global'),
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _openBtcMap(cleanCity),
              icon: const Icon(Icons.open_in_new, size: 16, color: Colors.green),
              label: Text(
                hasCity ? AppLocalizations.of(context).tp('market_btcmap_view_city', {'city': cleanCity}) : AppLocalizations.of(context).t('market_btcmap_open'),
                style: const TextStyle(color: Colors.green),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.green),
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openBtcMap(String city) async {
    String url;
    if (city.isNotEmpty) {
      final encodedCity = Uri.encodeComponent(city);
      url = 'https://btcmap.org/map#q=$encodedCity';
    } else {
      url = 'https://btcmap.org/map';
    }
    
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).tp('market_btcmap_error', {'error': e.toString()})), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ============================================
  // REVIEW DIALOG
  // ============================================

  void _showReviewDialog(MarketplaceOffer offer) {
    int ratingAtendimento = 3;
    int ratingProduto = 3;
    final commentController = TextEditingController();
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.star, color: Colors.amber),
              const SizedBox(width: 8),
              Expanded(
                child: Text(AppLocalizations.of(context).t('market_rate_seller_title'), style: const TextStyle(color: Colors.white, fontSize: 18)),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  offer.sellerName,
                  style: const TextStyle(color: Colors.orange, fontSize: 14, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 20),
                
                Text(AppLocalizations.of(context).t('market_rating_service'), style: const TextStyle(color: Colors.white70, fontSize: 14)),
                const SizedBox(height: 8),
                _buildRatingSelector(
                  value: ratingAtendimento,
                  onChanged: (v) => setDialogState(() => ratingAtendimento = v),
                  ctx: context,
                ),
                const SizedBox(height: 16),
                
                Text(AppLocalizations.of(context).t('market_rating_product'), style: const TextStyle(color: Colors.white70, fontSize: 14)),
                const SizedBox(height: 8),
                _buildRatingSelector(
                  value: ratingProduto,
                  onChanged: (v) => setDialogState(() => ratingProduto = v),
                  ctx: context,
                ),
                const SizedBox(height: 16),
                
                TextField(
                  controller: commentController,
                  style: const TextStyle(color: Colors.white),
                  maxLines: 2,
                  decoration: InputDecoration(
                    hintText: AppLocalizations.of(context).t('market_comment_hint'),
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: const Color(0xFF2E2E2E),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(AppLocalizations.of(context).t('cancel'), style: const TextStyle(color: Colors.white54)),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                Navigator.pop(dialogContext);
                
                scaffoldMessenger.showSnackBar(
                  SnackBar(content: Text(AppLocalizations.of(context).t('market_publishing_review'))),
                );
                
                final nostrService = NostrService();
                final privateKey = nostrService.privateKey;
                if (privateKey == null) {
                  scaffoldMessenger.showSnackBar(
                    SnackBar(content: Text(AppLocalizations.of(context).t('market_login_to_rate')), backgroundColor: Colors.red),
                  );
                  return;
                }
                
                final success = await _reputationService.publishReview(
                  privateKey: privateKey,
                  sellerPubkey: offer.sellerPubkey,
                  ratingAtendimento: ratingAtendimento,
                  ratingProduto: ratingProduto,
                  offerId: offer.id,
                  comment: commentController.text.isEmpty ? null : commentController.text,
                );
                
                scaffoldMessenger.showSnackBar(
                  SnackBar(
                    content: Text(success 
                      ? AppLocalizations.of(context).t('market_review_published')
                      : AppLocalizations.of(context).t('market_review_failed')),
                    backgroundColor: success ? Colors.green : Colors.red,
                  ),
                );
                
                if (success) {
                  _reputationService.clearCache();
                  _loadOffers();
                }
              },
              icon: const Icon(Icons.send),
              label: Text(AppLocalizations.of(context).t('market_publish')),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.amber),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRatingSelector({required int value, required ValueChanged<int> onChanged, BuildContext? ctx}) {
    final effectiveCtx = ctx ?? this.context;
    final options = [
      {'value': 3, 'label': AppLocalizations.of(effectiveCtx).t('market_rating_good'), 'color': Colors.green},
      {'value': 2, 'label': AppLocalizations.of(effectiveCtx).t('market_rating_medium'), 'color': Colors.orange},
      {'value': 1, 'label': AppLocalizations.of(effectiveCtx).t('market_rating_bad'), 'color': Colors.red},
    ];
    
    return Row(
      children: options.map((opt) {
        final isSelected = value == opt['value'];
        return Expanded(
          child: GestureDetector(
            onTap: () => onChanged(opt['value'] as int),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: isSelected
                    ? (opt['color'] as Color).withOpacity(0.25)
                    : const Color(0xFF2E2E2E),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isSelected
                      ? (opt['color'] as Color)
                      : Colors.white12,
                  width: isSelected ? 2 : 1,
                ),
              ),
              child: Center(
                child: Text(
                  opt['label'] as String,
                  style: TextStyle(
                    color: isSelected ? (opt['color'] as Color) : Colors.white54,
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  // ============================================
  // PAYMENT FLOW (Lightning)
  // ============================================

  void _showPaymentFlow(MarketplaceOffer offer) {
    // Preço com spread embutido (taxa da plataforma oculta no câmbio)
    final spreadMultiplier = 1.0 + AppConfig.platformFeePercent;
    final priceInBrl = offer.priceSats > 0 && _btcPrice > 0
        ? (offer.priceSats / 100000000) * _btcPrice * spreadMultiplier
        : 0.0;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.only(
              left: 24,
              right: 24,
              top: 24,
              bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 20),
                
                const Icon(Icons.bolt, color: Colors.amber, size: 48),
                const SizedBox(height: 12),
                Text(
                  AppLocalizations.of(context).t('market_payment_lightning'),
                  style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                
                // Resumo do pedido
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      _buildPaymentRow(AppLocalizations.of(context).t('market_product'), offer.title),
                      const Divider(color: Colors.white12),
                      _buildPaymentRow(AppLocalizations.of(context).t('market_seller'), offer.sellerName),
                      const Divider(color: Colors.white12),
                      _buildPaymentRow(AppLocalizations.of(context).t('market_payment_value'), '${_formatSats(offer.priceSats)} sats'),
                      if (priceInBrl > 0) ...[
                        const Divider(color: Colors.white12),
                        _buildPaymentRow('≈ BRL', 'R\$ ${priceInBrl.toStringAsFixed(2)}'),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                
                // Instruções de pagamento automático
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.green.withOpacity(0.3)),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.bolt, color: Colors.green, size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              AppLocalizations.of(context).t('market_auto_payment'),
                              style: const TextStyle(color: Colors.green, fontSize: 13, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        AppLocalizations.of(context).t('market_auto_payment_steps'),
                        style: const TextStyle(color: Colors.white54, fontSize: 12, height: 1.5),
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 16),
                
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.withOpacity(0.2)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.warning_amber, color: Colors.redAccent, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          AppLocalizations.of(context).t('market_lightning_irreversible'),
                          style: const TextStyle(color: Colors.redAccent, fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                
                // Botão comprar (abre chat com pedido automático)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _startPaymentChat(offer);
                    },
                    icon: const Icon(Icons.shopping_cart),
                    label: Text(AppLocalizations.of(context).t('market_buy')),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                
                // Botão só chat (sem pedido automático)
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(sheetContext);
                      _contactSeller(offer);
                    },
                    icon: const Icon(Icons.chat_bubble_outline, size: 18),
                    label: Text(AppLocalizations.of(context).t('market_just_chat')),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white54,
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Abre chat com pedido de pagamento automático
  void _startPaymentChat(MarketplaceOffer offer) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MarketplaceChatScreen(
          sellerPubkey: offer.sellerPubkey,
          sellerName: offer.sellerName,
          offerTitle: offer.title,
          offerId: offer.id,
          priceSats: offer.priceSats,
          autoPaymentRequest: true,
        ),
      ),
    );
  }

  Widget _buildPaymentRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 13)),
          Flexible(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // ============================================
  // BASE64 IMAGE HELPER
  // ============================================

  Widget _buildBase64Image(String base64Str, {BoxFit fit = BoxFit.cover}) {
    try {
      final bytes = base64Decode(base64Str);
      return Image.memory(
        Uint8List.fromList(bytes),
        fit: fit,
        errorBuilder: (_, __, ___) => Container(
          color: const Color(0xFF2A2A2A),
          child: const Center(
            child: Icon(Icons.broken_image, color: Colors.white38, size: 40),
          ),
        ),
      );
    } catch (_) {
      return Container(
        color: const Color(0xFF2A2A2A),
        child: const Center(
          child: Icon(Icons.image_not_supported, color: Colors.white38, size: 40),
        ),
      );
    }
  }

  // ============================================
  // CONTACT, REPORT, HELPERS
  // ============================================

  void _contactSeller(MarketplaceOffer offer) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MarketplaceChatScreen(
          sellerPubkey: offer.sellerPubkey,
          sellerName: offer.sellerName,
          offerTitle: offer.title,
          offerId: offer.id,
        ),
      ),
    );
  }

  void _showReportDialog(MarketplaceOffer offer) {
    String selectedType = 'spam';
    final reasonController = TextEditingController();
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Row(
            children: [
              const Icon(Icons.flag, color: Colors.red),
              const SizedBox(width: 8),
              Text(AppLocalizations.of(context).t('market_report_offer'), style: const TextStyle(color: Colors.white)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(AppLocalizations.of(context).t('market_violation_type'), style: const TextStyle(color: Colors.white70, fontSize: 14)),
                const SizedBox(height: 8),
                ...ContentModerationService.reportTypes.entries.map((entry) {
                  return RadioListTile<String>(
                    title: Text(entry.value, style: const TextStyle(color: Colors.white)),
                    value: entry.key,
                    groupValue: selectedType,
                    activeColor: Colors.red,
                    onChanged: (value) => setDialogState(() => selectedType = value!),
                  );
                }),
                const SizedBox(height: 16),
                TextField(
                  controller: reasonController,
                  style: const TextStyle(color: Colors.white),
                  maxLines: 2,
                  decoration: InputDecoration(
                    hintText: AppLocalizations.of(context).t('market_report_reason_hint'),
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: const Color(0xFF2E2E2E),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(AppLocalizations.of(context).t('cancel'), style: const TextStyle(color: Colors.white54)),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                Navigator.pop(dialogContext);
                navigator.pop();
                
                scaffoldMessenger.showSnackBar(
                  SnackBar(content: Text(AppLocalizations.of(context).t('market_sending_report'))),
                );
                
                final success = await _moderationService.reportContent(
                  targetPubkey: offer.sellerPubkey,
                  targetEventId: offer.id,
                  reportType: selectedType,
                  reason: reasonController.text.isEmpty ? null : reasonController.text,
                );
                
                if (mounted) {
                  scaffoldMessenger.showSnackBar(
                    SnackBar(
                      content: Text(success 
                        ? AppLocalizations.of(context).t('market_report_sent')
                        : AppLocalizations.of(context).t('market_report_local')),
                      backgroundColor: success ? Colors.green : Colors.orange,
                    ),
                  );
                  _loadOffers();
                }
              },
              icon: const Icon(Icons.send),
              label: Text(AppLocalizations.of(context).t('market_submit_report')),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyView(String title, String subtitle, IconData icon) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 80, color: Colors.grey[600]),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const OfferScreen()),
                ).then((_) => _loadOffers());
              },
              icon: const Icon(Icons.add),
              label: Text(AppLocalizations.of(context).t('market_create_offer')),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
            const SizedBox(height: 16),
            Text(
              AppLocalizations.of(context).tp('market_error_detail', {'error': _error ?? ''}),
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _loadData,
              child: Text(AppLocalizations.of(context).t('market_retry')),
            ),
          ],
        ),
      ),
    );
  }

  Map<String, dynamic> _getCategoryInfo(String category, {BuildContext? ctx}) {
    switch (category) {
      case 'servico':
      case 'servicos':
        return {
          'label': ctx != null ? AppLocalizations.of(ctx).t('market_service_label') : 'SERVIÇO',
          'icon': Icons.business_center,
          'color': Colors.orange,
        };
      case 'produto':
      case 'produtos':
        return {
          'label': ctx != null ? AppLocalizations.of(ctx).t('market_category_product') : 'PRODUTO',
          'icon': Icons.shopping_bag,
          'color': Colors.green,
        };
      default:
        return {
          'label': ctx != null ? AppLocalizations.of(ctx).t('market_category_other') : 'OUTRO',
          'icon': Icons.category,
          'color': Colors.grey,
        };
    }
  }

  String _formatSats(int sats) {
    if (sats >= 1000000) {
      return '${(sats / 1000000).toStringAsFixed(1)}M';
    } else if (sats >= 1000) {
      return '${(sats / 1000).toStringAsFixed(1)}k';
    }
    return sats.toString();
  }

  String _getTimeAgo(DateTime dateTime, {BuildContext? context}) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inDays > 0) {
      return '${difference.inDays}d';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}min';
    } else {
      return context != null ? AppLocalizations.of(context).t('market_now') : 'Agora';
    }
  }

  // ============================================
  // v248: OFFER ID + SELLER MESSAGES
  // ============================================

  /// Gera ID curto numérico a partir do UUID do anúncio (6 dígitos)
  String _generateShortId(String offerId) {
    if (offerId.isEmpty) return '000000';
    // Hash simples: soma dos codeUnits módulo 999999
    int hash = 0;
    for (int i = 0; i < offerId.length; i++) {
      hash = (hash * 31 + offerId.codeUnitAt(i)) & 0x7FFFFFFF;
    }
    return (hash % 999999 + 1).toString().padLeft(6, '0');
  }

  /// v253: Confirma e executa exclusão de uma oferta do marketplace
  Future<void> _confirmDeleteOffer(MarketplaceOffer offer) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(AppLocalizations.of(context).t('market_delete_offer'), style: const TextStyle(color: Colors.white)),
        content: Text(
          AppLocalizations.of(context).tp('market_delete_confirm', {'title': offer.title}),
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppLocalizations.of(context).t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppLocalizations.of(context).t('market_delete'), style: const TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    // Fechar o bottom sheet de detalhes
    Navigator.pop(context);

    final privateKey = _nostrService.privateKey;
    if (privateKey == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).t('market_private_key_error'))),
      );
      return;
    }

    setState(() => _isLoading = true);

    final success = await _nostrOrderService.deleteMarketplaceOffer(
      privateKey: privateKey,
      offerId: offer.id,
    );

    if (mounted) {
      if (success) {
        setState(() {
          _offers.removeWhere((o) => o.id == offer.id);
          _myOffers.removeWhere((o) => o.id == offer.id);
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).t('market_offer_deleted'))),
        );
      } else {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).t('market_offer_delete_error'))),
        );
      }
    }
  }

  /// Abre lista de conversas filtrada para mensagens do marketplace
  void _showOfferMessages(MarketplaceOffer offer) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const NostrConversationsScreen(),
      ),
    );
  }
}
