import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_settings.dart' show appSettingsChannelName;

/// 后台能不能收到消息的**两道系统开关**（老端 `store/login.js` 里的
/// `systemNotify` / `systemBattery`）。
///
/// 为什么需要它们：这一版的消息到达**完全靠 WS 长连接**（见 REFACTOR_PLAN 的
/// S8 推送那一节）。而 WS 活着的前提是**进程活着**，进程能不能活着由系统的两个
/// 开关说了算：
///
/// * **通知权限**（`POST_NOTIFICATIONS`，安卓 13+）：关着 = 后台收到消息也**弹不出
///   通知栏**，用户等于不知道有人找过他；
/// * **电池优化**：没把本应用加入白名单 = 切后台几分钟后进程会被冻结，WS 断开，
///   **消息都收不到**（不只是不弹）。
///
/// 老端把这两条做成了消息列表顶部的**红色提示条**（`pages/message/index.vue` 的
/// `uni-notice-bar`），本端照做（见 `features/notify/system_health_banner.dart`）。
///
/// 抽成接口的理由与 `CallKeepAlive` / `MediaSaver` 一样：平台能力只有真机能验，
/// 而「什么时候该提示、点一下跳哪里」必须能在单测里钉住。
abstract interface class BackgroundHealth {
  /// 这个平台有没有「系统可能会让你收不到消息」这类开关。
  ///
  /// 安卓有两道（通知权限 + 电池优化），iOS 只有一道（通知权限，
  /// 电池那条在这边根本不存在），桌面没有 —— 但三端走的都是这一个接口，
  /// 界面只问「要不要显示那行/那条提示」。
  bool get supported;

  /// 通知权限开着吗（安卓 13 以下恒为 true）
  Future<bool> notificationGranted();

  /// 本应用已被系统排除在电池优化之外吗
  Future<bool> ignoringBatteryOptimizations();

  /// 跳到本应用的通知设置页（用户去手动打开）
  Future<bool> openNotificationSettings();

  /// 本应用能用「全屏通知」吗（S8.1h）。
  ///
  /// 全屏通知 = 息屏/锁屏时来电**直接亮屏弹来电界面**。安卓 14 起系统
  /// **只给「通话类应用」自动授权**，其它应用默认关着；关着时来电会降级成
  /// 横幅 + 响铃（照样能接，只是没那么醒目），所以这条只用来在设置页给一行入口，
  /// **不进消息列表那条红提示条**（不是病，别去烦用户）。
  ///
  /// 查不出来 / 版本太低一律算「允许」（不误报）。
  Future<bool> fullScreenIntentAllowed();

  /// 跳到本应用的全屏通知设置页（安卓 14 以下返回 false：那时没有这个页面）
  Future<bool> openFullScreenIntentSettings();

  /// 申请「忽略电池优化」（系统弹确认框；弹不出来就打开电池优化列表页）
  Future<bool> requestIgnoreBatteryOptimizations();
}

/// 安卓实现：走 `MainActivity.kt` 里那条 `gracelinkim/app_settings` 通道。
///
/// 所有查询**失败一律偏向「正常」**（通知=开、电池=已忽略）：查不出来就不该拿着
/// 一条红提示条去烦用户 —— 那是误报，比漏报更招人烦。
class AndroidBackgroundHealth implements BackgroundHealth {
  // ignore: prefer_initializing_formals —— 可注入是为了单测能替掉那条通道
  const AndroidBackgroundHealth({MethodChannel? channel}) : _channel = channel;

  final MethodChannel? _channel;

  static const MethodChannel _defaultChannel = MethodChannel(
    appSettingsChannelName,
  );

  MethodChannel get _methodChannel => _channel ?? _defaultChannel;

  @override
  bool get supported => true;

  @override
  Future<bool> notificationGranted() async {
    try {
      return await _methodChannel.invokeMethod<bool>(
            'notificationPermission',
          ) ??
          true;
    } catch (error) {
      debugPrint('[后台开关] 查询通知权限失败：$error');
      return true;
    }
  }

  @override
  Future<bool> ignoringBatteryOptimizations() async {
    try {
      return await _methodChannel.invokeMethod<bool>(
            'isIgnoringBatteryOptimizations',
          ) ??
          true;
    } catch (error) {
      debugPrint('[后台开关] 查询电池优化状态失败：$error');
      return true;
    }
  }

  @override
  Future<bool> openNotificationSettings() =>
      _invoke('openNotificationSettings');

  @override
  Future<bool> requestIgnoreBatteryOptimizations() =>
      _invoke('requestIgnoreBatteryOptimizations');

  @override
  Future<bool> fullScreenIntentAllowed() async {
    try {
      return await _methodChannel.invokeMethod<bool>(
            'fullScreenIntentAllowed',
          ) ??
          true;
    } catch (error) {
      debugPrint('[后台开关] 查询全屏通知权限失败：$error');
      return true;
    }
  }

  @override
  Future<bool> openFullScreenIntentSettings() =>
      _invoke('openFullScreenIntentSettings');

  /// 「跳转」类的调用：跳不跳得成不影响提示条该不该在，所以只记日志。
  Future<bool> _invoke(String method) async {
    try {
      await _methodChannel.invokeMethod<void>(method);
      return true;
    } catch (error) {
      debugPrint('[后台开关] $method 失败：$error');
      return false;
    }
  }
}

/// iOS 实现：**只有「通知权限」那一道是真的**，电池那条在 iOS 上不存在。
///
/// 为什么 iOS 也要接（而不是继续用 Noop）：iPhone 上用户把通知关掉之后，
/// 后台收消息这件事就没了 —— 消息进了库、提示音响了，通知栏里空空如也，
/// 锁屏时用户根本不知道有人找过他。那正是会话列表顶部那条红提示条
/// （`system.notNotify`）想说的事，与安卓一模一样。
///
/// 三处「安卓有、iOS 没有」的地方就直接如实回答（而不是伪造一个状态）：
/// * 电池优化白名单 —— iOS 不存在这个东西，后台能不能干活由
///   `UIBackgroundModes` 与音频会话决定（已在 Info.plist 里声明），所以恒 true；
/// * 「全屏通知」开关 —— 那是安卓 14 才有的东西，来电界面在 iOS 上是应用自己画的；
/// * 通知设置页的深链 —— iOS 只有 `openSettingsURLString`（本应用的设置页），
///   通知、麦克风、相机都在那一页里，没有更细的页面可跳。
class IosBackgroundHealth implements BackgroundHealth {
  // ignore: prefer_initializing_formals —— 可注入是为了单测能替掉那条通道
  const IosBackgroundHealth({MethodChannel? channel}) : _channel = channel;

  final MethodChannel? _channel;

  static const MethodChannel _defaultChannel = MethodChannel(
    appSettingsChannelName,
  );

  MethodChannel get _methodChannel => _channel ?? _defaultChannel;

  @override
  bool get supported => true;

  @override
  Future<bool> notificationGranted() async {
    try {
      return await _methodChannel.invokeMethod<bool>(
            'notificationPermission',
          ) ??
          true;
    } catch (error) {
      // 查不出来就不该拿着一条红提示条去烦用户（与安卓那份同一个口径）
      debugPrint('[后台开关] 查询通知权限失败：$error');
      return true;
    }
  }

  /// iOS 没有「电池优化白名单」：后台能收到消息靠的是系统的静默推送
  /// （`UIBackgroundModes: remote-notification`）与音频会话，与省电策略无关。
  @override
  Future<bool> ignoringBatteryOptimizations() async => true;

  @override
  Future<bool> openNotificationSettings() => _openSettings('openNotificationSettings');

  @override
  Future<bool> requestIgnoreBatteryOptimizations() async => false;

  @override
  Future<bool> fullScreenIntentAllowed() async => true;

  @override
  Future<bool> openFullScreenIntentSettings() async => false;

  /// 跳转类的调用：跳不跳成不影响提示条该不该在，所以只记日志。
  Future<bool> _openSettings(String method) async {
    try {
      await _methodChannel.invokeMethod<void>(method);
      return true;
    } catch (error) {
      debugPrint('[后台开关] $method 失败：$error');
      return false;
    }
  }
}

/// 没有这些开关的平台（桌面）：都当成正常，不提示。
class NoopBackgroundHealth implements BackgroundHealth {
  const NoopBackgroundHealth();

  @override
  bool get supported => false;

  @override
  Future<bool> notificationGranted() async => true;

  @override
  Future<bool> ignoringBatteryOptimizations() async => true;

  @override
  Future<bool> openNotificationSettings() async => false;

  @override
  Future<bool> requestIgnoreBatteryOptimizations() async => false;

  @override
  Future<bool> fullScreenIntentAllowed() async => true;

  @override
  Future<bool> openFullScreenIntentSettings() async => false;
}

final backgroundHealthProvider = Provider<BackgroundHealth>((ref) {
  if (Platform.isAndroid) return const AndroidBackgroundHealth();
  if (Platform.isIOS) return const IosBackgroundHealth();
  return const NoopBackgroundHealth();
});
