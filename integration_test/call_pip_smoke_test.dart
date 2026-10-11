import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/platform/call_pip.dart';
import 'package:integration_test/integration_test.dart';

/// 通话小窗（画中画，S6.6）的真机自检（**不是单测**）。
///
/// 验的是用户要求的那条行为（2026-09-19 改版后）：
///
/// * **回到桌面 / 划走不进小窗**：只留前台服务 + 常驻通知（`setParams` 不开自动缩窗）；
/// * **点「缩成小窗」才进**（`enter`），进去之后 `exit()` 收掉；
/// * 比例：语音 1:1、视频 3:4（进小窗后可以量窗口尺寸）。
///
/// 布局长什么样由单测钉（`test/features/call_page_test.dart`），这里只管系统那一半。
///
/// 跑法（**用 drive 而不是 `flutter test integration_test`**，后者跑完会卸载应用）：
/// ```
/// flutter drive --driver=test_driver/integration_test.dart \
///   --target=integration_test/call_pip_smoke_test.dart -d <设备号> --keep-app-running
/// ```
///
/// ## 需要「人按一次 Home」
/// 第一段自检会打一行标记然后等窗口期，此时按 Home 或划回桌面：
/// ```
/// [PIP] READY no-auto   ← 现在按 Home（adb shell input keyevent 3）
/// [PIP] CHECK no-auto   ← 窗口期结束，这里会断言「并没有缩窗」
/// [PIP] ENTER voice     ← 程序自己调 enter()，此时可以截图/dumpsys 量尺寸
/// [PIP] ENTER video     ← 同上，这次是 3:4
/// ```
///
/// ## 2026-09-19 真机结果（S23 Ultra / Android 14）
/// 自动缩窗那一版：按 Home 后 `isInPip()` 立刻为 true（当时是我们要的）。
/// 改成「只点按钮才进」之后再跑这条自检，`CHECK no-auto` 应当读回 false。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// 每段留多久给 adb 截图 / 手动观察
  const holdSeconds = 20;

  final pip = AndroidCallPip();

  void report(String line) {
    // ignore: avoid_print
    print('[PIP] $line');
  }

  Future<bool> waitUntil(
    Future<bool> Function() probe, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await probe()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }

  /// 小窗里显示什么由通话页决定；自检里换一块**一眼能认出来的**内容，
  /// 这样截图就能确认「小窗里确实是我们的画面、并且铺满了窗口」
  Future<void> pumpProbeScreen(WidgetTester tester, String label) async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: const Color(0xFF07C160),
          body: Center(
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('mode=no-auto：把参数交给系统之后，按 Home **不进**小窗', (tester) async {
    expect(pip.supported, isTrue);
    await pumpProbeScreen(tester, 'no-auto\n语音');

    final accepted = await pip.setParams(video: false, title: '自检');
    report('setParams(video=false) => $accepted');
    expect(accepted, isTrue, reason: '系统应当接受小窗参数');

    report('READY no-auto（现在按 Home）');
    await Future<void>.delayed(const Duration(seconds: holdSeconds));

    final inPip = await pip.isInPip();
    report('CHECK no-auto：按 Home 之后 isInPip = $inPip');
    expect(inPip, isFalse, reason: '用户要求「滑到后台默认不出小窗」——这里必须是 false');
  });

  testWidgets('mode=enter：enter() 立刻进小窗（语音 1:1），exit() 收掉', (tester) async {
    await pumpProbeScreen(tester, 'enter\n语音 1:1');

    expect(await pip.enter(), isTrue, reason: '点按钮应当能进小窗');
    final entered = await waitUntil(pip.isInPip);
    report('ENTER voice = $entered');
    expect(entered, isTrue);
    expect(await pip.isInPip(), isTrue);

    await Future<void>.delayed(const Duration(seconds: holdSeconds));

    await pip.exit();
    final left = await waitUntil(() async => !await pip.isInPip());
    report('EXIT voice = $left');
    expect(left, isTrue);
  });

  testWidgets('mode=video：enter() 进的是 3:4 小窗', (tester) async {
    await pumpProbeScreen(tester, 'enter\n视频 3:4');
    await pip.setParams(video: true, title: '自检');

    expect(await pip.enter(), isTrue, reason: '点按钮应当能进小窗');
    final entered = await waitUntil(pip.isInPip);
    report('ENTER video = $entered');
    expect(entered, isTrue);

    await Future<void>.delayed(const Duration(seconds: holdSeconds));

    await pip.exit();
    final left = await waitUntil(() async => !await pip.isInPip());
    report('EXIT video = $left');
    expect(left, isTrue);
  });
}
