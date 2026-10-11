import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// 打开「本应用」在系统设置里的页面（权限开关在那里）。
///
/// 为什么需要它：安卓上麦克风/摄像头权限**第二次被拒之后系统就不再弹授权框**，
/// `getUserMedia` 只会一味失败。这时提示里光说「请去系统设置里允许」等于没帮上忙，
/// 用户得自己在设置里翻半天找到这个应用。
///
/// 平台差异：
/// * 安卓：走一条自定义平台通道（`MainActivity.kt` 里那十几行）打开应用详情页，
///   `url_launcher` 打不开这个页面；
/// * iOS：`app-settings:` 这个 scheme 能直接跳到本应用的设置页。
///
/// 失败只返回 false（提示照常显示，不影响通话的收尾）。
///
/// 通知设置页 / 电池优化的那几个方法见 `background_health.dart`。
Future<bool> openAppSettings() async {
  try {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('openAppSettings');
      return true;
    }
    if (Platform.isIOS) {
      return await launchUrl(Uri.parse('app-settings:'));
    }
    return false;
  } catch (error) {
    debugPrint('[权限] 打开系统设置失败：$error');
    return false;
  }
}

/// 通道名给 `background_health.dart` 共用（两条能力都落在同一个 `MainActivity`
/// 处理器里，名字写两遍迟早写歪一个）
const String appSettingsChannelName = 'gracelinkim/app_settings';

const MethodChannel _channel = MethodChannel(appSettingsChannelName);
