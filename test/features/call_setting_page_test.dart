import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/platform/background_health.dart';
import 'package:gracelinkim/core/platform/call_keep_alive.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/ui/notice_bus.dart';
import 'package:gracelinkim/data/model/global_config.dart';
import 'package:gracelinkim/features/mine/call_setting_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「设置 › 音视频通话」这一页（2026-10-10）。
///
/// 起因是用户那句：「电脑端设置的音视频通话点开是啥都没有的这体验很不好，要么有
/// 东西，要么就不要有这一栏」。原来那两行开关都是**安卓专属**（`supported ==
/// false` 时各自 `SizedBox.shrink()` 掉），桌面上点进来就是一张白纸。
///
/// 所以这份用例**特意把平台钉成「那两行都不存在」的样子**，验这一页仍然有真东西：
/// 「通话线路」一行 + 点开后的明细。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late List<MethodCall> platformCalls;
  late List<AppNotice> notices;
  late StreamSubscription<AppNotice> noticeSub;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    platformCalls = <MethodCall>[];
    // 剪贴板要过平台通道，测试里截下来看看复制了什么（与诊断面板那条一样的做法）
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          platformCalls.add(call);
          return null;
        });
    notices = <AppNotice>[];
    noticeSub = noticeBus.stream.listen(notices.add);
    addTearDown(noticeSub.cancel);
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    ChatInfo chatInfo = const ChatInfo(),
  }) async {
    // 竖屏高一点：弹层里那几段清单都得在同一屏里
    tester.view.physicalSize = const Size(1170, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // 桌面那一份：没有前台服务、也没有全屏通知开关（两行都不画）
          callKeepAliveProvider.overrideWithValue(const NoopCallKeepAlive()),
          backgroundHealthProvider.overrideWithValue(
            const NoopBackgroundHealth(),
          ),
        ],
        child: const MaterialApp(home: CallSettingPage()),
      ),
    );
    container = ProviderScope.containerOf(
      tester.element(find.byType(CallSettingPage)),
    );
    container
        .read(sessionStoreProvider.notifier)
        .applyConfig(
          GlobalConfig(
            sysInfo: const SysInfo(),
            chatInfo: chatInfo,
            compass: const CompassConfig(),
            demonMode: false,
          ),
        );
    await tester.pumpAndSettle();
  }

  testWidgets('桌面上那两行不在，但这一页不是白纸：有「通话线路」', (tester) async {
    await pumpPage(tester);

    expect(find.text('通话线路'), findsOneWidget);
    expect(find.text('仅 STUN'), findsOneWidget);
    // 正是这两行让桌面上原本什么都没有
    expect(find.text('通话保活通知'), findsNothing);
    expect(find.text('来电全屏显示'), findsNothing);
  });

  testWidgets('点开：六条公共 STUN + 站点那一段 + 一句人话结论', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('通话线路'));
    await tester.pumpAndSettle();

    expect(find.text('公共 STUN（客户端固定）'), findsOneWidget);
    expect(find.text('stun:stun.xten.com'), findsOneWidget);
    expect(find.text('stun:stun.l.google.com:19302'), findsOneWidget);
    expect(find.text('站点配置的线路'), findsOneWidget);
    expect(find.text('站点没有配置，用的是客户端兜底地址'), findsOneWidget);
    expect(find.text('stun:stun.callwithus.com'), findsOneWidget);
    expect(find.text('不需要账号'), findsOneWidget);
    expect(find.textContaining('没有可用的 TURN'), findsOneWidget);
    // 内置 TURN 现在是空的 -> 那一段不画
    expect(find.text('客户端内置 TURN'), findsNothing);
  });

  testWidgets('站点配了 TURN：行上是「已配置 TURN」，明细一字不差，凭据不露面', (tester) async {
    await pumpPage(
      tester,
      chatInfo: const ChatInfo(
        stun: 'stun:stun.cloudflare.com:3478, turn:turn.example.com:3478',
        stunUser: 'user-1',
        stunPass: 'secret-pass-123',
      ),
    );

    expect(find.text('已配置 TURN'), findsOneWidget);
    expect(find.text('仅 STUN'), findsNothing);

    await tester.tap(find.text('通话线路'));
    await tester.pumpAndSettle();

    expect(find.text('stun:stun.cloudflare.com:3478'), findsOneWidget);
    expect(find.text('turn:turn.example.com:3478'), findsOneWidget);
    expect(find.text('需要账号鉴权（已配置）'), findsOneWidget);
    expect(find.textContaining('已经配了 TURN'), findsOneWidget);
    // 只报「配没配」，绝不把账号密码摆出来
    expect(find.textContaining('secret-pass-123'), findsNothing);
    expect(find.textContaining('user-1'), findsNothing);
  });

  testWidgets('站点漏写 turn: 前缀：行上只能算「仅 STUN」，明细里橙字指出来', (tester) async {
    // 这是很容易犯的一个错：填了 `turn.example.com:3478` 却没有前缀，客户端会把它
    // 当 STUN 发出去 —— 行上说「仅 STUN」是**实话**（当前确实没有 TURN 可用），
    // 点开就能看到那句话到底为什么。
    await pumpPage(
      tester,
      chatInfo: const ChatInfo(stun: 'turn.example.com:3478'),
    );

    expect(find.text('仅 STUN'), findsOneWidget);

    await tester.tap(find.text('通话线路'));
    await tester.pumpAndSettle();

    expect(find.text('stun:turn.example.com:3478'), findsOneWidget);
    expect(
      find.text(
        '站点填的「turn.example.com:3478」会被当作 STUN 发出去；要用 TURN 得写成 turn:主机:端口',
      ),
      findsOneWidget,
    );
  });

  testWidgets('复制线路：把清单复制出去并提示一句', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('通话线路'));
    await tester.pumpAndSettle();

    // 弹层比窗口矮，但按钮在最下面，稳妥起见还是先滚过去
    await tester.ensureVisible(find.text('复制线路'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制线路'));
    await tester.pumpAndSettle();

    final copy = platformCalls.firstWhere(
      (call) => call.method == 'Clipboard.setData',
    );
    final text = (copy.arguments as Map<Object?, Object?>)['text']! as String;
    expect(text, contains('stun:stun.xten.com'));
    expect(text, contains('stun:stun.callwithus.com'));
    expect(
      notices.whereType<ToastNotice>().map((notice) => notice.message),
      contains('线路信息已复制'),
    );
  });
}
