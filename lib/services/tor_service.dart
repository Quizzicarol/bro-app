import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tor/tor.dart';

import 'log_utils.dart';
import 'storage_service.dart';

/// Estado da conexão Tor (exibido na tela de privacidade).
enum TorConnectionStatus {
  /// Toggle desligado — conexões diretas.
  disabled,

  /// Tor ligando (bootstrap pode levar 5-30s).
  connecting,

  /// Proxy SOCKS5 pronto em 127.0.0.1:socksPort.
  active,

  /// Última tentativa falhou — conexões seguem DIRETAS (fail-soft) e o
  /// serviço tenta de novo sozinho em background (sem botão de retry).
  error,
}

/// TorService — gerencia o proxy Tor embarcado (pacote `tor`, baseado no
/// arti, implementação oficial do Tor em Rust).
///
/// Uso:
///   - `await TorService.instance.init()` no boot do app (main.dart) — lê o
///     toggle salvo e liga o Tor em background se estiver ativo.
///   - `TorService.instance.setEnabled(bool)` no toggle da tela de privacidade.
///   - Fábricas de conexão em `tor_http.dart` consultam `isActive` a cada
///     nova conexão: Tor ativo → via SOCKS5; inativo/erro → direta.
///
/// Fail-soft por design: se a rede Tor estiver bloqueada/lenta, o app NÃO
/// quebra — segue em conexão direta e o status na tela mostra "indisponível".
/// (Regra do projeto: nada de botão "tentar de novo" — retry automático.)
class TorService extends ChangeNotifier {
  TorService._();
  static final TorService instance = TorService._();

  TorConnectionStatus _status = TorConnectionStatus.disabled;
  TorConnectionStatus get status => _status;

  bool _enabled = false;
  bool get isEnabled => _enabled;

  /// true apenas quando o proxy SOCKS5 está pronto para uso.
  bool get isActive => _status == TorConnectionStatus.active;

  /// Porta do proxy SOCKS5 local (null se inativo).
  int? get socksPort => isActive ? Tor.instance.port : null;

  bool _starting = false;
  Timer? _retryTimer;
  int _retryCount = 0;
  static const int _maxAutoRetries = 3;

  /// Lê o toggle salvo e, se ativo, liga o Tor em background (não bloqueia
  /// o boot do app — o bootstrap do Tor leva segundos).
  Future<void> init() async {
    try {
      _enabled = await StorageService().getTorEnabled();
    } catch (e) {
      broLog('🧅 TorService.init: falha ao ler toggle ($e) — assumindo desligado');
      _enabled = false;
    }
    if (_enabled) {
      unawaited(start());
    }
  }

  /// Liga o Tor (idempotente). Chamado pelo toggle ou pelo boot.
  Future<void> start() async {
    if (_status == TorConnectionStatus.active || _starting) return;
    _starting = true;
    _retryTimer?.cancel();
    _setStatus(TorConnectionStatus.connecting);
    try {
      broLog('🧅 Tor: iniciando bootstrap...');
      await Tor.init();
      await Tor.instance.start();
      if (Tor.instance.started) {
        _retryCount = 0;
        _setStatus(TorConnectionStatus.active);
        broLog('🧅 Tor: ATIVO na porta SOCKS5 ${Tor.instance.port}');
      } else {
        throw StateError('Tor.start() retornou sem started=true');
      }
    } catch (e) {
      broLog('🧅 Tor: FALHA ao iniciar ($e) — conexões seguem diretas');
      _setStatus(TorConnectionStatus.error);
      _scheduleRetry();
    } finally {
      _starting = false;
    }
  }

  /// Desliga o Tor e volta para conexão direta.
  Future<void> stop() async {
    _retryTimer?.cancel();
    _retryCount = 0;
    try {
      if (Tor.instance.started) {
        await Tor.instance.stop();
      }
    } catch (e) {
      broLog('🧅 Tor: erro ao parar ($e) — ignorado');
    }
    _setStatus(TorConnectionStatus.disabled);
    broLog('🧅 Tor: DESLIGADO');
  }

  /// Toggle da tela de privacidade: persiste e aplica imediatamente.
  Future<void> setEnabled(bool enabled) async {
    _enabled = enabled;
    try {
      await StorageService().saveTorEnabled(enabled);
    } catch (e) {
      broLog('🧅 TorService: falha ao salvar toggle ($e)');
    }
    if (enabled) {
      unawaited(start());
    } else {
      unawaited(stop());
    }
  }

  /// Retry automático com backoff (30s, 60s, 120s) — sem botão manual.
  void _scheduleRetry() {
    if (!_enabled || _retryCount >= _maxAutoRetries) return;
    _retryCount++;
    final delay = Duration(seconds: 30 * (1 << (_retryCount - 1)));
    broLog('🧅 Tor: retry automático #$_retryCount em ${delay.inSeconds}s');
    _retryTimer = Timer(delay, () {
      if (_enabled && !isActive) unawaited(start());
    });
  }

  void _setStatus(TorConnectionStatus s) {
    if (_status == s) return;
    _status = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    super.dispose();
  }
}
