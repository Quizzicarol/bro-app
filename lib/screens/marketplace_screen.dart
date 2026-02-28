import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/marketplace_offer.dart';
import '../services/nostr_service.dart';
import '../services/nostr_order_service.dart';
import '../services/bitcoin_price_service.dart';
import '../services/content_moderation_service.dart';
import '../services/marketplace_reputation_service.dart';
import 'marketplace_chat_screen.dart';
import 'offer_screen.dart';

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
      debugPrint('🔍 Carregando ofertas do marketplace...');
      
      await _moderationService.loadFromCache();
      final nostrOffers = await _nostrOrderService.fetchMarketplaceOffers();
      debugPrint('📦 ${nostrOffers.length} ofertas do Nostr');
      
      final allOffers = nostrOffers.map((data) {
        List<String> photos = [];
        if (data['photos'] is List) {
          photos = (data['photos'] as List).cast<String>();
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
      debugPrint('❌ Erro ao carregar ofertas: $e');
    }
  }

  List<MarketplaceOffer> _generateSampleOffers() {
    return [
      MarketplaceOffer(
        id: '1',
        title: 'Consultoria em Bitcoin',
        description: 'Ofereço consultoria personalizada sobre Bitcoin, carteiras, segurança e DCA. 1 hora de call.',
        priceSats: 50000,
        priceDiscount: 0,
        category: 'servicos',
        sellerPubkey: 'npub1example1......',
        sellerName: 'Bitcoin Coach',
        createdAt: DateTime.now().subtract(const Duration(hours: 2)),
      ),
      MarketplaceOffer(
        id: '2',
        title: 'Hardware Wallet Coldcard',
        description: 'Coldcard MK4 nova lacrada. Melhor segurança para suas chaves Bitcoin.',
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
        title: const Text('Marketplace'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const OfferScreen()),
              ).then((_) => _loadOffers());
            },
            tooltip: 'Criar Oferta',
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.orange,
          labelColor: Colors.orange,
          unselectedLabelColor: Colors.white60,
          tabs: const [
            Tab(text: 'Ofertas', icon: Icon(Icons.storefront)),
            Tab(text: 'Minhas Ofertas', icon: Icon(Icons.sell)),
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
          const Expanded(
            child: Text(
              'O Bro não se responsabiliza e nem tem ingerência nos anúncios publicados. '
              'Verifique a procedência e reputação de produtos e serviços antes de qualquer negociação P2P.',
              style: TextStyle(
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
        'Nenhuma oferta encontrada',
        'Seja o primeiro a publicar uma oferta no marketplace!',
        Icons.storefront_outlined,
      );
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      color: Colors.orange,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _offers.length,
        itemBuilder: (context, index) => _buildOfferCard(_offers[index]),
      ),
    );
  }

  Widget _buildMyOffersTab() {
    if (_myOffers.isEmpty) {
      return _buildEmptyView(
        'Você não tem ofertas',
        'Crie uma oferta de produto ou serviço!',
        Icons.sell_outlined,
      );
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      color: Colors.orange,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _myOffers.length,
        itemBuilder: (context, index) => _buildOfferCard(_myOffers[index], isMine: true),
      ),
    );
  }

  // ============================================
  // OFFER CARD (com foto thumbnail e reputação)
  // ============================================

  Widget _buildOfferCard(MarketplaceOffer offer, {bool isMine = false}) {
    final categoryInfo = _getCategoryInfo(offer.category);
    final priceInBrl = offer.priceSats > 0 && _btcPrice > 0
        ? (offer.priceSats / 100000000) * _btcPrice
        : 0.0;
    final timeAgo = _getTimeAgo(offer.createdAt);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isMine ? Colors.orange.withOpacity(0.5) : Colors.white12,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _showOfferDetail(offer),
          borderRadius: BorderRadius.circular(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Foto thumbnail no topo do card (se tiver)
              if (offer.photoBase64List.isNotEmpty)
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                  child: SizedBox(
                    height: 160,
                    width: double.infinity,
                    child: _buildBase64Image(offer.photoBase64List.first, fit: BoxFit.cover),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: (categoryInfo['color'] as Color).withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            categoryInfo['icon'] as IconData,
                            color: categoryInfo['color'] as Color,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                categoryInfo['label'] as String,
                                style: TextStyle(
                                  color: categoryInfo['color'] as Color,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                offer.title,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        if (isMine)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.orange.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: Colors.orange),
                            ),
                            child: const Text(
                              'MINHA',
                              style: TextStyle(
                                color: Colors.orange,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    
                    // Descrição
                    Text(
                      offer.description,
                      style: const TextStyle(color: Colors.white70, fontSize: 14),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 12),
                    
                    // Reputação do vendedor (sempre visível no card)
                    ...[
                      _buildReputationBadge(offer),
                      const SizedBox(height: 12),
                    ],
                    
                    // Preço e info
                    Row(
                      children: [
                        if (offer.priceSats > 0) ...[
                          const Icon(Icons.bolt, color: Colors.amber, size: 18),
                          const SizedBox(width: 4),
                          Text(
                            '${_formatSats(offer.priceSats)} sats',
                            style: const TextStyle(
                              color: Colors.amber,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (priceInBrl > 0)
                            Text(
                              ' (R\$ ${priceInBrl.toStringAsFixed(2)})',
                              style: const TextStyle(color: Colors.white54, fontSize: 12),
                            ),
                        ],
                        const Spacer(),
                        if (offer.photoBase64List.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Icon(Icons.photo, color: Colors.purple.shade300, size: 16),
                          ),
                        Text(
                          timeAgo,
                          style: const TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    
                    // Vendedor + contato
                    Row(
                      children: [
                        const Icon(Icons.person, color: Colors.white38, size: 16),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            offer.sellerName,
                            style: const TextStyle(color: Colors.white54, fontSize: 13),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () => _contactSeller(offer),
                          icon: const Icon(Icons.message, size: 16),
                          label: const Text('Contato'),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.orange,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                          ),
                        ),
                      ],
                    ),
                  ],
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
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.star_border, size: 14, color: Colors.white38),
            SizedBox(width: 4),
            Text(
              'Sem avaliações ainda',
              style: TextStyle(fontSize: 11, color: Colors.white38),
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
            'Atend: ${_ratingEmoji(avgAtend)} • Produto: ${_ratingEmoji(avgProd)} • $total avaliações',
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
  // OFFER DETAIL (Bottom Sheet)
  // ============================================

  void _showOfferDetail(MarketplaceOffer offer) {
    final categoryInfo = _getCategoryInfo(offer.category);
    final priceInBrl = offer.priceSats > 0 && _btcPrice > 0
        ? (offer.priceSats / 100000000) * _btcPrice
        : 0.0;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.8,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => ListView(
          controller: scrollController,
          padding: const EdgeInsets.all(24),
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
                      '${offer.photoBase64List.length} fotos — deslize para ver',
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
            const SizedBox(height: 16),
            
            // Descrição
            const Text('Descrição', style: TextStyle(color: Colors.white54, fontSize: 12)),
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
                          const Text('Site ou Referências', style: TextStyle(color: Colors.white54, fontSize: 12)),
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
                          const SnackBar(content: Text('Link copiado!')),
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
                        const SnackBar(content: Text('Pubkey copiada!')),
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
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.redAccent, size: 16),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'O Bro não se responsabiliza e nem tem ingerência nos anúncios publicados. '
                      'Verifique a procedência e reputação de produtos e serviços antes de qualquer negociação P2P.',
                      style: TextStyle(color: Colors.redAccent, fontSize: 11, height: 1.3),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            
            // Botões de ação
            // 1. Contato via DM
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  _contactSeller(offer);
                },
                icon: const Icon(Icons.message),
                label: const Text('Entrar em Contato'),
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
                  label: const Text('Pagar com Lightning', style: TextStyle(color: Colors.black)),
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
                label: const Text('Avaliar Vendedor', style: TextStyle(color: Colors.amber)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.amber),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(height: 12),
            
            // Compartilhar e Reportar
            Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(
                        text: 'Oferta: ${offer.title}\n'
                              'Preço: ${_formatSats(offer.priceSats)} sats\n'
                              'Vendedor: ${offer.sellerName}\n'
                              'Pubkey: ${offer.sellerPubkey}${offer.siteUrl != null ? '\nSite: ${offer.siteUrl}' : ''}',
                      ));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Oferta copiada!')),
                      );
                    },
                    icon: const Icon(Icons.share, size: 16),
                    label: const Text('Compartilhar'),
                    style: TextButton.styleFrom(foregroundColor: Colors.white70),
                  ),
                ),
                Expanded(
                  child: TextButton.icon(
                    onPressed: () => _showReportDialog(offer),
                    icon: const Icon(Icons.flag_outlined, color: Colors.red, size: 16),
                    label: const Text('Reportar', style: TextStyle(color: Colors.red)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ============================================
  // REPUTATION SECTION (detailed in offer detail)
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
                'Reputação do Vendedor',
                style: TextStyle(
                  color: Colors.amber.shade300,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              Text(
                '$total avaliações',
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
          if (total > 0) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _buildRatingBar('Atendimento', avgAtend),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildRatingBar('Produto', avgProd),
                ),
              ],
            ),
          ] else ...[
            const SizedBox(height: 8),
            const Text(
              'Nenhuma avaliação ainda. Seja o primeiro!',
              style: TextStyle(color: Colors.white38, fontSize: 12),
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
          const Row(
            children: [
              Icon(Icons.map, color: Colors.green, size: 20),
              SizedBox(width: 8),
              Text(
                'BTCMap — Encontre no Mapa',
                style: TextStyle(
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
                ? 'Veja comerciantes Bitcoin perto de $cleanCity'
                : 'Veja o mapa global de comerciantes Bitcoin',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _openBtcMap(cleanCity),
              icon: const Icon(Icons.open_in_new, size: 16, color: Colors.green),
              label: Text(
                hasCity ? 'Ver $cleanCity no BTCMap' : 'Abrir BTCMap',
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
          SnackBar(content: Text('Erro ao abrir BTCMap: $e'), backgroundColor: Colors.red),
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
          title: const Row(
            children: [
              Icon(Icons.star, color: Colors.amber),
              SizedBox(width: 8),
              Expanded(
                child: Text('Avaliar Vendedor', style: TextStyle(color: Colors.white, fontSize: 18)),
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
                
                const Text('Atendimento:', style: TextStyle(color: Colors.white70, fontSize: 14)),
                const SizedBox(height: 8),
                _buildRatingSelector(
                  value: ratingAtendimento,
                  onChanged: (v) => setDialogState(() => ratingAtendimento = v),
                ),
                const SizedBox(height: 16),
                
                const Text('Produto/Serviço:', style: TextStyle(color: Colors.white70, fontSize: 14)),
                const SizedBox(height: 8),
                _buildRatingSelector(
                  value: ratingProduto,
                  onChanged: (v) => setDialogState(() => ratingProduto = v),
                ),
                const SizedBox(height: 16),
                
                TextField(
                  controller: commentController,
                  style: const TextStyle(color: Colors.white),
                  maxLines: 2,
                  decoration: InputDecoration(
                    hintText: 'Comentário (opcional)',
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
              child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                Navigator.pop(dialogContext);
                
                scaffoldMessenger.showSnackBar(
                  const SnackBar(content: Text('Publicando avaliação...')),
                );
                
                final nostrService = NostrService();
                final privateKey = nostrService.privateKey;
                if (privateKey == null) {
                  scaffoldMessenger.showSnackBar(
                    const SnackBar(content: Text('Faça login para avaliar'), backgroundColor: Colors.red),
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
                      ? '⭐ Avaliação publicada com sucesso!'
                      : '❌ Falha ao publicar avaliação'),
                    backgroundColor: success ? Colors.green : Colors.red,
                  ),
                );
                
                if (success) {
                  _reputationService.clearCache();
                  _loadOffers();
                }
              },
              icon: const Icon(Icons.send),
              label: const Text('Publicar'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.amber),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRatingSelector({required int value, required ValueChanged<int> onChanged}) {
    const options = [
      {'value': 3, 'label': '👍 Bom', 'color': Colors.green},
      {'value': 2, 'label': '👌 Médio', 'color': Colors.orange},
      {'value': 1, 'label': '👎 Ruim', 'color': Colors.red},
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
    final priceInBrl = offer.priceSats > 0 && _btcPrice > 0
        ? (offer.priceSats / 100000000) * _btcPrice
        : 0.0;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
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
              const Text(
                'Pagamento Lightning',
                style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    _buildPaymentRow('Produto', offer.title),
                    const Divider(color: Colors.white12),
                    _buildPaymentRow('Vendedor', offer.sellerName),
                    const Divider(color: Colors.white12),
                    _buildPaymentRow('Valor', '${_formatSats(offer.priceSats)} sats'),
                    if (priceInBrl > 0) ...[
                      const Divider(color: Colors.white12),
                      _buildPaymentRow('≈ BRL', 'R\$ ${priceInBrl.toStringAsFixed(2)}'),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Column(
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info_outline, color: Colors.blue, size: 16),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Como pagar:',
                            style: TextStyle(color: Colors.blue, fontSize: 13, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 8),
                    Text(
                      '1. Entre em contato com o vendedor pelo chat\n'
                      '2. Peça o endereço Lightning (invoice ou LNURL)\n'
                      '3. Use sua carteira do Bro para pagar\n'
                      '4. Confirme o pagamento com o vendedor',
                      style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.5),
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
                child: const Row(
                  children: [
                    Icon(Icons.warning_amber, color: Colors.redAccent, size: 16),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Pagamentos Lightning são irreversíveis. Só pague após confirmar a procedência do vendedor.',
                        style: TextStyle(color: Colors.redAccent, fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    _contactSeller(offer);
                  },
                  icon: const Icon(Icons.message),
                  label: const Text('Iniciar Negociação via Chat'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
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
          title: const Row(
            children: [
              Icon(Icons.flag, color: Colors.red),
              SizedBox(width: 8),
              Text('Reportar Oferta', style: TextStyle(color: Colors.white)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Tipo de violação:', style: TextStyle(color: Colors.white70, fontSize: 14)),
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
                    hintText: 'Motivo adicional (opcional)',
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
              child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                Navigator.pop(dialogContext);
                navigator.pop();
                
                scaffoldMessenger.showSnackBar(
                  const SnackBar(content: Text('Enviando report...')),
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
                        ? '✅ Report enviado! Oferta ocultada.'
                        : '❌ Oferta ocultada localmente (relay offline)'),
                      backgroundColor: success ? Colors.green : Colors.orange,
                    ),
                  );
                  _loadOffers();
                }
              },
              icon: const Icon(Icons.send),
              label: const Text('Enviar Report'),
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
              label: const Text('Criar Oferta'),
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
              'Erro: $_error',
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _loadData,
              child: const Text('Tentar Novamente'),
            ),
          ],
        ),
      ),
    );
  }

  Map<String, dynamic> _getCategoryInfo(String category) {
    switch (category) {
      case 'servico':
      case 'servicos':
        return {
          'label': 'SERVIÇO',
          'icon': Icons.business_center,
          'color': Colors.orange,
        };
      case 'produto':
      case 'produtos':
        return {
          'label': 'PRODUTO',
          'icon': Icons.shopping_bag,
          'color': Colors.green,
        };
      default:
        return {
          'label': 'OUTRO',
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

  String _getTimeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inDays > 0) {
      return '${difference.inDays}d';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}min';
    } else {
      return 'Agora';
    }
  }
}
