import 'shared_window_watch.dart';

/// web（以及任何没有 `dart:io` 的平台）：没有 Win32 可问，什么都不做。
WindowVisibleProbe? desktopWindowProbe() => null;
