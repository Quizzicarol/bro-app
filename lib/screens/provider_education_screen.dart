import 'package:flutter/material.dart';
import '../config.dart';
import '../services/secure_storage_service.dart';
import '../services/nostr_service.dart';

/// Tela educacional sobre o sistema de provedor
/// Explica como funciona, requisitos, riscos e benefícios
class ProviderEducationScreen extends StatelessWidget {
  const ProviderEducationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Como Ser Provedor'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeroSection(),
            const SizedBox(height: 24),
            _buildSectionTitle('🎯 Como Funciona'),
            _buildInfoCard(
              steps: [
                '1️⃣ Deposite Bitcoin como garantia',
                '2️⃣ Escolha ordens disponíveis na plataforma',
                '3️⃣ Pague a conta no banco com seu dinheiro',
                '4️⃣ Envie o comprovante de pagamento',
                '5️⃣ Receba 3% de cada operação por ser um Bro',
                '6️⃣ Resgate sua garantia ao zerar suas ordens aceitas',
              ],
            ),
            const SizedBox(height: 24),
            _buildSectionTitle('💰 Sistema de Garantias'),
            _buildTierTable(),
            const SizedBox(height: 24),
            _buildSectionTitle('⚠️ Riscos e Responsabilidades'),
            _buildRisksCard(),
            const SizedBox(height: 32),
            _buildStartButton(context),
            const SizedBox(height: 100), // Extra padding for nav buttons
          ],
        ),
      ),
    );
  }

  Widget _buildHeroSection() {
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
          const Text(
            'Seja um Bro e facilite trocas',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text(
            'Como Bro você faz a ponte, ajuda pessoas a pagarem contas e recebe sats como recompensa',
            style: TextStyle(color: Colors.white70, fontSize: 14),
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

  Widget _buildTierTable() {
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
            tier: '🧪 Trial',
            guarantee: 'R\$ 10',
            maxOrder: 'até R\$ 10',
            color: Colors.green,
            isHeader: false,
          ),
          const Divider(color: Colors.white12, height: 1),
          _buildTierRow(
            tier: '🥉 Iniciante',
            guarantee: 'R\$ 50',
            maxOrder: 'até R\$ 50',
            color: Colors.orange,
            isHeader: false,
          ),
          const Divider(color: Colors.white12, height: 1),
          _buildTierRow(
            tier: '🥈 Básico',
            guarantee: 'R\$ 200',
            maxOrder: 'até R\$ 200',
            color: Colors.grey,
            isHeader: false,
          ),
          const Divider(color: Colors.white12, height: 1),
          _buildTierRow(
            tier: '🥇 Intermediário',
            guarantee: 'R\$ 500',
            maxOrder: 'até R\$ 500',
            color: Colors.blue,
            isHeader: false,
          ),
          const Divider(color: Colors.white12, height: 1),
          _buildTierRow(
            tier: '💎 Avançado',
            guarantee: 'R\$ 1.000',
            maxOrder: 'até R\$ 1.000',
            color: Colors.purple,
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

  Widget _buildBenefitsCard() {
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
          _buildBenefit('💵', 'Ganhe 3% em cada transação'),
          _buildBenefit('⚡', 'Receba Bitcoin instantaneamente'),
          _buildBenefit('🔒', 'Protegido por sistema de escrow'),
          _buildBenefit('📈', 'Sem limite de ganhos'),
          _buildBenefit('🏦', 'Use seu banco normalmente'),
          _buildBenefit('🌐', 'Trabalhe de qualquer lugar'),
          _buildBenefit('⏰', 'Horário flexível'),
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

  Widget _buildRisksCard() {
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
          _buildRisk('⚠️', 'Garantia bloqueada durante ordem ativa'),
          _buildRisk('💸', 'Você paga com seu dinheiro primeiro'),
          _buildRisk('🕐', 'Validação pode levar até 2 horas'),
          _buildRisk('⚖️', 'Disputas podem resultar em perda de garantia'),
          _buildRisk('📸', 'Comprovante obrigatório com dados legíveis'),
          const SizedBox(height: 12),
          const Divider(color: Colors.orange),
          const SizedBox(height: 12),
          const Text(
            '⚠️ ATENÇÃO: Fraude ou tentativa de golpe resulta em perda total da garantia e banimento permanente.',
            style: TextStyle(
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

  Widget _buildEscrowExplanation() {
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
          const Text(
            'O que é Escrow?',
            style: TextStyle(
              color: Colors.blue,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Escrow é um sistema de garantia onde o Bitcoin do usuário fica bloqueado até você provar que pagou a conta. Isso protege ambas as partes:',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
          const SizedBox(height: 12),
          _buildEscrowStep('1', 'Usuário paga Lightning → Bitcoin bloqueado'),
          _buildEscrowStep('2', 'Você aceita ordem → Garantia bloqueada'),
          _buildEscrowStep('3', 'Você Bro → Envia comprovante'),
          _buildEscrowStep('4', 'Validação aprovada → Você recebe Bitcoin + taxa'),
          _buildEscrowStep('5', 'Garantia desbloqueada → Pode aceitar nova ordem'),
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

  Widget _buildExample() {
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
          const Text(
            'Exemplo: Conta de R\$ 1.000',
            style: TextStyle(
              color: Colors.purple,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          _buildExampleRow('Você paga no banco:', 'R\$ 1.000,00'),
          _buildExampleRow('Sua taxa (3%):', 'R\$ 30,00', color: Colors.green),
          const Divider(color: Colors.white12),
          _buildExampleRow(
            'Você recebe:',
            'R\$ 1.030,00 em Bitcoin',
            isBold: true,
            color: Colors.orange,
          ),
          const SizedBox(height: 12),
          const Text(
            '💡 Se Bitcoin for 1 BTC = R\$ 500.000, você recebe ~206.000 sats',
            style: TextStyle(
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

  Widget _buildFAQ() {
    return Column(
      children: [
        _buildFAQItem(
          question: 'Quanto posso ganhar?',
          answer: '3% de cada transação. Sem limite! Quanto mais ordens aceitar, mais ganha.',
        ),
        _buildFAQItem(
          question: 'Quanto tempo leva para receber?',
          answer: 'Após enviar o comprovante, a validação leva até 2 horas. Aprovado = recebe na hora!',
        ),
        _buildFAQItem(
          question: 'Posso sacar minha garantia?',
          answer: 'Sim! Quando não houver ordens ativas, pode solicitar o resgate da garantia.',
        ),
        _buildFAQItem(
          question: 'O que acontece em disputa?',
          answer: 'A plataforma analisa os comprovantes. Se comprovar fraude, perde a garantia. Se for engano do usuário, recebe normalmente.',
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

  Widget _buildStartButton(BuildContext context) {
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
              debugPrint('✅ Modo provedor salvo (via Começar Agora) para pubkey: ${pubkey?.substring(0, 8) ?? "null"}');
              Navigator.pushNamed(context, '/provider-collateral');
            },
            icon: const Icon(Icons.rocket_launch),
            label: const Text('Começar Agora'),
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
                debugPrint('🧪 Clicou no botão Modo Teste');
                try {
                  // Obter pubkey do usuário atual
                  final nostrService = NostrService();
                  final pubkey = nostrService.publicKey;
                  // Salvar que o usuário está em modo provedor COM PUBKEY
                  await SecureStorageService.setProviderMode(true, userPubkey: pubkey);
                  debugPrint('✅ Modo provedor salvo como ativo para pubkey: ${pubkey?.substring(0, 8) ?? "null"}');
                  
                  // Usar pubkey real do NostrService
                  final providerId = pubkey ?? 'unknown';
                  debugPrint('🧪 Navegando para /provider-orders com providerId: $providerId');
                  Navigator.pushNamed(context, '/provider-orders', arguments: {
                    'providerId': providerId,
                  });
                  debugPrint('🧪 pushNamed executado');
                } catch (e) {
                  debugPrint('❌ Erro ao navegar: $e');
                }
              },
              icon: const Icon(Icons.science, color: Colors.cyan),
              label: const Text(
                'Modo Teste (Sem Garantias)',
                style: TextStyle(color: Colors.cyan),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.cyan),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            '⚠️ Modo teste: não requer garantias (apenas desenvolvimento)',
            style: TextStyle(color: Colors.cyan, fontSize: 12, fontStyle: FontStyle.italic),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}
