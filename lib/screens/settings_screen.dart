import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:bro_app/services/log_utils.dart';
import 'package:crypto/crypto.dart';
import '../services/storage_service.dart';
import '../services/version_check_service.dart';
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
  
  // Admin password hash loaded from env (not in source code)
  static const String _adminPasswordHash = String.fromEnvironment('ADMIN_PASSWORD_HASH', defaultValue: '');

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
      broLog('Erro ao carregar versão: $e');
    }
  }

  void _onTitleTap() {
    _adminTapCount++;
    if (_adminTapCount >= 7) {
      _adminTapCount = 0;
      _showAdminPasswordDialog();
    }
    // Sem feedback visual - acesso admin totalmente oculto
  }

  void _showNotificationGuide(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A2E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.75,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: Colors.grey[600],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const Row(
                children: [
                  Icon(Icons.notifications_active, color: Colors.amber, size: 28),
                  SizedBox(width: 12),
                  Text(
                    'Notificações em segundo plano',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'Para receber notificações de novas ordens mesmo com o app fechado, '
                'é necessário desativar a otimização de bateria para o Bro.',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 24),
              _buildGuideSection(
                'Passo 1 — Abrir Configurações do celular',
                'Vá em Configurações > Apps (ou Aplicativos) > Bro',
                Icons.settings,
              ),
              _buildGuideSection(
                'Passo 2 — Bateria',
                'Toque em "Bateria" (ou "Uso de bateria")',
                Icons.battery_std,
              ),
              _buildGuideSection(
                'Passo 3 — Sem restrições',
                'Selecione "Sem restrições" (ou "Não otimizado")',
                Icons.battery_charging_full,
              ),
              const Divider(color: Colors.white24, height: 32),
              const Text(
                'Samsung — Passo extra',
                style: TextStyle(
                  color: Colors.amber,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              _buildGuideSection(
                'Apps que nunca entram em suspensão',
                'Configurações > Cuidados com dispositivo > Bateria > '
                'Apps que nunca entram em suspensão > Adicionar > Bro',
                Icons.phone_android,
              ),
              const SizedBox(height: 24),
              if (Platform.isAndroid)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      try {
                        const platform = MethodChannel('com.pagaconta.mobile/settings');
                        await platform.invokeMethod('openBatterySettings');
                      } catch (_) {
                        // If method channel fails, show fallback message
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Abra manualmente: Configurações > Apps > Bro > Bateria'),
                            ),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Abrir Configurações de Bateria'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.amber,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Entendi', style: TextStyle(color: Colors.amber, fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGuideSection(String title, String description, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.amber.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: Colors.amber, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: const TextStyle(color: Colors.white60, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showAdminPasswordDialog() {
    final passwordController = TextEditingController();
    bool obscure = true;
    
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A2E),
          title: const Row(
            children: [
              Icon(Icons.admin_panel_settings, color: Colors.amber, size: 28),
              SizedBox(width: 10),
              Text('Admin Access', style: TextStyle(color: Colors.white)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Digite a senha de administrador:',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: passwordController,
                obscureText: obscure,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Senha',
                  hintStyle: const TextStyle(color: Colors.white38),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFF333333)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Colors.amber),
                  ),
                  prefixIcon: const Icon(Icons.lock, color: Colors.white54),
                  suffixIcon: IconButton(
                    icon: Icon(
                      obscure ? Icons.visibility_off : Icons.visibility,
                      color: Colors.white54,
                    ),
                    onPressed: () => setDialogState(() => obscure = !obscure),
                  ),
                  filled: true,
                  fillColor: Colors.black26,
                ),
                onSubmitted: (_) {
                  _validateAdminPassword(passwordController.text);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              onPressed: () {
                _validateAdminPassword(passwordController.text);
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.amber),
              child: const Text('Entrar', style: TextStyle(color: Colors.black)),
            ),
          ],
        ),
      ),
    );
  }
  
  void _validateAdminPassword(String password) {
    if (_adminPasswordHash.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚠️ Admin não configurado neste build'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }
    
    final inputHash = sha256.convert(utf8.encode(password)).toString();
    
    if (inputHash == _adminPasswordHash) {
      Navigator.pop(context); // Fechar dialog
      Navigator.pushNamed(context, '/admin-bro-2024');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('❌ Senha incorreta'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 2),
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
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFFF6B6B)))
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

                  // Notificações
                  const Text(
                    'Notificações',
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
                              color: Colors.amber.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.notifications_active, color: Colors.amber),
                          ),
                          title: const Text('Ativar Notificações em Segundo Plano', style: TextStyle(color: Colors.white)),
                          subtitle: const Text('Receba alertas mesmo com o app fechado', style: TextStyle(color: Colors.white54)),
                          trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          onTap: () => _showNotificationGuide(context),
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
                          trailing: const Icon(Icons.system_update, color: Colors.orange, size: 20),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 8,
                          ),
                          onTap: () async {
                            final versionService = VersionCheckService();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Verificando atualizações...'),
                                duration: Duration(seconds: 2),
                              ),
                            );
                            await versionService.checkForUpdate(force: true);
                            if (!mounted) return;
                            if (versionService.updateAvailable) {
                              versionService.showUpdateDialog(context);
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('✅ Você já está na versão mais recente!'),
                                  backgroundColor: Colors.green,
                                  duration: Duration(seconds: 3),
                                ),
                              );
                            }
                          },
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
