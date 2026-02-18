import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/storage_service.dart';
import '../providers/breez_provider.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _showSeed = false;
  String? _mnemonic;
  bool _isLoading = true;
  int _adminTapCount = 0;
  String _appVersion = '1.0.0';

  @override
  void initState() {
    super.initState();
    _loadMnemonic();
    _loadAppVersion();
  }

  Future<void> _loadAppVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      setState(() {
        _appVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
      });
    } catch (e) {
      debugPrint('Erro ao carregar versão: $e');
    }
  }

  void _onTitleTap() {
    _adminTapCount++;
    if (_adminTapCount >= 7) {
      _adminTapCount = 0;
      Navigator.pushNamed(context, '/admin-bro-2024');
    } else if (_adminTapCount >= 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${7 - _adminTapCount} toques restantes...'),
          duration: const Duration(milliseconds: 500),
          backgroundColor: Colors.deepPurple,
        ),
      );
    }
  }

  Future<void> _loadMnemonic() async {
    final mnemonic = await StorageService().getBreezMnemonic();
    setState(() {
      _mnemonic = mnemonic;
      _isLoading = false;
    });
  }

  void _copySeed() {
    if (_mnemonic != null) {
      Clipboard.setData(ClipboardData(text: _mnemonic!));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Seed copiada para a área de transferência'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _toggleShowSeed() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 28),
            SizedBox(width: 10),
            Text('Atenção'),
          ],
        ),
        content: const Text(
          'Nunca compartilhe sua seed com ninguém!\n\n'
          'Qualquer pessoa com acesso a estas 12 palavras pode roubar todos os seus Bitcoin.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _showSeed = true;
              });
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
            ),
            child: const Text('Entendi, mostrar'),
          ),
        ],
      ),
    );
  }

  void _showRestoreSeedDialog() {
    final seedController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.restore, color: Colors.deepPurple, size: 28),
            SizedBox(width: 10),
            Expanded(child: Text('Restaurar Carteira')),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Digite as 12 palavras da sua seed, separadas por espaço:',
                style: TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 15),
              TextField(
                controller: seedController,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: 'palavra1 palavra2 palavra3 ...',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.all(12),
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning, color: Colors.red, size: 20),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'A carteira atual será substituída!',
                        style: TextStyle(
                          color: Colors.red,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
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
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () async {
              final seed = seedController.text.trim();
              final words = seed.split(RegExp(r'\s+'));
              
              if (words.length != 12) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('A seed deve ter exatamente 12 palavras'),
                    backgroundColor: Colors.red,
                  ),
                );
                return;
              }
              
              Navigator.pop(context);
              
              // Mostrar loading
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (context) => const Center(
                  child: CircularProgressIndicator(),
                ),
              );
              
              try {
                // Usar reinitializeWithNewSeed para reiniciar SDK com nova seed
                final breezProvider = Provider.of<BreezProvider>(context, listen: false);
                final success = await breezProvider.reinitializeWithNewSeed(seed);
                
                Navigator.pop(context); // Fechar loading
                
                if (success) {
                  // Atualizar estado local
                  setState(() {
                    _mnemonic = seed;
                  });
                  
                  // Buscar saldo
                  final balanceInfo = await breezProvider.getBalance();
                  final balance = balanceInfo['balance'] ?? 0;
                  
                  // Mostrar sucesso
                  showDialog(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Row(
                        children: [
                          Icon(Icons.check_circle, color: Colors.green, size: 28),
                          SizedBox(width: 10),
                          Text('Sucesso!'),
                        ],
                      ),
                      content: Text(
                        'Carteira restaurada com sucesso!\n\n'
                        'Saldo: $balance sats',
                      ),
                      actions: [
                        ElevatedButton(
                          onPressed: () {
                            Navigator.pop(context);
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                          ),
                          child: const Text('OK'),
                        ),
                      ],
                    ),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Erro ao reinicializar carteira'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              } catch (e) {
                Navigator.pop(context); // Fechar loading
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Erro ao restaurar: $e'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepPurple,
            ),
            child: const Text('Restaurar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: GestureDetector(
          onTap: _onTitleTap,
          child: const Text('Configurações'),
        ),
        backgroundColor: const Color(0xFF1A1A1A),
        foregroundColor: Colors.orange,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Colors.orange))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Seção de Segurança
                  const Text(
                    'Segurança',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.orange,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Card da Seed
                  Card(
                    color: const Color(0xFF1A1A1A),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: Colors.orange.withOpacity(0.2)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.orange.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Icon(
                                  Icons.vpn_key,
                                  color: Colors.orange,
                                  size: 20,
                                ),
                              ),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Seed da Carteira',
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white,
                                      ),
                                    ),
                                    SizedBox(height: 2),
                                    Text(
                                      '12 palavras de recuperação',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.white54,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),

                          // Aviso
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.orange.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Colors.orange.withOpacity(0.2),
                              ),
                            ),
                            child: const Row(
                              children: [
                                Icon(
                                  Icons.warning_amber_rounded,
                                  color: Colors.orange,
                                  size: 16,
                                ),
                                SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Guarde estas palavras em local seguro!',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.orange,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Seed (oculta ou visível)
                          if (_mnemonic != null) ...[
                            if (_showSeed) ...[
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF2A2A2A),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: Colors.grey.withOpacity(0.3),
                                  ),
                                ),
                                child: SelectableText(
                                  _mnemonic!,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontFamily: 'monospace',
                                    height: 1.5,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.white70,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: _copySeed,
                                      icon: const Icon(Icons.copy, size: 16),
                                      label: const Text('Copiar'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.orange,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 10,
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: () {
                                        setState(() {
                                          _showSeed = false;
                                        });
                                      },
                                      icon: const Icon(Icons.visibility_off, size: 16),
                                      label: const Text('Ocultar'),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Colors.white54,
                                        side: BorderSide(color: Colors.white24),
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 10,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              // Info: Seed vinculada ao usuário
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.blue.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Row(
                                  children: [
                                    Icon(Icons.link, color: Colors.blue, size: 14),
                                    SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        'Esta seed está vinculada à sua conta Nostr',
                                        style: TextStyle(fontSize: 11, color: Colors.blue),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ] else ...[
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  onPressed: _toggleShowSeed,
                                  icon: const Icon(Icons.visibility, size: 16),
                                  label: const Text('Mostrar Seed'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.orange,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ] else ...[
                            const Center(
                              child: Text(
                                'Nenhuma seed encontrada',
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ),
                            const SizedBox(height: 15),
                            // Contato suporte
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.red.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.red.withOpacity(0.3)),
                              ),
                              child: const Column(
                                children: [
                                  Row(
                                    children: [
                                      Icon(Icons.warning, color: Colors.red, size: 20),
                                      SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          'Sua carteira não foi encontrada!',
                                          style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                    ],
                                  ),
                                  SizedBox(height: 8),
                                  Text(
                                    'Entre em contato com o suporte se você tinha sats nesta carteira.',
                                    style: TextStyle(color: Colors.red, fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 30),

                  // Carteira Lightning
                  const Text(
                    'Carteira Lightning',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.orange,
                    ),
                  ),
                  const SizedBox(height: 12),

                  Card(
                    elevation: 0,
                    color: const Color(0xFF1A1A1A),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: Colors.orange.withOpacity(0.2)),
                    ),
                    child: ListTile(
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.orange.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.account_balance_wallet, color: Colors.orange),
                      ),
                      title: const Text('Minha Carteira', style: TextStyle(color: Colors.white)),
                      subtitle: const Text('Ver saldo e transações', style: TextStyle(color: Colors.white54)),
                      trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                      onTap: () => Navigator.pushNamed(context, '/wallet'),
                    ),
                  ),
                  
                  const SizedBox(height: 10),
                  
                  // BOTÃO RESTAURAR SEED
                  Card(
                    elevation: 0,
                    color: const Color(0xFF1A1A1A),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: Colors.red.withOpacity(0.2)),
                    ),
                    child: ListTile(
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.restore, color: Colors.red),
                      ),
                      title: const Text('Restaurar Carteira', style: TextStyle(color: Colors.white)),
                      subtitle: const Text('Usar uma seed existente', style: TextStyle(color: Colors.white54)),
                      trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                      onTap: _showRestoreSeedDialog,
                    ),
                  ),

                  const SizedBox(height: 30),

                  // Nostr & Privacidade
                  const Text(
                    'Nostr & Privacidade',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.orange,
                    ),
                  ),
                  const SizedBox(height: 12),

                  Card(
                    elevation: 0,
                    color: const Color(0xFF1A1A1A),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: Colors.orange.withOpacity(0.2)),
                    ),
                    child: Column(
                      children: [
                        ListTile(
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.purple.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.person, color: Colors.purple),
                          ),
                          title: const Text('Perfil Nostr', style: TextStyle(color: Colors.white)),
                          subtitle: const Text('Ver suas chaves e npub', style: TextStyle(color: Colors.white54)),
                          trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          onTap: () => Navigator.pushNamed(context, '/nostr-profile'),
                        ),
                        Divider(height: 1, color: Colors.white12),
                        ListTile(
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.indigo.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.dns, color: Colors.indigo),
                          ),
                          title: const Text('Gerenciar Relays', style: TextStyle(color: Colors.white)),
                          subtitle: const Text('Adicionar ou remover relays', style: TextStyle(color: Colors.white54)),
                          trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          onTap: () => Navigator.pushNamed(context, '/relay-management'),
                        ),
                        Divider(height: 1, color: Colors.white12),
                        ListTile(
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.teal.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.shield, color: Colors.teal),
                          ),
                          title: const Text('Privacidade', style: TextStyle(color: Colors.white)),
                          subtitle: const Text('Tor, NIP-44 e mais', style: TextStyle(color: Colors.white54)),
                          trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          onTap: () => Navigator.pushNamed(context, '/privacy-settings'),
                        ),
                        Divider(height: 1, color: Colors.white12),
                        ListTile(
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.orange.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.key, color: Colors.orange),
                          ),
                          title: const Text('Backup NIP-06', style: TextStyle(color: Colors.white)),
                          subtitle: const Text('Derivar chaves da seed', style: TextStyle(color: Colors.white54)),
                          trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          onTap: () => Navigator.pushNamed(context, '/nip06-backup'),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 30),

                  // Suporte
                  const Text(
                    'Suporte',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.orange,
                    ),
                  ),
                  const SizedBox(height: 12),

                  Card(
                    elevation: 0,
                    color: const Color(0xFF1A1A1A),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: Colors.orange.withOpacity(0.2)),
                    ),
                    child: Column(
                      children: [
                        ListTile(
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.blue.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.help_outline, color: Colors.blue),
                          ),
                          title: const Text('Central de Ajuda', style: TextStyle(color: Colors.white)),
                          subtitle: const Text('Enviar email para suporte', style: TextStyle(color: Colors.white54)),
                          trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          onTap: () async {
                            final Uri emailUri = Uri(
                              scheme: 'mailto',
                              path: 'brostr@proton.me',
                              queryParameters: {
                                'subject': 'Ajuda - Bro App v$_appVersion',
                              },
                            );
                            if (await canLaunchUrl(emailUri)) {
                              await launchUrl(emailUri);
                            } else {
                              Clipboard.setData(const ClipboardData(text: 'brostr@proton.me'));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Email copiado: brostr@proton.me'),
                                  backgroundColor: Colors.blue,
                                ),
                              );
                            }
                          },
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 30),

                  // Sobre
                  const Text(
                    'Sobre',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.orange,
                    ),
                  ),
                  const SizedBox(height: 12),

                  Card(
                    elevation: 0,
                    color: const Color(0xFF1A1A1A),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: Colors.orange.withOpacity(0.2)),
                    ),
                    child: Column(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.info_outline, color: Colors.orange),
                          title: const Text('Versão', style: TextStyle(color: Colors.white)),
                          subtitle: Text(_appVersion, style: const TextStyle(color: Colors.white54)),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 8,
                          ),
                          onTap: _onTitleTap,
                        ),
                        Divider(height: 1, color: Colors.white12),
                        ListTile(
                          leading: const Icon(Icons.language, color: Colors.orange),
                          title: const Text('Site', style: TextStyle(color: Colors.white)),
                          subtitle: const Text('brostr.app', style: TextStyle(color: Colors.white54)),
                          trailing: const Icon(Icons.open_in_new, size: 18),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          onTap: () async {
                            final Uri url = Uri.parse('https://brostr.app');
                            if (await canLaunchUrl(url)) {
                              await launchUrl(url, mode: LaunchMode.externalApplication);
                            }
                          },
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 30),

                  // Botão de Logout
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        final confirm = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            backgroundColor: const Color(0xFF1A1A1A),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(color: Colors.red.withOpacity(0.3)),
                            ),
                            title: const Text('Sair do App', style: TextStyle(color: Colors.white)),
                            content: const Text(
                              'Tem certeza que deseja sair?\n\n'
                              'Certifique-se de ter sua seed anotada para recuperar sua carteira!',
                              style: TextStyle(color: Colors.white70),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
                              ),
                              ElevatedButton(
                                onPressed: () => Navigator.pop(context, true),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red,
                                ),
                                child: const Text('Sair'),
                              ),
                            ],
                          ),
                        );

                        if (confirm == true) {
                          // Fazer logout
                          await StorageService().logout();
                          
                          // Navegar para login e remover todas as rotas
                          if (mounted) {
                            Navigator.of(context).pushNamedAndRemoveUntil(
                              '/login',
                              (route) => false,
                            );
                          }
                        }
                      },
                      icon: const Icon(Icons.logout),
                      label: const Text('Sair do App'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red),
                        padding: const EdgeInsets.symmetric(vertical: 15),
                      ),
                    ),
                  ),
                  
                  // Espaço extra para botões de navegação
                  const SizedBox(height: 100),
                ],
              ),
            ),
    );
  }
}
