import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/platform/desktop_shell.dart';

/// **电脑端窗口的最小宽度必须挡住手机版式**（用户 2026-10-09 定的堵法）。
///
/// 为什么值得钉：窗口窄到 [kDesktopFrameMinWidth] 以下就从三栏退回**手机版式**，
/// 而那一版是把账号密码表单直接摊在页面上的 —— 等于绕开了「密码登陆只对美国出口
/// IP 开放」那道闸门（`features/login/password_login_policy.dart`）。所以 win32
/// runner（以及 macOS 的 `macos/Runner/MainFlutterWindow.swift`）里那个最小客户区
/// 宽度**必须 ≥ [kDesktopFrameMinWidth]**。
///
/// 这个洞的危险之处在于它是**静悄悄回来的**：Dart 那侧一个用例都不会红，只有人手
/// 把窗口拖窄才会看见。所以这里直接读 C++ 源码把数字钉住（与 `branding_test.dart`
/// 读 `Runner.rc` 是同一个路子）。
void main() {
  // 行尾统一成 `\n`：这两个文件在 Windows 上是 CRLF
  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  /// 从源码里取一个 `const int 名字 = 数字;`（取不到就让用例带着名字红）
  int intConstant(String source, String name, String file) {
    final match = RegExp(
      'const int $name = (\\d+);',
    ).firstMatch(source);
    expect(
      match,
      isNotNull,
      reason: '$file 里找不到 `const int $name = 数字;`（改过名字就把这条用例一起改）',
    );
    return int.parse(match!.group(1)!);
  }

  group('桌面窗口的最小尺寸挡住手机版式', () {
    test('win32_window.cpp：最小客户区宽度 ≥ kDesktopFrameMinWidth', () {
      final source = read('windows/runner/win32_window.cpp');
      final minWidth = intConstant(source, 'kMinClientWidth', 'win32_window.cpp');
      expect(
        minWidth,
        greaterThanOrEqualTo(kDesktopFrameMinWidth),
        reason:
            '小于 $kDesktopFrameMinWidth 就能把窗口拉成手机版式，'
            '那一版的账号密码表单不过地域闸门',
      );
    });

    test('win32_window.cpp：高度也有个下限（600）', () {
      final source = read('windows/runner/win32_window.cpp');
      expect(
        intConstant(source, 'kMinClientHeight', 'win32_window.cpp'),
        greaterThanOrEqualTo(600),
      );
    });

    test('main.cpp：初始宽度与「收窄时的下限」都在那一档之上', () {
      final source = read('windows/runner/main.cpp');
      expect(
        intConstant(source, 'kInitialWidth', 'main.cpp'),
        greaterThanOrEqualTo(kDesktopFrameMinWidth),
        reason: '初始就是手机版式的话，一开出来就看见那一版',
      );
      // 屏幕比窗口还窄时（小笔记本 / 竖屏）会把初始宽度收一收，那个下限同样不能在
      // 阈值之下 —— 否则那些机器上一开出来就是手机版式
      final floor = RegExp(
        r'std::max\((\d+), work_width - 80\)',
      ).firstMatch(source);
      expect(
        floor,
        isNotNull,
        reason: 'main.cpp 里那句收窄的写法变了，同步这条用例',
      );
      expect(
        int.parse(floor!.group(1)!),
        greaterThanOrEqualTo(kDesktopFrameMinWidth),
      );
    });

    test('MainFlutterWindow.swift：最小内容区尺寸也要够宽', () {
      // macOS 那一半（2026-10-11）：同一道闸门，另一边也得堵上 ——
      // 那边是 `contentMinSize`，写在 awakeFromNib 里（这是个静态常量，
      // 只认 "NSSize(width: 数字, height: 数字)" 这一种写法）。
      final source = read('macos/Runner/MainFlutterWindow.swift');
      final match = RegExp(
        r'NSSize\(width: (\d+), height: (\d+)\)',
      ).firstMatch(source);
      expect(
        match,
        isNotNull,
        reason:
            'MainFlutterWindow.swift 里那个 contentMinSize 的写法变了，'
            '同步这条用例（不要把这条闸门一起去掉）',
      );
      expect(
        int.parse(match!.group(1)!),
        greaterThanOrEqualTo(kDesktopFrameMinWidth),
        reason: '与 win32_window.cpp 同一个理由：窄窗会把账号密码表单放出来',
      );
      expect(int.parse(match.group(2)!), greaterThanOrEqualTo(600));
    });
  });
}
