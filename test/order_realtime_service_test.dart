import 'dart:async';

import 'package:bro_app/services/order_realtime_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _FakeSink implements WebSocketSink {
  final List<Object?> messages = [];
  final Completer<void> closed = Completer<void>();

  @override
  void add(Object? data) => messages.add(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    if (!closed.isCompleted) closed.complete();
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<Object?> stream) async {
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future<void> get done => closed.future;
}

class _FakeChannel extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  _FakeChannel(this.ready);

  @override
  final Future<void> ready;
  final StreamController<dynamic> controller =
      StreamController<dynamic>.broadcast();
  final _FakeSink fakeSink = _FakeSink();

  @override
  Stream<dynamic> get stream => controller.stream;

  @override
  WebSocketSink get sink => fakeSink;

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const relay = 'wss://test.relay';
  const pubkey = '0123456789abcdef0123456789abcdef';
  late OrderRealtimeService service;
  late List<_FakeChannel> channels;
  late List<Duration> delays;
  late DateTime now;

  setUp(() {
    service = OrderRealtimeService();
    channels = [];
    delays = [];
    now = DateTime(2026, 11, 20, 12);
    OrderRealtimeService.clockOverride = () => now;
    OrderRealtimeService.relaysOverride = [relay];
    OrderRealtimeService.readyTimeoutOverride =
        const Duration(milliseconds: 20);
    OrderRealtimeService.reconnectCheckInterval = const Duration(hours: 1);
    OrderRealtimeService.reconnectDelayOverride = (failures) {
      final delay = Duration(seconds: failures * 10);
      delays.add(delay);
      return delay;
    };
    OrderRealtimeService.channelFactoryOverride = (_) {
      final channel = _FakeChannel(Completer<void>().future);
      channels.add(channel);
      return channel;
    };
  });

  tearDown(() {
    service.stop();
    for (final channel in channels) {
      channel.controller.close();
    }
    OrderRealtimeService.channelFactoryOverride = null;
    OrderRealtimeService.relaysOverride = null;
    OrderRealtimeService.reconnectDelayOverride = null;
    OrderRealtimeService.clockOverride = DateTime.now;
    OrderRealtimeService.readyTimeoutOverride = const Duration(seconds: 8);
    OrderRealtimeService.reconnectCheckInterval = const Duration(seconds: 30);
  });

  test('socket não pronto não recebe REQ e reconexão respeita backoff',
      () async {
    service.start(pubkey);
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(channels, hasLength(1));
    expect(channels.single.fakeSink.messages, isEmpty);
    expect(service.debugReconnectFailures(relay), 1);
    expect(delays, [const Duration(seconds: 10)]);

    service.debugCheckReconnect();
    await Future<void>.delayed(Duration.zero);
    expect(channels, hasLength(1), reason: 'backoff ainda não expirou');

    now = now.add(const Duration(seconds: 10));
    service.debugCheckReconnect();
    await Future<void>.delayed(Duration.zero);
    expect(channels, hasLength(2));

    channels[1].controller.addError(StateError('network failed'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(service.debugReconnectFailures(relay), 2);
    expect(delays, [const Duration(seconds: 10), const Duration(seconds: 20)]);
  });

  test('erro assíncrono em conexão pronta agenda backoff', () async {
    final ready = Completer<void>();
    OrderRealtimeService.channelFactoryOverride = (_) {
      final channel = _FakeChannel(ready.future);
      channels.add(channel);
      return channel;
    };
    service.start(pubkey);
    ready.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(channels.single.fakeSink.messages, hasLength(2));

    channels.single.controller.addError(StateError('network failed'));
    await Future<void>.delayed(Duration.zero);
    expect(service.debugReconnectFailures(relay), 1);
    expect(delays, [const Duration(seconds: 10)]);
  });

  test('troca de pubkey fecha sockets, reseta backoff e isola filtros', () async {
    const newPubkey = 'fedcba9876543210fedcba9876543210';
    const secondRelay = 'wss://pending.relay';
    OrderRealtimeService.relaysOverride = [relay, secondRelay];
    final oldReady = Completer<void>();
    final newReady = Completer<void>();
    final pendingReady = Completer<void>();
    final readies = [oldReady, pendingReady, newReady, Completer<void>()];
    OrderRealtimeService.channelFactoryOverride = (_) {
      final channel = _FakeChannel(readies.removeAt(0).future);
      channels.add(channel);
      return channel;
    };

    service.start(pubkey);
    oldReady.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(channels[0].fakeSink.messages, hasLength(2));
    expect(channels[1].fakeSink.messages, isEmpty,
        reason: 'segundo socket da conta antiga fica pendente no handshake');
    channels[0].controller.addError(StateError('old account disconnect'));
    await Future<void>.delayed(Duration.zero);
    expect(service.debugReconnectFailures(relay), 1);

    service.start(newPubkey);
    await Future<void>.delayed(Duration.zero);
    expect(channels[1].fakeSink.closed.isCompleted, isTrue,
        reason: 'socket pendente da conta antiga deve ser fechado no stop');
    expect(service.debugReconnectFailures(relay), 0);
    expect(service.debugReconnectFailures(secondRelay), 0);
    expect(channels, hasLength(4));

    pendingReady.complete();
    newReady.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(channels[1].fakeSink.messages, isEmpty,
        reason: 'handshake antigo nunca pode assinar filtros da nova conta');
    expect(channels[2].fakeSink.messages, hasLength(2));
    for (final message in channels[2].fakeSink.messages) {
      expect(message, contains(newPubkey));
      expect(message, isNot(contains(pubkey)));
    }
  });

  test('REQ só é enviado depois do ready e filtros permanecem', () async {
    final ready = Completer<void>();
    OrderRealtimeService.channelFactoryOverride = (_) {
      final channel = _FakeChannel(ready.future);
      channels.add(channel);
      return channel;
    };

    service.start(pubkey);
    await Future<void>.delayed(Duration.zero);
    expect(channels.single.fakeSink.messages, isEmpty);

    ready.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(channels.single.fakeSink.messages, hasLength(2));
    expect(channels.single.fakeSink.messages[0], contains('"#p"'));
    expect(channels.single.fakeSink.messages[1], contains('"authors"'));
  });
}
