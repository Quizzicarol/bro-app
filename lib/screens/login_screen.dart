?import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:nostr/nostr.dart';
import '../services/nostr_service.dart';
import '../services/nostr_profile_service.dart';
import '../services/storage_service.dart';
import '../services/nip06_service.dart';
import '../services/platform_fee_service.dart';
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
  final _nip06Service = Nip06Service();
  final _privateKeyController = TextEditingController();

  bool _isLoading = false;
  bool _showPrivateKey = false;
  String? _error;
  String? _statusMessage;
  
  // Detectar tipo de input
  bool _isSeedPhrase = false;
  String? _detectedMnemonic;
  
  // Seed da carteira Bitcoin gerada junto com nova chave Nostr
  String? _generatedWalletSeed;
  
  // Controle de tela: true = tela inicial, false = tela de login
  bool _showWelcomeScreen = true;

  @override
  void dispose() {
    _privateKeyController.dispose();
    super.dispose();
  }

  /// Detectar se input � seed (12/24 palavras) ou chave privada hex
  void _detectInputType(String input) {
    final trimmed = input.trim().toLowerCase();
    final words = trimmed.split(RegExp(r'\s+'));
    
    // Se tem 12 ou 24 palavras, provavelmente � seed
    if ((words.length == 12 || words.length == 24) && _nip06Service.validateMnemonic(trimmed)) {
      setState(() {
        _isSeedPhrase = true;
        _detectedMnemonic = trimmed;
      });
      debugPrint('?? Detectado: Seed de ${words.length} palavras');
    } else {
      setState(() {
        _isSeedPhrase = false;
        _detectedMnemonic = null;
      });
    }
  }

  /// Gerar nova conta usando NIP-06 (seed unificada)
  /// A MESMA seed � usada para identidade Nostr E carteira Lightning!
  Future<void> _generateNewPrivateKey() async {
    // Gerar seed BIP-39 que ser� usada para TUDO
    final unifiedSeed = _nip06Service.generateMnemonic();
    
    // Derivar chave Nostr da seed (NIP-06)
    final keys = _nip06Service.deriveNostrKeys(unifiedSeed);
    final privateKey = keys['privateKey']!;
    
    // Guardar a seed para usar na carteira tamb�m
    _generatedWalletSeed = unifiedSeed;
    
    // Preencher campo com a SEED (n�o a chave) para o usu�rio guardar
    _privateKeyController.text = unifiedSeed;
    
    setState(() {
      _isSeedPhrase = true;
      _detectedMnemonic = unifiedSeed;
    });

    debugPrint('?? Nova conta NIP-06 criada!');

    if (mounted) {
      // Mostrar di�logo com APENAS a seed (uma coisa s� para guardar!)
      _showNewAccountDialogUnified(unifiedSeed);
    }
  }
  
  /// Di�logo mostrando APENAS a seed unificada (mais simples!)
  void _showNewAccountDialogUnified(String seed) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Bot�o voltar
            IconButton(
              onPressed: () {
                Navigator.pop(context);
                // Limpar estado para voltar � tela inicial
                setState(() {
                  _privateKeyController.clear();
                  _error = null;
                });
              },
              icon: const Icon(Icons.arrow_back, color: Colors.white70, size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.spa, color: Color(0xFF3DE98C), size: 22),
            const SizedBox(width: 8),
            const Flexible(
              child: Text('Nova Conta!', 
                style: TextStyle(color: Colors.white, fontSize: 16),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withOpacity(0.3)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning, color: Colors.red, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'GUARDE ESTAS 12 PALAVRAS!\nSem elas voc� PERDE acesso � conta e aos fundos.',
                        style: TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF3DE98C).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF3DE98C).withOpacity(0.3)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.info_outline, color: Color(0xFF3DE98C), size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Esta seed controla sua identidade Nostr E sua carteira Lightning!',
                        style: TextStyle(color: Color(0xFF3DE98C), fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 16),
              const Text('?? Sua Seed (12 palavras):', 
                style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black38,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  seed,
                  style: const TextStyle(color: Color(0xFF3DE98C), fontSize: 14, height: 1.5),
                ),
              ),
              
              const SizedBox(height: 16),
              const Text(
                '?? Dica: Anote em papel e guarde em local seguro. Nunca compartilhe!',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: seed));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('? Seed copiada! Guarde em local seguro!'),
                    backgroundColor: Color(0xFF3DE98C),
                  ),
                );
              }
            },
            child: const Text('?? Copiar', style: TextStyle(color: Color(0xFFFF9800))),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              // IMPORTANTE: Fazer login autom�tico ap�s fechar o di�logo!
              _login();
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF3DE98C)),
            child: const Text('Entendi, Guardei!', style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
  }
  
  /// Di�logo mostrando chave Nostr e seed da carteira (modo avan�ado - LEGADO)
  void _showNewAccountDialog(String privateKey, String walletSeed) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.key, color: Color(0xFF3DE98C), size: 24),
            SizedBox(width: 12),
            Text('Nova Conta Criada!', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withOpacity(0.3)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning, color: Colors.red, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'GUARDE ESTAS INFORMA��ES!\nSem elas voc� PERDE acesso � conta e aos fundos.',
                        style: TextStyle(color: Colors.red, fontSize: 12, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              
              const Text('?? Chave Privada Nostr:', 
                style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black38,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  privateKey,
                  style: const TextStyle(color: Color(0xFF3DE98C), fontSize: 11, fontFamily: 'monospace'),
                ),
              ),
              
              const SizedBox(height: 16),
              const Text('?? Seed da Carteira Bitcoin:', 
                style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black38,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  walletSeed,
                  style: const TextStyle(color: Color(0xFFFFB74D), fontSize: 11),
                ),
              ),
              
              const SizedBox(height: 16),
              const Text(
                '?? Dica: Use a chave Nostr para login e a seed da carteira para recuperar seus fundos Bitcoin se necess�rio.',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              // Copiar ambos para �rea de transfer�ncia
              final text = 'CHAVE NOSTR:\n$privateKey\n\nSEED CARTEIRA:\n$walletSeed';
              await Clipboard.setData(ClipboardData(text: text));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('? Copiado para �rea de transfer�ncia!'),
                    backgroundColor: Color(0xFF3DE98C),
                  ),
                );
              }
            },
            child: const Text('?? Copiar Tudo', style: TextStyle(color: Color(0xFFFF9800))),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF3DE98C)),
            child: const Text('Entendi, Guardei!', style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
  }

  /// Dialog para login via NIP-06 (seed BIP-39)
  Future<void> _showNip06LoginDialog() async {
    final seedController = TextEditingController();
    bool showSeed = false;
    
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.spa, color: Color(0xFF3DE98C), size: 24),
              SizedBox(width: 12),
              Text('Login via Seed (NIP-06)', style: TextStyle(color: Colors.white, fontSize: 18)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF3DE98C).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF3DE98C).withOpacity(0.3)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.info_outline, color: Color(0xFF3DE98C), size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'A seed BIP-39 deriva sua chave Nostr E sua carteira Lightning!',
                          style: TextStyle(color: Color(0xFF3DE98C), fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: seedController,
                  obscureText: !showSeed,
                  maxLines: showSeed ? 3 : 1,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: InputDecoration(
                    labelText: 'Seed de 12 ou 24 palavras',
                    labelStyle: const TextStyle(color: Color(0x99FFFFFF)),
                    hintText: 'abandon ability able about...',
                    hintStyle: const TextStyle(color: Color(0x66FFFFFF)),
                    prefixIcon: const Icon(Icons.spa, color: Color(0xFF3DE98C)),
                    suffixIcon: IconButton(
                      icon: Icon(
                        showSeed ? Icons.visibility_off : Icons.visibility,
                        color: const Color(0x99FFFFFF),
                      ),
                      onPressed: () => setDialogState(() => showSeed = !showSeed),
                    ),
                    filled: true,
                    fillColor: const Color(0x0DFFFFFF),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0x33FFFFFF)),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () {
                        final newSeed = _nip06Service.generateMnemonic();
                        seedController.text = newSeed;
                        setDialogState(() => showSeed = true);
                      },
                      child: const Text('Gerar nova seed', style: TextStyle(color: Color(0xFF3DE98C))),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar', style: TextStyle(color: Color(0x99FFFFFF))),
            ),
            ElevatedButton(
              onPressed: () {
                final seed = seedController.text.trim().toLowerCase();
                if (_nip06Service.validateMnemonic(seed)) {
                  Navigator.pop(context);
                  _privateKeyController.text = seed;
                  _detectInputType(seed);
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Seed inv�lida! Verifique as 12 ou 24 palavras.'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF3DE98C)),
              child: const Text('Usar Seed', style: TextStyle(color: Colors.black)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _generateKeys() async {
    // Gerar SEED (n�o apenas chave) - assim pode ser usada para Nostr E Bitcoin
    final mnemonic = _nip06Service.generateMnemonic();
    _privateKeyController.text = mnemonic;
    
    _detectInputType(mnemonic);

    debugPrint('?? Nova seed gerada');

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Seed gerada! Guarde estas 12 palavras em local MUITO seguro!'),
          backgroundColor: Color(0xFFFF6B6B),
          duration: Duration(seconds: 4),
        ),
      );
    }
  }

  /// Login Avan�ado: permite inserir chave privada Nostr + Seed Bitcoin SEPARADAMENTE
  /// �til para usu�rios que:
  /// 1. J� t�m uma identidade Nostr criada SEM usar NIP-06
  /// 2. Querem vincular uma carteira Bitcoin a essa identidade existente
  Future<void> _showAdvancedLoginDialog() async {
    final nostrKeyController = TextEditingController();
    final seedController = TextEditingController();
    String? dialogError;
    bool dialogLoading = false;
    
    // Capturar refer�ncias ANTES de abrir o di�logo
    final breezProv = !kIsWeb ? context.read<BreezProvider>() : null;

    // Retorna true se login foi bem sucedido
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1C1C1E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.settings, color: Color(0xFFFF6B6B)),
              SizedBox(width: 10),
              Text(
                'Login Avan�ado',
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Explica��o
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0x1AFF6B6B),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0x33FF6B6B)),
                  ),
                  child: const Text(
                    'Use este login se sua conta Nostr foi criada SEPARADAMENTE da sua carteira Bitcoin.\n\n'
                    'Isso vincular� sua identidade Nostr � sua carteira Lightning permanentemente.',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
                const SizedBox(height: 16),

                // Campo 1: Chave Nostr
                const Text(
                  '1. Chave Privada Nostr',
                  style: TextStyle(color: Color(0xFF9C27B0), fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Sua chave privada (nsec ou hex)',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: nostrKeyController,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'nsec1... ou hex de 64 caracteres',
                    hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
                    filled: true,
                    fillColor: const Color(0xFF2C2C2E),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 16),

                // Campo 2: Seed Bitcoin
                const Text(
                  '2. Seed da Carteira Bitcoin',
                  style: TextStyle(color: Color(0xFF3DE98C), fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const SizedBox(height: 4),
                const Text(
                  '12 palavras da sua carteira Lightning',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: seedController,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'palavra1 palavra2 palavra3...',
                    hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
                    filled: true,
                    fillColor: const Color(0xFF2C2C2E),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                  maxLines: 3,
                ),

                // Erro
                if (dialogError != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: const Color(0x1AFF0000),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      dialogError!,
                      style: const TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: dialogLoading ? null : () => Navigator.pop(dialogContext),
              child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              onPressed: dialogLoading ? null : () async {
                final nostrKey = nostrKeyController.text.trim();
                final seed = seedController.text.trim().toLowerCase();

                // Valida��es
                if (nostrKey.isEmpty) {
                  setDialogState(() => dialogError = 'Digite sua chave privada Nostr');
                  return;
                }
                if (seed.isEmpty) {
                  setDialogState(() => dialogError = 'Digite a seed da carteira');
                  return;
                }
                if (!_nostrService.isValidPrivateKey(nostrKey)) {
                  setDialogState(() => dialogError = 'Chave Nostr inv�lida');
                  return;
                }
                if (!_nip06Service.validateMnemonic(seed)) {
                  setDialogState(() => dialogError = 'Seed inv�lida (use 12 ou 24 palavras BIP-39)');
                  return;
                }

                setDialogState(() {
                  dialogLoading = true;
                  dialogError = null;
                });

                try {
                  // Derivar chave p�blica Nostr
                  final publicKey = _nostrService.getPublicKey(nostrKey);
                  
                  debugPrint('?? LOGIN AVAN�ADO: chaves configuradas');

                  // Salvar chaves Nostr
                  await _storage.saveNostrKeys(
                    privateKey: nostrKey,
                    publicKey: publicKey,
                  );
                  _nostrService.setKeys(nostrKey, publicKey);

                  // LOGIN AVAN�ADO: FOR�A a troca de seed (o usu�rio escolheu explicitamente)
                  await _storage.forceUpdateBreezMnemonic(seed, ownerPubkey: publicKey);
                  debugPrint('?? Seed vinculada ao usu�rio');

                  // Salvar URL do backend
                  await _storage.saveBackendUrl(AppConfig.defaultBackendUrl);

                  // Capturar refer�ncias ANTES de qualquer navega��o
                  final seedToUse = seed;

                  // Resetar o Breez para usar a nova seed
                  if (breezProv != null) {
                    await breezProv.resetForNewUser();
                  }

                  debugPrint('? Login Avan�ado completo!');

                  // Inicializar Breez em BACKGROUND (n�o bloqueia)
                  if (breezProv != null) {
                    Future.microtask(() async {
                      try {
                        await breezProv.initialize(mnemonic: seedToUse);
                        debugPrint('? Breez inicializado com seed vinculada!');
                      } catch (e) {
                        debugPrint('?? Erro inicializando Breez: $e');
                      }
                    });
                  }

                  // Retornar sucesso e fechar di�logo
                  if (dialogContext.mounted) {
                    Navigator.pop(dialogContext, true);
                  }

                } catch (e) {
                  setDialogState(() {
                    dialogLoading = false;
                    dialogError = 'Erro: $e';
                  });
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF6B6B),
              ),
              child: dialogLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Vincular e Entrar', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );

    // Se login foi bem sucedido, mostrar sucesso e orientar
    if (result == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('? Seed vinculada! Agora fa�a login com sua chave Nostr acima.'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _login() async {
    final input = _privateKeyController.text.trim();

    if (input.isEmpty) {
      setState(() => _error = 'Digite sua chave privada Nostr (nsec ou hex)');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
      _statusMessage = 'Validando...';
    });

    try {
      // DIAGN�STICO: Mostrar todos os dados de seed antes do login
      debugPrint('');
      debugPrint('?? DIAGN�STICO PR�-LOGIN:');
      await _storage.debugShowAllSeeds();
      
      String privateKey;
      String publicKey;
      String? mnemonic;
      
      // Detectar tipo de input
      final words = input.toLowerCase().split(RegExp(r'\s+'));
      final isSeed = (words.length == 12 || words.length == 24) && _nip06Service.validateMnemonic(input.toLowerCase());
      
      if (isSeed) {
        // LOGIN VIA NIP-06 (SEED)
        debugPrint('?? Login via NIP-06 (seed de ${words.length} palavras)');
        setState(() => _statusMessage = 'Derivando chaves da seed...');
        
        mnemonic = input.toLowerCase();
        final keys = _nip06Service.deriveNostrKeys(mnemonic);
        privateKey = keys['privateKey']!;
        publicKey = keys['publicKey']!;
        
        debugPrint('?? NIP-06: chaves derivadas com sucesso');
        
        // IMPORTANTE: N�O salvar a seed aqui ainda!
        // Primeiro salvamos as chaves Nostr, depois a seed COM o pubkey
        // Isso garante que seed e identidade Nostr fiquem SEMPRE vinculadas!
        
      } else {
        // LOGIN VIA CHAVE PRIVADA NOSTR (hex ou nsec)
        debugPrint('?? Login via chave privada Nostr');
        
        if (!_nostrService.isValidPrivateKey(input)) {
          throw Exception('Input inv�lido. Use:\n- Seed de 12 palavras (NIP-06)\n- Chave privada hex (64 chars)\n- nsec...');
        }
        
        // Normalizar chave para hex (pode vir como nsec)
        // Usar Keychain para converter nsec -> hex
        final keychain = Keychain(input);
        privateKey = keychain.private; // Sempre retorna hex
        publicKey = keychain.public;
        
        debugPrint('?? Chave normalizada para hex');
        
        // PRIORIDADE: Seed salva > Seed derivada
        // Isso permite que Login Avan�ado vincule uma seed espec�fica
        debugPrint('?? Buscando seed para pubkey...');
        
        // PRIMEIRO: Verificar se existe seed salva (vinculada via Login Avan�ado)
        String? existingSeed = await _storage.getBreezMnemonic(forPubkey: publicKey);
        
        if (existingSeed != null) {
          mnemonic = existingSeed;
          debugPrint('? Seed SALVA encontrada (Login Avan�ado ou anterior)');
        } else {
          // SEGUNDO: Derivar deterministicamente da chave Nostr
          debugPrint('?? Nenhuma seed salva. Derivando da chave Nostr...');
          try {
            mnemonic = _nip06Service.deriveSeedFromNostrKey(privateKey);
            debugPrint('? Seed DERIVADA com sucesso!');
          } catch (e) {
            debugPrint('? Erro ao derivar seed: $e');
          }
        }
        debugPrint('???????????????????????????????????????????????????????????');
        debugPrint('');
      }

      debugPrint('? Login com Nostr. Pubkey: ${publicKey.substring(0, 16)}...');

      // Salvar chaves Nostr PRIMEIRO
      await _storage.saveNostrKeys(
        privateKey: privateKey,
        publicKey: publicKey,
      );

      _nostrService.setKeys(privateKey, publicKey);
      
      // AGORA salvar a seed vinculada ao pubkey correto
      // Isso garante que NIP-06 mantenha identidade Nostr + carteira Bitcoin vinculadas
      if (mnemonic != null) {
        await _storage.saveBreezMnemonic(mnemonic, ownerPubkey: publicKey);
        debugPrint('?? Seed salva VINCULADA ao usu�rio: ${publicKey.substring(0, 16)}...');
      } else if (_generatedWalletSeed != null) {
        await _storage.saveBreezMnemonic(_generatedWalletSeed!, ownerPubkey: publicKey);
        debugPrint('?? Seed gerada salva para usu�rio: ${publicKey.substring(0, 16)}...');
        _generatedWalletSeed = null; // Limpar ap�s salvar
      }

      // Buscar perfil Nostr dos relays (com timeout)
      if (mounted) {
        setState(() => _statusMessage = 'Buscando perfil Nostr...');
      }
      
      try {
        final profile = await _profileService.fetchProfile(publicKey)
            .timeout(const Duration(seconds: 5), onTimeout: () {
          debugPrint('? Timeout ao buscar perfil - continuando');
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
      }

      // Salvar URL do backend
      await _storage.saveBackendUrl(AppConfig.defaultBackendUrl);

      // Inicializar Breez SDK
      if (!kIsWeb) {
        if (mounted) {
          setState(() => _statusMessage = 'Inicializando carteira Lightning...');
        }
        try {
          final breezProvider = context.read<BreezProvider>();
          
          // SEMPRE tentar inicializar COM a seed que temos
          // Se mnemonic � null, o BreezProvider vai buscar a seed do storage
          if (mnemonic != null) {
            debugPrint('? Inicializando Breez COM SEED EXISTENTE: ${mnemonic.split(' ').take(2).join(' ')}...');
            final success = await breezProvider.initialize(mnemonic: mnemonic)
                .timeout(const Duration(seconds: 15), onTimeout: () {
              debugPrint('? Timeout na inicializa��o do Breez');
              return false;
            });
            
            if (success) {
              debugPrint('? Breez inicializado com seed existente!');
              // CR�TICO: Configurar callback do PlatformFeeService
              PlatformFeeService.setPaymentCallback(
                (String invoice) => breezProvider.payInvoice(invoice),
                'Spark',
              );
              debugPrint('?? PlatformFeeService callback configurado');
            }
          } else {
            // ATEN��O: N�o temos seed - o BreezProvider vai criar uma nova!
            debugPrint('?? SEM SEED RECUPERADA - Breez vai gerar nova!');
            debugPrint('?? Se voc� tinha saldo, use Login Avan�ado para vincular seed!');
            final success = await breezProvider.initialize()
                .timeout(const Duration(seconds: 15), onTimeout: () {
              debugPrint('? Timeout na inicializa��o do Breez');
              return false;
            });
            
            if (success) {
              // CR�TICO: Configurar callback do PlatformFeeService
              PlatformFeeService.setPaymentCallback(
                (String invoice) => breezProvider.payInvoice(invoice),
                'Spark',
              );
              debugPrint('?? PlatformFeeService callback configurado');
            }
            
            if (!success && mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Carteira inicializar� em background'),
                  backgroundColor: Colors.orange,
                  duration: Duration(seconds: 2),
                ),
              );
            }
          }
        } catch (e) {
          debugPrint('? Erro no Breez (ignorando): $e');
        }
      }

      // Carregar ordens do usu�rio
      if (mounted) {
        setState(() => _statusMessage = 'Carregando hist�rico...');
        final orderProvider = context.read<OrderProvider>();
        await orderProvider.loadOrdersForUser(publicKey);
        debugPrint('? Ordens carregadas para ${publicKey.substring(0, 8)}...');
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
                         MediaQuery.of(context).padding.bottom - 48, // Reduzir altura m�nima
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.start, // Alinhar ao topo
              children: [
                const SizedBox(height: 40), // Espa�o menor no topo
                _buildLoginContent(),
              ],
            ),
          ),
        ),
      ),
    );
  }
  
  Widget _buildLoginContent() {
    // Tela inicial clean (para novos usu�rios)
    if (_showWelcomeScreen) {
      return _buildWelcomeScreen();
    }
    
    // Tela de login (para quem j� tem conta)
    return _buildLoginScreen();
  }
  
  /// Tela inicial clean para novos usu�rios - estilo Apple
  Widget _buildWelcomeScreen() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 40),
        
        // Logo elegante
        Image.asset(
          'assets/images/bro-logo.png',
          height: 80,
        ),
        const SizedBox(height: 12),
        
        // Slogan minimalista
        const Text(
          'Escambo digital via Nostr',
          style: TextStyle(
            fontSize: 15,
            color: Color(0x99FFFFFF),
            fontWeight: FontWeight.w400,
            letterSpacing: 0.3,
          ),
          textAlign: TextAlign.center,
        ),
        
        const SizedBox(height: 40),
        
        // Card esfuma�ado igual ao login screen
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
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.key, color: Color(0xFFFF6B6B), size: 24),
                  SizedBox(width: 8),
                  Text(
                    'Login via Nostr',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              
              const SizedBox(height: 20),
              
              // Bot�o Nova Conta (elegante, laranja)
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFFF6B6B), Color(0xFFFF8A8A)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFF6B6B).withOpacity(0.25),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: ElevatedButton(
            onPressed: _isLoading ? null : _generateNewPrivateKey,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.transparent,
              shadowColor: Colors.transparent,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_circle_outline, color: Colors.white, size: 20),
                      SizedBox(width: 10),
                      Text(
                        'Nova Conta',
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
        
        const SizedBox(height: 16),
        
        // Link "J� tenho conta" (verde, discreto)
        TextButton(
          onPressed: () {
            setState(() => _showWelcomeScreen = false);
          },
          child: const Text(
            'J� tenho conta',
            style: TextStyle(
              color: Color(0xFF3DE98C),
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
            ],
          ),
        ),
        
        const SizedBox(height: 30),
      ],
    );
  }
  
  /// Tela de login para quem j� tem conta
  Widget _buildLoginScreen() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Bot�o voltar
        Align(
          alignment: Alignment.centerLeft,
          child: IconButton(
            onPressed: () {
              setState(() {
                _showWelcomeScreen = true;
                _privateKeyController.clear();
                _error = null;
              });
            },
            icon: const Icon(Icons.arrow_back, color: Colors.white70),
          ),
        ),
        
        // Logo menor
        Image.asset(
          'assets/images/bro-logo.png',
          height: 60,
        ),
        const SizedBox(height: 16),

              // Card de Login - CHAVE PRIVADA (PRINCIPAL)
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
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.key, color: Color(0xFFFF6B6B), size: 24),
                        SizedBox(width: 8),
                        Text(
                          'Login via Nostr',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Entre com chave privada Nostr (nsec/hex) ou seed NIP-06',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0x99FFFFFF),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),

                    // Campo de chave privada (PRINCIPAL)
                    TextField(
                      controller: _privateKeyController,
                      obscureText: !_showPrivateKey,
                      maxLines: _showPrivateKey && _isSeedPhrase ? 3 : 1,
                      style: const TextStyle(color: Colors.white),
                      onChanged: _detectInputType,
                      decoration: InputDecoration(
                        labelText: _isSeedPhrase 
                            ? '?? Seed NIP-06 detectada!' 
                            : 'Chave Privada ou Seed',
                        labelStyle: TextStyle(
                          color: _isSeedPhrase ? const Color(0xFF3DE98C) : const Color(0xB3FFFFFF),
                        ),
                        hintText: 'nsec1... ou 12 palavras da seed',
                        hintStyle: const TextStyle(color: Color(0x66FFFFFF)),
                        prefixIcon: Icon(
                          _isSeedPhrase ? Icons.spa : Icons.vpn_key,
                          color: _isSeedPhrase ? const Color(0xFF3DE98C) : const Color(0xFFFF6B6B),
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
                    const SizedBox(height: 16),

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
                    
                    // Bot�o Login Avan�ado (para vincular Nostr + Seed separados)
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: _isLoading ? null : _showAdvancedLoginDialog,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.settings, color: Colors.white54, size: 16),
                          SizedBox(width: 6),
                          Text(
                            'Login Avan�ado (Nostr + Seed separados)',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 30),
            ],
          );
  }
}
