import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/features/home/home_shell.dart';
import 'package:gracelinkim/features/login/login_page.dart';
import 'package:gracelinkim/features/splash/splash_page.dart';
import 'package:gracelinkim/main.dart' as app;
import 'package:integration_test/integration_test.dart';

/// 「这台机器上到底能不能把 App 跑起来」的自检（**不是单测**，要在真设备上跑）。
///
/// 为什么非要这么一个东西：`flutter build macos --release` 成功只证明**编得过**。
/// Mac 那条链上真正没底的从来不是编译，而是「装出来以后起不起得来」——
/// 而开发机是 Windows，编不了 macOS，本地连跑一次的机会都没有。
/// 所以这条用例交给 CI 上的 Mac：**真的走一遍 `main()`**，看界面有没有走到登录页。
///
/// 跑法：
/// ```
/// flutter test integration_test/boot_smoke_test.dart -d macos     # CI 上跑这个
/// flutter test integration_test/boot_smoke_test.dart -d windows    # 本地 Windows 也能跑
/// ```
///
/// 判据为什么用**类型**、而不是找某句文案：CI 那台 Mac 的系统语言是英文，
/// 界面会跟着落英文，写死中文文案的断言在那边必红（而本地是绿的）——
/// 那种「本地好好的、CI 一直红」的用例比没有更坏。
///
/// 判据为什么是「登录页**或**主界面」而不是只认登录页：这台机器上有没有登录态
/// 决定了它落哪儿（路由守卫会自己跳）。开发机上有登录态（`shared_preferences` 里
/// 躺着 token），本地跑就会落到主界面；CI 那台机器是干净的，会落登录页。
/// 两者都证明同一件事：**它起来了、并且画出了真界面**。
///
/// ⚠️ 这条用例**会连外网**（`main()` 里那套 WS / 全局配置都是生产路径）。
/// 这是故意的：它要验的就是「真启动」，不是「干净环境里启动」。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    '从零启动：能跑到登录页',
    (tester) async {
      final started = DateTime.now();
      // ignore: avoid_print
      print('[SMOKE] 开始启动：${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}');

      // 真走一遍 main()：本地存储、语言包、路由守卫、WS、通话链路
      // 全按生产路径来 —— 这正是「装出来的包能不能起来」这件事本身
      await app.main(const <String>[]);

      // 不用 `pumpAndSettle`：主界面有常驻的定时器 / 长连接，settle 等到天荒地老也不会到
      // —— 那个已知的「macOS 上挂住」的坑，一半就踩在这种等法上。改成「有上限地轮询」。
      // 等它自己从启动页走到真界面（两个目标都算过，见文件头）
      final landed = await _waitForAny(
        tester,
        <String, Finder>{
          '登录页': find.byType(LoginPage),
          '主界面': find.byType(HomeShell),
        },
        timeout: const Duration(seconds: 90),
      );

      // 起不来时这几行是唯一的线索来源，所以无条件打出来
      // ignore: avoid_print
      print('[SMOKE] 落在=$landed，'
          '耗时=${DateTime.now().difference(started).inSeconds}s，'
          '仍停在启动页=${find.byType(SplashPage).evaluate().isNotEmpty}');

      expect(
        landed,
        isNotNull,
        reason:
            '90 秒内没走到登录页也没走到主界面 —— '
            '要么卡在启动那一路，要么界面根本没起来（看上面那行「仍停在启动页」）',
      );
      // 启动过程中不该有没接住的异常（接了又吞的不算，那种会走 debugPrint）
      expect(tester.takeException(), isNull);

      // 收尾：把「已经起来的这一份」拆掉，免得留一堆常驻定时器
      //（真机自检是一次性的，进程随后就退了）
      // ignore: avoid_print
      print('[SMOKE] 启动自检通过');
    },
    // 上限比 CI 那一步的 timeout 小：让它**先于** runner 掐断而失败，
    // 这样日志里能看到是这条用例自己判的死，而不是被 runner 杀掉
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

/// 有上限地等**若干个**目标里的任意一个命中，命中就把它名字还回来。
///
/// `pumpAndSettle` 在这里不能用（见上面注释）：它等的是「没有帧在排了」，
/// 而生产启动路径里有一堆常驻的东西，永远排不到头。
Future<String?> _waitForAny(
  WidgetTester tester,
  Map<String, Finder> targets, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 200));
    for (final entry in targets.entries) {
      if (entry.value.evaluate().isNotEmpty) return entry.key;
    }
  }
  return null;
}
