import 'package:flutter/foundation.dart';

/// 路由守卫读的会话快照。
///
/// go_router 的 `redirect` 在路由表里是**顶层闭包**，拿不到 Riverpod 的容器；
/// 所以由启动代码监听 `sessionStoreProvider` 并把结果写到这里，
/// 再通过 `refreshListenable` 通知路由重新计算跳转。
///
/// 两个字段都是刻意的：
/// * [ready]——本地会话是否已恢复。未恢复时停在启动页，避免先闪一下登录页；
/// * [hasSession]——本地有没有登录态（老端是等接口 401 才把人踢去登录页）。
class SessionGuard extends ChangeNotifier {
  SessionGuard();

  bool _ready = false;
  bool _hasSession = false;

  bool get ready => _ready;
  bool get hasSession => _hasSession;

  void update({required bool ready, required bool hasSession}) {
    if (_ready == ready && _hasSession == hasSession) return;
    _ready = ready;
    _hasSession = hasSession;
    notifyListeners();
  }
}

/// 全局单例：`main()` 里绑定到 `sessionStoreProvider`
final SessionGuard sessionGuard = SessionGuard();
