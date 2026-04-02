import 'package:bro_app/services/log_utils.dart';
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../config.dart';
import '../services/secure_storage_service.dart';
import '../services/nostr_service.dart';

/// Tela educacional sobre o sistema de provedor
/// Explica como funciona, requisitos, riscos e benefícios
class ProviderEducationScreen extends StatelessWidget {
  const ProviderEducationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(l.t('prov_edu_title')),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeroSection(l),
            const SizedBox(height: 24),
            _buildSectionTitle(l.t('prov_edu_how_it_works')),
            _buildInfoCard(
              steps: [
                l.t('prov_edu_step1'),
                l.t('prov_edu_step2'),
                l.t('prov_edu_step3'),
                l.t('prov_edu_step4'),
                l.t('prov_edu_step5'),
                l.t('prov_edu_step6'),
              ],
            ),
            const SizedBox(height: 24),
            _buildSectionTitle(l.t('prov_edu_collateral_system')),
            _buildTierTable(l),
            const SizedBox(height: 24),
            _buildSectionTitle(l.t('prov_edu_risks')),
            _buildRisksCard(l),
            const SizedBox(height: 32),
            _buildStartButton(context, l),
            const SizedBox(height: 100), // Extra padding for nav buttons
          ],
        ),
      ),
    );
  }

  Widget _buildHeroSection(AppLocalizations l) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.orange.withOpacity(0.3), Colors.purple.withOpacity(0.2)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.orange.withOpacity(0.5)),
      ),
      child: Column(
        children: [
          const Icon(Icons.monetization_on, size: 64, color: Colors.orange),
          const SizedBox(height: 16),
          Text(
            l.t('prov_edu_hero_title'),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            l.t('prov_edu_hero_subtitle'),
            style: const TextStyle(color: Colors.white70, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildInfoCard({required List<String> steps}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: steps.map((step) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                step.substring(0, 2),
                style: const TextStyle(fontSize: 20),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  step.substring(3),
                  style: const TextStyle(color: Colors.white70, fontSize: 15),
                ),
              ),
            ],
          ),
        )).toList(),
      ),
    );
  }

  Widget _buildTierTable(AppLocalizations l) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        children: [
          // 🧪 Tier Trial para testar
          _buildTierRow(
            tier: l.t('prov_edu_tier_trial'),
            guarantee: 'R\$ 10',
            maxOrder: 'até R\$ 10',
            color: Colors.green,
            isHeader: false,
          ),
          const Divider(color: Colors.white12, height: 1),
          _buildTierRow(
            tier: l.t('prov_edu_tier_beginner'),
            guarantee: 'R\$ 50',
            maxOrder: 'até R\$ 50',
            color: Colors.orange,
            isHeader: false,
          ),
          const Divider(color: Colors.white12, height: 1),
          _buildTierRow(
            tier: l.t('prov_edu_tier_basic'),
            guarantee: 'R\$ 200',
            maxOrder: 'até R\$ 200',
            color: Colors.grey,
            isHeader: false,
          ),
          const Divider(color: Colors.white12, height: 1),
          _buildTierRow(
            tier: l.t('prov_edu_tier_intermediate'),
            guarantee: 'R\$ 500',
            maxOrder: 'até R\$ 500',
            color: Colors.blue,
            isHeader: false,
          ),
          const Divider(color: Colors.white12, height: 1),
          _buildTierRow(
            tier: l.t('prov_edu_tier_advanced'),
            guarantee: 'R\$ 1.000',
            maxOrder: 'até R\$ 1.000',
            color: Colors.purple,
            isHeader: false,
          ),
          const Divider(color: Colors.white12, height: 1),
          _buildTierRow(
            tier: l.t('prov_edu_tier_master'),
            guarantee: 'R\$ 3.000',
            maxOrder: 'ilimitado',
            color: Colors.amber,
            isHeader: false,
          ),
        ],
      ),
    );
  }

  Widget _buildTierRow({
    required String tier,
    required String guarantee,
    required String maxOrder,
    required Color color,
    required bool isHeader,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.star, color: color, size: 16),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    tier,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              guarantee,
              style: const TextStyle(color: Colors.orange, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              maxOrder,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBenefitsCard(AppLocalizations l) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.green.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.green.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildBenefit('💵', l.t('prov_edu_benefit_earn')),
          _buildBenefit('⚡', l.t('prov_edu_benefit_instant')),
          _buildBenefit('🔒', l.t('prov_edu_benefit_escrow')),
          _buildBenefit('📈', l.t('prov_edu_benefit_unlimited')),
          _buildBenefit('🏦', l.t('prov_edu_benefit_bank')),
          _buildBenefit('🌐', l.t('prov_edu_benefit_anywhere')),
          _buildBenefit('⏰', l.t('prov_edu_benefit_flexible')),
        ],
      ),
    );
  }

  Widget _buildBenefit(String emoji, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 20)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRisksCard(AppLocalizations l) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildRisk('⚠️', l.t('prov_edu_risk_locked')),
          _buildRisk('💸', l.t('prov_edu_risk_pay_first')),
          _buildRisk('🕐', l.t('prov_edu_risk_validation')),
          _buildRisk('⚖️', l.t('prov_edu_risk_dispute')),
          _buildRisk('📸', l.t('prov_edu_risk_receipt')),
          const SizedBox(height: 12),
          const Divider(color: Colors.orange),
          const SizedBox(height: 12),
          Text(
            l.t('prov_edu_fraud_warning'),
            style: const TextStyle(
              color: Colors.red,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRisk(String emoji, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEscrowExplanation(AppLocalizations l) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blue.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.t('prov_edu_escrow_title'),
            style: const TextStyle(
              color: Colors.blue,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            l.t('prov_edu_escrow_desc'),
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 12),
          _buildEscrowStep('1', l.t('prov_edu_escrow_step1')),
          _buildEscrowStep('2', l.t('prov_edu_escrow_step2')),
          _buildEscrowStep('3', l.t('prov_edu_escrow_step3')),
          _buildEscrowStep('4', l.t('prov_edu_escrow_step4')),
          _buildEscrowStep('5', l.t('prov_edu_escrow_step5')),
        ],
      ),
    );
  }

  Widget _buildEscrowStep(String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.blue),
            ),
            child: Center(
              child: Text(
                number,
                style: const TextStyle(
                  color: Colors.blue,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExample(AppLocalizations l) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.purple.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.purple.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.t('prov_edu_example_title'),
            style: const TextStyle(
              color: Colors.purple,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          _buildExampleRow(l.t('prov_edu_example_pay'), 'R\$ 1.000,00'),
          _buildExampleRow(l.t('prov_edu_example_fee'), 'R\$ 30,00', color: Colors.green),
          const Divider(color: Colors.white12),
          _buildExampleRow(
            l.t('prov_edu_example_receive'),
            l.t('prov_edu_example_receive_val'),
            isBold: true,
            color: Colors.orange,
          ),
          const SizedBox(height: 12),
          Text(
            l.t('prov_edu_example_tip'),
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 12,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExampleRow(String label, String value, {bool isBold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.white70,
              fontSize: 14,
              fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: color ?? Colors.white,
              fontSize: 14,
              fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFAQ(AppLocalizations l) {
    return Column(
      children: [
        _buildFAQItem(
          question: l.t('prov_edu_faq_earn_q'),
          answer: l.t('prov_edu_faq_earn_a'),
        ),
        _buildFAQItem(
          question: l.t('prov_edu_faq_time_q'),
          answer: l.t('prov_edu_faq_time_a'),
        ),
        _buildFAQItem(
          question: l.t('prov_edu_faq_withdraw_q'),
          answer: l.t('prov_edu_faq_withdraw_a'),
        ),
        _buildFAQItem(
          question: l.t('prov_edu_faq_dispute_q'),
          answer: l.t('prov_edu_faq_dispute_a'),
        ),

      ],
    );
  }

  Widget _buildFAQItem({required String question, required String answer}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.help_outline, color: Colors.orange, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  question,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            answer,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildStartButton(BuildContext context, AppLocalizations l) {
    return Column(
      children: [
        // Botão principal
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () async {
              // Obter pubkey do usuário atual
              final nostrService = NostrService();
              final pubkey = nostrService.publicKey;
              // Salvar que está iniciando modo provedor COM PUBKEY
              await SecureStorageService.setProviderMode(true, userPubkey: pubkey);
              broLog('✅ Modo provedor salvo (via Começar Agora) para pubkey: ${pubkey?.substring(0, 8) ?? "null"}');
              Navigator.pushNamed(context, '/provider-collateral');
            },
            icon: const Icon(Icons.rocket_launch),
            label: Text(l.t('prov_edu_start_now')),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
        
        // Botão de teste (apenas em modo teste)
        if (AppConfig.providerTestMode) ...[
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () async {
                broLog('🧪 Clicou no botão Modo Teste');
                try {
                  // Obter pubkey do usuário atual
                  final nostrService = NostrService();
                  final pubkey = nostrService.publicKey;
                  // Salvar que o usuário está em modo provedor COM PUBKEY
                  await SecureStorageService.setProviderMode(true, userPubkey: pubkey);
                  broLog('✅ Modo provedor salvo como ativo para pubkey: ${pubkey?.substring(0, 8) ?? "null"}');
                  
                  // Usar pubkey real do NostrService
                  final providerId = pubkey ?? 'unknown';
                  broLog('🧪 Navegando para /provider-orders com providerId: $providerId');
                  Navigator.pushNamed(context, '/provider-orders', arguments: {
                    'providerId': providerId,
                  });
                  broLog('🧪 pushNamed executado');
                } catch (e) {
                  broLog('❌ Erro ao navegar: $e');
                }
              },
              icon: const Icon(Icons.science, color: Colors.cyan),
              label: Text(
                l.t('prov_edu_test_mode'),
                style: const TextStyle(color: Colors.cyan),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.cyan),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l.t('prov_edu_test_warning'),
            style: const TextStyle(color: Colors.cyan, fontSize: 12, fontStyle: FontStyle.italic),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}
