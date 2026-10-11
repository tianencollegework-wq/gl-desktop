import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_foreground.dart';
import '../../core/platform/background_health.dart';

/// 会话列表顶部那条红色提示条**要说什么**。
///
/// 对照老端 `pages/message/index.vue` 第 26、27 行：两条 `uni-notice-bar` 是
/// `v-if` / `v-else-if`，也就是**一次只显示一条**。
///
/// 与老端不同（刻意的）：老端那条「系统开启了省电优化」**去掉了**
/// （用户 2026-09-27 要求：「这个红色横幅也很丑，而且也有推送通知了要这个干嘛」）。
/// 它当初的理由是「切后台 WS 被冻结 → 消息收不到」，而现在消息靠**厂商推送**
/// 唤醒，那条链子断了照样收得到 —— 再顶一条常驻红条只会吓人。
/// 平台那侧的能力（`BackgroundHealth.ignoringBatteryOptimizations`）留着，
/// 以后有别的用途再挂上去。
///
/// 另一条「来电全屏显示未开启」也**从红条里去掉了**（用户 2026-09-30：
/// 「首页顶部那条红色横幅删掉，通话提醒就在发起通话之前弹窗提示就好了啊」）——
/// 它现在是拨号前弹一次的白框（`core/ui/permission_gate.dart` 的
/// `remindFullScreenBeforeCall`），设置里那一行照旧。
/// 所以这条红提示只剩「通知权限没开」一种：那是真的「消息收不到」，值得常驻。
enum SystemHealthHint {
  /// 都正常，不显示提示条
  none,

  /// 通知权限没开：后台收到消息也弹不出通知栏（`system.notNotify`）
  notification,
}

/// 一次检查的结果（纯数据，方便单测直接构造）
class SystemHealth {
  const SystemHealth({required this.notificationGranted});

  /// 都正常（也用作「查不出来」时的值：不误报）
  static const SystemHealth ok = SystemHealth(notificationGranted: true);

  final bool notificationGranted;

  /// 该显示哪条提示
  SystemHealthHint get hint =>
      resolveSystemHealthHint(notificationGranted: notificationGranted);
}

/// 决定显示哪条提示（纯函数：老端那两条 `v-if` / `v-else-if` 的等价写法）
///
/// 省电优化那条**故意不再有**（2026-09-27 去掉，见 [SystemHealthHint]）；
/// 「来电全屏显示」那条 2026-09-30 也搬到了拨号前的弹窗里，不再常驻。
SystemHealthHint resolveSystemHealthHint({required bool notificationGranted}) =>
    notificationGranted ? SystemHealthHint.none : SystemHealthHint.notification;

/// 系统开关的当前状态。
///
/// **什么时候重新查**（这是这个 provider 存在的全部理由）：
/// * 进消息列表时查一次（`build`）；
/// * **App 回到前台时再查一次** —— 用户点提示条去系统设置里改完回来，
///   提示条必须自己消失（老端是在 `App.vue` 的 `onShow` 里重查的）。
///
/// 用 [AsyncNotifier] 而不是普通 Notifier：查询本身是平台通道的异步调用，
/// 加载中（`valueOrNull == null`）时界面**什么都不显示**，而不是先闪一条错提示。
class SystemHealthNotifier extends AsyncNotifier<SystemHealth> {
  bool _checking = false;

  @override
  Future<SystemHealth> build() async {
    ref.listen(appForegroundProvider, (previous, next) {
      // 只在「从后台回到前台」时重查，别在切出去那一刻查
      if (next && previous != true) unawaited(refresh());
    });
    return _check();
  }

  Future<SystemHealth> _check() async {
    final health = ref.read(backgroundHealthProvider);
    if (!health.supported) return SystemHealth.ok;
    return SystemHealth(
      notificationGranted: await health.notificationGranted(),
    );
  }

  /// 重新查一遍（回到前台、或刚点完提示条）
  ///
  /// 刻意**不先置 loading**：那样提示条会闪一下（消失再出现）。重查期间保留
  /// 上一次的结论，查完再整体替换。
  Future<void> refresh() async {
    if (_checking) return;
    _checking = true;
    try {
      state = AsyncValue<SystemHealth>.data(await _check());
    } catch (error, stack) {
      state = AsyncValue<SystemHealth>.error(error, stack);
    } finally {
      _checking = false;
    }
  }

  /// 点提示条：去把对应那道开关打开（跳系统设置），跳完立刻重查一次。
  ///
  /// 通知那条是**跳设置页**而不是弹系统授权框：进到消息列表时已经问过一次了
  /// （见 `NotificationHost` 那条通知权限引导），用户当时拒绝之后系统不会再弹框，
  /// 只能去设置里手动打开。
  Future<void> fixHint(SystemHealthHint hint) async {
    final health = ref.read(backgroundHealthProvider);
    switch (hint) {
      case SystemHealthHint.notification:
        await health.openNotificationSettings();
      case SystemHealthHint.none:
        return;
    }
    await refresh();
  }
}

final systemHealthProvider =
    AsyncNotifierProvider<SystemHealthNotifier, SystemHealth>(
      SystemHealthNotifier.new,
    );
