import 'package:flutter/material.dart';
import '../services/bitcoin_price_service.dart';
import '../services/nostr_service.dart';
import '../services/nostr_order_service.dart';

/// Tela para criar uma oferta de produto ou servico
class OfferScreen extends StatefulWidget {
  const OfferScreen({Key? key}) : super(key: key);

  @override
  State<OfferScreen> createState() => _OfferScreenState();
}

class _OfferScreenState extends State<OfferScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _priceController = TextEditingController();
  final _cityController = TextEditingController();
  final _siteController = TextEditingController();
  
  String _selectedCategory = 'produto';
  bool _acceptsPhotos = true;
  bool _isPublishing = false;
  double? _btcPriceBrl; // Preço atual do BTC em BRL

  @override
  void initState() {
    super.initState();
    _loadBtcPrice();
    _priceController.addListener(_onPriceChanged);
  }

  Future<void> _loadBtcPrice() async {
    final price = await BitcoinPriceService.getBitcoinPriceWithCache();
    if (mounted) {
      setState(() {
        _btcPriceBrl = price ?? 480558.0; // Fallback
      });
    }
  }

  void _onPriceChanged() {
    setState(() {}); // Rebuild para atualizar o hint de preço
  }

  final List<Map<String, dynamic>> _categories = [
    {'id': 'produto', 'name': 'Produto', 'icon': Icons.shopping_bag},
    {'id': 'servico', 'name': 'Serviço', 'icon': Icons.business_center}, // Maleta
    {'id': 'outro', 'name': 'Outro', 'icon': Icons.more_horiz},
  ];

  @override
  void dispose() {
    _priceController.removeListener(_onPriceChanged);
    _titleController.dispose();
    _descriptionController.dispose();
    _priceController.dispose();
    _cityController.dispose();
    _siteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        elevation: 0,
        title: const Text(
          'Nova Oferta',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Info box
                _buildInfoBox(),
                const SizedBox(height: 24),

                // Categoria
                const Text(
                  'Categoria',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              const SizedBox(height: 12),
              _buildCategorySelector(),
              const SizedBox(height: 24),

              // Titulo
              const Text(
                'Titulo da Oferta',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _titleController,
                style: const TextStyle(color: Colors.white),
                decoration: _buildInputDecoration(
                  hint: 'Ex: iPhone 14 Pro Max 256GB',
                  icon: Icons.title,
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Digite um titulo';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 24),

              // Descricao
              const Text(
                'Descricao',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _descriptionController,
                style: const TextStyle(color: Colors.white),
                maxLines: 5,
                decoration: _buildInputDecoration(
                  hint: 'Descreva seu produto ou servico em detalhes...\n\n- Estado de conservacao\n- O que esta incluso\n- Formas de entrega',
                  icon: Icons.description,
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Digite uma descricao';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 24),

              // Preco
              const Text(
                'Preco em Sats',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _priceController,
                style: const TextStyle(color: Colors.white),
                keyboardType: TextInputType.number,
                decoration: _buildInputDecoration(
                  hint: 'Ex: 100000',
                  icon: Icons.bolt,
                  suffix: 'sats',
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Digite o preco';
                  }
                  if (int.tryParse(value) == null) {
                    return 'Digite apenas numeros';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 8),
              _buildPriceHint(),
              const SizedBox(height: 24),

              // Cidade
              const Text(
                'Cidade (onde você atende)',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _cityController,
                style: const TextStyle(color: Colors.white),
                decoration: _buildInputDecoration(
                  hint: 'Ex: São Paulo, SP ou Brasil inteiro',
                  icon: Icons.location_city,
                ),
              ),
              const SizedBox(height: 24),

              // Site ou Referências
              const Text(
                'Site ou Referências (opcional)',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _siteController,
                style: const TextStyle(color: Colors.white),
                decoration: _buildInputDecoration(
                  hint: 'Ex: https://meusite.com ou @meunostr',
                  icon: Icons.link,
                ),
              ),
              const SizedBox(height: 32),

              // Botao publicar
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isPublishing ? null : _publishOffer,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF3DE98C),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    elevation: 0,
                  ),
                  child: _isPublishing
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            color: Colors.black,
                            strokeWidth: 2,
                          ),
                        )
                      : const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.rocket_launch, size: 22),
                            SizedBox(width: 8),
                            Text(
                              'Publicar Oferta',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 16),

              // Info sobre Nostr
              _buildNostrInfo(),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
      ),
    );
  }

  Widget _buildInfoBox() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF3DE98C).withOpacity(0.15),
            const Color(0xFF3DE98C).withOpacity(0.05),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF3DE98C).withOpacity(0.3),
        ),
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline, color: Color(0xFF3DE98C), size: 24),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Sua oferta sera publicada no Nostr. Interessados podem entrar em contato via chat privado.',
              style: TextStyle(
                fontSize: 13,
                color: Color(0xB3FFFFFF),
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategorySelector() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _categories.map((category) {
        final isSelected = _selectedCategory == category['id'];
        return GestureDetector(
          onTap: () => setState(() => _selectedCategory = category['id']),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: isSelected
                  ? const Color(0xFF3DE98C)
                  : const Color(0x1AFFFFFF),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isSelected
                    ? const Color(0xFF3DE98C)
                    : const Color(0x33FFFFFF),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  category['icon'] as IconData,
                  size: 18,
                  color: isSelected ? Colors.black : const Color(0x99FFFFFF),
                ),
                const SizedBox(width: 6),
                Text(
                  category['name'] as String,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: isSelected ? Colors.black : const Color(0x99FFFFFF),
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  InputDecoration _buildInputDecoration({
    required String hint,
    required IconData icon,
    String? suffix,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(
        color: Color(0x4DFFFFFF),
        fontSize: 14,
      ),
      prefixIcon: Icon(icon, color: const Color(0x66FFFFFF), size: 22),
      suffixText: suffix,
      suffixStyle: const TextStyle(
        color: Color(0xFFFFD93D),
        fontWeight: FontWeight.w600,
      ),
      filled: true,
      fillColor: const Color(0x0DFFFFFF),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0x1AFFFFFF)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0x1AFFFFFF)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFF3DE98C)),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFFF6B6B)),
      ),
    );
  }

  Widget _buildPriceHint() {
    final priceText = _priceController.text;
    final sats = int.tryParse(priceText) ?? 0;
    final btc = sats / 100000000;
    
    // Calcular valor em reais se tiver preço do BTC
    String priceInBrl = '';
    if (_btcPriceBrl != null && sats > 0) {
      final brlValue = btc * _btcPriceBrl!;
      priceInBrl = ' \u2248 R\$ ${brlValue.toStringAsFixed(2)}';
    }
    
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.calculate, color: Color(0xFFFFD93D), size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  sats > 0
                      ? '${sats.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]}.')} sats = ${btc.toStringAsFixed(8)} BTC'
                      : 'Digite o valor para ver a convers\u00e3o',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0x99FFFFFF),
                  ),
                ),
              ),
            ],
          ),
          if (priceInBrl.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.attach_money, color: Colors.green, size: 18),
                const SizedBox(width: 8),
                Text(
                  priceInBrl,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.green,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPhotoOption() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x1AFFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.photo_camera, color: Color(0xFF9C27B0), size: 24),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Fotos Privadas',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Envie fotos do produto apenas para interessados via DM',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0x99FFFFFF),
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _acceptsPhotos,
                onChanged: (value) => setState(() => _acceptsPhotos = value),
                activeColor: const Color(0xFF9C27B0),
              ),
            ],
          ),
          if (_acceptsPhotos) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF9C27B0).withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                children: [
                  Icon(Icons.lock, color: Color(0xFFBA68C8), size: 16),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Fotos sao enviadas de forma criptografada via Nostr DM',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFFBA68C8),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNostrInfo() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Column(
        children: [
          Row(
            children: [
              Icon(Icons.public, color: Color(0xFF9C27B0), size: 20),
              SizedBox(width: 8),
              Text(
                'Publicado no Nostr',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFBA68C8),
                ),
              ),
            ],
          ),
          SizedBox(height: 8),
          Text(
            'Sua oferta ficara visivel em todos os clientes Nostr compativeis. Voce pode deletar a qualquer momento.',
            style: TextStyle(
              fontSize: 12,
              color: Color(0x66FFFFFF),
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _publishOffer() async {
    if (_formKey.currentState?.validate() != true) return;

    setState(() => _isPublishing = true);

    try {
      // Publicar no Nostr de verdade
      final nostrService = NostrService();
      final nostrOrderService = NostrOrderService();
      
      final privateKey = nostrService.privateKey;
      if (privateKey == null) {
        throw Exception('Faça login para publicar ofertas');
      }

      // Monta descrição com cidade
      String fullDescription = _descriptionController.text;
      if (_cityController.text.isNotEmpty) {
        fullDescription = '📍 ${_cityController.text}\n\n$fullDescription';
      }

      final offerId = await nostrOrderService.publishMarketplaceOffer(
        privateKey: privateKey,
        title: _titleController.text,
        description: fullDescription,
        priceSats: int.tryParse(_priceController.text) ?? 0,
        category: _selectedCategory,
        siteUrl: _siteController.text.trim().isEmpty ? null : _siteController.text.trim(),
      );

      if (offerId == null) {
        throw Exception('Falha ao publicar nos relays');
      }

      setState(() => _isPublishing = false);

      if (mounted) {
        // Mostra sucesso
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(
                    color: Color(0xFF3DE98C),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check, color: Colors.black, size: 32),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Oferta Publicada!',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Sua oferta esta visivel no Nostr. Aguarde interessados entrarem em contato!',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: Color(0x99FFFFFF),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.pop(context); // Fecha dialog
                      Navigator.pop(context); // Volta para tela anterior
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF3DE98C),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('Fechar'),
                  ),
                ),
              ],
            ),
          ),
        );
      }
    } catch (e) {
      setState(() => _isPublishing = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Erro: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}
