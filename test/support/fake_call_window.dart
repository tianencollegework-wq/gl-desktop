import 'package:gracelinkim/core/platform/call_window.dart';

/// 「通话界面盖在锁屏之上」那个窗口开关的替身：值可读，通道调用次数可数。
///
/// 调用次数要数，是因为控制器里 `_publish` 调得很频繁 —— 幂等是它必须保证的性质。
class FakeCallWindow implements CallWindow {
  FakeCallWindow({this.supported = true});

  @override
  bool supported;

  /// 现在开着吗（真机上等价于 `setShowWhenLocked` / `setTurnScreenOn`）
  bool enabled = false;

  /// 一共打过几次通道（幂等断言用）
  int setCalls = 0;

  /// 通道抛异常时控制器必须当没事发生（锁屏显示是体验，不能拖垮通话）
  Object? throwOnSet;

  @override
  Future<void> setCallScreenMode({required bool enabled}) async {
    setCalls += 1;
    final error = throwOnSet;
    if (error != null) throw error;
    this.enabled = enabled;
  }
}
