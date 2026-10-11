import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/domain/call/call_diagnostics.dart';
import 'package:gracelinkim/features/call/call_diagnostics_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 通话诊断面板：把「打不通 / 黑屏 / 没声音」变成能看的一屏数据。
///
/// 这里只验面板本身（结论、候选、时间线、空态），采集逻辑在
/// `test/call/call_diagnostics_test.dart`，接线在 `test/call/call_controller_test.dart`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> platformCalls;

  setUp(() async {
    // 语言包要过 CredentialStore（记住用户选的语言），测试里得先初始化它
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    platformCalls = <MethodCall>[];
    // 剪贴板要经过平台通道，测试里截下来看看复制了什么（与聊天页那条一样的做法）
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          platformCalls.add(call);
          return null;
        });
  });

  Future<void> pumpSheet(
    WidgetTester tester,
    ValueListenable<CallDiagnostics> source,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () => showCallDiagnosticsSheet(context, source),
                  child: const Text('打开诊断'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开诊断'));
    await tester.pumpAndSettle();
  }

  testWidgets('有通话记录：结论 / 候选 / 时间线都在，且能复制', (tester) async {
    final recorder =
        CallDiagnosticsRecorder(clock: () => DateTime(2026, 9, 19, 21, 3, 12))
          ..begin(
            video: true,
            caller: true,
            peer: '老B',
            iceServers: const <String>['stun:stun.cloudflare.com:3478（无账号）'],
          );
    recorder
      ..localCandidate('candidate:1 1 udp 2130706431 192.168.1.5 5000 typ host')
      ..localCandidate(
        'candidate:2 1 udp 1 203.0.113.7 5001 typ srflx raddr 0 rport 0',
      )
      ..signalSent('calling')
      ..setConnected(true);

    await pumpSheet(
      tester,
      ValueNotifier<CallDiagnostics>(recorder.snapshot()),
    );

    // 结论（最值钱的那行）
    expect(find.text('已连通：点对点直连（P2P）'), findsOneWidget);
    // 候选按类型分开数
    expect(find.textContaining('本机 2（host 1 / srflx 1）'), findsOneWidget);
    // 时间线里也有 ICE 状态
    expect(find.textContaining('ICE 已连通'), findsOneWidget);
    // ICE 服务器一字不差地摆出来（少个 stun: 前缀就打不通）
    expect(find.textContaining('stun.cloudflare.com:3478'), findsOneWidget);
    // 时间线与信令
    expect(find.textContaining('+0.00s  开始拨号'), findsOneWidget);
    expect(find.textContaining('calling 1'), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('导出日志'), findsOneWidget);

    // 面板比测试窗口高，按钮在下面：先滚过去再点
    await tester.ensureVisible(find.text('复制'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    // 复制出去的就是那份可粘贴的诊断文本
    final copy = platformCalls.firstWhere(
      (call) => call.method == 'Clipboard.setData',
    );
    final text = (copy.arguments as Map<Object?, Object?>)['text']! as String;
    expect(text, contains('通话诊断 · 2026-09-19 21:03:12'));
    expect(text, contains('结论：已连通'));
  });

  testWidgets('还没通过话：只说一句「还没有通话记录」，不给复制/导出', (tester) async {
    await pumpSheet(
      tester,
      ValueNotifier<CallDiagnostics>(const CallDiagnostics.empty()),
    );

    expect(find.text('通话诊断'), findsOneWidget);
    expect(find.textContaining('还没有通话记录'), findsOneWidget);
    expect(find.text('复制'), findsNothing);
    expect(find.text('导出日志'), findsNothing);
    expect(find.text('关闭'), findsOneWidget);
  });

  testWidgets('通话中面板跟着快照实时长（新候选 / 新信令）', (tester) async {
    final recorder = CallDiagnosticsRecorder(
      clock: () => DateTime(2026, 9, 19, 21, 3, 12),
    )..begin(video: false, caller: true, peer: '老B');
    final source = ValueNotifier<CallDiagnostics>(recorder.snapshot());

    await pumpSheet(tester, source);
    expect(find.textContaining('一条本机候选都没有'), findsOneWidget);

    // 新来一条 relay 候选 → 面板重绘
    recorder
      ..localCandidate('candidate:1 1 tcp 1 10.0.0.2 9 typ relay')
      ..setConnected(true);
    source.value = recorder.snapshot();
    await tester.pumpAndSettle();

    expect(find.textContaining('一条本机候选都没有'), findsNothing);
    expect(find.textContaining('本机 1（relay 1）'), findsOneWidget);
    expect(
      find.text('已连通：本机只有 relay 候选，只能走 TURN 中转'),
      findsOneWidget,
      reason: '走中转要明说（直连没打成功）',
    );
  });
}
