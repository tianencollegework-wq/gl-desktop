import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 通话小窗（画中画，S6.6）—— 安卓侧的 Dart 入口。
///
/// 进小窗的**唯一入口是用户点通话页那颗「缩成小窗」**（[enter]）。
/// 回到桌面 / 划走 / 切到别的应用**不进小窗**（2026-09-19 按用户要求改的）：
/// 那几种情况下只留前台服务与常驻通知，点通知回到通话页。
/// 所以这里**刻意不用** `setAutoEnterEnabled`。
///
/// 其余行为：
/// * 小窗里**只有内容、没有任何按钮** —— 进了 PiP 之后触摸被系统接管
///   （点一下是「展开 / 菜单」，不是我们的界面），按钮画上去也点不到；
/// * **通话一结束就把小窗收掉**（[exit]，任务回后台，通话通知还在，点它回通话页）。
///
/// 抽成接口的理由与 [CallKeepAlive] 一样：平台能力只有真机能跑，而
/// 「参数什么时候交给系统、每条结束路径都要收尾」这件事必须能在单测里钉住。
abstract interface class CallPip {
  /// 这个平台有没有这条通道（安卓有；iOS 的画中画跟通话 UI 一起做，属于 S6.4）
  bool get supported;

  /// 把参数交给系统：**比例**（[video] 决定语音 1:1 / 视频 3:4）与标题。
  ///
  /// 返回**系统接没接受**（部分 ROM 关掉了画中画时为 false）。这只是体验问题，
  /// 绝不该影响通话，所以失败不抛、只让控制器记一行诊断。
  Future<bool> setParams({required bool video, String title = ''});

  /// 现在是不是正缩在小窗里（界面据此切成「只有内容、没有按钮」）
  Future<bool> isInPip();

  /// **立刻**进小窗（通话页那颗「缩成小窗」，视频通话底部那排也有一个）：
  /// 不用按 Home 离开应用。进不去（ROM 关了画中画）返回 false，不抛。
  ///
  /// 注意：Android 14+ 要求从**前台可见**的界面发起，所以它是按钮触发。
  Future<bool> enter();

  /// 退出小窗（通话结束时收尾）：不在小窗里就什么都不做。
  Future<bool> exit();

  /// 原生回调：进了 / 出了小窗。
  ///
  /// 用的是**监听表**而不是一个 setter：1:1 通话与群通话各自要一份
  /// （两条链路可能先后用同一个进程的窗口，谁是当前那一通都得知道自己在不在小窗里）。
  /// 写成 setter 的话后注册的那个会把前一个顶掉 —— 群通话挂断后 1:1 那边就再也
  /// 收不到「进/出小窗」了（而它的界面正是靠这条消息切成「只有内容」的）。
  void addModeListener(void Function(bool inPip) handler);

  /// 摘掉监听（控制器 `dispose` 时）。传进来的必须是**注册过的那个函数对象**
  /// （实例方法撕下来的 tear-off 是同一个，Dart 2.15 起保证相等）。
  void removeModeListener(void Function(bool inPip) handler);
}

/// 安卓实现：一条 MethodChannel（`MainActivity` 里的 `gracelinkim/pip`）
class AndroidCallPip implements CallPip {
  AndroidCallPip({MethodChannel? channel})
    : _channel = channel; // ignore: prefer_initializing_formals —— 可注入是为了单测

  final MethodChannel? _channel;

  static const MethodChannel _defaultChannel = MethodChannel('gracelinkim/pip');

  /// 上一次交给系统的参数：控制器在每次界面状态变化时都会来问一遍，
  /// 参数没变就不该再打一次平台通道（通话里状态变化很频繁）。
  bool? _lastVideo;
  String? _lastTitle;

  MethodChannel get _methodChannel => _channel ?? _defaultChannel;

  @override
  bool get supported => true;

  @override
  Future<bool> setParams({required bool video, String title = ''}) async {
    if (_lastVideo == video && _lastTitle == title) return true;
    try {
      final applied = await _methodChannel.invokeMethod<bool>(
        'setParams',
        <String, dynamic>{'video': video, 'title': title},
      );
      _lastVideo = video;
      _lastTitle = title;
      return applied ?? false;
    } catch (error) {
      debugPrint('[通话] 设置画中画参数失败：$error');
      return false;
    }
  }

  @override
  Future<bool> exit() async {
    try {
      return await _methodChannel.invokeMethod<bool>('exit') ?? false;
    } catch (error) {
      debugPrint('[通话] 退出画中画失败：$error');
      return false;
    }
  }

  @override
  Future<bool> isInPip() async {
    try {
      return await _methodChannel.invokeMethod<bool>('isInPip') ?? false;
    } catch (error) {
      debugPrint('[通话] 查询小窗状态失败：$error');
      return false;
    }
  }

  @override
  Future<bool> enter() async {
    try {
      return await _methodChannel.invokeMethod<bool>('enter') ?? false;
    } catch (error) {
      debugPrint('[通话] 进画中画失败：$error');
      return false;
    }
  }

  @override
  void addModeListener(void Function(bool inPip) handler) {
    // 第一条监听进来时挂平台回调，最后一条走掉时摘掉：没人听就不白占着通道
    if (_modeListeners.isEmpty) {
      _methodChannel.setMethodCallHandler((call) async {
        if (call.method == 'modeChanged') {
          for (final listener in List<void Function(bool)>.of(_modeListeners)) {
            listener(call.arguments == true);
          }
        }
        return null;
      });
    }
    _modeListeners.add(handler);
  }

  @override
  void removeModeListener(void Function(bool inPip) handler) {
    _modeListeners.remove(handler);
    if (_modeListeners.isEmpty) _methodChannel.setMethodCallHandler(null);
  }

  /// 现在听着「进 / 出小窗」的人（1:1 与群通话各自一份，互不顶掉）
  final Set<void Function(bool inPip)> _modeListeners = {};
}

/// 没有画中画的平台（iOS / 桌面）：什么都不做。
class NoopCallPip implements CallPip {
  const NoopCallPip();

  @override
  bool get supported => false;

  @override
  Future<bool> setParams({required bool video, String title = ''}) async =>
      false;

  @override
  Future<bool> isInPip() async => false;

  @override
  Future<bool> enter() async => false;

  @override
  Future<bool> exit() async => false;

  @override
  void addModeListener(void Function(bool inPip) handler) {}

  @override
  void removeModeListener(void Function(bool inPip) handler) {}
}

final callPipProvider = Provider<CallPip>(
  (ref) => Platform.isAndroid ? AndroidCallPip() : const NoopCallPip(),
);
