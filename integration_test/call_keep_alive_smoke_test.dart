import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/platform/call_keep_alive.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/domain/call/call_media_config.dart';
import 'package:integration_test/integration_test.dart';

/// 真机保活自检（**不是单测**）。
///
/// 前台服务这件事只有设备说了算：能不能起、类型位对不对、通知长什么样、息屏之后
/// 会不会被系统停掉。单测那半是假的（`test/core/call_keep_alive_test.dart` 只验通道
/// 契约），Kotlin 那半在 `CallForegroundService.kt`。
///
/// 跑法：
/// ```
/// flutter test integration_test/call_keep_alive_smoke_test.dart -d <设备号> \
///   --plain-name 'mode=main'
/// ```
///
/// ## 跑之前先补权限（**装包会重置运行时权限**，而 integration_test 每次都会重装）
/// ```
/// adb shell pm grant com.example.gracelinkim android.permission.RECORD_AUDIO
/// adb shell pm grant com.example.gracelinkim android.permission.POST_NOTIFICATIONS
/// adb shell pm grant com.example.gracelinkim android.permission.CAMERA   # 视频模式
/// ```
/// 且**手机必须解锁亮屏**：Android 14 不允许从后台起 mic/camera 类型的前台服务，
/// 锁屏或 App 不在前台时这条自检会（正确地）失败。
///
/// ## 观察窗口（[holdSeconds] 那段时间）
/// ```
/// adb shell dumpsys activity services com.example.gracelinkim   # isForeground / 类型位
/// adb shell dumpsys notification --noredact | grep gracelinkim  # 渠道与通知
/// adb shell input keyevent 26                                   # 息屏，看服务还在不在
/// ```
/// 类型位：语音 = microphone = `0x00000080`，视频 = microphone|camera = `0x000000c0`。
///
/// ## 2026-09-19 真机踩出来的两个坑（都已修，留在这里当说明书）
/// 1. **`startForeground` 会抛**（`validateForegroundServiceType`：mic 类型不许从后台
///    起）。原来没接住 → 整个进程当场死 → 用户看到的是「打个电话闪退」。现在
///    服务侧接住并记下原因（诊断面板会显示），Dart 侧 `start` 读回确认后抛
///    [CallKeepAliveException]。
/// 2. **通知权限框会把 App 顶到后台**，所以「申请权限」绝不能紧挨着「起服务」：
///    通话路径里只查不申请（`hasNotificationPermission`），申请留给设置页。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  /// 起服务之后保持多久（给 adb 观察/锁屏验证留窗口）
  const holdSeconds = 90;

  const keepAlive = AndroidCallKeepAlive();

  void report(String line) {
    // ignore: avoid_print
    print('[KEEPALIVE] $line');
  }

  /// 轮询等一个条件成立（权限框要等真机上被点掉）
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

  setUpAll(() async {
    // 通知文案要按当前语言拼（AndroidCallKeepAlive 里用 AppI18n）
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
  });

  testWidgets('mode=main：先取麦克风 → 起服务 → 读回 → 保持 $holdSeconds 秒 → 停干净', (
    tester,
  ) async {
    expect(keepAlive.supported, isTrue);

    // ① 通知权限：这里**只查**；没给就先申请并等它被同意 —— 顺序不能反：
    //    权限框会把 App 顶到后台，而那一刻起 mic 类型的前台服务会被系统拒掉
    final before = await keepAlive.hasNotificationPermission();
    report('通知权限（只查看）= $before');
    if (!before) {
      await keepAlive.requestNotificationPermission();
      final granted = await waitUntil(keepAlive.hasNotificationPermission);
      report('等权限框之后，通知权限 = $granted');
    }

    // ② 先取麦克风（真实通话就是这个顺序）：Android 14 要求 mic 类型的前台服务
    //    启动时真的能用麦克风。首次会弹 RECORD_AUDIO 框（跑之前先 adb 授权）
    final stream = await navigator.mediaDevices.getUserMedia(
      CallMediaConfig.localMediaConstraints(video: false),
    );
    report('mic OK tracks=${stream.getTracks().length}');

    // ③ 起服务（媒体已就绪、App 在前台 —— 与生产路径完全一致）
    await keepAlive.start(video: false, peerName: '自检');
    report('start（语音）成功');

    final running = await keepAlive.isRunning();
    report('isRunning = $running');
    expect(running, isTrue, reason: '起服务之后应该读回「在跑」');

    // 观察窗口：这段时间里从 adb 看服务/通知，也可以息屏再唤醒
    await Future<void>.delayed(const Duration(seconds: holdSeconds));

    final stillRunning = await keepAlive.isRunning();
    report('$holdSeconds 秒后 isRunning = $stillRunning');
    expect(stillRunning, isTrue, reason: '前台服务不该在息屏/切后台之后被系统停掉');

    await keepAlive.stop();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final after = await keepAlive.isRunning();
    report('stop 之后 isRunning = $after');
    expect(after, isFalse, reason: '停不干净会留下「麦克风正在使用」的常驻通知');

    // 收尾：停掉麦克风（免得这条自检自己一直占着麦克风）
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    report('麦克风已释放');
  });

  testWidgets('mode=video：视频通话的类型位（microphone|camera）', (tester) async {
    final stream = await navigator.mediaDevices.getUserMedia(
      CallMediaConfig.localMediaConstraints(video: true),
    );
    report('camera OK tracks=${stream.getTracks().length}');

    await keepAlive.start(video: true, peerName: '自检');
    report('start（视频）成功，isRunning = ${await keepAlive.isRunning()}');
    expect(await keepAlive.isRunning(), isTrue);

    // 留几秒给 adb 看类型位（应当是 0x000000c0）
    await Future<void>.delayed(const Duration(seconds: 10));

    await keepAlive.stop();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(await keepAlive.isRunning(), isFalse);

    for (final track in stream.getTracks()) {
      await track.stop();
    }
    report('视频类型位检查完毕，摄像头与麦克风已释放');
  });
}
