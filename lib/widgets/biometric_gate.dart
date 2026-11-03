import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/biometric_lock_service.dart';

/// Portão de trava biométrica (opt-in via tela de Privacidade).
/// Envolve TODO o conteúdo do app: ao abrir ou voltar do background com a
/// trava ativa, cobre a tela e pede biometria/PIN do sistema. Nenhum dado
/// biométrico passa pelo app — o sistema operacional só devolve sim/não.
class BiometricGate extends StatefulWidget {
  final Widget child;
  const BiometricGate({super.key, required this.child});

  @override
  State<BiometricGate> createState() => _BiometricGateState();
}

class _BiometricGateState extends State<BiometricGate> with WidgetsBindingObserver {
  final BiometricLockService _bio = BiometricLockService();
  bool _locked = false;
  bool _prompting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkLock();
  }

  Future<void> _checkLock() async {
    if (await _bio.shouldLock()) {
      if (mounted) setState(() => _locked = true);
      _prompt();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _bio.lock();
    } else if (state == AppLifecycleState.resumed) {
      _checkLock();
    }
  }

  Future<void> _prompt() async {
    if (_prompting) return;
    _prompting = true;
    final ok = await _bio.unlock();
    _prompting = false;
    if (ok && mounted) setState(() => _locked = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_locked) return widget.child;
    final l = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.fingerprint, size: 72, color: Color(0xFFFF6B6B)),
            const SizedBox(height: 16),
            Text(
              l.t('privacy_biometric_lock'),
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 24),
            TextButton.icon(
              onPressed: _prompt,
              icon: const Icon(Icons.lock_open, color: Colors.white70),
              label: Text(
                l.t('biometric_unlock'),
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
