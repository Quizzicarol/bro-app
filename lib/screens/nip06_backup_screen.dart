import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/storage_service.dart';
import '../services/nip06_service.dart';
import '../providers/breez_provider_export.dart';

class Nip06BackupScreen extends StatefulWidget {
  const Nip06BackupScreen({Key? key}) : super(key: key);

  @override
  State<Nip06BackupScreen> createState() => _Nip06BackupScreenState();
}

class _Nip06BackupScreenState extends State<Nip06BackupScreen> {
  final _storage = StorageService();
  final _nip06 = Nip06Service();
  final _mnemonicController = TextEditingController();
  final _passphraseController = TextEditingController();
  
  bool _isLoading = false;
  bool _showMnemonic = false;
  bool _showPassphrase = false;
  String? _currentMnemonic;
  String? _derivedPublicKey;
  String? _derivedPrivateKey;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadCurrentMnemonic();
  }

  @override
  void dispose() {
    _mnemonicController.dispose();
    _passphraseController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentMnemonic() async {
    final mnemonic = await _storage.getBreezMnemonic();
    setState(() {
      _currentMnemonic = mnemonic;
    });
  }

  Future<void> _generateNewMnemonic() async {
    final mnemonic = _nip06.generateMnemonic(strength: 128); // 12 palavras
    setState(() {
      _mnemonicController.text = mnemonic;
    });
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('🔑 Nova seed gerada! Guarde em local seguro.'),
        backgroundColor: Color(0xFFFF6B6B),
      ),
    );
  }

  Future<void> _deriveKeys() async {
    debugPrint('🔑 [NIP06] _deriveKeys() chamado');
    final mnemonic = _mnemonicController.text.trim();
    final passphrase = _passphraseController.text;
    
    debugPrint('🔑 [NIP06] Mnemonic: ${mnemonic.split(' ').length} palavras');
    
    if (mnemonic.isEmpty) {
      debugPrint('❌ [NIP06] Mnemonic vazio!');
      setState(() => _error = 'Digite ou gere uma seed');
      return;
    }
    
    final isValid = _nip06.validateMnemonic(mnemonic);
    debugPrint('🔑 [NIP06] Mnemonic válido: $isValid');
    
    if (!isValid) {
      setState(() => _error = 'Seed inválida. Verifique as palavras.');
      return;
    }
    
    setState(() {
      _isLoading = true;
      _error = null;
    });
    
    try {
      debugPrint('🔑 [NIP06] Derivando chaves...');
      final keys = _nip06.deriveNostrKeys(mnemonic, passphrase: passphrase);
      debugPrint('✅ [NIP06] Chaves derivadas! PubKey: ${keys['publicKey']?.substring(0, 16)}...');
      
      setState(() {
        _derivedPublicKey = keys['publicKey'];
        _derivedPrivateKey = keys['privateKey'];
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('❌ [NIP06] Erro ao derivar: $e');
      setState(() {
        _error = 'Erro ao derivar chaves: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _saveAndUseKeys() async {
    if (_derivedPrivateKey == null || _derivedPublicKey == null) return;
    
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Confirmar', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Isso substituirá suas chaves Nostr atuais.\n\n'
          'Certifique-se de ter backup das chaves anteriores antes de continuar.',
          style: TextStyle(color: Color(0xB3FFFFFF)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF6B6B)),
            child: const Text('Confirmar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    
    if (confirm == true) {
      await _storage.saveNostrKeys(
        privateKey: _derivedPrivateKey!,
        publicKey: _derivedPublicKey!,
      );
      
      // FORÇAR atualização da seed (usuário escolheu restaurar)
      final newMnemonic = _mnemonicController.text.trim();
      await _storage.forceUpdateBreezMnemonic(newMnemonic, ownerPubkey: _derivedPublicKey!);
      
      // Reinicializar carteira Lightning com nova seed
      if (mounted) {
        try {
          final breezProvider = context.read<BreezProvider>();
          await breezProvider.reinitializeWithNewSeed(newMnemonic);
          debugPrint('✅ Carteira Lightning reinicializada com nova seed');
        } catch (e) {
          debugPrint('⚠️ Erro ao reinicializar carteira: $e');
        }
      }
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Chaves e carteira restauradas com sucesso!'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
    }
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('📋 $label copiado!'),
        backgroundColor: const Color(0xFF9C27B0),
      ),
    );
  }

  void _useCurrentMnemonic() {
    if (_currentMnemonic != null) {
      setState(() {
        _mnemonicController.text = _currentMnemonic!;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xF70A0A0A),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'NIP-06: Backup Unificado',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: const Color(0x33FF6B35), height: 1),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Info card
              _buildInfoCard(),
              const SizedBox(height: 24),
              
              // Seed input
              _buildSeedInput(),
              const SizedBox(height: 16),
              
              // Passphrase (optional)
              _buildPassphraseInput(),
              const SizedBox(height: 24),
              
              // Buttons
              _buildActionButtons(),
            
            // Error message
            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0x1AFF0000),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0x33FF0000)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.red, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.red, fontSize: 16),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            
            // Derived keys result
            if (_derivedPublicKey != null) ...[
              const SizedBox(height: 24),
              _buildDerivedKeysSection(),
            ],
            
            // Extra padding at bottom for navigation buttons
            const SizedBox(height: 48),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildInfoCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFFFF6B6B).withOpacity(0.2),
            const Color(0xFFFF6B6B).withOpacity(0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x33FF6B35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.info_outline, color: Color(0xFFFF6B6B)),
              SizedBox(width: 8),
              Text(
                'O que é NIP-06?',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'NIP-06 permite derivar suas chaves Nostr a partir de uma seed BIP-39 '
            '(as mesmas 12 ou 24 palavras usadas em carteiras Bitcoin).',
            style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 16, height: 1.5),
          ),
          const SizedBox(height: 16),
          // Esclarecimento importante
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0x1AFFC107),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0x33FFC107)),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.lightbulb_outline, color: Color(0xFFFFC107), size: 18),
                    SizedBox(width: 8),
                    Text(
                      'Importante entender:',
                      style: TextStyle(
                        color: Color(0xFFFFC107),
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 8),
                Text(
                  '🔐 SEED = Sua frase secreta de 12 ou 24 palavras\n\n'
                  '🟣 Chaves Nostr = Sua identidade no protocolo Nostr (npub/nsec)\n\n'
                  '🟠 Chaves Bitcoin = Suas carteiras para guardar/enviar sats\n\n'
                  '💡 Uma ÚNICA seed pode gerar ambas as chaves, facilitando o backup!',
                  style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 15, height: 1.5),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '✅ Um único backup para Bitcoin e Nostr\n'
            '✅ Chaves determinísticas e recuperáveis\n'
            '✅ Passphrase opcional para maior segurança',
            style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 16, height: 1.5),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0x1AFFFFFF),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(
              children: [
                Icon(Icons.route, color: Color(0xFFFF6B6B), size: 16),
                SizedBox(width: 8),
                Text(
                  "Derivation path: m/44'/1237'/0'/0/0",
                  style: TextStyle(
                    color: Color(0xB3FFFFFF),
                    fontSize: 14,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSeedInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Seed (12 ou 24 palavras)',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            IconButton(
              icon: Icon(
                _showMnemonic ? Icons.visibility_off : Icons.visibility,
                color: const Color(0x99FFFFFF),
              ),
              onPressed: () => setState(() => _showMnemonic = !_showMnemonic),
            ),
          ],
        ),
        const SizedBox(height: 8),
        // Seed é exibida como texto normal (palavras visíveis) ou oculta (asteriscos)
        // Não pode usar obscureText com maxLines > 1, então usamos um workaround
        if (_showMnemonic) ...[
          TextField(
            controller: _mnemonicController,
            maxLines: 3,
            style: const TextStyle(color: Colors.white, fontFamily: 'monospace'),
            decoration: InputDecoration(
              hintText: 'Digite ou cole sua seed aqui...',
              hintStyle: const TextStyle(color: Color(0x66FFFFFF)),
              filled: true,
              fillColor: const Color(0x0DFFFFFF),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0x33FFFFFF)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFFFF6B6B)),
              ),
            ),
          ),
        ] else ...[
          // Quando oculto, mostra asteriscos em campo não editável
          GestureDetector(
            onTap: () => setState(() => _showMnemonic = true),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0x0DFFFFFF),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0x33FFFFFF)),
              ),
              child: Text(
                _mnemonicController.text.isEmpty
                    ? 'Toque para inserir sua seed...'
                    : '• ' * (_mnemonicController.text.split(' ').length) + '(${_mnemonicController.text.split(' ').length} palavras)',
                style: TextStyle(
                  color: _mnemonicController.text.isEmpty
                      ? const Color(0x66FFFFFF)
                      : Colors.white,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ],
        if (_currentMnemonic != null) ...[
          const SizedBox(height: 8),
          GestureDetector(
            onTap: _useCurrentMnemonic,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0x1A9C27B0),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_awesome, color: Color(0xFF9C27B0), size: 16),
                  SizedBox(width: 8),
                  Text(
                    'Usar seed atual da carteira',
                    style: TextStyle(color: Color(0xFFBA68C8), fontSize: 15),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildPassphraseInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              'Passphrase (opcional)',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0x1AFF6B35),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Avançado',
                style: TextStyle(
                  color: Color(0xFFFF6B6B),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'Adiciona uma camada extra de segurança. Se usar, lembre-se dela!',
          style: TextStyle(color: Color(0x99FFFFFF), fontSize: 15),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _passphraseController,
          obscureText: !_showPassphrase,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Passphrase opcional...',
            hintStyle: const TextStyle(color: Color(0x66FFFFFF)),
            prefixIcon: const Icon(Icons.lock_outline, color: Color(0x99FFFFFF)),
            suffixIcon: IconButton(
              icon: Icon(
                _showPassphrase ? Icons.visibility_off : Icons.visibility,
                color: const Color(0x99FFFFFF),
              ),
              onPressed: () => setState(() => _showPassphrase = !_showPassphrase),
            ),
            filled: true,
            fillColor: const Color(0x0DFFFFFF),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0x33FFFFFF)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFFFF6B6B)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildActionButtons() {
    return Column(
      children: [
        // Primeira linha: Gerar Nova e Derivar Chaves
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _generateNewMnemonic,
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Gerar Nova'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF9C27B0),
                  side: const BorderSide(color: Color(0xFF9C27B0)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _isLoading ? null : _deriveKeys,
                icon: _isLoading 
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.key),
                label: const Text('Derivar Chaves'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF6B6B),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // Segunda linha: Botão de restaurar carteira Lightning (destacado)
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _isLoading ? null : _restoreWalletOnly,
            icon: _isLoading 
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.account_balance_wallet),
            label: const Text('💰 RESTAURAR CARTEIRA LIGHTNING'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              textStyle: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _restoreWalletOnly() async {
    final mnemonic = _mnemonicController.text.trim();
    
    if (mnemonic.isEmpty) {
      setState(() => _error = 'Digite a seed para restaurar');
      return;
    }
    
    if (!_nip06.validateMnemonic(mnemonic)) {
      setState(() => _error = 'Seed inválida. Verifique as palavras.');
      return;
    }
    
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.account_balance_wallet, color: Color(0xFFFF6B6B)),
            SizedBox(width: 8),
            Text('Restaurar Carteira', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: const Text(
          '⚠️ ATENÇÃO: Isso irá substituir a carteira Lightning atual pela nova seed.\n\n'
          'O saldo da carteira antiga será PERDIDO se você não tiver backup.\n\n'
          'Tem certeza que deseja continuar?',
          style: TextStyle(color: Color(0xB3FFFFFF)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF6B6B)),
            child: const Text('Restaurar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    
    if (confirm != true) return;
    
    setState(() {
      _isLoading = true;
      _error = null;
    });
    
    try {
      debugPrint('🔄 [NIP06] Restaurando carteira Lightning...');
      
      // FORÇAR atualização de seed (usuário escolheu explicitamente restaurar)
      // Igual ao login avançado - usa forceOverwrite para substituir a seed atual
      await _storage.forceUpdateBreezMnemonic(mnemonic);
      
      // Reinicializar SDK com a seed
      if (mounted) {
        final breezProvider = context.read<BreezProvider>();
        final success = await breezProvider.reinitializeWithNewSeed(mnemonic);
        
        if (success) {
          debugPrint('✅ [NIP06] Carteira restaurada com sucesso!');
          
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('✅ Carteira Lightning restaurada com sucesso!'),
                backgroundColor: Colors.green,
              ),
            );
          }
        } else {
          throw Exception('Falha ao reinicializar SDK');
        }
      }
      
      setState(() => _isLoading = false);
    } catch (e) {
      debugPrint('❌ [NIP06] Erro ao restaurar: $e');
      setState(() {
        _error = 'Erro ao restaurar carteira: $e';
        _isLoading = false;
      });
    }
  }

  Widget _buildDerivedKeysSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x1A00FF00),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x3300FF00)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.check_circle, color: Colors.green),
              SizedBox(width: 8),
              Text(
                'Chaves Derivadas',
                style: TextStyle(
                  color: Colors.green,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          
          // Public Key
          _buildKeyDisplay(
            'Chave Pública',
            _derivedPublicKey!,
            const Color(0xFF9C27B0),
          ),
          const SizedBox(height: 12),
          
          // Private Key (warning)
          _buildKeyDisplay(
            'Chave Privada (⚠️ secreta)',
            _derivedPrivateKey!,
            Colors.orange,
          ),
          const SizedBox(height: 16),
          
          // Save button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _saveAndUseKeys,
              icon: const Icon(Icons.save),
              label: const Text('Salvar e Usar Estas Chaves'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKeyDisplay(String label, String value, Color color) {
    final truncated = '${value.substring(0, 16)}...${value.substring(value.length - 16)}';
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: () => _copyToClipboard(value, label),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0x0DFFFFFF),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    truncated,
                    style: const TextStyle(
                      color: Color(0xB3FFFFFF),
                      fontSize: 15,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                Icon(Icons.copy, color: color, size: 16),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
