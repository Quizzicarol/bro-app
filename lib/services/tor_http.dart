import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:socks5_proxy/socks_client.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'log_utils.dart';
import 'tor_service.dart';

/// TorHttp — fábricas de conexão de rede conscientes do estado do Tor.
///
/// Regra única em TODO o app: ninguém mais chama `WebSocketChannel.connect`,
/// `WebSocket.connect`, `http.get/post` ou cria `Dio` sem passar por aqui.
///
/// Comportamento:
///   - Tor ATIVO (TorService.isActive) → conexão via SOCKS5 127.0.0.1:porta.
///   - Tor desligado/conectando/erro → conexão DIRETA (fail-soft: o app nunca
///     quebra por causa do Tor; a tela de privacidade mostra o status real).
///
/// A decisão é tomada A CADA nova conexão, então ligar/desligar o toggle
/// afeta as próximas conexões sem precisar reiniciar o app.
class TorHttp {
  TorHttp._();

  static bool get _torActive => TorService.instance.isActive;

  // ---------------------------------------------------------------------------
  // WebSocket
  // ---------------------------------------------------------------------------

  /// Abre WebSocket para [url] — via Tor quando ativo, direto caso contrário.
  /// Substitui `WebSocketChannel.connect(Uri.parse(url))`.
  static Future<WebSocketChannel> connectWs(String url) async {
    if (!_torActive) {
      return WebSocketChannel.connect(Uri.parse(url));
    }
    final ws = await connectRawWebSocket(url);
    return IOWebSocketChannel(ws);
  }

  /// Abre `dart:io` WebSocket cru via Tor (ou direto se inativo).
  /// Usado por código que precisa do WebSocket nativo e não do Channel.
  static Future<WebSocket> connectRawWebSocket(String url,
      {Duration? timeout}) async {
    if (!_torActive) {
      final future = WebSocket.connect(url);
      return timeout != null ? future.timeout(timeout) : future;
    }
    try {
      final client = _createProxiedHttpClient();
      // WebSocket.connect aceita customClient — o handshake HTTP de upgrade
      // inteiro passa pelo proxy SOCKS5 do Tor, inclusive o TLS é terminado
      // DEPOIS do túnel (o exit node não vê o conteúdo, só o destino).
      final future = WebSocket.connect(url, customClient: client);
      final ws = timeout != null ? await future.timeout(timeout) : await future;
      return ws;
    } catch (e) {
      broLog('🧅 TorHttp: WS via Tor FALHOU para $url ($e) — usando conexão direta');
      final future = WebSocket.connect(url);
      return timeout != null ? future.timeout(timeout) : future;
    }
  }

  // ---------------------------------------------------------------------------
  // package:http
  // ---------------------------------------------------------------------------

  /// Cria um http.Client roteado conforme o estado atual do Tor.
  /// O chamador DEVE chamar `client.close()` após o uso (como o http.get faz).
  static http.Client createClient() {
    if (!_torActive) return http.Client();
    return IOClient(_createProxiedHttpClient());
  }

  /// Equivalente ao `http.get`, roteado via Tor quando ativo.
  static Future<http.Response> get(Uri url, {Map<String, String>? headers}) async {
    final client = createClient();
    try {
      return await client.get(url, headers: headers);
    } catch (e) {
      if (_torActive) {
        broLog('🧅 TorHttp: GET via Tor FALHOU para ${url.host} ($e) — direto');
        final fallback = http.Client();
        try {
          return await fallback.get(url, headers: headers);
        } finally {
          fallback.close();
        }
      }
      rethrow;
    } finally {
      client.close();
    }
  }

  /// Equivalente ao `http.post`, roteado via Tor quando ativo.
  static Future<http.Response> post(Uri url,
      {Map<String, String>? headers, Object? body}) async {
    final client = createClient();
    try {
      return await client.post(url, headers: headers, body: body);
    } catch (e) {
      if (_torActive) {
        broLog('🧅 TorHttp: POST via Tor FALHOU para ${url.host} ($e) — direto');
        final fallback = http.Client();
        try {
          return await fallback.post(url, headers: headers, body: body);
        } finally {
          fallback.close();
        }
      }
      rethrow;
    } finally {
      client.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Dio
  // ---------------------------------------------------------------------------

  /// Aplica (ou remove) o adapter Tor num Dio existente, conforme o estado
  /// atual. Registrar o Dio aqui também faz ele ser atualizado
  /// automaticamente quando o Tor ligar/desligar/cair.
  static void applyToDio(Dio dio) {
    _applyAdapter(dio);
    if (!_registeredDios.contains(dio)) {
      _registeredDios.add(dio);
      _ensureDioListener();
    }
  }

  static final List<Dio> _registeredDios = [];
  static bool _dioListenerActive = false;

  static void _ensureDioListener() {
    if (_dioListenerActive) return;
    _dioListenerActive = true;
    TorService.instance.addListener(() {
      for (final dio in List<Dio>.of(_registeredDios)) {
        _applyAdapter(dio);
      }
    });
  }

  static void _applyAdapter(Dio dio) {
    if (_torActive) {
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: _createProxiedHttpClient,
      );
    } else {
      // Adapter padrão (conexão direta).
      dio.httpClientAdapter = IOHttpClientAdapter();
    }
  }

  // ---------------------------------------------------------------------------
  // Interno
  // ---------------------------------------------------------------------------

  /// HttpClient (dart:io) com TODAS as conexões roteadas pelo SOCKS5 do Tor.
  /// Pré-condição: TorService.isActive == true.
  static HttpClient _createProxiedHttpClient() {
    final port = TorService.instance.socksPort;
    if (port == null) {
      // Não deveria acontecer (chamadores checam isActive) — fail-soft.
      return HttpClient();
    }
    final client = HttpClient();
    SocksTCPClient.assignToHttpClient(client, [
      ProxySettings(InternetAddress.loopbackIPv4, port),
    ]);
    return client;
  }
}

/// Atalho: `Dio(BaseOptions(...)).withTor()` aplica o adapter Tor e registra
/// o Dio para re-aplicar automaticamente quando o Tor ligar/desligar.
extension TorDioX on Dio {
  Dio withTor() {
    TorHttp.applyToDio(this);
    return this;
  }
}
