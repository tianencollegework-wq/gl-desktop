import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/platform/call_keep_alive.dart';
import 'package:integration_test/integration_test.dart';

/// iOS 通话保活的自检（**不是单测**，要在设备/模拟器上跑）。
///
/// 为什么要有它：`boot_smoke_test.dart` 只证明「App 起得来」，**一步都没走通话**；
/// 而 iOS 上真正没底的是我们**自己那段 Swift**
/// （`ios/Runner/AppDelegate.swift` 的 `handleCallService` →
/// `AVAudioSession(playAndRecord)` + `setActive(true)`）。
/// `test/core/call_keep_alive_test.dart` 验的是**通道契约**（通道是假的），
/// 「这段 Swift 在这台机器上到底跑不跑得起来」只有设备说了算 —— 就是这份文件。
///
/// 跑法：
/// ```
/// flutter test integration_test/ios_call_keep_alive_smoke_test.dart -d <设备号>
/// ```
///
/// ── 每一处通道调用都有硬时限（2026-10-15 加，这不是可选项）──────────────────
/// 第十一跑（`111d220`）整步卡满 28 分钟被杀，而同一个 job 里「装包 + 起 App +
/// 到登录页」只花 2 分 58 秒 —— 所以卡的是**某一条设备调用**，不是 runner 慢。
/// 最可能的就是 `setActive(true)`：无头模拟器上系统麦克风权限框没人点，那一步
/// 会一直等（`integration_test` 把用例超时设成了 `Timeout.none`，所以**没人替我们
/// 判死**）。被 `timeout-minutes` 杀掉时，工作流里那句 `annotate.sh` 根本来不及跑
/// —— 卡死等于现场全丢，比红还糟。
///
/// 所以每条通道调用都套上 [withDeadline]：超时就**以「卡住」为结论失败**，
/// 并说清卡在哪一步。宁可红得明白，不要挂得无声。
///
/// 判据为什么允许「起不来」：模拟器没有真实音频硬件，`setActive(true)` 有可能失败；
/// 被别人抢走会话时真机上一样会失败。而生产路径对这件事的态度是
/// **记一笔、通话继续**（抛 [CallKeepAliveException]，见
/// `lib/core/platform/call_keep_alive.dart` 的文件头）。所以这里钉的是
/// 「通道答得上话、状态自洽、**不崩**」，而不是「必须成功」。
///
/// ⚠️ 它**不**证明通话能打通：那是信令 + 对端的事（`ios_call_media_smoke_test.dart`
/// 负责「建连 + 取麦克风」那半）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  void report(String line) {
    // ignore: avoid_print
    print('[IOS-KEEPALIVE] $line');
  }

  /// 给一条通道调用套硬时限：超时抛 [TimeoutException]，让用例**当场红**并
  /// 说清卡在哪一步（与 `ios_call_media_smoke_test.dart` 里那份同一个理由）。
  Future<T> withDeadline<T>(
    String label,
    Future<T> Function() action, {
    Duration limit = const Duration(seconds: 30),
  }) async {
    final watch = Stopwatch()..start();
    try {
      final value = await action().timeout(
        limit,
        onTimeout: () => throw TimeoutException(
          '「$label」超过 ${limit.inSeconds} 秒没有返回 —— 最可能是原生那一步'
          '在等一个没人点的系统权限框（无头模拟器上必然如此）',
        ),
      );
      report('$label：${watch.elapsedMilliseconds}ms');
      return value;
    } on TimeoutException {
      report('$label：**卡住**（>${limit.inSeconds}s）');
      rethrow;
    }
  }

  testWidgets('原生保活：start → isRunning → stop 都不崩，且状态自洽', (tester) async {
    const keepAlive = IosCallKeepAlive();
    expect(keepAlive.supported, isTrue, reason: 'iOS 这张包里这条通道是实现了的');

    // 通知权限：只查、不申请（申请留给设置页 —— 权限框会把 App 顶到后台）
    final notified = await withDeadline(
      'hasNotificationPermission',
      keepAlive.hasNotificationPermission,
    );
    report('通知权限（只查看）= $notified');

    var started = false;
    String? failure;
    try {
      // 这一步最可能卡：`setActive(true)` 会要麦克风权限，而框没人点。
      await withDeadline(
        'start（原生 AVAudioSession 那一步）',
        () => keepAlive.start(video: false, peerName: '自检'),
        limit: const Duration(seconds: 45),
      );
      started = true;
    } on CallKeepAliveException catch (error) {
      // 允许失败，但必须是**我们自己抛的**这条异常：一个没接住的崩溃会在
      // 这里表现为整个进程被杀（用例直接红），那才是「点接听就闪退」。
      failure = error.message;
    }
    report('start：${started ? '成功' : '起不来（$failure）'}');

    final running = await withDeadline('isRunning', keepAlive.isRunning);
    report('isRunning = $running');
    expect(
      running,
      started,
      reason: '起成功了就该读回「在跑」；没起来就不该假装在跑（诊断面板读的就是它）',
    );

    // 停：要能停干净，而且要**幂等**（iOS 上没停干净的表现是麦克风指示灯一直亮，
    // 而且别的播放器起不来）
    await withDeadline('stop', keepAlive.stop);
    expect(
      await withDeadline('isRunning（stop 之后）', keepAlive.isRunning),
      isFalse,
      reason: 'stop 之后不该还在跑',
    );
    await withDeadline('stop（第二次，验幂等）', keepAlive.stop);
    expect(
      await withDeadline('isRunning（二次 stop 之后）', keepAlive.isRunning),
      isFalse,
      reason: '重复 stop 不该把它弄成「在跑」',
    );

    report('收尾完成（started=$started）');
  });
}
