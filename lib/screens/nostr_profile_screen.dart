import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/storage_service.dart';
import '../services/nip06_service.dart';

class NostrProfileScreen extends StatefulWidget {
  const NostrProfileScreen({Key? key}) : super(key: key);

  @override
  State<NostrProfileScreen> createState() => _NostrProfileScreenState();
}

class _NostrProfileScreenState extends State<NostrProfileScreen> {
  final _storage = StorageService();
  final _nip06 = Nip06Service();
  
  String? _publicKey;
  String? _privateKey;
  String? _npub;
  String? _lightningAddress;
  Map<String, dynamic>? _profile;
  bool _isLoading = true;
  bool _showPrivateKey = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final publicKey = await _storage.getNostrPublicKey();
    final privateKey = await _storage.getNostrPrivateKey();
    
    setState(() {
      _publicKey = publicKey;
      _privateKey = privateKey;
      _npub = publicKey != null ? _toNpub(publicKey) : null;
      _lightningAddress = publicKey != null 
          ? '${publicKey.substring(0, 8)}@paga-conta.app'
          : null;
      _isLoading = false;
    });
    
    // TODO: Fetch profile from relays
  }

  String _toNpub(String hex) {
    // Simplified npub encoding (real implementation needs bech32)
    return 'npub1${hex.substring(0, 20)}...${hex.substring(hex.length - 8)}';
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('📋 $label copiado!'),
        backgroundColor: const Color(0xFF9C27B0),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showQRCode(String data, String title) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.qr_code_2, size: 200, color: Colors.black),
              // TODO: Replace with actual QR code widget
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0x0DFFFFFF),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                data,
                style: const TextStyle(
                  color: Color(0xB3FFFFFF),
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fechar', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton.icon(
            onPressed: () {
              _copyToClipboard(data, title);
              Navigator.pop(context);
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copiar'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF9C27B0),
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
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
          'Meu Perfil Nostr',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined, color: Color(0xFFFF6B35)),
            onPressed: () {
              // TODO: Edit profile
            },
            tooltip: 'Editar Perfil',
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: const Color(0x33FF6B35), height: 1),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF9C27B0)))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  // Profile header
                  _buildProfileHeader(),
                  const SizedBox(height: 24),
                  
                  // Public Key
                  _buildKeyCard(
                    title: 'Chave Pública (npub)',
                    value: _npub ?? '',
                    icon: Icons.public,
                    color: const Color(0xFF9C27B0),
                    onCopy: () => _copyToClipboard(_publicKey ?? '', 'npub'),
                    onQR: () => _showQRCode(_npub ?? '', 'Meu npub'),
                  ),
                  const SizedBox(height: 16),
                  
                  // Lightning Address
                  _buildKeyCard(
                    title: 'Lightning Address',
                    value: _lightningAddress ?? '',
                    icon: Icons.bolt,
                    color: const Color(0xFFFF6B35),
                    onCopy: () => _copyToClipboard(_lightningAddress ?? '', 'Lightning Address'),
                    onQR: () => _showQRCode('lightning:$_lightningAddress', 'Lightning Address'),
                  ),
                  const SizedBox(height: 24),
                  
                  // Private Key (hidden by default)
                  _buildPrivateKeySection(),
                  const SizedBox(height: 24),
                  
                  // NIP-06 Backup
                  _buildNip06Section(),
                ],
              ),
            ),
    );
  }

  Widget _buildProfileHeader() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF9C27B0).withOpacity(0.2),
            const Color(0xFF9C27B0).withOpacity(0.05),
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0x339C27B0)),
      ),
      child: Column(
        children: [
          // Avatar
          Container(
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF9C27B0), Color(0xFFBA68C8)],
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF9C27B0).withOpacity(0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Center(
              child: Text(
                _publicKey?.substring(0, 2).toUpperCase() ?? '??',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          
          // Name (placeholder or from profile)
          Text(
            _profile?['name'] ?? 'Anon',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          
          // Hex pubkey (truncated)
          if (_publicKey != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0x1AFFFFFF),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '${_publicKey!.substring(0, 8)}...${_publicKey!.substring(_publicKey!.length - 8)}',
                style: const TextStyle(
                  color: Color(0xB3FFFFFF),
                  fontSize: 12,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          const SizedBox(height: 16),
          
          // Stats row
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _buildStat('Verificado', '✓', const Color(0xFF00FF00)),
              _buildStat('NIP-05', '❌', Colors.grey),
              _buildStat('Relays', '3', const Color(0xFFFF6B35)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStat(String label, String value, Color color) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildKeyCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
    required VoidCallback onCopy,
    required VoidCallback onQR,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0x0DFFFFFF),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              value,
              style: const TextStyle(
                color: Color(0xB3FFFFFF),
                fontSize: 13,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copiar'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: color,
                    side: BorderSide(color: color.withOpacity(0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onQR,
                  icon: const Icon(Icons.qr_code, size: 16),
                  label: const Text('QR Code'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: color,
                    side: BorderSide(color: color.withOpacity(0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPrivateKeySection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x1AFF0000),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x33FF0000)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Chave Privada (NUNCA compartilhe!)',
                  style: TextStyle(
                    color: Colors.orange,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Switch(
                value: _showPrivateKey,
                onChanged: (value) {
                  if (value) {
                    _showPrivateKeyWarning();
                  } else {
                    setState(() => _showPrivateKey = false);
                  }
                },
                activeColor: Colors.orange,
              ),
            ],
          ),
          if (_showPrivateKey && _privateKey != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0x0DFFFFFF),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _privateKey!,
                style: const TextStyle(
                  color: Colors.orange,
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '⚠️ Qualquer pessoa com essa chave pode acessar sua conta e seus fundos!',
              style: TextStyle(color: Color(0xFFFF6B35), fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }

  void _showPrivateKeyWarning() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.red, size: 28),
            SizedBox(width: 12),
            Text('ATENÇÃO!', style: TextStyle(color: Colors.red)),
          ],
        ),
        content: const Text(
          'Sua chave privada dá acesso TOTAL à sua identidade Nostr e carteira Lightning.\n\n'
          '❌ NUNCA compartilhe com ninguém\n'
          '❌ NUNCA cole em sites suspeitos\n'
          '❌ NUNCA envie por mensagem\n\n'
          'Deseja mostrar a chave privada?',
          style: TextStyle(color: Color(0xB3FFFFFF)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() => _showPrivateKey = true);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Entendi, mostrar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildNip06Section() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFFFF6B35).withOpacity(0.1),
            const Color(0xFFFF6B35).withOpacity(0.05),
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
              Icon(Icons.backup, color: Color(0xFFFF6B35)),
              SizedBox(width: 8),
              Text(
                'NIP-06: Backup Unificado',
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
            'Use sua seed Bitcoin (12 ou 24 palavras) para derivar chaves Nostr. '
            'Um backup para Bitcoin e Nostr!',
            style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 13),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                Navigator.pushNamed(context, '/nip06-backup');
              },
              icon: const Icon(Icons.key),
              label: const Text('Configurar Backup NIP-06'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFFF6B35),
                side: const BorderSide(color: Color(0xFFFF6B35)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
