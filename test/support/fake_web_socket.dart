import 'dart:async';

import 'package:gracelinkim/core/ws/ws_client.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 假通道：只实现 `WsClient` 真正用到的那几个成员（ready / stream / sink），
/// 其余成员走 `noSuchMethod`——被调到时直接抛，等于"用到了没实现的接口"。
///
/// 有了它，测试就能断言**发出去的帧**（例如登录后的 `bindUid`），
/// 或者伪造**服务端推过来的报文**（例如 `init`、`offline`）。
class FakeWebSocketChannel implements WebSocketChannel {
  FakeWebSocketChannel();

  final StreamController<dynamic> _incoming =
      StreamController<dynamic>.broadcast();

  /// 客户端发出去的原始报文（JSON 字符串）
  final List<dynamic> sent = <dynamic>[];

  bool closed = false;

  /// 伪造一条服务端推送
  void emit(String message) => _incoming.add(message);

  /// 服务端把连接掰了（让 `WsClient` 收到 onDone → 自己判定断开）
  Future<void> closeIncoming() => _incoming.close();

  @override
  Future<void> get ready => Future<void>.value();

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _FakeSink(this);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSink implements WebSocketSink {
  _FakeSink(this._channel);

  final FakeWebSocketChannel _channel;

  @override
  void add(dynamic data) => _channel.sent.add(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    _channel.closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 建一个连着假通道、已启动的 [WsService]，用完记得 `dispose()`
Future<WsService> startTestWsService(FakeWebSocketChannel channel) async {
  final service = WsService(
    client: WsClient(
      url: 'ws://test.local/wss',
      autoReconnect: false,
      connector: (_) => channel,
    ),
  );
  service.start();
  // 让 connect() 里的 await channel.ready 走完
  await Future<void>.delayed(Duration.zero);
  return service;
}
