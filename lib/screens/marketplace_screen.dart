import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/nostr_service.dart';
import '../services/nostr_order_service.dart';
import '../services/bitcoin_price_service.dart';
import '../services/content_moderation_service.dart';
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
  
  late TabController _tabController;
  
  List<MarketplaceOffer> _offers = [];
  List<MarketplaceOffer> _myOffers = [];
  bool _isLoading = true;
  String? _error;
  double _btcPrice = 0;

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
      // Buscar preço do BTC
      _btcPrice = await BitcoinPriceService.getBitcoinPriceInBRL() ?? 480558;
      
      // Buscar ofertas do Nostr
      await _loadOffers();
      
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
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
      debugPrint('   Minha pubkey: ${myPubkey?.substring(0, 8) ?? "null"}');
      
      // Carregar dados de moderação
      await _moderationService.loadFromCache();
      
      // Buscar ofertas do Nostr
      final nostrOffers = await _nostrOrderService.fetchMarketplaceOffers();
      debugPrint('📦 ${nostrOffers.length} ofertas do Nostr');
      
      // Converter para MarketplaceOffer
      final allOffers = nostrOffers.map((data) => MarketplaceOffer(
        id: data['id'] ?? '',
        title: data['title'] ?? '',
        description: data['description'] ?? '',
        priceSats: data['priceSats'] ?? 0,
        priceDiscount: 0,
        category: data['category'] ?? 'outros',
        sellerPubkey: data['sellerPubkey'] ?? '',
        sellerName: 'Usuário ${(data['sellerPubkey'] ?? '').toString().substring(0, 6)}',
        createdAt: DateTime.tryParse(data['createdAt'] ?? '') ?? DateTime.now(),
      )).toList();
      
      // Filtrar conteúdo proibido/reportado
      final filteredOffers = allOffers.where((offer) {
        return !_moderationService.shouldHideOffer(
          title: offer.title,
          description: offer.description,
          sellerPubkey: offer.sellerPubkey,
        );
      }).toList();
      
      // Ordenar por Web of Trust (ofertas de pessoas confiáveis primeiro)
      filteredOffers.sort((a, b) {
        final trustA = _moderationService.getTrustScore(a.sellerPubkey);
        final trustB = _moderationService.getTrustScore(b.sellerPubkey);
        if (trustA != trustB) return trustB.compareTo(trustA); // Maior trust primeiro
        return b.createdAt.compareTo(a.createdAt); // Depois por data
      });
      
      // Se não tem ofertas do Nostr, usar exemplos
      final finalOffers = filteredOffers.isEmpty && allOffers.isEmpty 
          ? _generateSampleOffers() 
          : filteredOffers;
      
      if (mounted) {
        setState(() {
          // Mostrar todas as ofertas na aba principal (incluindo próprias para facilitar teste)
          _offers = finalOffers.toList();
          _myOffers = finalOffers.where((o) => o.sellerPubkey == myPubkey).toList();
        });
        debugPrint('✅ ${_offers.length} ofertas (${allOffers.length - filteredOffers.length} filtradas)');
      }
    } catch (e) {
      debugPrint('❌ Erro ao carregar ofertas: $e');
    }
  }

  List<MarketplaceOffer> _generateSampleOffers() {
    // Ofertas de exemplo para demonstração
    // Em produção, esses dados virão do Nostr (kind 30019)
    return [
      MarketplaceOffer(
        id: '1',
        title: 'Consultoria em Bitcoin',
        description: 'Ofereço consultoria personalizada sobre Bitcoin, carteiras, segurança e DCA. 1 hora de call.',
        priceSats: 50000,
        priceDiscount: 0,
        category: 'servicos',
        sellerPubkey: 'npub1example1...',
        sellerName: 'Bitcoin Coach',
        createdAt: DateTime.now().subtract(const Duration(hours: 2)),
        imageUrl: null,
      ),
      MarketplaceOffer(
        id: '2',
        title: 'Hardware Wallet Coldcard',
        description: 'Coldcard MK4 nova lacrada. Melhor segurança para suas chaves Bitcoin.',
        priceSats: 200000,
        priceDiscount: 0,
        category: 'produtos',
        sellerPubkey: 'npub1example2...',
        sellerName: 'BTC Store',
        createdAt: DateTime.now().subtract(const Duration(hours: 5)),
        imageUrl: null,
      ),
      MarketplaceOffer(
        id: '3',
        title: 'Serviço de Freelance por BTC',
        description: 'Desenvolvo sites e apps aceitando pagamento em Bitcoin Lightning.',
        priceSats: 50000,
        priceDiscount: 0,
        category: 'servicos',
        sellerPubkey: 'npub1example3...',
        sellerName: 'Dev Nostr',
        createdAt: DateTime.now().subtract(const Duration(days: 1)),
        imageUrl: null,
      ),
      MarketplaceOffer(
        id: '4',
        title: 'Camiseta Bitcoin por sats',
        description: 'Vendo camisetas Bitcoin de qualidade. Tamanhos P, M, G, GG.',
        priceSats: 50000,
        priceDiscount: 0,
        category: 'produtos',
        sellerPubkey: 'npub1example4...',
        sellerName: 'BTC Store',
        createdAt: DateTime.now().subtract(const Duration(days: 2)),
        imageUrl: null,
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
    );
  }

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
          child: Padding(
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
                        color: categoryInfo['color'].withOpacity(0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        categoryInfo['icon'],
                        color: categoryInfo['color'],
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            categoryInfo['label'],
                            style: TextStyle(
                              color: categoryInfo['color'],
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
                      if (priceInBrl > 0) ...[
                        Text(
                          ' (R\$ ${priceInBrl.toStringAsFixed(2)})',
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ],
                    if (offer.priceDiscount != 0) ...[
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: offer.priceDiscount > 0 
                              ? Colors.green.withOpacity(0.2)
                              : Colors.red.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          offer.priceDiscount > 0 
                              ? '-${offer.priceDiscount}%' 
                              : '+${offer.priceDiscount.abs()}%',
                          style: TextStyle(
                            color: offer.priceDiscount > 0 ? Colors.green : Colors.red,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                    const Spacer(),
                    Text(
                      timeAgo,
                      style: const TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                
                // Vendedor
                Row(
                  children: [
                    const Icon(Icons.person, color: Colors.white38, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      offer.sellerName,
                      style: const TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                    const Spacer(),
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
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
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
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.9,
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
            
            // Categoria
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: categoryInfo['color'].withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(categoryInfo['icon'], color: categoryInfo['color'], size: 18),
                  const SizedBox(width: 6),
                  Text(
                    categoryInfo['label'],
                    style: TextStyle(
                      color: categoryInfo['color'],
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
            const Text(
              'Descrição',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
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
                    const Spacer(),
                    if (offer.priceDiscount != 0)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: offer.priceDiscount > 0 
                              ? Colors.green.withOpacity(0.2)
                              : Colors.red.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          offer.priceDiscount > 0 
                              ? '-${offer.priceDiscount}%' 
                              : '+${offer.priceDiscount.abs()}%',
                          style: TextStyle(
                            color: offer.priceDiscount > 0 ? Colors.green : Colors.red,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
            
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
                          const Text(
                            'Site ou Referências',
                            style: TextStyle(color: Colors.white54, fontSize: 12),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            offer.siteUrl!,
                            style: const TextStyle(
                              color: Colors.blue,
                              fontSize: 14,
                            ),
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
                      tooltip: 'Copiar link',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
            
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
                          '${offer.sellerPubkey.substring(0, 20)}...',
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
                    tooltip: 'Copiar Pubkey',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            
            // Botões de ação
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
            const SizedBox(height: 12),
            TextButton.icon(
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
              icon: const Icon(Icons.share),
              label: const Text('Compartilhar'),
              style: TextButton.styleFrom(foregroundColor: Colors.white70),
            ),
            const SizedBox(height: 8),
            // Botão de Reportar (NIP-56)
            TextButton.icon(
              onPressed: () => _showReportDialog(offer),
              icon: const Icon(Icons.flag_outlined, color: Colors.red),
              label: const Text('Reportar', style: TextStyle(color: Colors.red)),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
            ),
          ],
        ),
      ),
    );
  }

  void _contactSeller(MarketplaceOffer offer) {
    // Abrir chat direto via Nostr DM (NIP-04)
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

  /// Dialog para reportar oferta (NIP-56)
  void _showReportDialog(MarketplaceOffer offer) {
    String selectedType = 'spam';
    final reasonController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
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
                const Text(
                  'Tipo de violação:',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 8),
                ...ContentModerationService.reportTypes.entries.map((entry) {
                  return RadioListTile<String>(
                    title: Text(entry.value, style: const TextStyle(color: Colors.white)),
                    value: entry.key,
                    groupValue: selectedType,
                    activeColor: Colors.red,
                    onChanged: (value) {
                      setDialogState(() => selectedType = value!);
                    },
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
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.withOpacity(0.3)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.orange, size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Reports são publicados no Nostr (NIP-56) de forma descentralizada.',
                          style: TextStyle(color: Colors.orange, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                Navigator.pop(context);
                
                // Mostrar loading
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Enviando report...')),
                );
                
                // Publicar report
                final success = await _moderationService.reportContent(
                  targetPubkey: offer.sellerPubkey,
                  targetEventId: offer.id,
                  reportType: selectedType,
                  reason: reasonController.text.isEmpty ? null : reasonController.text,
                );
                
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(success 
                        ? '✅ Report enviado! Deseja silenciar este vendedor?'
                        : '❌ Erro ao enviar report'),
                      backgroundColor: success ? Colors.green : Colors.red,
                      action: success ? SnackBarAction(
                        label: 'SILENCIAR',
                        textColor: Colors.white,
                        onPressed: () async {
                          await _moderationService.mutePubkey(offer.sellerPubkey);
                          _loadOffers(); // Recarregar sem a oferta
                        },
                      ) : null,
                    ),
                  );
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

  Map<String, dynamic> _getCategoryInfo(String category) {
    switch (category) {
      case 'servico':
      case 'servicos':
        return {
          'label': 'SERVIÇO',
          'icon': Icons.business_center, // Maleta
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

/// Modelo de oferta do Marketplace
class MarketplaceOffer {
  final String id;
  final String title;
  final String description;
  final int priceSats;
  final int priceDiscount; // Positivo = desconto, Negativo = premium
  final String category;
  final String sellerPubkey;
  final String sellerName;
  final DateTime createdAt;
  final String? imageUrl;
  final String? siteUrl; // Site ou referência externa

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
  });

  factory MarketplaceOffer.fromNostrEvent(Map<String, dynamic> event) {
    // TODO: Implementar parsing de evento Nostr kind 30019
    final tags = event['tags'] as List<dynamic>? ?? [];
    String title = '';
    String description = '';
    int priceSats = 0;
    String category = 'outros';
    
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
            category = tag.length > 1 ? tag[1] : 'outros';
            break;
        }
      }
    }
    
    return MarketplaceOffer(
      id: event['id'] ?? '',
      title: title,
      description: description.isEmpty ? (event['content'] ?? '') : description,
      priceSats: priceSats,
      priceDiscount: 0,
      category: category,
      sellerPubkey: event['pubkey'] ?? '',
      sellerName: 'Vendedor',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        ((event['created_at'] ?? 0) as int) * 1000,
      ),
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
  };
}
