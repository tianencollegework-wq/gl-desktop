import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../router/app_router.dart';
import '../store/session_store.dart';
import '../ws/ws_service.dart';
import 'notice_bus.dart';
import 'wechat_toast.dart';

/// 全局 ScaffoldMessenger。
///
/// 全局提示**不再走它**（S7.6 起统一走 [WeChatToastLayer] 那种居中浮层，
/// 见 [NoticeHandler]）；它还留着是给页面自己那种贴着底边的 `SnackBar` 用
/// （目前只有通话诊断面板「导出日志 + 打开」那一条）。
final GlobalKey<ScaffoldMessengerState> appMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// 消费全局通知。
///
/// 对应老端在 `utils/request.js` 拦截器里直接 `uni.showToast` / `uni.reLaunch`，
/// Flutter 端把这两件事挪到这里，网络层只负责发通知（见 notice_bus.dart）。
///
/// 提示的**长相**在 [WeChatToastLayer]（屏幕正中那块深色圆角盒子，微信的位置），
/// 这一层只管「谁、什么时候」：
///
/// * 普通提示 → 弹一句；
/// * [ReloginNotice] → 弹一句 + 断连接 + 清会话（路由守卫随后把人送回登录页）。
///
/// 另：同一句提示**只弹一次**是 [WeChatToastLayer.show] 的规矩（同一句还在屏幕上
/// 时不重复弹）—— 接口层默认会弹一遍、有些页面 catch 到之后又弹一遍，两边发出来的
/// 是同一句话，靠它吞掉（S7.6）。
class NoticeHandler {
  NoticeHandler(this._container);

  final ProviderContainer _container;
  StreamSubscription<AppNotice>? _subscription;

  /// 提示浮层：挂在根 Navigator 的 Overlay 上（换页不会被带走）
  late final WeChatToastLayer _toast = WeChatToastLayer(
    overlayOf: () => _container
        .read(appRouterProvider)
        .routerDelegate
        .navigatorKey
        .currentState
        ?.overlay,
  );

  void start() {
    _subscription = noticeBus.stream.listen(_onNotice);
  }

  Future<void> _onNotice(AppNotice notice) async {
    switch (notice) {
      case ToastNotice():
        _toast.show(
          notice.message,
          actionLabel: notice.actionLabel,
          onAction: notice.onAction,
        );
      case ReloginNotice():
        _toast.show(notice.message);
        // 老端是直接 reLaunch 到登录页；这里先清会话与连接，
        // 再由路由守卫把人送到登录页（见 core/router/session_guard.dart），
        // 避免"清了会话但页面还停在主界面"的中间态。
        await _container.read(wsServiceProvider).stop();
        _container.read(sessionStoreProvider.notifier).clearSession();
    }
  }

  void dispose() {
    _toast.dispose();
    _subscription?.cancel();
  }
}
