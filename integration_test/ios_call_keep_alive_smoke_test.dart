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
/// 判据为什么允许「起不来」：模拟器没有真实音频硬件，`setActive(true)` 有可能失败；
/// 被别人抢走会话时真机上一样会失败。而生产路径对这件事的态度是
/// **记一笔、通话继续**（抛 [CallKeepAliveException]，见
/// `lib/core/platform/call_keep_alive.dart` 的文件头）。所以这里钉的是
/// 「通道答得上话、状态自洽、**不崩**」，而不是「必须成功」。
///
/// ⚠️ 它**不**证明通话能打通：那是信令 + 对端的事（`call_media_smoke_test.dart`
/// 负责「建连 + 取麦克风」那半）。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  void report(String line) {
    // ignore: avoid_print
    print('[IOS-KEEPALIVE] $line');
  }

  testWidgets('原生保活：start → isRunning → stop 都不崩，且状态自洽', (tester) async {
    const keepAlive = IosCallKeepAlive();
    expect(keepAlive.supported, isTrue, reason: 'iOS 这张包里这条通道是实现了的');

    // 通知权限：只查、不申请（申请留给设置页 —— 权限框会把 App 顶到后台）
    final notified = await keepAlive.hasNotificationPermission();
    report('通知权限（只查看）= $notified');

    var started = false;
    String? failure;
    try {
      await keepAlive.start(video: false, peerName: '自检');
      started = true;
    } on CallKeepAliveException catch (error) {
      // 允许失败，但必须是**我们自己抛的**这条异常：一个没接住的崩溃会在
      // 这里表现为整个进程被杀（用例直接红），那才是「点接听就闪退」。
      failure = error.message;
    }
    report('start：${started ? '成功' : '起不来（$failure）'}');

    final running = await keepAlive.isRunning();
    report('isRunning = $running');
    expect(
      running,
      started,
      reason: '起成功了就该读回「在跑」；没起来就不该假装在跑（诊断面板读的就是它）',
    );

    // 停：要能停干净，而且要**幂等**（iOS 上没停干净的表现是麦克风指示灯一直亮，
    // 而且别的播放器起不来）
    await keepAlive.stop();
    expect(await keepAlive.isRunning(), isFalse, reason: 'stop 之后不该还在跑');
    await keepAlive.stop();
    expect(await keepAlive.isRunning(), isFalse, reason: '重复 stop 不该把它弄成「在跑」');

    report('收尾完成（started=$started）');
  });
}
