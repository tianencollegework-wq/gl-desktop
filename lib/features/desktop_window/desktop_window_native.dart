/// 子窗口跟 native 说话的入口（runner 里那条 `gracelinkim/child_window`）。
///
/// 为什么自己要一条通道：`desktop_multi_window` 原生只给了 `window_show` /
/// `window_hide`，标题、尺寸、居中都得自己出；而且这些动作只有**子窗口自己**
/// 方便做 —— 它是 `hiddenAtLaunch` 建的，得等标题/大小就绪了再叫它显形，
/// 免得先闪一下 800×600 的默认样子。
///
/// 全部方法都吞异常：万一（非 Windows / 通道没注册）拿不到就用默认样子，
/// 窗口照样能用，不该因此崩掉。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class DesktopWindowNative {
  const DesktopWindowNative._();

  static const MethodChannel _channel = MethodChannel(
    'gracelinkim/child_window',
  );

  /// 用户按了 ✕（或 Alt+F4）时原生先来问一声 —— 装过处理就走它，没装原生直接销毁。
  static Future<void> Function()? _onCloseRequested;

  /// 原生标题栏那行字（中文会走 UTF-8 → UTF-16 转过去）
  static Future<void> setTitle(String title) =>
      _guard(() => _channel.invokeMethod<void>('setTitle', title));

  /// 逻辑像素的窗口尺寸（native 那边按窗口所在显示器的 DPI 折算）
  static Future<void> setSize(double width, double height) => _guard(
    () => _channel.invokeMethod<void>('setSize', <String, double>{
      'w': width,
      'h': height,
    }),
  );

  /// 居中到自己那块屏的工作区
  static Future<void> center() =>
      _guard(() => _channel.invokeMethod<void>('center'));

  /// 显形（窗口是 hiddenAtLaunch 建的）
  static Future<void> show() =>
      _guard(() => _channel.invokeMethod<void>('show'));

  /// 从窗口自己这边要求关掉它：**真销毁**（窗口和引擎一起释放，见
  /// `windows/runner/flutter_window.cpp`）。
  ///
  /// ⚠️ S12.29 起它**不再**是「等于用户按 ✕」：✕ 那条会先回头问 [onCloseRequested]
  /// （谁有活要收就自己收），这个是「我已经收完了，拆吧」。所以叫它之前要把该放
  /// 的放干净 —— 通话窗那颗媒体引擎还活着就拆引擎，webrtc 会在拆音频设备时
  /// abort 整个进程（见 [onCloseRequested] 的注释）。
  static Future<void> close() =>
      _guard(() => _channel.invokeMethod<void>('close'));

  /// 进 / 出**画中画小窗**（桌面，2026-10-05）：通话窗那一颗。
  ///
  /// 进小窗 = 原生把那扇窗改造成：无边框 + 不占任务栏（`WS_EX_TOOLWINDOW`）
  /// + 置顶（`HWND_TOPMOST`）+ 挪到工作区右下角 [width]×[height]（逻辑像素）；
  /// 出来 = **原样还回去**（样式与位置都是进之前存下的那一份）。
  ///
  /// 返回**这台机器上做没做成**：通道没注册（非 Windows / 老版本 runner）就
  /// 回 false —— 界面据此把版式切回去，绝不弄成「界面以为在小窗里、窗口还是大的」。
  static Future<bool> setPip({
    required bool on,
    required double width,
    required double height,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('setPip', <String, dynamic>{
            'on': on,
            'w': width,
            'h': height,
          }) ??
          false;
    } on Object catch (error) {
      debugPrint('[窗口] 画中画没做成（保持原样）：$error');
      return false;
    }
  }

  /// 拖窗那三下（小窗里按住画面拖）：`begin` 记住按下时的光标与窗口位置，
  /// `update` 按当前光标算位移，`end` 收摊。
  ///
  /// 位移为什么不在 Dart 这边算：窗口一跟着动，指针在窗里的局部坐标也跟着变，
  /// 两边一抵消就拖不动了（详见 runner 里那份 `DragState` 的注释）。
  static Future<void> dragBegin() =>
      _guard(() => _channel.invokeMethod<void>('dragBegin'));

  static Future<void> dragUpdate() =>
      _guard(() => _channel.invokeMethod<void>('dragUpdate'));

  static Future<void> dragEnd() =>
      _guard(() => _channel.invokeMethod<void>('dragEnd'));

  /// 装上「用户按 ✕ 了」这一手（原生先问，答完它就不自己销毁了）。
  ///
  /// 为什么要有这一手：**本机媒体还活着的时候拆那颗引擎，webrtc 会 abort 整个
  /// 进程**（2026-10-05 真机实测：通话中按 ✕，事件日志 `gracelinkim.exe`
  /// 异常代码 `0xc0000409`，两次都在 `[窗口] 开始销毁子窗口` 之后、
  /// `[窗口] 子窗口销毁返回` 之前；对照：点窗里那颗「挂断」（先 `engine.close()`
  /// 再关窗）一切正常）。
  ///
  /// 所以通话窗要装这一手：先把媒体放干净、再叫 [close]；**文章窗 / 网页窗不装
  /// —— 原生那边拿到 ✕ 就**直接关**（它们没有要收的活）。
  ///
  /// ⚠️ 2026-10-08 改过一刀：**装上这一手才等于向原生声明「这扇窗的 ✕ 交给我」**
  /// （先发一条 `guardClose`）。在那之前是反过来的——不管哪扇窗，✕ 都先吞下来
  /// 问 Dart，而没装这一手的窗压根没人答，窗口就**永远关不掉**（用户报的
  /// 「灵听/媒体号一出来就点叉关不掉」）。
  ///
  /// [handler] 是异步的，但原生**不等**它跑完（答应一声就往下走），所以 handler
  /// 自己要保证「最后一定把窗关掉」（见 `call_window.dart::_onCloseRequested`）；
  /// 原生那边还配了一道超时兜底，真收不完也不会把窗留在那儿。
  static void onCloseRequested(Future<void> Function() handler) {
    _onCloseRequested = handler;
    unawaited(_declareGuardClose());
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'close_requested') {
        throw MissingPluginException('窗口不认识这个调用：${call.method}');
      }
      final current = _onCloseRequested;
      if (current == null) {
        throw MissingPluginException('这扇窗没接 ✕；原生那边会照老路直接销毁');
      }
      unawaited(current());
      return <String, dynamic>{'ok': true};
    });
  }

  /// 告诉原生「这扇窗的 ✕ 先交给我收摊」（没声明的窗一律直接关）。
  ///
  /// 失败只记一行：**绝不能因此不让窗口装这一手** —— 老 runner 上没有这个
  /// 方法（MissingPluginException），那时退回到原生那套「先问 Dart 再说」，
  /// 通话窗的行为与以前一模一样。
  static Future<void> _declareGuardClose() async {
    try {
      await _channel.invokeMethod<void>('guardClose');
    } on Object catch (error) {
      debugPrint('[窗口] 没能声明「✕ 自己收摊」（老 runner？）：$error');
    }
  }

  static Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      debugPrint('[窗口] native 动作失败（忽略）：$error');
    }
  }
}
