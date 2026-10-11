import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// App 是不是在前台（老端 `App.vue` 里的 `appStatus`）。
///
/// 老端用它决定「收到消息要不要建通知栏」：`if(!appStatus && ...)`。
/// 新端同样要这个判断，但注册观察者的地方从页面挪到了
/// `NotificationHost`（挂在 Navigator 之上，任何页面上都管用），
/// 这样聊天页、设置页、通话页都不需要各自关心生命周期。
class AppForeground extends Notifier<bool> {
  /// 初始值直接问引擎（还没挂上生命周期观察者时 `lifecycleState` 可能是 null ——
  /// 那按「在前台」处理，免得启动瞬间把应用内提示音变成一条通知）
  @override
  bool build() {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  /// 只由 [NotificationHost] 的生命周期回调驱动
  void update(bool value) {
    if (state != value) state = value;
  }
}

final appForegroundProvider = NotifierProvider<AppForeground, bool>(
  AppForeground.new,
);
