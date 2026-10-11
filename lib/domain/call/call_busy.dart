import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'call_controller.dart';

/// 「现在是不是正打着 1:1 电话」（S6.15）。
///
/// 群通话的入口都要过这一道：一条链路一只麦克风、一块屏幕，两通电话同时开着
/// 只会把两边都弄坏（老网页端也没有这个场景）。判据本身在 `CallController.view`
/// 这个 `ValueNotifier` 里，拎成 provider 之后有两样好处：
///
/// * 界面 `ref.watch` 就能跟着变 —— 群通话的横幅在 1:1 电话期间不出现，
///   那通电话一挂，横幅立刻能出来（不用等下一次推送）；
/// * 测试里可以直接换掉（见 [CallBusyNotifier] 的子类替身）—— 造一个
///   「正在通话」的真控制器要一整条媒体链路，那是 `<feature>_test` 的地盘。
class CallBusyNotifier extends Notifier<bool> {
  @override
  bool build() {
    final view = ref.watch(callControllerProvider).view;
    void sync() => state = view.value.isActive;
    // 通话状态是 `ValueNotifier`（不是 provider），所以自己挂一次监听；
    // 控制器被换掉（登录/登出）时 provider 会重建，那时顺手摘掉旧的
    view.addListener(sync);
    ref.onDispose(() => view.removeListener(sync));
    return view.value.isActive;
  }
}

final callBusyProvider = NotifierProvider<CallBusyNotifier, bool>(
  CallBusyNotifier.new,
);
