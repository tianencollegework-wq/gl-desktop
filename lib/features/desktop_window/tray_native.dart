/// 系统托盘（Windows 桌面，S12.36）跟 native 说话的入口 —— runner 里那条
/// `gracelinkim/tray`。
///
/// 用户 2026-10-06 要的是微信那套：「你从 Windows 底部栏右边那个小箭头点开还能
/// 看到，应用没有真正被关掉」。所以关窗只是**缩回托盘**：进程、WebSocket、铃声
/// 全都留着，来电和消息照样收得到；真退出只有托盘菜单里那一项。
///
/// 缩窗 / 恢复 / 菜单 / 气泡全在原生（见 `windows/runner/tray_icon.cpp` 与
/// `flutter_window.cpp` 里 `WM_CLOSE` 那一手），Dart 这边只负责**把文字递过去**。
/// 为什么要递：托盘菜单上的字得跟着 App 语言走，而语言包（`assets/i18n` 那 7 份）
/// 只有 Dart 读得到 —— 原生那边一个字都不翻译。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/i18n/app_i18n.dart';

class TrayNative {
  const TrayNative._();

  static const MethodChannel _channel = MethodChannel('gracelinkim/tray');

  /// 上一次配过去的语言码。
  ///
  /// 调用点在 [GracelinkApp] 的 `build` 里（语言一变那里就会重建），所以这份
  /// 去重是必需的：同一种语言只过一次通道。
  static String? _configured;

  /// 托盘那三句文案（纯函数，单测直接钉）。
  ///
  /// 三个 key 都在 7 份语言包里（`test/core/i18n_keys_test.dart` 会守着）：
  /// 菜单第一项「打开 Gracelink」、第二项「退出」、以及第一次缩进托盘时那个气泡。
  static Map<String, String> payloadOf(AppI18n i18n) => <String, String>{
    'open': i18n.t('tray.open'),
    'exit': i18n.t('tray.exit'),
    'balloon': i18n.t('tray.balloon'),
  };

  /// 把当前语言的托盘文案配过去。
  ///
  /// 通道没注册（手机 / 网页 / 老 runner）就静默忽略：托盘上顶多没字，
  /// **不该因此影响启动**。失败也算配过（同一个语言不反复重试、不刷日志）——
  /// 真机上这条通道一定在，失败只可能是「这台机器上本来就没有托盘」。
  static Future<void> configure(AppI18n i18n) async {
    final code = i18n.localeCode;
    if (code == _configured) return;
    _configured = code;
    try {
      await _channel.invokeMethod<void>('configure', payloadOf(i18n));
    } on Object catch (error) {
      debugPrint('[托盘] 文案没配上（忽略）：$error');
    }
  }

  /// 单测用：把那道「同一语言不重复配」的记忆清掉
  @visibleForTesting
  static void resetForTest() => _configured = null;
}
