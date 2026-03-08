import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

class PrivacySettingsScreen extends StatefulWidget {
  const PrivacySettingsScreen({Key? key}) : super(key: key);

  @override
  State<PrivacySettingsScreen> createState() => _PrivacySettingsScreenState();
}

class _PrivacySettingsScreenState extends State<PrivacySettingsScreen> {
  bool _torEnabled = false;
  bool _nip44Enabled = true;
  bool _hideBalance = false;
  bool _sharePaymentReceipts = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    // TODO: Load from storage
    setState(() => _isLoading = false);
  }

  Future<void> _saveSetting(String key, bool value) async {
    // TODO: Save to storage
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppLocalizations.of(context).t('privacy_setting_saved')),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 1),
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
        title: Text(
          AppLocalizations.of(context).t('privacy_title'),
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: const Color(0x33FF6B35), height: 1),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFFF6B6B)))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Privacy score
                  _buildPrivacyScore(),
                  const SizedBox(height: 24),
                  
                  // Network section
                  _buildSectionTitle(AppLocalizations.of(context).t('privacy_network'), Icons.wifi),
                  const SizedBox(height: 12),
                  _buildTorSetting(),
                  const SizedBox(height: 24),
                  
                  // Encryption section
                  _buildSectionTitle(AppLocalizations.of(context).t('privacy_encryption'), Icons.lock),
                  const SizedBox(height: 12),
                  _buildNip44Setting(),
                  const SizedBox(height: 24),
                  
                  // Display section
                  _buildSectionTitle(AppLocalizations.of(context).t('privacy_display'), Icons.visibility),
                  const SizedBox(height: 12),
                  _buildHideBalanceSetting(),
                  const SizedBox(height: 24),
                  
                  // Relays
                  _buildRelaysButton(),
                  
                  // Espaço para safe area (botões de navegação)
                  SizedBox(height: MediaQuery.of(context).padding.bottom + 24),
                ],
              ),
            ),
    );
  }

  Widget _buildPrivacyScore() {
    // Calculate score based on settings
    int score = 50; // Base
    if (_torEnabled) score += 25;
    if (_nip44Enabled) score += 15;
    if (_hideBalance) score += 10;
    
    Color scoreColor;
    String scoreLabel;
    final t = AppLocalizations.of(context).t;
    if (score >= 80) {
      scoreColor = Colors.green;
      scoreLabel = t('privacy_excellent');
    } else if (score >= 60) {
      scoreColor = const Color(0xFFFF6B6B);
      scoreLabel = t('privacy_good');
    } else {
      scoreColor = Colors.orange;
      scoreLabel = t('privacy_can_improve');
    }
    
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            scoreColor.withOpacity(0.2),
            scoreColor.withOpacity(0.05),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scoreColor.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [scoreColor.withOpacity(0.3), scoreColor.withOpacity(0.1)],
              ),
              border: Border.all(color: scoreColor, width: 3),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$score',
                    style: TextStyle(
                      color: scoreColor,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    '/100',
                    style: TextStyle(
                      color: scoreColor.withOpacity(0.7),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t('privacy_score'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  scoreLabel,
                  style: TextStyle(
                    color: scoreColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _torEnabled 
                      ? t('privacy_tor_active')
                      : t('privacy_enable_tor_hint'),
                  style: const TextStyle(
                    color: Color(0x99FFFFFF),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFFFF6B6B), size: 20),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildTorSetting() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _torEnabled ? const Color(0x339C27B0) : const Color(0x33FFFFFF),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _torEnabled 
                      ? const Color(0x339C27B0)
                      : const Color(0x1AFFFFFF),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '🧅',
                  style: TextStyle(fontSize: _torEnabled ? 24 : 20),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppLocalizations.of(context).t('privacy_tor_connection'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _torEnabled 
                          ? AppLocalizations.of(context).t('privacy_ip_hidden')
                          : AppLocalizations.of(context).t('privacy_hides_real_ip'),
                      style: TextStyle(
                        color: _torEnabled ? Colors.green : const Color(0x99FFFFFF),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _torEnabled,
                onChanged: (value) {
                  setState(() => _torEnabled = value);
                  _saveSetting('tor_enabled', value);
                  
                  if (value) {
                    _showTorInfo();
                  }
                },
                activeColor: const Color(0xFF9C27B0),
              ),
            ],
          ),
          if (_torEnabled) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0x1A9C27B0),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: Color(0xFF9C27B0), size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      AppLocalizations.of(context).t('privacy_tor_slower'),
                      style: const TextStyle(color: Color(0xFFBA68C8), fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _showTorInfo() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Text('🧅', style: TextStyle(fontSize: 28)),
            const SizedBox(width: 12),
            Text(AppLocalizations.of(context).t('privacy_tor_enabled'), style: const TextStyle(color: Colors.white)),
          ],
        ),
        content: Text(
          AppLocalizations.of(context).t('privacy_tor_info'),
          style: const TextStyle(color: Color(0xB3FFFFFF)),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF9C27B0),
            ),
            child: Text(AppLocalizations.of(context).t('ok'), style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildNip44Setting() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0x1AFF6B35),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.enhanced_encryption, color: Color(0xFFFF6B6B)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        AppLocalizations.of(context).t('privacy_nip44_title'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.green.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        AppLocalizations.of(context).t('privacy_recommended'),
                        style: const TextStyle(color: Colors.green, fontSize: 9),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  AppLocalizations.of(context).t('privacy_nip44_description'),
                  style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 13),
                ),
              ],
            ),
          ),
          Switch(
            value: _nip44Enabled,
            onChanged: (value) {
              setState(() => _nip44Enabled = value);
              _saveSetting('nip44_enabled', value);
            },
            activeColor: const Color(0xFFFF6B6B),
          ),
        ],
      ),
    );
  }

  Widget _buildHideBalanceSetting() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0x1AFFFFFF),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _hideBalance ? Icons.visibility_off : Icons.visibility,
              color: const Color(0x99FFFFFF),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocalizations.of(context).t('privacy_hide_balance'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  AppLocalizations.of(context).t('privacy_hide_balance_desc'),
                  style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 13),
                ),
              ],
            ),
          ),
          Switch(
            value: _hideBalance,
            onChanged: (value) {
              setState(() => _hideBalance = value);
              _saveSetting('hide_balance', value);
            },
            activeColor: const Color(0xFFFF6B6B),
          ),
        ],
      ),
    );
  }

  Widget _buildShareReceiptsSetting() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0x1A9C27B0),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.receipt_long, color: Color(0xFF9C27B0)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppLocalizations.of(context).t('privacy_publish_receipts'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      AppLocalizations.of(context).t('privacy_publish_receipts_desc'),
                      style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 13),
                    ),
                  ],
                ),
              ),
              Switch(
                value: _sharePaymentReceipts,
                onChanged: (value) {
                  setState(() => _sharePaymentReceipts = value);
                  _saveSetting('share_receipts', value);
                },
                activeColor: const Color(0xFF9C27B0),
              ),
            ],
          ),
          if (_sharePaymentReceipts) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0x1A9C27B0),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.public, color: Color(0xFF9C27B0), size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      AppLocalizations.of(context).t('privacy_payments_visible'),
                      style: const TextStyle(color: Color(0xFFBA68C8), fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRelaysButton() {
    return GestureDetector(
      onTap: () => Navigator.pushNamed(context, '/relay-management'),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              const Color(0xFFFF6B6B).withOpacity(0.1),
              const Color(0xFFFF6B6B).withOpacity(0.05),
            ],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0x33FF6B35)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0x33FF6B35),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.cloud_queue, color: Color(0xFFFF6B6B)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppLocalizations.of(context).t('privacy_manage_relays'),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    AppLocalizations.of(context).t('privacy_choose_relays'),
                    style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 13),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios, color: Color(0xFFFF6B6B), size: 18),
          ],
        ),
      ),
    );
  }
}
