import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/nostr_service.dart';
import '../services/bitcoin_price_service.dart';

/// Tela do Marketplace para ver ofertas publicadas no Nostr
/// Utiliza NIP-15 (kind 30019) para listagem de classificados
class MarketplaceScreen extends StatefulWidget {
  const MarketplaceScreen({super.key});

  @override
  State<MarketplaceScreen> createState() => _MarketplaceScreenState();
}

class _MarketplaceScreenState extends State<MarketplaceScreen> with SingleTickerProviderStateMixin {
  final NostrService _nostrService = NostrService();
  
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
      
      // Buscar eventos do tipo 30019 (NIP-15 Classifieds)
      // Por enquanto, usar dados de exemplo enquanto implementamos a busca real
      final sampleOffers = _generateSampleOffers();
      
      if (mounted) {
        setState(() {
          _offers = sampleOffers.where((o) => o.sellerPubkey != myPubkey).toList();
          _myOffers = sampleOffers.where((o) => o.sellerPubkey == myPubkey).toList();
        });
      }
    } catch (e) {
      debugPrint('Erro ao carregar ofertas: $e');
    }
  }

  List<MarketplaceOffer> _generateSampleOffers() {
    // Ofertas de exemplo para demonstração
    // Em produção, esses dados virão do Nostr (kind 30019)
    return [
      MarketplaceOffer(
        id: '1',
        title: 'Vendo 100k sats a 85%',
        description: 'Vendo satoshis com desconto de 15% do valor de mercado. Aceito PIX.',
        priceSats: 100000,
        priceDiscount: 15,
        category: 'venda_sats',
        sellerPubkey: 'npub1example1...',
        sellerName: 'Satoshi Trader',
        createdAt: DateTime.now().subtract(const Duration(hours: 2)),
        imageUrl: null,
      ),
      MarketplaceOffer(
        id: '2',
        title: 'Compro sats a 105%',
        description: 'Comprando satoshis pagando 5% acima do mercado. Tenho PIX ilimitado.',
        priceSats: 500000,
        priceDiscount: -5, // Premium de 5%
        category: 'compra_sats',
        sellerPubkey: 'npub1example2...',
        sellerName: 'BTC Maxi',
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
        title: 'Gift Card Amazon por sats',
        description: 'Troco gift cards da Amazon (R\$50, R\$100, R\$200) por satoshis.',
        priceSats: 0,
        priceDiscount: 10,
        category: 'gift_cards',
        sellerPubkey: 'npub1example4...',
        sellerName: 'Gift Master',
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
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Marketplace'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _showCreateOfferDialog,
            tooltip: 'Criar Oferta',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadData,
            tooltip: 'Atualizar',
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
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.orange))
          : _error != null
              ? _buildErrorView()
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _buildOffersTab(),
                    _buildMyOffersTab(),
                  ],
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
        'Crie uma oferta para vender ou comprar sats!',
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
        color: const Color(0xFF1E1E1E),
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
                              fontSize: 11,
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
                            fontSize: 10,
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
              onPressed: _showCreateOfferDialog,
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
      backgroundColor: const Color(0xFF1E1E1E),
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
                        'Pubkey: ${offer.sellerPubkey}',
                ));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Oferta copiada!')),
                );
              },
              icon: const Icon(Icons.share),
              label: const Text('Compartilhar'),
              style: TextButton.styleFrom(foregroundColor: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }

  void _showCreateOfferDialog() {
    final titleController = TextEditingController();
    final descriptionController = TextEditingController();
    final satsController = TextEditingController();
    String selectedCategory = 'venda_sats';
    int discount = 0;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 24,
            bottom: MediaQuery.of(context).viewInsets.bottom + 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
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
                
                const Text(
                  'Criar Oferta',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 20),
                
                // Categoria
                const Text('Categoria', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: selectedCategory,
                  dropdownColor: const Color(0xFF2E2E2E),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: const Color(0xFF2E2E2E),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'venda_sats', child: Text('Venda de Sats', style: TextStyle(color: Colors.white))),
                    DropdownMenuItem(value: 'compra_sats', child: Text('Compra de Sats', style: TextStyle(color: Colors.white))),
                    DropdownMenuItem(value: 'servicos', child: Text('Serviços', style: TextStyle(color: Colors.white))),
                    DropdownMenuItem(value: 'gift_cards', child: Text('Gift Cards', style: TextStyle(color: Colors.white))),
                    DropdownMenuItem(value: 'outros', child: Text('Outros', style: TextStyle(color: Colors.white))),
                  ],
                  onChanged: (value) {
                    setSheetState(() => selectedCategory = value!);
                  },
                ),
                const SizedBox(height: 16),
                
                // Título
                const Text('Título', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 8),
                TextField(
                  controller: titleController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Ex: Vendo 100k sats com desconto',
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
                
                // Descrição
                const Text('Descrição', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 8),
                TextField(
                  controller: descriptionController,
                  style: const TextStyle(color: Colors.white),
                  maxLines: 3,
                  decoration: InputDecoration(
                    hintText: 'Descreva sua oferta...',
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
                
                // Quantidade em sats
                const Text('Quantidade (sats)', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 8),
                TextField(
                  controller: satsController,
                  style: const TextStyle(color: Colors.white),
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    hintText: 'Ex: 100000',
                    hintStyle: const TextStyle(color: Colors.white38),
                    prefixIcon: const Icon(Icons.bolt, color: Colors.amber),
                    filled: true,
                    fillColor: const Color(0xFF2E2E2E),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                
                // Desconto/Premium
                const Text('Desconto/Premium (%)', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: discount.toDouble(),
                        min: -20,
                        max: 20,
                        divisions: 40,
                        activeColor: discount > 0 ? Colors.green : (discount < 0 ? Colors.red : Colors.orange),
                        label: discount > 0 ? '-$discount% (desconto)' : (discount < 0 ? '+${-discount}% (premium)' : '0%'),
                        onChanged: (value) {
                          setSheetState(() => discount = value.round());
                        },
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: discount > 0 
                            ? Colors.green.withOpacity(0.2) 
                            : (discount < 0 ? Colors.red.withOpacity(0.2) : Colors.grey.withOpacity(0.2)),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        discount > 0 ? '-$discount%' : (discount < 0 ? '+${-discount}%' : '0%'),
                        style: TextStyle(
                          color: discount > 0 ? Colors.green : (discount < 0 ? Colors.red : Colors.white),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                
                // Botões
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white38),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('Cancelar'),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          if (titleController.text.isEmpty || descriptionController.text.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Preencha todos os campos')),
                            );
                            return;
                          }
                          
                          Navigator.pop(context);
                          await _createOffer(
                            title: titleController.text,
                            description: descriptionController.text,
                            priceSats: int.tryParse(satsController.text) ?? 0,
                            category: selectedCategory,
                            discount: discount,
                          );
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: const Text('Publicar'),
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

  Future<void> _createOffer({
    required String title,
    required String description,
    required int priceSats,
    required String category,
    required int discount,
  }) async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Publicando oferta...')),
      );
      
      // TODO: Implementar publicação real via Nostr (kind 30019)
      // Por enquanto, apenas simular
      await Future.delayed(const Duration(seconds: 1));
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Oferta publicada com sucesso!'),
          backgroundColor: Colors.green,
        ),
      );
      
      _loadData();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erro: $e'), backgroundColor: Colors.red),
      );
    }
  }

  void _contactSeller(MarketplaceOffer offer) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Contato', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Para entrar em contato com ${offer.sellerName}, você pode:',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.copy, color: Colors.orange),
              title: const Text('Copiar Pubkey', style: TextStyle(color: Colors.white)),
              subtitle: Text(
                '${offer.sellerPubkey.substring(0, 20)}...',
                style: const TextStyle(color: Colors.white54, fontSize: 12),
              ),
              onTap: () {
                Clipboard.setData(ClipboardData(text: offer.sellerPubkey));
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Pubkey copiada! Use um cliente Nostr para enviar DM.')),
                );
              },
            ),
            const Divider(color: Colors.white24),
            const ListTile(
              leading: Icon(Icons.info_outline, color: Colors.blue),
              title: Text('Dica', style: TextStyle(color: Colors.white)),
              subtitle: Text(
                'Use um cliente Nostr como Damus, Amethyst ou Primal para enviar uma mensagem direta.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }

  Map<String, dynamic> _getCategoryInfo(String category) {
    switch (category) {
      case 'venda_sats':
        return {
          'label': 'VENDA DE SATS',
          'icon': Icons.sell,
          'color': Colors.green,
        };
      case 'compra_sats':
        return {
          'label': 'COMPRA DE SATS',
          'icon': Icons.shopping_cart,
          'color': Colors.blue,
        };
      case 'servicos':
        return {
          'label': 'SERVIÇOS',
          'icon': Icons.work,
          'color': Colors.purple,
        };
      case 'gift_cards':
        return {
          'label': 'GIFT CARDS',
          'icon': Icons.card_giftcard,
          'color': Colors.pink,
        };
      default:
        return {
          'label': 'OUTROS',
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
  };
}
