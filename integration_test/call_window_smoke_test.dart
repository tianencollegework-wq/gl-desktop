import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/features/call/call_window_host.dart';
import 'package:gracelinkim/features/desktop_window/child_window_app.dart';
import 'package:gracelinkim/features/desktop_window/window_args.dart';
import 'package:integration_test/integration_test.dart';

/// 通话独立窗口的真机自检（2026-10-04）。
///
/// 跑的**就是产品那条路**：`MultiWindowCallWindowTransport` 真开一颗引擎
/// （子引擎里 `main()` 分流到 `runDesktopChildWindow` → 通话窗那套界面 + 本地真
/// 媒体引擎），然后把媒体指令、状态推送、关窗走一遍。它回答的是组件测试答不了的
/// 那几件事：
///
/// * Windows 上这颗窗到底开不开得出来、子引擎会不会真的把那条线挂上；
/// * 冷启动那几百毫秒里「多试几次」这套重试能不能等到它；
/// * 真取一次麦克风（媒体引擎真的在通话窗那颗引擎里）；
/// * 挂断时那句 `bye` 能不能让窗口自己关掉。
///
/// 还有一条**对照**：先开一颗文章窗（早就验过的那条路）并 ping 它 —— 要是连它
/// 也叫不应，那就说明是这台机器/这次运行的环境问题（比如会话锁着、引擎起不来），
/// 而不是通话窗这一段写错了。
///
/// ⚠️ **2026-10-04 实测：`flutter test -d windows` 这条路验不了窗口**，所以这两条
/// 用例是 `skip` 的（留着当证据与配方，别删）：
///
/// * 子引擎继承的是 `--target` 指的那个入口（本文件），而 `flutter test` 给它的
///   是个**监听器包装**（`flutter_test_listener.dart`），它先跟测试宿主握手 ——
///   子引擎里那一步永远等不到，我们的 `main` 压根不会执行（日志里连一行子窗
///   日志都没有）；
/// * 于是子窗既不注册通道也不画界面：对照那条里**早就验过的文章窗**也
///   `CHANNEL_UNREGISTERED`（`[SMOKE] 对照：文章窗 1 → 2，叫应=false`）。
///
/// 结论：窗口类功能只能跑**真 App**（`flutter run -d windows` 或 release 包）
/// 用鼠标验；通道那一层改由「假原生」契约测试盯着（`test/features/call_window_test.dart`
/// 里的「传输层（假原生）」那组）。这段自检等哪天 Flutter 的测试宿主不再包入口点
/// 了可以直接去掉 `skip`。
///
/// 怎么跑（会先重建 debug，别和正在跑的 release 实例搞混）：
/// `flutter test integration_test/call_window_smoke_test.dart -d windows`
///
/// （`testWidgets` 的 `skip` 只认 bool，原因就写在上面这段与下面两处注释里。）

/// 这颗引擎是窗口（子引擎）吗？是就把窗口那张界面跑起来，并告诉调用方「到此为止」。
Future<bool> _bootChildWindowIfNeeded() async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    final current = await WindowController.fromCurrentEngine();
    final raw = current.arguments;
    if (raw.isEmpty) return false;
    debugPrint('[SMOKE] 这颗引擎是窗口（${current.windowId}）：$raw');
    return await runDesktopChildWindow(<String>[
      'multi_window',
      current.windowId,
      raw,
    ]);
  } on Object catch (error) {
    debugPrint('[SMOKE] 没认出窗口身份（当主窗口继续）：$error');
    return false;
  }
}

Future<void> main() async {
  // ⚠️ 子引擎继承的就是**本文件这个入口点**（`flutter test -d windows` 把
  // `--target` 指向它），所以这里要自己认出「我是不是一颗窗口」并把子窗那条路
  // 走起来 —— 不然子引擎跑的是测试 main：既不注册通道也不画界面，自检永远等不到
  // 回应（2026-10-04 实测：连早就验过的**文章窗**都 CHANNEL_UNREGISTERED）。
  //
  // 认的办法是问原生：「我这颗引擎的窗口参数是什么」（`getWindowDefinition`）；
  // 主窗口那条返回空参数，自然就往下走测试。
  //
  // 不能靠 `main(List<String> args)`：测试那个入口是 `FutureOr<dynamic> Function()`
  // （自行生成的 `flutter_test_listener.dart`），带参数就直接编译不过。
  if (await _bootChildWindowIfNeeded()) return;

  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // 跳过的原因见文件头：这条在 flutter test -d windows 下**必定失败**（子引擎跑
  // 的是测试监听器，不是我们的 main）
  testWidgets('对照：文章窗照样开得出来、叫得应', skip: true, (tester) async {
    final before = await WindowController.getAll();
    await WindowController.create(
      WindowConfiguration(
        arguments: const DesktopWindowArgs.article(
          id: 'smoke-1',
          title: '自检文章',
        ).encode(),
        hiddenAtLaunch: true,
      ),
    );
    Object? lastError;
    var answered = false;
    // 与 `desktop_window_service.dart::_revive` 同一套：ping 得通才算真活着
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      try {
        await WindowMethodChannel(
          'gracelink/window/article',
          mode: ChannelMode.unidirectional,
        ).invokeMethod<dynamic>('ping').timeout(const Duration(seconds: 5));
        answered = true;
        break;
      } on Object catch (error) {
        lastError = error;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    final after = await WindowController.getAll();
    debugPrint(
      '[SMOKE] 对照：文章窗 ${before.length} → ${after.length}，'
      '叫应=$answered（${lastError ?? '没有报错'}）',
    );
    expect(answered, isTrue, reason: '文章窗是早就验过的路，它都不通就是环境问题');
  });

  testWidgets('通话窗：开一颗真窗、媒体指令往返、推状态、关掉', skip: true, (tester) async {
    final before = await WindowController.getAll();
    debugPrint('[SMOKE] 开窗前窗口数=${before.length}');

    final transport = MultiWindowCallWindowTransport();
    transport.plan(
      const CallWindowSpec(
        peerId: 'peer-smoke',
        peerName: '集成自检',
        video: false,
        isCaller: true,
        // 公共 STUN：这条自检只取本机麦克风，不真连对方
        iceServers: <Map<String, dynamic>>[
          <String, dynamic>{'urls': 'stun:stun.cloudflare.com:3478'},
        ],
      ),
    );

    final openedAt = DateTime.now();
    // 1) 媒体指令往返：真取麦克风（子引擎冷启动那条空档也在这条路上）
    await transport.invokeMedia('open', <String, dynamic>{'video': false});
    final openMs = DateTime.now().difference(openedAt).inMilliseconds;

    final during = await WindowController.getAll();
    debugPrint('[SMOKE] 开窗后窗口数=${during.length}（open 用了 ${openMs}ms）');

    // 2) 再来一条往返：媒体统计（拿不到也必须是空采样，不许抛）
    final stats = await transport.invokeMedia('sampleStats');
    debugPrint('[SMOKE] 统计=${stats is Map ? stats.length : stats}');

    // 3) 界面状态推送（真机上这决定那一屏画什么）
    await transport.pushState(<String, dynamic>{
      'phase': 'connected',
      'peerId': 'peer-smoke',
      'peerName': '集成自检',
      'video': false,
      'isCaller': true,
      'callTime': 3,
      'microphoneEnabled': true,
    });

    // 4) 挂断：让窗口自己关掉
    await transport.closeWindow();
    // 关窗是子引擎那边的事，给它一点时间（真机上按窗口销毁回收引擎）
    await Future<void>.delayed(const Duration(seconds: 2));
    final after = await WindowController.getAll();
    debugPrint('[SMOKE] 关窗后窗口数=${after.length}');

    debugPrint(
      '[SMOKE] call window OK windows ${before.length} → ${during.length} '
      '→ ${after.length}',
    );
    expect(during.length, greaterThan(before.length), reason: '通话窗真的开了');
  });
}
