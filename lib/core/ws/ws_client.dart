import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../net/protocol_log.dart';
import 'ws_event.dart';

/// 连接状态。
///
/// 老端只有一个 `is_open_socket` 布尔量；这里显式区分「重连中」，
/// 因为会话页要显示"连接已断开，点击重连"，而重连中的提示语不一样。
enum WsStatus { idle, connecting, connected, reconnecting, closed }

/// 便于测试注入假的 channel
typedef WsConnector = WebSocketChannel Function(Uri uri);

/// WebSocket 客户端，替代老端 `common/socket.js`。
///
/// 与老端一致：地址 `wss://{host}/wss`、客户端每 25 秒发 `{"type":"ping"}`、
/// 退出时先发 `{"type":"close"}` 再关闭。
///
/// 与老端不同的三点：
/// 1. **重连统一成指数退避**。老端 `onSocketError` 走 15 秒 `setInterval`（最多 10 次），
///    `onClose` 走另一套（最多 5 次），还依赖几个抄来的标志位；这里统一成
///    1s → 2s → 4s → … → 30s（带抖动），连上即重置。
/// 2. **加了心跳超时判定**。老端只发心跳，不检查对端是否还活着，
///    出现"假连接"（socket 没关但收不到消息）时不会自愈。
/// 3. 丢掉老端 `socket.js` 里与本项目无关的残留代码（traderDetailIndex 之类）。
class WsClient {
  WsClient({
    required this.url,
    this.heartbeatInterval = const Duration(seconds: 25),
    this.heartbeatTimeout = const Duration(seconds: 70),
    this.maxBackoff = const Duration(seconds: 30),
    this.autoReconnect = true,
    WsConnector? connector,
  }) : _connector = connector ?? WebSocketChannel.connect;

  final String url;

  /// 心跳间隔（老端 25 秒）
  final Duration heartbeatInterval;

  /// 多久收不到任何报文就判定假连接并重连
  final Duration heartbeatTimeout;

  final Duration maxBackoff;
  final bool autoReconnect;
  final WsConnector _connector;
  final Random _random = Random();

  final StreamController<WsEvent> _eventController =
      StreamController<WsEvent>.broadcast();
  final StreamController<WsStatus> _statusController =
      StreamController<WsStatus>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  int _attempt = 0;
  bool _manualClose = false;
  DateTime? _lastInboundAt;
  WsStatus _status = WsStatus.idle;

  Stream<WsEvent> get events => _eventController.stream;

  Stream<WsStatus> get statusChanges => _statusController.stream;

  WsStatus get status => _status;

  bool get isConnected => _status == WsStatus.connected;

  /// 重连次数（连上后归零）
  int get reconnectAttempt => _attempt;

  /// 退避策略（纯函数，便于单测）：1s、2s、4s、8s…上限 [max]
  static Duration backoffFor(
    int attempt, {
    Duration max = const Duration(seconds: 30),
  }) {
    if (attempt <= 1) return const Duration(seconds: 1);
    final shift = min(attempt - 1, 16);
    final millis = 1000 * (1 << shift);
    return Duration(milliseconds: min(millis, max.inMilliseconds));
  }

  Future<void> connect() async {
    if (_status == WsStatus.connecting || _status == WsStatus.connected) return;
    _manualClose = false;
    _setStatus(WsStatus.connecting);

    try {
      final channel = _connector(Uri.parse(url));
      await channel.ready;
      _channel = channel;
      _attempt = 0;
      _lastInboundAt = DateTime.now();
      _subscription = channel.stream.listen(
        _onData,
        onError: (Object error) {
          debugPrint('[WS] 连接出错：$error');
          _handleDisconnected();
        },
        onDone: _handleDisconnected,
        cancelOnError: false,
      );
      _setStatus(WsStatus.connected);
      _startHeartbeat();
    } catch (error) {
      debugPrint('[WS] 连接失败：$error');
      _handleDisconnected();
    }
  }

  /// 发送一帧。未连接时只记日志（老端同样是静默失败）。
  bool send(Map<String, dynamic> payload) {
    final channel = _channel;
    if (channel == null || !isConnected) {
      debugPrint('[WS] 未连接，丢弃发送：$payload');
      return false;
    }
    ProtocolLog.wsOut(payload);
    channel.sink.add(_encode(payload));
    return true;
  }

  /// 优雅关闭：先发 `{"type":"close"}`（老端 `scoketClose()` 的行为），再断开，不再重连。
  Future<void> close({bool graceful = true}) async {
    _manualClose = true;
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    if (graceful && isConnected) {
      send(const <String, dynamic>{'type': 'close'});
    }
    await _teardownChannel();
    _setStatus(WsStatus.closed);
  }

  void dispose() {
    _manualClose = true;
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close();
    _eventController.close();
    _statusController.close();
  }

  // ------------------------------------------------------------------ 内部

  void _onData(dynamic message) {
    _lastInboundAt = DateTime.now();
    ProtocolLog.wsIn(message);

    final event = WsEvent.tryParse(message);
    if (event == null) {
      debugPrint('[WS] 无法解析的报文：$message');
      return;
    }
    // 心跳应答（服务端 `ping` → 回 `pong`）是**协议层**的事，在
    // `protocolWsHandlers` 里，这里只负责分发 —— 传输层保持与老端一致。
    _eventController.add(event);
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      final last = _lastInboundAt;
      if (last != null && DateTime.now().difference(last) > heartbeatTimeout) {
        debugPrint('[WS] 心跳超时（${heartbeatTimeout.inSeconds}s 无报文），强制重连');
        _forceReconnect();
        return;
      }
      send(const <String, dynamic>{'type': 'ping'});
    });
  }

  void _forceReconnect() {
    unawaited(_teardownChannel().then((_) => _handleDisconnected()));
  }

  Future<void> _teardownChannel() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    final channel = _channel;
    _channel = null;
    try {
      await channel?.sink.close();
    } catch (_) {
      // 关闭失败无所谓，连接已经不可用
    }
  }

  void _handleDisconnected() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    if (_manualClose) {
      _setStatus(WsStatus.closed);
      return;
    }

    _setStatus(WsStatus.reconnecting);
    if (!autoReconnect) return;

    _attempt += 1;
    final delay = _withJitter(backoffFor(_attempt, max: maxBackoff));
    debugPrint('[WS] ${delay.inMilliseconds}ms 后进行第 $_attempt 次重连');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () {
      if (!_manualClose) unawaited(connect());
    });
  }

  Duration _withJitter(Duration base) {
    final jitter = _random.nextInt(300);
    return Duration(milliseconds: base.inMilliseconds + jitter);
  }

  /// 老端是 `JSON.stringify`
  String _encode(Map<String, dynamic> payload) => jsonEncode(payload);

  void _setStatus(WsStatus next) {
    if (_status == next) return;
    _status = next;
    if (!_statusController.isClosed) _statusController.add(next);
  }
}
