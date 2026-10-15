// ignore_for_file: avoid_print

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/platform/callkit.dart';
import 'package:integration_test/integration_test.dart';

/// iOS 的**系统来电界面**（CallKit + PushKit）自检 —— 不是单测，要在设备/模拟器上跑。
///
/// 为什么要有它：`test/core/callkit_test.dart` 钉的是 Dart 那一层的契约
/// （参数对不对、失败会不会抛），`test/core/ios_runner_test.dart` 钉的是**源代码里
/// 该有的东西在不在**（`voip` 后台模式、推送回调里立刻上报、通道方法名对得上）。
/// 两份都**不碰真机**。而 CallKit 这件事恰恰是「代码写得再对，也可能在这台设备上
/// 根本不工作」——这条用例就是去问那台设备。
///
/// ── 它**故意**不把「来电真的弹出来了」当判据 ──────────────────────────────
/// 模拟器上 CallKit 不工作（苹果没在模拟器上实现它），而 CI 用的正是模拟器。
/// 把「一定弹得出来」写成断言，等于给自己造一条永久红。所以这里的判据是：
///
/// 1. **通道在**：`isAvailable` / `reportIncomingCall` / `voipToken` 都答得上话
///    （通道名差一个字就是 `MissingPluginException`，而那会被上层收成
///    「平台不支持」→ 功能静默消失）；
/// 2. **上报不会「既没成功也没原因」**：要么系统接下了，要么带回一条**非空**的
///    原因 —— 「锁屏没反应，而且不知道为什么」是最难查的一种；
/// 3. 能报成的时候（真机上）顺手验一次**同一通不会报两次**（锁屏上重复来电那种）。
///
/// 被叫醒那条路（推送 → PushKit → CallKit）**在这条用例里没法验**：
/// VoIP 推送投递不到模拟器（`simctl push` 也不支持它），所以它明确跳过并说清原因
/// —— 与「这台机器没麦克风」同一套口径（见 `ios_call_media_smoke_test.dart`）。
///
/// 跑法：
/// ```
/// flutter test integration_test/ios_callkit_smoke_test.dart -d <设备号>
/// ```
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final callKit = IosCallKit();

  void report(String line) {
    // 文件头已经 ignore_for_file: avoid_print
    print('[IOS-CALLKIT] $line');
  }

  /// 给一条设备调用套硬时限：超时就**以「卡住」为结论失败**，并说清卡在哪一步。
  /// （理由与 `ios_call_media_smoke_test.dart` 里那段一样：卡死等于现场全丢。）
  Future<T> withDeadline<T>(
    String label,
    Duration limit,
    Future<T> Function() action,
  ) async {
    final watch = Stopwatch()..start();
    try {
      final value = await action().timeout(
        limit,
        onTimeout: () =>
            throw TimeoutException('「$label」超过 ${limit.inSeconds} 秒没有返回'),
      );
      report('$label：${watch.elapsedMilliseconds}ms');
      return value;
    } on TimeoutException {
      report('$label：**卡住**（>${limit.inSeconds}s）');
      rethrow;
    }
  }

  testWidgets('通道在：CallKit 这条门在这台设备上是开着的', (tester) async {
    expect(callKit.supported, isTrue, reason: 'iOS 上 callKitProvider 必须给真实现');

    final available = await withDeadline(
      'isAvailable',
      const Duration(seconds: 30),
      callKit.isAvailable,
    );
    final token = await withDeadline(
      'voipToken',
      const Duration(seconds: 30),
      callKit.voipToken,
    );
    final error = await withDeadline(
      'lastError',
      const Duration(seconds: 30),
      callKit.lastError,
    );

    report('isAvailable=$available');
    report(
      'VoIP token：${token.isEmpty ? '还没有（模拟器上必然如此）' : '${token.length} 位'}',
    );
    if (error.isNotEmpty) report('上一次失败：$error');

    // 判据只有一条：通道答得上话。**不判 available 为真** —— 模拟器上是 false，
    // 那是环境事实，不是我们的 bug（见用例文件头）。
    if (!available) {
      report('SKIP：这台设备上 CallKit 不可用（模拟器上必然如此），上报那一段只作报告');
    } else {
      report('这台设备上 CallKit 可用 ✓');
    }
  });

  testWidgets('上报来电：要么系统接下，要么带回一条非空的原因', (tester) async {
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final payload =
        '{"id":"callkit-smoke-$stamp","type":"webrtc",'
        '"extends":{"event":"calling","type":0}}';

    final first = await withDeadline(
      'reportIncomingCall',
      const Duration(seconds: 30),
      () => callKit.reportIncomingCall(
        callId: 'callkit-smoke-$stamp',
        peerId: 'smoke-peer',
        peerName: '自检来电',
        video: false,
        payload: payload,
      ),
    );
    report('上报结果：$first');

    if (!first.accepted) {
      // 模拟器上走这里：**要有原因**，否则「锁屏没反应」就没法查
      expect(
        first.reason.trim(),
        isNotEmpty,
        reason: '没接下又没给原因 —— 这种失败最难查（现场只剩「没反应」三个字）',
      );
      report('SKIP：这台设备没接下这条来电（原因见上），注册与去重那两段不适用');
      return;
    }

    // 能报成（真机）：同一通再报一次必须是「已经报过了」，否则锁屏上是两条来电
    final again = await withDeadline(
      'reportIncomingCall（同一通第二次）',
      const Duration(seconds: 30),
      () => callKit.reportIncomingCall(
        callId: 'callkit-smoke-$stamp',
        peerId: 'smoke-peer',
        peerName: '自检来电',
        video: false,
        payload: payload,
      ),
    );
    report('重复上报：$again');
    expect(again.alreadyReported, isTrue, reason: '同一通报了两次 —— 锁屏上会变成两条一模一样的来电');

    // 收尾：别把这条假来电留在系统那儿（真机上会影响后面手动验收的人）
    await withDeadline(
      'reportEnded',
      const Duration(seconds: 30),
      () => callKit.reportEnded(
        callId: 'callkit-smoke-$stamp',
        reason: 'declined',
      ),
    );
    report('已收尾 ✓');
  });

  testWidgets('被划掉之后被叫醒（PushKit）：只有真机能验，这里明确跳过', (tester) async {
    // 这一条不是「没写」，是**这一层验不了**：VoIP 推送投递不到模拟器
    //（`simctl push` 也不支持），而它要证明的恰恰是「推送来了之后会怎样」。
    // 所以照实说出来，而不是写一条永远绿的假用例。
    final token = await withDeadline(
      'voipToken',
      const Duration(seconds: 30),
      callKit.voipToken,
    );
    report(
      'SKIP：VoIP 推送投递不到模拟器（simctl push 也不支持），'
      '「App 被划掉之后还能被叫醒」这条只有真机能验'
      '${token.isEmpty ? '；这台设备也还没拿到 VoIP token' : '（这台设备已经有 token）'}',
    );
  });
}
