import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'shared_window_watch.dart';

/// Windows：问 user32 三个问题 ——
///
/// * `IsWindow`：这个句柄还是不是一个窗口（窗口被关掉之后源就没了，别再管）；
/// * `IsIconic`：**最小化**（`ShowWindow(SW_MINIMIZE)` 之后为真）；
/// * `IsWindowVisible`：`WS_VISIBLE`（有些程序「最小化到托盘」走的是 `ShowWindow(SW_HIDE)`，
///   这时候 `IsIconic` 是假、`IsWindowVisible` 才是那条判据）。
///
/// 三个都得问：只看最小化会漏掉「藏到托盘」，只看可见会漏掉「还在桌面上但最小化了」。
///
/// ⚠️ 这里**不引 `package:ffi`**（本仓没这条依赖）：这三个函数都不需要传字符串，
/// 用 `dart:ffi` 自带的 `lookupFunction` 就够，也就没有「analyze 要干净」的麻烦。
///
/// 非 Windows 返回 null（`dart:ffi` 那条导入本身在 web 上会被条件导入挡掉，
/// 见 `window_state_probe.dart`）。
WindowVisibleProbe? desktopWindowProbe() {
  if (!Platform.isWindows) return null;
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final isWindow = user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'IsWindow',
    );
    final isIconic = user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'IsIconic',
    );
    final isVisible = user32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'IsWindowVisible',
        );
    return (hwnd) =>
        isWindow(hwnd) != 0 && isIconic(hwnd) == 0 && isVisible(hwnd) != 0;
  } on Object catch (error) {
    debugPrint('[群通话] 装不上 Win32 窗口状态绑定（不盯最小化了）：$error');
    return null;
  }
}
