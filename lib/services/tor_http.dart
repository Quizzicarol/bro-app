import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
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

  /// Timeout de leitura adaptado ao Tor: via Tor tudo é mais lento (o connect
  /// de cada relay leva ~5-20s, e circuitos variam ao longo do dia). Sem isso,
  /// as leituras estouravam o timeout de 8s e a lista de "ordens disponíveis"
  /// vinha VAZIA com Tor ligado.
  static Duration get readTimeout => TorService.instance.isActive
      ? const Duration(seconds: 45)
      : const Duration(seconds: 8);

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
  ///
  /// v663h: WebSocket.connect(customClient:) com o HttpClient roteado pelo
  /// SOCKS5 do Tor — o Dart faz o upgrade WS internamente via detachSocket
  /// (à prova de buffer; o meu handshake manual re-ouvia o socket e quebrava
  /// com "Stream has already been listened"). O Dart converte wss→https antes
  /// de chamar o connectionFactory, então o TLS é aplicado pelo _connectTcpViaTor.
  static Future<WebSocket> connectRawWebSocket(String url,
      {Duration? timeout}) async {
    if (!_torActive) {
      final future = WebSocket.connect(url);
      return timeout != null ? future.timeout(timeout) : future;
    }
    try {
      // v663i: timeout OBRIGATÓRIO no caminho Tor. Sem ele, um relay lento via
      // Tor pendurava o connect pra sempre e travava o Future.wait de publish
      // (a ordem 02ebc36d ficou eventId=NULL — criada mas nunca publicada,
      // porque o republish estourava o timeout de 30s no aguardo do connect).
      // 20s: circuitos do Tor variam bastante ao longo do dia.
      final effectiveTimeout = timeout ?? const Duration(seconds: 20);
      final client = _createProxiedHttpClient();
      final ws = await WebSocket.connect(url, customClient: client)
          .timeout(effectiveTimeout);
      return ws;
    } catch (e) {
      broLog('🧅 TorHttp: WS via Tor FALHOU para $url ($e) — usando conexão direta');
      final future = WebSocket.connect(url);
      return timeout != null ? future.timeout(timeout) : future;
    }
  }

  /// Abre uma conexão TCP para [host]:[port] através do SOCKS5 do Tor,

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
    // v663f: NÃO usar SocksTCPClient.assignToHttpClient — ele resolve o domínio
    // LOCALMENTE (InternetAddress.lookup) antes de mandar pro Tor, o que VAZA
    // o DNS e quebra quando a rede local não resolve ("Failed host lookup").
    // Aqui o connectionFactory manda o DOMÍNIO pro Tor (AddressType.domain) e
    // o exit node resolve o DNS — o IP real nem é consultado localmente.
    client.connectionFactory = (uri, proxyHost, proxyPort) async {
      final isSecure = uri.scheme == 'https';
      final future = _connectTcpViaTor(uri.host, uri.port, secure: isSecure);
      return ConnectionTask.fromSocket(future, () async {
        (await future).close().ignore();
      });
    };
    return client;
  }

  /// Abre uma conexão TCP para [host]:[port] através do SOCKS5 do Tor,
  /// mandando o DOMÍNIO (o exit node resolve o DNS). Se [secure], termina o
  /// TLS depois do túnel. Reuso da mesma lógica do WebSocket.
  static Future<Socket> _connectTcpViaTor(String host, int port,
      {required bool secure}) async {
    final socksPort = TorService.instance.socksPort;
    if (socksPort == null) {
      throw StateError('Tor inativo (sem porta SOCKS5)');
    }
    var socket = await Socket.connect(InternetAddress.loopbackIPv4, socksPort);
    // Mesmo padrão do WebSocket: UMA subscrição contínua acumulando num buffer.
    final buffer = <int>[];
    final dataReady = StreamController<void>.broadcast();
    late final StreamSubscription<List<int>> sub;
    sub = socket.listen(
      (chunk) {
        buffer.addAll(chunk);
        dataReady.add(null);
      },
      onError: (Object e) => dataReady.addError(e),
      onDone: () {},
    );
    Future<List<int>> readExact(int n) async {
      while (buffer.length < n) {
        await dataReady.stream.first;
      }
      final out = buffer.sublist(0, n);
      buffer.removeRange(0, n);
      return out;
    }

    socket.add([0x05, 0x01, 0x00]);
    await socket.flush();
    final greeting = await readExact(2);
    if (greeting[1] != 0x00) {
      throw StateError('SOCKS5 greeting rejeitado pelo Tor');
    }
    final hostBytes = host.codeUnits;
    socket.add([
      0x05, 0x01, 0x00, 0x03, hostBytes.length, ...hostBytes,
      (port >> 8) & 0xFF, port & 0xFF,
    ]);
    await socket.flush();
    final head = await readExact(4);
    if (head[1] != 0x00) {
      throw StateError('SOCKS5 CONNECT falhou (código ${head[1]}) — o Tor não alcançou $host');
    }
    final atyp = head[3];
    final addrLen = (atyp == 0x01) ? 4 : (atyp == 0x03 ? (await readExact(1))[0] : 16);
    await readExact(addrLen + 2);
    sub.pause(); // pausar (não cancelar) — o SecureSocket.secure retoma a leitura

    if (secure) {
      socket = await SecureSocket.secure(socket, host: host);
    }
    return socket;
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
