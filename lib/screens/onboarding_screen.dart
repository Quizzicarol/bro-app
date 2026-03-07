import 'package:flutter/material.dart';
import '../services/storage_service.dart';
import '../theme/bro_colors.dart';
import 'login_screen.dart';

class OnboardingScreen extends StatefulWidget {
  final VoidCallback? onComplete;
  
  const OnboardingScreen({Key? key, this.onComplete}) : super(key: key);

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pageController = PageController();
  int _currentPage = 0;

  static const _totalPages = 4;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final storage = StorageService();
    await storage.init();
    await storage.saveData('has_seen_onboarding', 'true');
    if (widget.onComplete != null) {
      widget.onComplete!();
    } else {
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  void _next() {
    if (_currentPage < _totalPages - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      _finish();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: SafeArea(
        child: Column(
          children: [
            // Skip
            Align(
              alignment: Alignment.topRight,
              child: TextButton(
                onPressed: _finish,
                child: const Text(
                  'Pular',
                  style: TextStyle(color: Color(0x99FFFFFF), fontSize: 14),
                ),
              ),
            ),
            
            // Pages
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (i) => setState(() => _currentPage = i),
                children: [
                  _buildPage1(),
                  _buildPage2(),
                  _buildPage3(),
                  _buildPage4(),
                ],
              ),
            ),
            
            // Dots + Button
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
              child: Column(
                children: [
                  // Page dots
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(_totalPages, (i) {
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: _currentPage == i ? 24 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: _currentPage == i
                              ? BroColors.coral
                              : const Color(0x33FFFFFF),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      );
                    }),
                  ),
                  const SizedBox(height: 24),
                  
                  // Button
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _next,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: BroColors.coral,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        elevation: 0,
                      ),
                      child: Text(
                        _currentPage == _totalPages - 1 ? 'Começar' : 'Próximo',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPage1() {
    return _pageLayout(
      icon: Icons.flash_on_rounded,
      iconColor: BroColors.coral,
      title: 'Pague contas com Bitcoin',
      subtitle: 'Boletos, PIX, contas de luz, água, telefone...\nTudo pago com sats via Lightning Network.',
    );
  }

  Widget _buildPage2() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text(
            'Como funciona',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 36),
          _stepItem('1', 'Escaneie', 'Código de barras, QR Code PIX ou cole a linha digitável', Icons.qr_code_scanner_rounded),
          const SizedBox(height: 20),
          _stepItem('2', 'Pague em BTC', 'O valor é convertido e você paga em sats via Lightning', Icons.bolt_rounded),
          const SizedBox(height: 20),
          _stepItem('3', 'Pronto!', 'Um Bro da comunidade paga sua conta em reais e envia o comprovante', Icons.check_circle_outline_rounded),
        ],
      ),
    );
  }

  Widget _buildPage3() {
    return _pageLayout(
      icon: Icons.shield_outlined,
      iconColor: BroColors.mint,
      title: 'Seguro e P2P',
      subtitle: 'Sem custódia. Seus sats vão direto da sua wallet para a wallet do provedor via Lightning.\n\nProvedores depositam garantia (colateral) antes de aceitar ordens. Se algo der errado, o sistema de mediação resolve.',
    );
  }

  Widget _buildPage4() {
    return _pageLayout(
      icon: Icons.key_rounded,
      iconColor: BroColors.coral,
      title: 'Sua chave, seu dinheiro',
      subtitle: 'Ao criar sua conta, você recebe uma seed phrase de 12 palavras. Guarde-a em lugar seguro.\n\nSem ela, não é possível recuperar seus fundos. Ninguém mais tem acesso — nem nós.',
    );
  }

  Widget _pageLayout({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Icon(icon, color: iconColor, size: 40),
          ),
          const SizedBox(height: 28),
          Text(
            title,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          Text(
            subtitle,
            style: const TextStyle(
              fontSize: 15,
              color: Color(0xAAFFFFFF),
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _stepItem(String number, String title, String desc, IconData icon) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: BroColors.coral.withOpacity(0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: BroColors.coral, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                desc,
                style: const TextStyle(
                  fontSize: 13,
                  color: Color(0x99FFFFFF),
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
