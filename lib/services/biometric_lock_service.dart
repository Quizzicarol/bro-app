import 'package:local_auth/local_auth.dart';
import 'storage_service.dart';
import 'log_utils.dart';

/// Trava biométrica opcional do app (issue do repo público + pedido out/2026).
///
/// PRIVACIDADE: os dados biométricos NUNCA saem do chip seguro do aparelho
/// (Secure Enclave no iOS, Keystore/TEE no Android). O app recebe apenas
/// "sucesso/falha" do sistema operacional — é tecnicamente impossível o Bro
/// (ou qualquer app) ler a digital/face do usuário. Nada é enviado a relays
/// ou servidores. O toggle é opt-in e fica na tela de Privacidade.
class BiometricLockService {
  static final BiometricLockService _instance = BiometricLockService._internal();
  factory BiometricLockService() => _instance;
  BiometricLockService._internal();

  final LocalAuthentication _auth = LocalAuthentication();
  final StorageService _storage = StorageService();

  /// true se o usuário ativou a trava E a sessão atual ainda não desbloqueou.
  bool _unlockedThisSession = false;

  Future<bool> isEnabled() async => _storage.getBiometricLock();

  Future<void> setEnabled(bool value) async {
    await _storage.saveBiometricLock(value);
    if (!value) _unlockedThisSession = true; // desativar libera a sessão
  }

  /// O aparelho tem biometria ou PIN/padrão configurado?
  Future<bool> isAvailable() async {
    try {
      final canCheck = await _auth.canCheckBiometrics;
      final supported = await _auth.isDeviceSupported();
      return canCheck || supported;
    } catch (e) {
      broLog('⚠️ Biometria indisponível: $e');
      return false;
    }
  }

  /// Deve mostrar a tela de trava agora?
  Future<bool> shouldLock() async {
    if (_unlockedThisSession) return false;
    return isEnabled();
  }

  /// Marcar como bloqueado (chamado quando o app vai para background).
  void lock() {
    _unlockedThisSession = false;
  }

  /// Pedir biometria/PIN do sistema. Retorna true se desbloqueou.
  Future<bool> unlock() async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: 'Desbloquear o Bro',
        options: const AuthenticationOptions(
          // biometricOnly=false: permite PIN/padrão como fallback do sistema —
          // sem isso, quem tem biometria fraca/cadastrada mal fica trancado fora.
          biometricOnly: false,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
      if (ok) _unlockedThisSession = true;
      return ok;
    } catch (e) {
      broLog('⚠️ Falha na autenticação biométrica: $e');
      return false;
    }
  }
}
