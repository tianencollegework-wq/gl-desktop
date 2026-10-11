import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../core/ws/ws_client.dart';
import '../../core/ws/ws_event.dart';
import '../../domain/session/session_service.dart';

/// 电脑端扫码登录这一步走到哪儿了（登录页二维码面板上那几种状态）。
enum QrLoginPhase {
  /// 正在连消息服务（还没拿到二维码）
  connecting,

  /// 二维码已经在屏幕上，等手机扫
  waiting,

  /// 手机确认过了，登录态已经落盘（页面马上会被路由守卫带走）
  confirmed,

  /// 断了 / 超时：面板上给一句提示与一颗「刷新二维码」
  failed,
}

@immutable
class QrLoginState {
  const QrLoginState({
    this.qrUrl = '',
    this.phase = QrLoginPhase.connecting,
    this.message = '',
  });

  /// 本轮二维码的内容（服务端给的 `qrurl`，手机扫的就是它）
  final String qrUrl;

  final QrLoginPhase phase;

  /// 失败时给用户看的那句话
  final String message;

  QrLoginState copyWith({
    String? qrUrl,
    QrLoginPhase? phase,
    String? message,
  }) => QrLoginState(
    qrUrl: qrUrl ?? this.qrUrl,
    phase: phase ?? this.phase,
    message: message ?? this.message,
  );
}

/// 电脑端扫码登录：**与网页端同一个协议**（服务端 `app/worker/Events.php` +
/// `app/enterprise/controller/Im.php::tokenLogin`，逐条对照 `public/assets/js/
/// app.*.js` 里那个 `Socket` 组件与登录页的 `openQr`）：
///
/// ```text
/// 电脑（这条连接）                          服务端                      手机（已登录）
/// ── ws 连上 ────────────────────────────────► init {client_id}
/// ── {type:pong, isQrLogin:true} ─────────────►
///                                  {type:codeLoginQr, qrurl} ◄── 二维码内容：
///                                                                {app_host}/scan/a/{token}
///                                                              ── 扫到 → POST 那个地址 ──►
///                                              scanQr(action=a) → {loginToken}
///                                                              ── 用户在手机上点确认 ──►
///                                              POST /enterprise/im/tokenLogin {token:loginToken}
///                                  {type:tokenLogin, data:{sessionId, authToken, userInfo}}
/// ◄─────────────────────────────────────────┘   （同时把**这一条连接** bindUid 到那个人）
/// ```
///
/// 三个关键点，都是从服务端代码里读出来的，不是猜的：
///
/// 1. **二维码不是本地画的，是服务端给的**：只有服务端知道 `client_id` 与它的
///    加密口径（`authcode($client_id, 'ENCODE', app_id, 100)`），而且扫到的地址
///    `/scan/a/<token>` 必须能被手机认成「自家链接」（`scan_target.dart` 那条
///    `data.contains(apiUrl)` 的判据），所以**原样用服务端那句 `qrurl`**。
/// 2. **要了才有**：服务端只在收到 `{type:'pong', isQrLogin:true}` 时才生成并推送
///    二维码（`Events.php` 的 `case 'pong'`），网页端也是切到扫码 tab 那一刻先发这
///    一句（`openQr`）。所以这里连上就问一次，之后**每 [refreshInterval] 再问一次**
///    —— 二维码里那个 token 的寿命是 100 秒（服务端 `authcode(..., 100)`），
///    过期之后手机扫到的是「扫描失败」，定期换一张才一直能用。
/// 3. **登录态是推过来的**：服务端在 `tokenLogin` 里把 `{sessionId, authToken,
///    userInfo}` 推给**那条要登录的连接**，电脑端不需要轮询、也不需要密码——
///    收到就用 [SessionService.applyQrLogin] 落盘（那一步与密码登录共用后半段）。
class QrLoginSession {
  QrLoginSession({
    required this.url,
    required this.onLogin,
    this.connector,
    this.refreshInterval = const Duration(seconds: 50),
    this.heartbeatInterval = const Duration(seconds: 25),
  });

  /// 消息服务地址（与聊天那条连接同一个：`wss://{host}/wss`）
  final String url;

  /// 收到 `tokenLogin` 时把那份登录态交给谁（登录页里是 `SessionService.applyQrLogin`）
  final Future<void> Function(Map<String, dynamic> data) onLogin;

  /// 便于单测注入假连接；生产为 null（走 `WebSocketChannel.connect`）
  final WsConnector? connector;

  /// 多久不带条件地重要一张二维码（服务端 token 100 秒过期）
  final Duration refreshInterval;

  final Duration heartbeatInterval;

  final ValueNotifier<QrLoginState> state = ValueNotifier<QrLoginState>(
    const QrLoginState(),
  );

  WsClient? _client;
  StreamSubscription<WsEvent>? _events;
  StreamSubscription<WsStatus>? _statuses;
  Timer? _refreshTimer;
  bool _finished = false;

  /// 开一条匿名连接去要二维码。重复调用无副作用（连上之后就一直连着）。
  void start() {
    if (_client != null || _finished) return;
    final client = WsClient(
      url: url,
      connector: connector,
      heartbeatInterval: heartbeatInterval,
      autoReconnect: true,
    );
    _client = client;
    _events = client.events.listen(_onEvent, onError: (Object _) {});
    _statuses = client.statusChanges.listen(_onStatus);
    unawaited(client.connect());
    _refreshTimer = Timer.periodic(refreshInterval, (_) => _requestQr());
  }

  /// 用户点「刷新二维码」/ 断了之后重来：重开一条连接（新的 client_id 就是新的一张码）
  void restart() {
    if (_finished) return;
    _teardown();
    state.value = const QrLoginState();
    start();
  }

  void dispose() {
    _teardown();
    state.dispose();
  }

  void _teardown() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    unawaited(_events?.cancel());
    _events = null;
    unawaited(_statuses?.cancel());
    _statuses = null;
    final client = _client;
    _client = null;
    unawaited(client?.close(graceful: false));
  }

  void _onEvent(WsEvent event) {
    switch (event.type) {
      // 连上了：报一声「我要扫码登录」，服务端据此生成二维码
      case 'init':
      // 服务端 ping（每 60 秒一次）：网页端就是在这一句里回带 isQrLogin 的
      // —— 回一句就等于换一张新码
      case 'ping':
        _requestQr();
      case 'codeLoginQr':
        final qrUrl = event.top('qrurl')?.toString() ?? '';
        if (qrUrl.isEmpty) return;
        debugPrint('[扫码登录] 二维码已就绪：$qrUrl');
        state.value = state.value.copyWith(
          qrUrl: qrUrl,
          phase: QrLoginPhase.waiting,
        );
      case 'tokenLogin':
        unawaited(_onTokenLogin(event.data));
    }
  }

  void _onStatus(WsStatus status) {
    switch (status) {
      case WsStatus.connecting:
        if (state.value.qrUrl.isEmpty) {
          state.value = state.value.copyWith(phase: QrLoginPhase.connecting);
        }
      case WsStatus.reconnecting:
        // 断线重连 = 服务端那边那条连接没了：屏幕上那张码里的 `client_id` 随之作废
        // （手机扫了也绑不上），所以不能继续假装它还有效 —— 标成失败，让用户看到
        // 「连接已断开」；重连成功、新码推回来时会自动回到 waiting。
        if (state.value.qrUrl.isEmpty) {
          state.value = state.value.copyWith(phase: QrLoginPhase.connecting);
        } else {
          state.value = state.value.copyWith(
            phase: QrLoginPhase.failed,
            message: '与服务端的连接已断开，正在重连…',
          );
        }
      case WsStatus.closed:
        if (_finished) return;
        state.value = state.value.copyWith(
          phase: QrLoginPhase.failed,
          message: '与服务端的连接已断开',
        );
      case WsStatus.idle:
      case WsStatus.connected:
        break;
    }
  }

  Future<void> _onTokenLogin(Map<String, dynamic> data) async {
    if (_finished || data.isEmpty) return;
    _finished = true;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    debugPrint('[扫码登录] 手机已确认，服务端推来了登录态');
    state.value = state.value.copyWith(phase: QrLoginPhase.confirmed);
    try {
      await onLogin(data);
    } catch (error) {
      debugPrint('[扫码登录] 登录态落盘失败：$error');
      _finished = false;
      state.value = state.value.copyWith(
        phase: QrLoginPhase.failed,
        message: '$error',
      );
      return;
    }
    // 登录态已经落到本机，这条匿名连接没用了（聊天那条连接会自己 bindUid）
    _teardown();
  }

  /// 要一张二维码（服务端只认这一句）
  void _requestQr() {
    final client = _client;
    if (client == null || _finished) return;
    client.send(const <String, dynamic>{'type': 'pong', 'isQrLogin': true});
  }
}

/// 单测用的假连接（生产为 null）：`QrLoginSession` 会把它透给 [WsClient]。
final qrLoginConnectorProvider = Provider<WsConnector?>((ref) => null);

/// 登录页二维码面板的那条会话。
///
/// `autoDispose`：离开登录页（或者切回账号密码登录）时把这条匿名连接关掉，
/// 不留一条空转的连接在服务端。
final qrLoginSessionProvider = Provider.autoDispose<QrLoginSession>((ref) {
  final session = QrLoginSession(
    url: ref.watch(appConfigProvider).wssUrl,
    connector: ref.watch(qrLoginConnectorProvider),
    onLogin: (data) => ref.read(sessionServiceProvider).applyQrLogin(data),
  );
  ref.onDispose(session.dispose);
  return session;
});
