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
import '../l10n/app_localizations.dart';
import '../providers/locale_provider.dart';

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
              Row(
                children: [
                  const Icon(Icons.notifications_active, color: Colors.amber, size: 28),
                  const SizedBox(width: 12),
                  Text(
                    AppLocalizations.of(context).t('settings_notifications_bg_title'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                AppLocalizations.of(context).t('settings_notifications_desc'),
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 24),
              _buildGuideSection(
                AppLocalizations.of(context).t('settings_notif_step1_title'),
                AppLocalizations.of(context).t('settings_notif_step1_desc'),
                Icons.settings,
              ),
              _buildGuideSection(
                AppLocalizations.of(context).t('settings_notif_step2_title'),
                AppLocalizations.of(context).t('settings_notif_step2_desc'),
                Icons.battery_std,
              ),
              _buildGuideSection(
                AppLocalizations.of(context).t('settings_notif_step3_title'),
                AppLocalizations.of(context).t('settings_notif_step3_desc'),
                Icons.battery_charging_full,
              ),
              const Divider(color: Colors.white24, height: 32),
              Text(
                AppLocalizations.of(context).t('settings_samsung_title'),
                style: const TextStyle(
                  color: Colors.amber,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              _buildGuideSection(
                AppLocalizations.of(context).t('settings_samsung_step_title'),
                AppLocalizations.of(context).t('settings_samsung_step_desc'),
                Icons.phone_android,
              ),
              const SizedBox(height: 24),
              if (Platform.isAndroid)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      try {
                        const platform = MethodChannel('app.bro.mobile/settings');
                        await platform.invokeMethod('openBatterySettings');
                      } catch (_) {
                        // If method channel fails, show fallback message
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(AppLocalizations.of(context).t('settings_open_manually_battery')),
                            ),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.open_in_new),
                    label: Text(AppLocalizations.of(context).t('settings_open_battery_settings')),
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
                  child: Text(AppLocalizations.of(context).t('understood'), style: const TextStyle(color: Colors.amber, fontSize: 16)),
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
              Text(
                AppLocalizations.of(context).t('settings_enter_admin_password'),
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: passwordController,
                obscureText: obscure,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: AppLocalizations.of(context).t('settings_password_hint'),
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
              child: Text(AppLocalizations.of(context).t('cancel'), style: const TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              onPressed: () {
                _validateAdminPassword(passwordController.text);
              },
              style: ElevatedButton.styleFrom(backgroundColor: Colors.amber),
              child: Text(AppLocalizations.of(context).t('enter'), style: const TextStyle(color: Colors.black)),
            ),
          ],
        ),
      ),
    );
  }
  
  void _validateAdminPassword(String password) {
    if (_adminPasswordHash.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context).t('settings_admin_not_configured')),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 3),
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
        SnackBar(
          content: Text(AppLocalizations.of(context).t('settings_wrong_password')),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 2),
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
        SnackBar(
          content: Text(AppLocalizations.of(context).t('settings_seed_copied')),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _toggleShowSeed() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 28),
            const SizedBox(width: 10),
            Text(AppLocalizations.of(context).t('settings_attention')),
          ],
        ),
        content: Text(
          AppLocalizations.of(context).t('settings_never_share_seed'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context).t('cancel')),
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
            child: Text(AppLocalizations.of(context).t('settings_understood_show')),
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
        title: Row(
          children: [
            const Icon(Icons.restore, color: Colors.deepPurple, size: 28),
            const SizedBox(width: 10),
            Expanded(child: Text(AppLocalizations.of(context).t('settings_restore_wallet'))),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppLocalizations.of(context).t('settings_enter_12_words'),
                style: const TextStyle(fontSize: 14),
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
                child: Row(
                  children: [
                    const Icon(Icons.warning, color: Colors.red, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        AppLocalizations.of(context).t('settings_wallet_replaced'),
                        style: const TextStyle(
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
            child: Text(AppLocalizations.of(context).t('cancel')),
          ),
          ElevatedButton(
            onPressed: () async {
              final seed = seedController.text.trim();
              final words = seed.split(RegExp(r'\s+'));
              
              if (words.length != 12) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(AppLocalizations.of(context).t('settings_seed_12_words_error')),
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
                        AppLocalizations.of(context).tp('settings_wallet_restored', {'balance': balance.toString()}),
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
                    SnackBar(
                      content: Text(AppLocalizations.of(context).t('settings_error_reinitialize')),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              } catch (e) {
                Navigator.pop(context); // Fechar loading
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(AppLocalizations.of(context).tp('settings_error_restoring', {'error': e.toString()})),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.deepPurple,
            ),
            child: Text(AppLocalizations.of(context).t('settings_restore')),
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
          child: Text(AppLocalizations.of(context).t('settings_title')),
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
                  Text(
                    AppLocalizations.of(context).t('settings_security'),
                    style: const TextStyle(
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
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      AppLocalizations.of(context).t('settings_wallet_seed'),
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      AppLocalizations.of(context).t('settings_12_recovery_words'),
                                      style: const TextStyle(
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
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.warning_amber_rounded,
                                  color: Colors.orange,
                                  size: 16,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    AppLocalizations.of(context).t('settings_keep_words_safe'),
                                    style: const TextStyle(
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
                                      label: Text(AppLocalizations.of(context).t('copy')),
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
                                      label: Text(AppLocalizations.of(context).t('settings_hide')),
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
                                child: Row(
                                  children: [
                                    const Icon(Icons.link, color: Colors.blue, size: 14),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        AppLocalizations.of(context).t('settings_seed_linked_nostr'),
                                        style: const TextStyle(fontSize: 11, color: Colors.blue),
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
                                  label: Text(AppLocalizations.of(context).t('settings_show_seed')),
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
                            Center(
                              child: Text(
                                AppLocalizations.of(context).t('settings_no_seed_found'),
                                style: const TextStyle(
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
                              child: Column(
                                children: [
                                  Row(
                                    children: [
                                      const Icon(Icons.warning, color: Colors.red, size: 20),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          AppLocalizations.of(context).t('settings_wallet_not_found'),
                                          style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    AppLocalizations.of(context).t('settings_contact_support'),
                                    style: const TextStyle(color: Colors.red, fontSize: 13),
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
                  Text(
                    AppLocalizations.of(context).t('settings_lightning_wallet'),
                    style: const TextStyle(
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
                      title: Text(AppLocalizations.of(context).t('settings_my_wallet'), style: const TextStyle(color: Colors.white)),
                      subtitle: Text(AppLocalizations.of(context).t('settings_view_balance'), style: const TextStyle(color: Colors.white54)),
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
                      title: Text(AppLocalizations.of(context).t('settings_restore_wallet'), style: const TextStyle(color: Colors.white)),
                      subtitle: Text(AppLocalizations.of(context).t('settings_use_existing_seed'), style: const TextStyle(color: Colors.white54)),
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
                  Text(
                    AppLocalizations.of(context).t('settings_nostr_privacy'),
                    style: const TextStyle(
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
                          title: Text(AppLocalizations.of(context).t('settings_nostr_profile'), style: const TextStyle(color: Colors.white)),
                          subtitle: Text(AppLocalizations.of(context).t('settings_view_keys_npub'), style: const TextStyle(color: Colors.white54)),
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
                          title: Text(AppLocalizations.of(context).t('settings_manage_relays'), style: const TextStyle(color: Colors.white)),
                          subtitle: Text(AppLocalizations.of(context).t('settings_add_remove_relays'), style: const TextStyle(color: Colors.white54)),
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
                          title: Text(AppLocalizations.of(context).t('settings_privacy'), style: const TextStyle(color: Colors.white)),
                          subtitle: Text(AppLocalizations.of(context).t('settings_tor_nip44'), style: const TextStyle(color: Colors.white54)),
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
                          title: Text(AppLocalizations.of(context).t('settings_backup_nip06'), style: const TextStyle(color: Colors.white)),
                          subtitle: Text(AppLocalizations.of(context).t('settings_derive_keys'), style: const TextStyle(color: Colors.white54)),
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
                  Text(
                    AppLocalizations.of(context).t('settings_notifications'),
                    style: const TextStyle(
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
                          title: Text(AppLocalizations.of(context).t('settings_enable_bg_notifications'), style: const TextStyle(color: Colors.white)),
                          subtitle: Text(AppLocalizations.of(context).t('settings_receive_alerts'), style: const TextStyle(color: Colors.white54)),
                          trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          onTap: () => _showNotificationGuide(context),
                        ),
                        Divider(height: 1, color: Colors.white12),
                        ListTile(
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.blue.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(Icons.chat_bubble_outline, color: Colors.blue),
                          ),
                          title: Text(AppLocalizations.of(context).t('home_messages'), style: const TextStyle(color: Colors.white)),
                          subtitle: Text('Nostr DMs', style: const TextStyle(color: Colors.white54)),
                          trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                          onTap: () => Navigator.pushNamed(context, '/nostr-messages'),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 30),

                  // Suporte
                  Text(
                    AppLocalizations.of(context).t('settings_support'),
                    style: const TextStyle(
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
                          title: Text(AppLocalizations.of(context).t('settings_help_center'), style: const TextStyle(color: Colors.white)),
                          subtitle: Text(AppLocalizations.of(context).t('settings_send_email'), style: const TextStyle(color: Colors.white54)),
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
                                SnackBar(
                                  content: Text(AppLocalizations.of(context).t('settings_email_copied')),
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

                  // Idioma
                  Card(
                    elevation: 0,
                    color: const Color(0xFF1A1A1A),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: Colors.orange.withOpacity(0.2)),
                    ),
                    child: Theme(
                      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        leading: Text(
                          AppLocalizations.localeFlag(context.watch<LocaleProvider>().locale),
                          style: const TextStyle(fontSize: 22),
                        ),
                        title: Text(
                          AppLocalizations.of(context).t('settings_language'),
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          AppLocalizations.localeDisplayName(context.watch<LocaleProvider>().locale),
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                        iconColor: Colors.orange,
                        collapsedIconColor: Colors.white38,
                        children: [
                          for (final entry in AppLocalizations.supportedLocales)
                            ListTile(
                              leading: Text(
                                AppLocalizations.localeFlag(entry),
                                style: const TextStyle(fontSize: 20),
                              ),
                              title: Text(
                                AppLocalizations.localeDisplayName(entry),
                                style: const TextStyle(color: Colors.white, fontSize: 14),
                              ),
                              trailing: context.watch<LocaleProvider>().locale.languageCode == entry.languageCode
                                  ? const Icon(Icons.check_circle, color: Colors.orange, size: 20)
                                  : const Icon(Icons.circle_outlined, color: Colors.white24, size: 20),
                              dense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 0),
                              onTap: () {
                                context.read<LocaleProvider>().setLocale(entry);
                              },
                            ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 30),

                  // Sobre
                  Text(
                    AppLocalizations.of(context).t('settings_about'),
                    style: const TextStyle(
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
                          title: Text(AppLocalizations.of(context).t('settings_version'), style: const TextStyle(color: Colors.white)),
                          subtitle: Text(_appVersion, style: const TextStyle(color: Colors.white54)),
                          trailing: const Icon(Icons.system_update, color: Colors.orange, size: 20),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 8,
                          ),
                          onTap: () async {
                            final versionService = VersionCheckService();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(AppLocalizations.of(context).t('settings_checking_updates')),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                            await versionService.checkForUpdate(force: true);
                            if (!mounted) return;
                            if (versionService.updateAvailable) {
                              versionService.showUpdateDialog(context);
                            } else {
                              // Show dialog with option to download/reinstall anyway
                              final loc = AppLocalizations.of(context);
                              showDialog(
                                context: context,
                                builder: (ctx) => AlertDialog(
                                  backgroundColor: const Color(0xFF1A1A2E),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  title: Row(
                                    children: [
                                      const Icon(Icons.check_circle, color: Colors.green, size: 28),
                                      const SizedBox(width: 12),
                                      Expanded(child: Text(loc.t('settings_latest_version'), style: const TextStyle(color: Colors.white, fontSize: 15))),
                                    ],
                                  ),
                                  content: Text(
                                    loc.t('settings_download_anyway'),
                                    style: const TextStyle(color: Colors.white70),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(ctx),
                                      child: Text(loc.t('cancel'), style: const TextStyle(color: Colors.white54)),
                                    ),
                                    ElevatedButton.icon(
                                      onPressed: () {
                                        Navigator.pop(ctx);
                                        versionService.openDownload();
                                      },
                                      icon: const Icon(Icons.download, size: 18),
                                      label: Text(loc.t('settings_download_apk')),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.orange,
                                        foregroundColor: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }
                          },
                        ),
                        Divider(height: 1, color: Colors.white12),
                        ListTile(
                          leading: const Icon(Icons.language, color: Colors.orange),
                          title: Text(AppLocalizations.of(context).t('settings_website'), style: const TextStyle(color: Colors.white)),
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
                            title: Text(AppLocalizations.of(context).t('settings_logout_title'), style: const TextStyle(color: Colors.white)),
                            content: Text(
                              AppLocalizations.of(context).t('settings_logout_confirmation'),
                              style: const TextStyle(color: Colors.white70),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: Text(AppLocalizations.of(context).t('cancel'), style: const TextStyle(color: Colors.white54)),
                              ),
                              ElevatedButton(
                                onPressed: () => Navigator.pop(context, true),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.red,
                                ),
                                child: Text(AppLocalizations.of(context).t('settings_logout')),
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
                      label: Text(AppLocalizations.of(context).t('settings_logout_title')),
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
