import 'dart:async';

import 'package:gracelinkim/core/platform/call_keep_alive.dart';

/// 假的保活（S6.5）：记录「什么时候起、什么时候停、参数是什么」。
///
/// 真前台服务只有安卓真机能跑，但**「每条结束路径都要停干净」这件事必须在单测里钉住**
/// —— 漏一条的后果是用户手机上一直挂着「麦克风正在使用」的常驻通知。
class FakeCallKeepAlive implements CallKeepAlive {
  FakeCallKeepAlive({this.supported = true});

  @override
  final bool supported;

  /// 每次 `start` 的参数（`video=false peer=老B`），按顺序
  final List<String> starts = <String>[];

  /// `stop` 被调了几次（应当只调一次：控制器里做了幂等）
  int stops = 0;

  /// 服务当前在不在跑
  bool running = false;

  /// 起服务时抛的错（模拟系统拒绝：Android 14 的 while-in-use 校验）
  Object? startError;

  /// 让 `start` 挂在这里（模拟「起服务要几百毫秒」的异步窗口）
  Completer<void>? startBlocker;

  /// 通知权限（false 时不影响保活，只是通知不显示）
  bool notificationGranted = true;

  /// 查了几次通知权限
  int permissionChecks = 0;

  @override
  Future<void> start({required bool video, required String peerName}) async {
    final error = startError;
    if (error != null) {
      throw CallKeepAliveException('$error');
    }
    final blocker = startBlocker;
    if (blocker != null) await blocker.future;
    trace?.add('service.start');
    starts.add('video=$video peer=$peerName');
    running = true;
  }

  @override
  Future<void> stop() async {
    stops += 1;
    running = false;
    sharing = false;
  }

  /// 屏幕共享期间前台服务类型的升降（`true` = 加上 `mediaProjection`），按顺序
  final List<bool> sharingChanges = <bool>[];

  /// 服务当前带的共享类型位
  bool sharing = false;

  /// 升降类型位要抛的错（模拟系统拒绝）
  Object? sharingError;

  /// 可选的「跨层调用轨迹」：与 [FakeCallMediaEngine.trace] 用同一条列表，
  /// 好断言「先授权 → 再升类型 → 最后取屏幕流」这个**硬顺序**（S6.7）
  List<String>? trace;

  @override
  Future<void> setScreenSharing({required bool enabled}) async {
    trace?.add('service.sharing=$enabled');
    final error = sharingError;
    if (error != null) {
      throw CallKeepAliveException('$error');
    }
    sharingChanges.add(enabled);
    sharing = enabled;
  }

  @override
  Future<bool> isRunning() async => running;

  @override
  Future<bool> hasNotificationPermission() async {
    permissionChecks += 1;
    return notificationGranted;
  }

  @override
  Future<bool> requestNotificationPermission() async => notificationGranted;
}
