import 'shared_window_watch.dart';
// web 上没有 Win32（也没有 `dart:ffi`）——条件导入让 web 那份直接返回 null。
import 'window_state_probe_stub.dart'
    if (dart.library.io) 'window_state_probe_io.dart' as impl;

/// 拿一个「这扇窗还在、没被最小化、还可见」的探针。
///
/// 拿不到就返回 null：**非 Windows（安卓/iOS/macOS/Linux/web）与装不上绑定时**都是
/// null —— 调用方看到 null 就什么都不做（屏幕共享照旧，只是没有「最小化回来重建」
/// 这一层兜底）。
WindowVisibleProbe? desktopWindowProbe() => impl.desktopWindowProbe();
