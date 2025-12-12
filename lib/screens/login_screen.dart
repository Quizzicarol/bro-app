import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:provider/provider.dart';
import '../services/nostr_service.dart';
import '../services/storage_service.dart';
import '../services/nip06_service.dart';
import '../providers/breez_provider_export.dart';
import '../config.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({Key? key}) : super(key: key);

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _nostrService = NostrService();
  final _storage = StorageService();
  final _nip06Service = Nip06Service();
  final _privateKeyController = TextEditingController();
  
  bool _isLoading = false;
  bool _showPrivateKey = false;
  String? _error;
  int _loginMethod = 0; // 0 = nsec, 1 = seed (NIP-06), 2 = Amber QR

  @override
  void dispose() {
    _privateKeyController.dispose();
    super.dispose();
  }

  Future<void> _generateKeys() async {
    if (_loginMethod == 1) {
      // NIP-06: Gerar seed
      final mnemonic = _nip06Service.generateMnemonic();
      _privateKeyController.text = mnemonic;
      
      debugPrint('🔑 Nova seed gerada: ${mnemonic.split(' ').take(3).join(' ')}...');
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🔑 Seed gerada! Guarde estas 12 palavras em local seguro.'),
          backgroundColor: Color(0xFFFF6B35),
          duration: Duration(seconds: 3),
        ),
      );
    } else {
      // Método tradicional: Gerar chave Nostr
      final keys = _nostrService.generateKeys();
      _privateKeyController.text = keys['privateKey']!;
      
      debugPrint('🔑 Nova chave Nostr gerada: ${keys['privateKey']!.substring(0, 16)}...');
      debugPrint('🔑 Pubkey correspondente: ${keys['publicKey']!.substring(0, 16)}...');
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🔑 Chaves Nostr geradas! Guarde sua chave privada em local seguro.'),
          backgroundColor: Color(0xFFFF6B35),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _loginWithAmber() async {
    // TODO: Implementar deep link para Amber
    // amber://sign?event=...
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('🔜 Login com Amber em breve! Por enquanto, use a chave privada.'),
        backgroundColor: Color(0xFF9C27B0),
      ),
    );
  }

  Future<void> _login() async {
    final input = _privateKeyController.text.trim();

    if (input.isEmpty) {
      setState(() => _error = _loginMethod == 1 
          ? 'Digite ou gere uma seed (12 palavras)'
          : 'Digite ou gere uma chave privada Nostr');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      String privateKey;
      String publicKey;
      
      if (_loginMethod == 1) {
        // NIP-06: Derivar chaves da seed
        if (!_nip06Service.validateMnemonic(input)) {
          throw Exception('Seed inválida. Verifique as 12 palavras.');
        }
        final keys = _nip06Service.deriveNostrKeys(input);
        privateKey = keys['privateKey']!;
        publicKey = keys['publicKey']!;
        
        // Salvar seed também
        await _storage.saveBreezMnemonic(input);
      } else {
        // Método tradicional
        if (!_nostrService.isValidPrivateKey(input)) {
          throw Exception('Chave privada Nostr inválida');
        }
        privateKey = input;
        publicKey = _nostrService.getPublicKey(privateKey);
      }

      debugPrint('🔐 Login com:');
      debugPrint('   Private key: ${privateKey.substring(0, 16)}...');
      debugPrint('   Public key (hex): $publicKey');

      // Salvar chaves Nostr
      await _storage.saveNostrKeys(
        privateKey: privateKey,
        publicKey: publicKey,
      );

      _nostrService.setKeys(privateKey, publicKey);

      // Usar URL do backend do config.dart
      await _storage.saveBackendUrl(AppConfig.defaultBackendUrl);

      // Inicializar Breez SDK (não depende de backend)
      final breezProvider = context.read<BreezProvider>();
      
      // Em modo teste, inicializar diretamente sem backend
      if (AppConfig.testMode) {
        final success = await breezProvider.initialize();
        if (!success && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⚠️ Breez SDK não inicializou, mas você pode continuar em modo teste'),
              backgroundColor: Colors.orange,
            ),
          );
        }
      } else {
        // Em produção, tentar conectar ao backend
        final success = await breezProvider.initialize();
        if (!success) {
          throw Exception('Falha ao conectar com backend');
        }
      }

      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    } catch (e) {
      setState(() => _error = 'Erro no login: ${e.toString()}');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Widget _buildLoginMethodSelector() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          _buildMethodTab(0, 'nsec', Icons.key),
          _buildMethodTab(1, 'Seed', Icons.text_snippet),
          _buildMethodTab(2, 'Amber', Icons.smartphone),
        ],
      ),
    );
  }

  Widget _buildMethodTab(int index, String label, IconData icon) {
    final isSelected = _loginMethod == index;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() => _loginMethod = index);
          if (index == 2) {
            _loginWithAmber();
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFFFF6B35) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: isSelected ? Colors.white : const Color(0x99FFFFFF),
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? Colors.white : const Color(0x99FFFFFF),
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Logo Bitcoin com gradiente
                Container(
                  width: 120,
                  height: 120,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFFF6B35), Color(0xFFFF8F65)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFFFF6B35).withOpacity(0.3),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: const Icon(
                    Icons.currency_bitcoin,
                    size: 70,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 32),
                
                // Title
                const Text(
                  'Paga Conta',
                  style: TextStyle(
                    fontSize: 36,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Escambo digital via Nostr',
                  style: TextStyle(
                    fontSize: 16,
                    color: Color(0xB3FFFFFF),
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 48),

                // Card de Login
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0x0DFFFFFF),
                    border: Border.all(
                      color: const Color(0x33FF6B35),
                      width: 1,
                    ),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Subtítulo
                      const Text(
                        'Login via Nostr',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      
                      // Login method selector
                      _buildLoginMethodSelector(),
                      const SizedBox(height: 24),

                      // Input based on method - CAMPOS SEPARADOS para evitar conflito obscureText/maxLines
                      // Campo para nsec (método 0)
                      if (_loginMethod == 0) ...[
                        TextField(
                          controller: _privateKeyController,
                          obscureText: !_showPrivateKey,
                          maxLines: 1,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: 'Chave Privada Nostr',
                            labelStyle: const TextStyle(color: Color(0xB3FFFFFF)),
                            hintText: 'nsec1... ou hex',
                            hintStyle: const TextStyle(color: Color(0x66FFFFFF)),
                            prefixIcon: const Icon(
                              Icons.key, 
                              color: Color(0xFFFF6B35),
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
                                color: Color(0x33FF6B35),
                                width: 1,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(
                                color: Color(0xFFFF6B35),
                                width: 2,
                              ),
                            ),
                            filled: true,
                            fillColor: const Color(0x0DFFFFFF),
                          ),
                        ),
                      ],
                      // Campo para Seed (método 1) - SEM obscureText, COM maxLines
                      if (_loginMethod == 1) ...[
                        TextField(
                          controller: _privateKeyController,
                          obscureText: false,
                          maxLines: 3,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: 'Seed (12 palavras)',
                            labelStyle: const TextStyle(color: Color(0xB3FFFFFF)),
                            hintText: 'palavra1 palavra2 palavra3...',
                            hintStyle: const TextStyle(color: Color(0x66FFFFFF)),
                            prefixIcon: const Icon(
                              Icons.text_snippet, 
                              color: Color(0xFFFF6B35),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(
                                color: Color(0x33FF6B35),
                                width: 1,
                              ),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(
                                color: Color(0xFFFF6B35),
                                width: 2,
                              ),
                            ),
                            filled: true,
                            fillColor: const Color(0x0DFFFFFF),
                          ),
                        ),
                      ],
                      // Amber Login Mode (método 2)
                      if (_loginMethod == 2) ...[
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: const Color(0x0DFFFFFF),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: const Color(0x33FF6B35),
                            ),
                          ),
                          child: Column(
                            children: [
                              const Icon(
                                Icons.phone_android,
                                size: 48,
                                color: Color(0xFFFF6B35),
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                'Login com Amber',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Use o app Amber para assinar eventos Nostr de forma segura',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Color(0xB3FFFFFF),
                                ),
                              ),
                              const SizedBox(height: 16),
                              OutlinedButton.icon(
                                onPressed: _loginWithAmber,
                                icon: const Icon(Icons.qr_code_scanner),
                                label: const Text('Conectar com Amber'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: const Color(0xFFFF6B35),
                                  side: const BorderSide(
                                    color: Color(0xFFFF6B35),
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20, 
                                    vertical: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),

                      // Generate Keys Button (Outline)
                      OutlinedButton.icon(
                        onPressed: _generateKeys,
                        icon: const Icon(Icons.auto_awesome),
                        label: const Text('Gerar Novas Chaves'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFFF6B35),
                          side: const BorderSide(
                            color: Color(0xFFFF6B35),
                            width: 2,
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Error Message
                      if (_error != null) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0x1AFF0000),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: const Color(0x4DFF0000),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.error_outline, color: Colors.red, size: 20),
                              const SizedBox(width: 12),
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

                      // Login Button (Gradient)
                      Container(
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFFFF6B35), Color(0xFFFF8F65)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFFFF6B35).withOpacity(0.3),
                              blurRadius: 15,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: ElevatedButton(
                          onPressed: _isLoading ? null : _login,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            shadowColor: Colors.transparent,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: _isLoading
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                  ),
                                )
                              : const Text(
                                  'Entrar',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
