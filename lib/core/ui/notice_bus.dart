import 'dart:async';

import 'package:flutter/foundation.dart';

/// 全局提示：把「接口层要弹的提示」和「要跳登录页」这类副作用，从网络层解耦出来。
///
/// 老端是在 `request.js` 的拦截器里直接调 `uni.showToast` / `uni.reLaunch`，
/// Flutter 端分层之后不能这么干（网络层不该依赖 UI），所以走一条通知流，
/// 由 `AppNoticeHost` 在 UI 层消费。
sealed class AppNotice {
  const AppNotice(this.message);

  final String message;
}

/// 普通提示（对应老端 `uni.showToast`）
class ToastNotice extends AppNotice {
  const ToastNotice(super.message, {this.actionLabel, this.onAction});

  /// 提示上的那颖按钮（比如「需要麦克风权限…」旁边那颗「去授权」）。
  ///
  /// 为什么需要它：安卓从第二次拒绝权限起就**不再弹系统授权框**，用户必须自己
  /// 进设置里开 —— 光说「请去系统设置里打开」等于没帮上忙。
  final String? actionLabel;
  final VoidCallback? onAction;
}

/// 需要重新登录（对应老端 `reLaunch('/pages/login/index')`）
class ReloginNotice extends AppNotice {
  const ReloginNotice(super.message);
}

class NoticeBus {
  NoticeBus();

  final StreamController<AppNotice> _controller =
      StreamController<AppNotice>.broadcast();

  Stream<AppNotice> get stream => _controller.stream;

  void toast(String message) => _emit(ToastNotice(message));

  /// 带一颗按钮的提示（按钮点了之后自己处理，比如跳系统设置）
  void toastWithAction(
    String message, {
    required String actionLabel,
    required VoidCallback onAction,
  }) =>
      _emit(ToastNotice(message, actionLabel: actionLabel, onAction: onAction));

  void requireRelogin(String message) => _emit(ReloginNotice(message));

  void _emit(AppNotice notice) {
    if (_controller.isClosed) return;
    _controller.add(notice);
  }

  void dispose() => _controller.close();
}

/// 全局单例：网络层通过它发通知，UI 层通过它订阅
final NoticeBus noticeBus = NoticeBus();
