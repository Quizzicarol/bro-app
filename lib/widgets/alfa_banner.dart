import 'package:flutter/material.dart';

/// Banner de aviso que o app está em fase Alfa
/// Deve ser mostrado no topo de todas as telas principais
class AlfaBanner extends StatelessWidget {
  const AlfaBanner({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Pega o padding do status bar para posicionar corretamente
    final statusBarHeight = MediaQuery.of(context).padding.top;
    
    return Container(
      width: double.infinity,
      padding: EdgeInsets.only(
        top: statusBarHeight + 6,
        bottom: 8,
        left: 16,
        right: 16,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFFD32F2F), // Vermelho forte
        boxShadow: [
          BoxShadow(
            color: Colors.red.withOpacity(0.3),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                color: Colors.white,
                size: 14,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: const Text(
                  'App em testes • Bugs podem acontecer',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.none, // Remover sublinhado
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(width: 4),
              const Icon(
                Icons.warning_amber_rounded,
                color: Colors.white,
                size: 14,
              ),
            ],
          ),
          const SizedBox(height: 2),
          const Text(
            'Não negocie valores altos!',
            style: TextStyle(
              color: Colors.yellow,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              decoration: TextDecoration.none, // Remover qualquer sublinhado
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// Wrapper que adiciona o banner Alfa acima do conteúdo
/// Use: AlfaScaffold(body: ..., appBar: ...) em vez de Scaffold
class AlfaScaffold extends StatelessWidget {
  final Widget body;
  final PreferredSizeWidget? appBar;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;
  final Widget? drawer;
  final Color? backgroundColor;
  final FloatingActionButtonLocation? floatingActionButtonLocation;

  const AlfaScaffold({
    Key? key,
    required this.body,
    this.appBar,
    this.floatingActionButton,
    this.bottomNavigationBar,
    this.drawer,
    this.backgroundColor,
    this.floatingActionButtonLocation,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      drawer: drawer,
      floatingActionButton: floatingActionButton,
      floatingActionButtonLocation: floatingActionButtonLocation,
      bottomNavigationBar: bottomNavigationBar,
      body: Column(
        children: [
          // Banner Alfa no topo (abaixo da status bar)
          const AlfaBanner(),
          // AppBar customizado
          if (appBar != null) appBar!,
          // Conteúdo principal
          Expanded(child: body),
        ],
      ),
    );
  }
}
