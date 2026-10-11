import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../store/credential_store.dart';
import 'ws_client.dart';
import 'ws_event.dart';
import 'ws_handlers.dart';
import 'ws_router.dart';

/// WS 服务：把「连接」和「事件分发」粘起来，并对外暴露连接状态。
///
/// 老端是 `main.js` 里 `new socketIO()` 全局单例 + `App.vue` 里 `uni.$on` 监听，
/// 这里换成 Riverpod provider + 流，业务层不再需要全局事件总线。
class WsService {
  WsService({required this.client}) {
    router.registerAll(
      protocolWsHandlers(
        client: client,
        store: CredentialStore.instance,
        onClientId: (clientId) {
          _clientId = clientId;
          onClientReady?.call(clientId);
        },
        onMultiport: (value) => _multiport = value,
      ),
    );
  }

  final WsClient client;

  /// 事件路由。后续里程碑的业务处理器用 `service.router.register(...)` 挂上来。
  final WsRouter router = WsRouter();

  /// 连接就绪（收到 `init`）后的回调，上层用它触发 `bindUid`。
  ///
  /// 老端是在 `App.vue` 的 `init` 分支里直接干这件事；这里拆开，
  /// 免得协议层（M1）依赖会话层（M2）。
  void Function(String clientId)? onClientReady;

  final StreamController<WsStatus> _statusController =
      StreamController<WsStatus>.broadcast();

  StreamSubscription<WsEvent>? _eventSubscription;
  StreamSubscription<WsStatus>? _statusSubscription;

  bool _started = false;
  bool _multiport = false;
  String? _clientId;

  bool get isStarted => _started;

  WsStatus get status => client.status;

  bool get isConnected => client.isConnected;

  /// 连接状态流。
  ///
  /// **先吐当前这一帧**，再转发后续变化：`_statusController` 是广播流、不重放，
  /// 只转发的话，在「已经连上」之后才订阅的人永远收不到第一帧，界面就停在
  /// 「连接中…」直到下一次状态变化（用户 2026-09-30 报的：装好包一进消息页
  /// 一直显示连接中，点一下右边那颗刷新才消失）—— 会话页正是在首帧之后才建的：
  /// `main()` 里 `bootstrap()` 已经把 WS 连上，`runApp` 之后才轮到它订阅。
  Stream<WsStatus> get statusChanges async* {
    yield client.status;
    yield* _statusController.stream;
  }

  /// 发一帧（未连接时返回 false，老端同样是静默失败）
  bool send(Map<String, dynamic> payload) => client.send(payload);

  /// 是否多端在线（老端消息页那句"PC 在线"）
  bool get multiport => _multiport;

  /// 服务端分配的连接 id，来自 `init` 事件；`bindUid` 要用它
  String? get clientId => _clientId;

  void start() {
    if (_started) return;
    _started = true;

    _eventSubscription = client.events.listen(router.dispatch);
    _statusSubscription = client.statusChanges.listen((status) {
      debugPrint('[WS] 状态：${status.name}');
      if (!_statusController.isClosed) _statusController.add(status);
    });

    unawaited(client.connect());
  }

  /// 主动关闭（退出登录、被顶下线、切换账号时调用）。不会自动重连。
  Future<void> stop() async {
    _started = false;
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    await _statusSubscription?.cancel();
    _statusSubscription = null;
    // client_id 是**这条连接**的身份（服务端 `init` 分配的），连接一断就没意义了。
    // 不清的话，换账号后到新连接就绪之前，`bindGroup` 这类事会拿着一个已经死掉的
    // client_id 去绑（`chat_sync_service.bindGroupClient` 判定“有 id 就发”）。
    // 注意：持久化的 `CredentialStore.clientId` 不动 —— 退出登录那个接口要用它。
    _clientId = null;
    await client.close();
  }

  Future<void> restart() async {
    await stop();
    start();
  }

  void dispose() {
    _eventSubscription?.cancel();
    _statusSubscription?.cancel();
    _statusController.close();
  }
}

final wsClientProvider = Provider<WsClient>((ref) {
  final client = WsClient(url: ref.watch(appConfigProvider).wssUrl);
  ref.onDispose(client.dispose);
  return client;
});

final wsServiceProvider = Provider<WsService>((ref) {
  final service = WsService(client: ref.watch(wsClientProvider));
  ref.onDispose(service.dispose);
  return service;
});

/// 给 UI 用的连接状态流（会话页那条"连接已断开"提示）
final wsStatusProvider = StreamProvider<WsStatus>((ref) {
  final service = ref.watch(wsServiceProvider);
  return service.statusChanges;
});
