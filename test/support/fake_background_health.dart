import 'package:gracelinkim/core/platform/background_health.dart';

/// 「后台收不收得到消息」那两道系统开关的替身：值可读可改，跳转动作记次数。
///
/// 两个「去设置」的动作都顺手把对应开关置为正常 —— 真机上用户就是在跳过去那一步
/// 打开的，回来时界面应当因此把提示条收掉。
class FakeBackgroundHealth implements BackgroundHealth {
  FakeBackgroundHealth({
    this.notification = true,
    this.battery = true,
    this.fullScreenIntent = true,
  });

  bool notification;
  bool battery;

  /// 来电全屏显示（S8.1h）：安卓 14+ 默认关着，不影响收来电
  bool fullScreenIntent;
  int openedNotificationSettings = 0;
  int requestedBattery = 0;
  int openedFullScreenIntentSettings = 0;

  /// 有些平台（iOS/桌面）根本没有这两道开关，界面上不该出现提示条
  bool platformSupported = true;

  @override
  bool get supported => platformSupported;

  @override
  Future<bool> notificationGranted() async => notification;

  @override
  Future<bool> ignoringBatteryOptimizations() async => battery;

  @override
  Future<bool> fullScreenIntentAllowed() async => fullScreenIntent;

  @override
  Future<bool> openFullScreenIntentSettings() async {
    openedFullScreenIntentSettings += 1;
    fullScreenIntent = true;
    return true;
  }

  @override
  Future<bool> openNotificationSettings() async {
    openedNotificationSettings += 1;
    notification = true;
    return true;
  }

  @override
  Future<bool> requestIgnoreBatteryOptimizations() async {
    requestedBattery += 1;
    battery = true;
    return true;
  }
}
