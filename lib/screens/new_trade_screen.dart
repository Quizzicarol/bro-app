import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import 'payment_screen.dart';
import 'offer_screen.dart';

/// Tela de Pagar Conta - Hub para criar ofertas ou pagar contas
class NewTradeScreen extends StatelessWidget {
  const NewTradeScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xF70A0A0A),
        elevation: 0,
        title: Text(
          AppLocalizations.of(context).t('trade_title'),
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Título direto
              Text(
                AppLocalizations.of(context).t('trade_what_to_do'),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 16),

              // Opcao 1: Oferecer produto/servico
              _buildOptionCard(
                context,
                icon: Icons.sell,
                iconColor: const Color(0xFF3DE98C),
                gradientColors: [const Color(0xFF3DE98C), const Color(0xFF00CC7A)],
                title: AppLocalizations.of(context).t('trade_offer_product'),
                description: AppLocalizations.of(context).t('trade_offer_description'),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const OfferScreen()),
                  );
                },
              ),
              const SizedBox(height: 16),

              // Opcao 2: Pagar uma conta
              _buildOptionCard(
                context,
                icon: Icons.receipt_long,
                iconColor: const Color(0xFFFF6B6B),
                gradientColors: [const Color(0xFFFF6B6B), const Color(0xFFFF8A8A)],
                title: AppLocalizations.of(context).t('trade_pay_bill'),
                description: AppLocalizations.of(context).t('trade_pay_description'),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const PaymentScreen()),
                  );
                },
              ),
              const SizedBox(height: 24), // Espaço extra para evitar botões de navegação
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickGuide(BuildContext context) {
    final t = AppLocalizations.of(context).t;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF9C27B0).withOpacity(0.2),
            const Color(0xFF9C27B0).withOpacity(0.1),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFF9C27B0).withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lightbulb_outline, color: Color(0xFFBA68C8), size: 24),
              const SizedBox(width: 8),
              Text(
                t('trade_how_it_works'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildGuideItem('🛍️', t('trade_guide_offer')),
          const SizedBox(height: 8),
          _buildGuideItem('💬', t('trade_guide_chat')),
          const SizedBox(height: 8),
          _buildGuideItem('📸', t('trade_guide_photos')),
          const SizedBox(height: 8),
          _buildGuideItem('💳', t('trade_guide_pay')),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0x1A3DE98C),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.verified, color: Color(0xFF3DE98C), size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t('trade_p2p_privacy'),
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF3DE98C),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGuideItem(String emoji, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(emoji, style: const TextStyle(fontSize: 16)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xB3FFFFFF),
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOptionCard(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required List<Color> gradientColors,
    required String title,
    required String description,
    required VoidCallback onTap,
    bool comingSoon = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: const Color(0x0DFFFFFF),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: gradientColors[0].withOpacity(0.3),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: gradientColors,
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: Colors.white, size: 28),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      if (comingSoon)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: gradientColors[0].withOpacity(0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            AppLocalizations.of(context).t('trade_coming_soon'),
                            style: TextStyle(
                              fontSize: 10,
                              color: gradientColors[0],
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0x99FFFFFF),
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.arrow_forward_ios,
              color: gradientColors[0].withOpacity(0.5),
              size: 18,
            ),
          ],
        ),
      ),
    );
  }
}
