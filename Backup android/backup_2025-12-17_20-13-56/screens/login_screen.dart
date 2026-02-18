import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:provider/provider.dart';
import '../services/nostr_service.dart';
import '../services/nostr_profile_service.dart';
import '../services/storage_service.dart';
import '../providers/breez_provider_export.dart';
import '../providers/order_provider.dart';
import '../config.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _nostrService = NostrService();
  final _profileService = NostrProfileService();
  final _storage = StorageService();
  final _privateKeyController = TextEditingController();

  bool _isLoading = false;
  bool _showPrivateKey = false;
  String? _error;
  String? _statusMessage;

  @override
  void dispose() {
    _privateKeyController.dispose();
    super.dispose();
  }

  Future<void> _generateKeys() async {
    final keys = _nostrService.generateKeys();
    _privateKeyController.text = keys['privateKey']!;

    // Log de chave privada removido por segurança
    debugPrint('Pubkey: ${keys['publicKey']!.substring(0, 16)}...');

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Chaves Nostr geradas! Guarde sua chave privada em local seguro.'),
          backgroundColor: Color(0xFFFF6B6B),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _login() async {
    final input = _privateKeyController.text.trim();

    if (input.isEmpty) {
      setState(() => _error = 'Digite sua chave privada Nostr');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
      _statusMessage = 'Validando chave...';
    });

    try {
      // Validar chave privada
      if (!_nostrService.isValidPrivateKey(input)) {
        throw Exception('Chave privada Nostr invalida');
      }

      final privateKey = input;
      final publicKey = _nostrService.getPublicKey(privateKey);

      debugPrint('Login com Nostr. Pubkey: ${publicKey.substring(0, 16)}...');

      // Salvar chaves Nostr
      await _storage.saveNostrKeys(
        privateKey: privateKey,
        publicKey: publicKey,
      );

      _nostrService.setKeys(privateKey, publicKey);

      // Buscar perfil Nostr dos relays (com timeout)
      if (mounted) {
        setState(() => _statusMessage = 'Buscando perfil Nostr...');
      }
      
      try {
        final profile = await _profileService.fetchProfile(publicKey)
            .timeout(const Duration(seconds: 5), onTimeout: () {
          debugPrint('⏰ Timeout ao buscar perfil - continuando');
          return null;
        });
        if (profile != null) {
          debugPrint('Perfil encontrado: ${profile.preferredName}');
          debugPrint('Avatar: ${profile.picture ?? "nenhum"}');
          
          // Salvar dados do perfil localmente
          await _storage.saveNostrProfile(
            name: profile.name,
            displayName: profile.displayName,
            picture: profile.picture,
            about: profile.about,
          );
          
          if (mounted && profile.name != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Bem-vindo, ${profile.preferredName}!'),
                backgroundColor: const Color(0xFF3DE98C),
                duration: const Duration(seconds: 2),
              ),
            );
          }
        }
      } catch (e) {
        debugPrint('Erro ao buscar perfil (continuando login): $e');
        // Nao bloquear login se perfil nao for encontrado
      }

      // Salvar URL do backend
      await _storage.saveBackendUrl(AppConfig.defaultBackendUrl);

      // Inicializar Breez SDK (com timeout para não travar login)
      if (!kIsWeb) {
        if (mounted) {
          setState(() => _statusMessage = 'Inicializando carteira...');
        }
        try {
          final breezProvider = context.read<BreezProvider>();
          final success = await breezProvider.initialize()
              .timeout(const Duration(seconds: 10), onTimeout: () {
            debugPrint('⏰ Timeout na inicialização do Breez - continuando login');
            return false;
          });
          if (!success && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Carteira inicializará em background'),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 2),
              ),
            );
          }
        } catch (e) {
          debugPrint('❌ Erro no Breez (ignorando): $e');
        }
      }

      // Carregar ordens do usuário
      if (mounted) {
        setState(() => _statusMessage = 'Carregando histórico...');
        final orderProvider = context.read<OrderProvider>();
        await orderProvider.loadOrdersForUser(publicKey);
        debugPrint('✅ Ordens carregadas para ${publicKey.substring(0, 8)}...');
      }

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    } catch (e) {
      debugPrint('Erro no login: $e');
      setState(() => _error = 'Erro no login: ${e.toString()}');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _statusMessage = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: MediaQuery.of(context).size.height - 
                         MediaQuery.of(context).padding.top - 
                         MediaQuery.of(context).padding.bottom,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Seção superior - Logo centralizado
                const SizedBox(height: 20),
                Image.asset(
                  'assets/images/bro-logo.png',
                  height: 80,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Comunidade de escambo digital via Nostr',
                  style: TextStyle(
                    fontSize: 13,
                    color: Color(0xB3FFFFFF),
                    fontWeight: FontWeight.w400,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),

              // Card de Login
              Container(
                decoration: BoxDecoration(
                  color: const Color(0x0DFFFFFF),
                  border: Border.all(
                    color: const Color(0x33FF6B6B),
                    width: 1,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Login via Nostr',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Use sua chave existente ou gere uma nova',
                      style: TextStyle(
                        fontSize: 13,
                        color: Color(0x99FFFFFF),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),

                    // Campo de chave privada
                    TextField(
                      controller: _privateKeyController,
                      obscureText: !_showPrivateKey,
                      maxLines: 1,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Chave Privada Nostr (nsec ou hex)',
                        labelStyle: const TextStyle(color: Color(0xB3FFFFFF)),
                        hintText: 'Cole sua chave aqui',
                        hintStyle: const TextStyle(color: Color(0x66FFFFFF)),
                        prefixIcon: const Icon(
                          Icons.key,
                          color: Color(0xFFFF6B6B),
                        ),
                        suffixIcon: IconButton(
                          icon: Icon(
                            _showPrivateKey ? Icons.visibility_off : Icons.visibility,
                            color: const Color(0xB3FFFFFF),
                          ),
                          onPressed: () {
                            setState(() => _showPrivateKey = !_showPrivateKey);
                          },
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                            color: Color(0x33FF6B6B),
                            width: 1,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                            color: Color(0xFFFF6B6B),
                            width: 2,
                          ),
                        ),
                        filled: true,
                        fillColor: const Color(0x0DFFFFFF),
                      ),
                    ),
                    const SizedBox(height: 8),

                    // Gerar nova chave
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: _generateKeys,
                        icon: const Icon(
                          Icons.auto_awesome,
                          size: 16,
                          color: Color(0xFFFF6B6B),
                        ),
                        label: const Text(
                          'Gerar nova chave',
                          style: TextStyle(
                            color: Color(0xFFFF6B6B),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),

                    // Erro
                    if (_error != null) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0x1AFF0000),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: const Color(0x33FF0000),
                          ),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.error_outline,
                              color: Colors.red,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _error!,
                                style: const TextStyle(
                                  color: Colors.red,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],

                    // Botao de Login
                    Container(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFFFF6B6B), Color(0xFFFF8A8A)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFFF6B6B).withOpacity(0.3),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _login,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: _isLoading
                            ? Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  ),
                                  if (_statusMessage != null) ...[
                                    const SizedBox(height: 8),
                                    Text(
                                      _statusMessage!,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.white70,
                                      ),
                                    ),
                                  ],
                                ],
                              )
                            : const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.login, color: Colors.white),
                                  SizedBox(width: 8),
                                  Text(
                                    'Entrar',
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Info sobre perfil (menor)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0x0D9C27B0),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0x339C27B0)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.person_search, color: Color(0xFF9C27B0), size: 20),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Perfil Nostr carregado automaticamente',
                        style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),

              // Aviso de seguranca (menor)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0x0D3DE98C),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0x333DE98C)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.security, color: Color(0xFF3DE98C), size: 20),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Sua chave nunca sai do dispositivo',
                        style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
        ),
      ),
    );
  }
}
