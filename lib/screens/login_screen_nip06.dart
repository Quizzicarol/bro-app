import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/nostr_service.dart';
import '../services/nostr_profile_service.dart';
import '../services/storage_service.dart';
import '../services/nip06_service.dart';
import '../providers/breez_provider_export.dart';
import '../providers/order_provider.dart';
import 'home_screen.dart';

/// Tela de Login baseada em NIP-06
/// Uma única seed BIP-39 = Chave Nostr + Carteira Lightning
/// Isso garante que o usuário NUNCA perca seu saldo ou histórico
class LoginScreenNip06 extends StatefulWidget {
  const LoginScreenNip06({super.key});

  @override
  State<LoginScreenNip06> createState() => _LoginScreenNip06State();
}

class _LoginScreenNip06State extends State<LoginScreenNip06> {
  final _nip06 = Nip06Service();
  final _nostrService = NostrService();
  final _profileService = NostrProfileService();
  final _storage = StorageService();
  final _seedController = TextEditingController();

  bool _isLoading = false;
  bool _showSeed = false;
  String? _error;
  String? _statusMessage;
  String? _generatedSeed;
  bool _seedConfirmed = false;

  @override
  void dispose() {
    _seedController.dispose();
    super.dispose();
  }

  /// Gerar nova seed BIP-39 (12 palavras)
  void _generateNewSeed() {
    final seed = _nip06.generateMnemonic(strength: 128); // 12 palavras
    setState(() {
      _generatedSeed = seed;
      _seedController.text = seed;
      _seedConfirmed = false;
      _error = null;
    });
  }

  /// Copiar seed para clipboard
  void _copySeed() {
    if (_generatedSeed != null) {
      Clipboard.setData(ClipboardData(text: _generatedSeed!));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('📋 Seed copiada! Guarde em local seguro!'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  /// Login/Criar conta com seed
  Future<void> _loginWithSeed() async {
    final seed = _seedController.text.trim().toLowerCase();

    if (seed.isEmpty) {
      setState(() => _error = 'Digite ou gere uma seed');
      return;
    }

    // Validar seed
    if (!_nip06.validateMnemonic(seed)) {
      setState(() => _error = 'Seed inválida. Verifique as 12 palavras.');
      return;
    }

    // Se é uma seed nova, exigir confirmação
    if (_generatedSeed != null && !_seedConfirmed) {
      final confirmed = await _showSeedConfirmationDialog();
      if (!confirmed) return;
      setState(() => _seedConfirmed = true);
    }

    setState(() {
      _isLoading = true;
      _error = null;
      _statusMessage = 'Derivando chaves...';
    });

    try {
      // 1. Derivar chaves Nostr da seed (NIP-06)
      final keys = _nip06.deriveNostrKeys(seed);
      final privateKey = keys['privateKey']!;
      final publicKey = keys['publicKey']!;

      debugPrint('🔑 Chaves derivadas via NIP-06');
      debugPrint('   Pubkey: ${publicKey.substring(0, 16)}...');

      // 2. Salvar chaves Nostr
      await _storage.saveNostrKeys(
        privateKey: privateKey,
        publicKey: publicKey,
      );
      _nostrService.setKeys(privateKey, publicKey);

      // 3. Salvar seed para carteira Lightning (associada ao usuário)
      await _storage.saveBreezMnemonic(seed, ownerPubkey: publicKey);

      // 4. Buscar perfil Nostr (opcional, com timeout)
      if (mounted) {
        setState(() => _statusMessage = 'Buscando perfil...');
      }
      try {
        final profile = await _profileService.fetchProfile(publicKey)
            .timeout(const Duration(seconds: 5), onTimeout: () => null);
        if (profile != null) {
          debugPrint('✅ Perfil encontrado: ${profile.preferredName}');
          await _storage.saveNostrProfile(
            name: profile.name,
            displayName: profile.displayName,
            picture: profile.picture,
            about: profile.about,
          );
        }
      } catch (e) {
        debugPrint('⚠️ Perfil não encontrado (novo usuário)');
      }

      // 5. Inicializar carteira Lightning com a MESMA seed
      if (!kIsWeb && mounted) {
        setState(() => _statusMessage = 'Inicializando carteira...');
        try {
          final breezProvider = context.read<BreezProvider>();
          
          // Resetar SDK para garantir uso da nova seed
          await breezProvider.resetForNewUser();
          
          // Inicializar com a seed (a mesma do Nostr!)
          final success = await breezProvider.initialize(mnemonic: seed)
              .timeout(const Duration(seconds: 20), onTimeout: () {
            debugPrint('⏰ Timeout na inicialização - continuando');
            return false;
          });
          
          if (success) {
            debugPrint('✅ Carteira Lightning inicializada com a seed NIP-06');
          } else {
            debugPrint('⚠️ Carteira inicializará em background');
          }
        } catch (e) {
          debugPrint('❌ Erro no Breez: $e');
        }
      }

      // 6. Carregar ordens do usuário
      if (mounted) {
        setState(() => _statusMessage = 'Carregando histórico...');
        final orderProvider = context.read<OrderProvider>();
        await orderProvider.loadOrdersForUser(publicKey);
      }

      // 7. Navegar para home
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
    } catch (e) {
      debugPrint('❌ Erro no login: $e');
      setState(() => _error = 'Erro: ${e.toString()}');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _statusMessage = null;
        });
      }
    }
  }

  /// Dialog de confirmação de backup da seed
  Future<bool> _showSeedConfirmationDialog() async {
    return await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber, color: Colors.orange, size: 28),
            SizedBox(width: 12),
            Text('Backup Obrigatório', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '⚠️ ATENÇÃO: Esta seed é a ÚNICA forma de recuperar sua conta e seu saldo Bitcoin.',
              style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold),
            ),
            SizedBox(height: 16),
            Text(
              '• Anote as 12 palavras em papel\n'
              '• Guarde em local seguro\n'
              '• NUNCA compartilhe com ninguém\n'
              '• Se perder, perderá TODO o saldo',
              style: TextStyle(color: Color(0xB3FFFFFF)),
            ),
            SizedBox(height: 16),
            Text(
              'Confirmo que fiz backup da minha seed?',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Voltar', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF6B6B)),
            child: const Text('Sim, fiz backup', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    ) ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: SingleChildScrollView(
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
                const SizedBox(height: 20),
                
                // Logo
                Image.asset('assets/images/bro-logo.png', height: 80),
                const SizedBox(height: 8),
                const Text(
                  'Comunidade de escambo digital via Nostr',
                  style: TextStyle(fontSize: 13, color: Color(0xB3FFFFFF)),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),

                // Card principal
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0x0DFFFFFF),
                    border: Border.all(color: const Color(0x33FF6B6B)),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        '🔐 Login Unificado',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Uma única seed = Conta Nostr + Carteira Bitcoin',
                        style: TextStyle(fontSize: 13, color: Color(0x99FFFFFF)),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),

                      // Campo de seed
                      TextField(
                        controller: _seedController,
                        obscureText: !_showSeed,
                        maxLines: _showSeed ? 3 : 1,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        decoration: InputDecoration(
                          labelText: 'Seed (12 palavras)',
                          labelStyle: const TextStyle(color: Color(0xB3FFFFFF)),
                          hintText: 'word1 word2 word3 ... word12',
                          hintStyle: const TextStyle(color: Color(0x66FFFFFF)),
                          prefixIcon: const Icon(Icons.key, color: Color(0xFFFF6B6B)),
                          suffixIcon: IconButton(
                            icon: Icon(
                              _showSeed ? Icons.visibility_off : Icons.visibility,
                              color: const Color(0xB3FFFFFF),
                            ),
                            onPressed: () => setState(() => _showSeed = !_showSeed),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: Color(0x33FF6B6B)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: Color(0xFFFF6B6B), width: 2),
                          ),
                          filled: true,
                          fillColor: const Color(0x0DFFFFFF),
                        ),
                        onChanged: (_) {
                          // Se usuário editou, não é mais a seed gerada
                          if (_generatedSeed != null && _seedController.text != _generatedSeed) {
                            setState(() {
                              _generatedSeed = null;
                              _seedConfirmed = false;
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 12),

                      // Botões de ação da seed
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _generateNewSeed,
                              icon: const Icon(Icons.auto_awesome, size: 18),
                              label: const Text('Criar Nova'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFF9C27B0),
                                side: const BorderSide(color: Color(0xFF9C27B0)),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                            ),
                          ),
                          if (_generatedSeed != null) ...[
                            const SizedBox(width: 8),
                            IconButton(
                              onPressed: _copySeed,
                              icon: const Icon(Icons.copy, color: Colors.orange),
                              tooltip: 'Copiar seed',
                            ),
                          ],
                        ],
                      ),

                      // Aviso se seed foi gerada
                      if (_generatedSeed != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0x1AFF6B00),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0x33FF6B00)),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.warning, color: Colors.orange, size: 20),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  '⚠️ Anote esta seed AGORA! Ela não será mostrada novamente.',
                                  style: TextStyle(color: Colors.orange, fontSize: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      // Erro
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0x1AFF0000),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0x33FF0000)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.error_outline, color: Colors.red, size: 20),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _error!,
                                  style: const TextStyle(color: Colors.red, fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),

                      // Botão principal
                      Container(
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [Color(0xFFFF6B6B), Color(0xFFFF8A8A)],
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
                          onPressed: _isLoading ? null : _loginWithSeed,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            shadowColor: Colors.transparent,
                            padding: const EdgeInsets.symmetric(vertical: 16),
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
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      _generatedSeed != null ? Icons.person_add : Icons.login,
                                      color: Colors.white,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      _generatedSeed != null ? 'Criar Conta' : 'Entrar',
                                      style: const TextStyle(
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

                // Info cards
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0x0D3DE98C),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0x333DE98C)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.shield, color: Color(0xFF3DE98C), size: 20),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Seed = Conta + Carteira. Mesmo login = mesmo saldo sempre!',
                          style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0x0D9C27B0),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0x339C27B0)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.info_outline, color: Color(0xFF9C27B0), size: 20),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Compatível com NIP-06. Sua seed nunca sai do dispositivo.',
                          style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
