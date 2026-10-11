import 'package:gracelinkim/domain/call/call_controller.dart';

/// 手动推进的计时器。
///
/// 组件测试里不能用真的 `Timer.periodic`：它每隔一秒就会让通话页重建一次，
/// `pumpAndSettle` 永远等不到静止（与上传进度圈、录音秒数同一个坑）。
/// 用这个替身可以精确控制「过了几秒」——拨号超时、通话时长都靠它推。
class ManualCallTicker implements CallTicker {
  void Function()? _onTick;

  /// `start` / `stop` 被调用了几次
  int starts = 0;
  int stops = 0;

  bool get running => _onTick != null;

  @override
  void start(void Function() onTick) {
    _onTick = onTick;
    starts += 1;
  }

  @override
  void stop() {
    _onTick = null;
    stops += 1;
  }

  /// 往前走 [seconds] 秒（没在跑就什么都不发生）
  void tick([int seconds = 1]) {
    for (var i = 0; i < seconds; i++) {
      _onTick?.call();
    }
  }
}
