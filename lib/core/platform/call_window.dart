import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 这条通道名（原生那半在 `MainActivity.kt` 里）
const String callWindowChannelName = 'gracelinkim/call_window';

/// 通话界面能不能**盖在锁屏之上**（S8.1n）。
///
/// 两个理由，都来自真机：
///
/// 1. **离线叫醒的来电要整屏弹出来。** 被推送唤醒的来电靠「全屏通知」
///    （full-screen intent）把 Activity 拉起来，但那只是「系统愿意让这个通知
///    启动界面」——**Activity 还得自己声明要盖在锁屏之上**
///    （`setShowWhenLocked` / `setTurnScreenOn`，安卓 8.1+）。不声明的话，
///    即使全屏通知被放行、Activity 也真的起来了，用户看到的**仍然是锁屏**
///    （系统退回成一条横幅）；声明了才会像微信那样整屏出来电界面、屏幕亮起。
/// 2. **通话中锁屏**：通话期间锁一下屏，来电/通话界面照样显示
///    （否则声音通着、界面被锁屏盖住）。
///
/// 抽成接口的理由与 `CallKeepAlive` / `CallPip` 一致：平台能力只有真机能验，
/// 而「什么时候开、什么时候关」必须能在单测里钉住。
abstract interface class CallWindow {
  /// 这个平台有没有这套开关（只有安卓有）
  bool get supported;

  /// 开 / 关（调用方会**每次会话状态变化都调**，实现要自己幂等）
  Future<void> setCallScreenMode({required bool enabled});
}

/// 安卓实现：走 `MainActivity.kt` 里那条 `gracelinkim/call_window` 通道。
///
/// 失败一律只记日志：锁屏显示是体验，**绝不能让通话因为它挂掉**。
class AndroidCallWindow implements CallWindow {
  // ignore: prefer_initializing_formals —— 可注入是为了单测能替掉那条通道
  const AndroidCallWindow({MethodChannel? channel}) : _channel = channel;

  final MethodChannel? _channel;

  static const MethodChannel _defaultChannel = MethodChannel(
    callWindowChannelName,
  );

  MethodChannel get _methodChannel => _channel ?? _defaultChannel;

  @override
  bool get supported => true;

  @override
  Future<void> setCallScreenMode({required bool enabled}) async {
    try {
      await _methodChannel.invokeMethod<void>(
        'setCallScreenMode',
        <String, dynamic>{'enabled': enabled},
      );
    } catch (error) {
      debugPrint('[通话窗口] 设置锁屏显示失败：$error');
    }
  }
}

/// 其它平台（iOS / 桌面）：什么都不做。
///
/// iOS 那条路是 CallKit（来电界面由系统画），跟这里的窗口开关是两件事。
class NoopCallWindow implements CallWindow {
  const NoopCallWindow();

  @override
  bool get supported => false;

  @override
  Future<void> setCallScreenMode({required bool enabled}) async {}
}

final callWindowProvider = Provider<CallWindow>(
  (ref) =>
      Platform.isAndroid ? const AndroidCallWindow() : const NoopCallWindow(),
);
