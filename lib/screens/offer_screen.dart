import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/bitcoin_price_service.dart';
import '../services/nostr_service.dart';
import '../services/nostr_order_service.dart';
import '../services/content_moderation_service.dart';

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
  final _quantityController = TextEditingController();
  
  String _selectedCategory = 'produto';
  bool _isPublishing = false;
  double? _btcPriceBrl;
  
  // Fotos do produto
  final List<File> _selectedPhotos = [];
  final ImagePicker _imagePicker = ImagePicker();
  static const int _maxPhotos = 3;

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
    _quantityController.dispose();
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

              // Quantidade (para produtos)
              if (_selectedCategory == 'produto') ...[              const Text(
                'Quantidade disponível',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _quantityController,
                style: const TextStyle(color: Colors.white),
                keyboardType: TextInputType.number,
                decoration: _buildInputDecoration(
                  hint: 'Ex: 10 (deixe vazio para ilimitado)',
                  icon: Icons.inventory_2,
                ),
              ),
              const SizedBox(height: 4),
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Text(
                  'O estoque diminui conforme você confirma vendas. Deixe vazio para serviços ou itens sem limite.',
                  style: TextStyle(color: Color(0x66FFFFFF), fontSize: 11),
                ),
              ),
              const SizedBox(height: 24),
              ],

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
              const SizedBox(height: 24),

              // Fotos do Produto
              const Text(
                'Fotos do Produto (opcional)',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              _buildPhotoSelector(),
              const SizedBox(height: 24),

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

  Widget _buildPhotoSelector() {
    return Column(
      children: [
        // Grid de fotos selecionadas
        if (_selectedPhotos.isNotEmpty) ...[
          SizedBox(
            height: 120,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _selectedPhotos.length,
              itemBuilder: (context, index) {
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.file(
                          _selectedPhotos[index],
                          width: 120,
                          height: 120,
                          fit: BoxFit.cover,
                        ),
                      ),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: GestureDetector(
                          onTap: () {
                            setState(() => _selectedPhotos.removeAt(index));
                          },
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.close, color: Colors.white, size: 16),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
        ],
        // Botões para adicionar foto
        if (_selectedPhotos.length < _maxPhotos)
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickPhotoFromGallery,
                  icon: const Icon(Icons.photo_library, color: Color(0xFF9C27B0)),
                  label: const Text('Galeria', style: TextStyle(color: Color(0xFF9C27B0))),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFF9C27B0)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickPhotoFromCamera,
                  icon: const Icon(Icons.camera_alt, color: Color(0xFF9C27B0)),
                  label: const Text('Câmera', style: TextStyle(color: Color(0xFF9C27B0))),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFF9C27B0)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
        const SizedBox(height: 8),
        Text(
          '${_selectedPhotos.length}/$_maxPhotos fotos • Máx. 200KB cada (comprimida automaticamente)',
          style: const TextStyle(fontSize: 11, color: Color(0x66FFFFFF)),
        ),
      ],
    );
  }

  Future<void> _pickPhotoFromGallery() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 60,
      );
      if (image != null && mounted) {
        // Verificar nome do arquivo
        if (ContentModerationService.hasProhibitedFileName(image.name)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('❌ Nome de arquivo suspeito. Imagem rejeitada.'),
              backgroundColor: Colors.red,
            ),
          );
          return;
        }
        setState(() => _selectedPhotos.add(File(image.path)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao selecionar foto: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _pickPhotoFromCamera() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.camera,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 60,
      );
      if (image != null && mounted) {
        setState(() => _selectedPhotos.add(File(image.path)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erro ao tirar foto: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  /// Converte fotos para base64 (comprimidas)
  Future<List<String>> _photosToBase64() async {
    final result = <String>[];
    for (final photo in _selectedPhotos) {
      try {
        final bytes = await photo.readAsBytes();
        // Limitar a 200KB
        if (bytes.length <= 200 * 1024) {
          result.add(base64Encode(bytes));
        } else {
          debugPrint('⚠️ Foto muito grande: ${bytes.length} bytes, ignorando');
        }
      } catch (e) {
        debugPrint('⚠️ Erro ao converter foto: $e');
      }
    }
    return result;
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

      // Converter fotos para base64
      debugPrint('📸 Convertendo ${_selectedPhotos.length} fotos para base64...');
      final photosBase64 = await _photosToBase64();
      debugPrint('✅ Base64 pronto: ${photosBase64.length} fotos');

      // Verificar conteúdo NSFW via ML antes de publicar
      // v247: Timeout de 15s + catch robusto para evitar crash nativo do TFLite
      if (_selectedPhotos.isNotEmpty) {
        try {
          debugPrint('🔍 Iniciando verificação NSFW...');
          final nsfwError = await ContentModerationService.checkImagesForNsfw(_selectedPhotos)
              .timeout(const Duration(seconds: 15), onTimeout: () {
            debugPrint('⏱️ NSFW check timeout após 15s, prosseguindo sem verificação');
            return null;
          });
          debugPrint('✅ Verificação NSFW concluída: ${nsfwError ?? "OK"}');
          if (nsfwError != null) {
            setState(() => _isPublishing = false);
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('🚫 $nsfwError'),
                  backgroundColor: Colors.red,
                  duration: const Duration(seconds: 5),
                ),
              );
            }
            return;
          }
        } catch (e, stack) {
          // v247: Captura qualquer erro (incluindo Error/native) para não crashar
          debugPrint('⚠️ NSFW verificação falhou (prosseguindo): $e');
          debugPrint('⚠️ Stack: $stack');
        }
      }

      // Verificar conteúdo das imagens antes de publicar (formato, tamanho)
      if (photosBase64.isNotEmpty) {
        final imageError = ContentModerationService.checkImagesForPublishing(photosBase64);
        if (imageError != null) {
          setState(() => _isPublishing = false);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('❌ $imageError'),
                backgroundColor: Colors.red,
                duration: const Duration(seconds: 4),
              ),
            );
          }
          return;
        }
      }

      debugPrint('📝 Verificando conteúdo de texto...');
      // Verificar conteúdo de texto proibido
      final modService = ContentModerationService();
      if (modService.containsBannedContent(_titleController.text) ||
          modService.containsBannedContent(_descriptionController.text)) {
        setState(() => _isPublishing = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('❌ Conteúdo proibido detectado. Revise o título e descrição.'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 4),
            ),
          );
        }
        return;
      }

      debugPrint('🚀 Publicando oferta no Nostr...');
      final offerId = await nostrOrderService.publishMarketplaceOffer(
        privateKey: privateKey,
        title: _titleController.text,
        description: fullDescription,
        priceSats: int.tryParse(_priceController.text) ?? 0,
        category: _selectedCategory,
        siteUrl: _siteController.text.trim().isEmpty ? null : _siteController.text.trim(),
        city: _cityController.text.trim().isEmpty ? null : _cityController.text.trim(),
        photos: photosBase64.isNotEmpty ? photosBase64 : null,
        quantity: int.tryParse(_quantityController.text) ?? 0,
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
