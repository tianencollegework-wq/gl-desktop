import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/platform/app_foreground.dart';
import 'package:gracelinkim/core/platform/background_health.dart';
import 'package:gracelinkim/domain/notify/system_health.dart';

import '../support/fake_background_health.dart';

/// 把假实现里那些已经就绪的 Future 冲刷干净（重查是 fire-and-forget 的）
Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// 会话列表顶上那条红提示条。
///
/// 老端有两条（`systemNotify` / `systemBattery`）；**省电优化那条 2026-09-27
/// 去掉了**（用户要求：消息已经靠推送唤醒，横幅又丑又吓人），
/// **「来电全屏显示」那条 2026-09-30 也去掉了**（用户：「首页顶部那条红色横幅
/// 删掉，通话提醒就在发起通话之前弹窗提示就好了啊」→ 改成拨号前的弹窗，
/// 见 `core/ui/permission_gate.dart::remindFullScreenBeforeCall`）——
/// 用例跟着改，顺便把这两条钉住：「没关电池优化」「全屏没开」都不会冒红条。
void main() {
  // 重查是靠 `appForegroundProvider` 驱动的，而它的初值要问引擎
  // （`WidgetsBinding.instance.lifecycleState`），所以这个文件也得有测试 binding
  TestWidgetsFlutterBinding.ensureInitialized();

  group('该显示哪条提示', () {
    test('通知没开就说通知（最要紧的那条）', () {
      expect(
        resolveSystemHealthHint(notificationGranted: false),
        SystemHealthHint.notification,
      );
    });

    test('通知开着、全屏通知也开着 = 不提示', () {
      expect(
        resolveSystemHealthHint(notificationGranted: true),
        SystemHealthHint.none,
      );
      expect(SystemHealth.ok.hint, SystemHealthHint.none);
    });

    test('「来电全屏显示」没开也不再冒红条（2026-09-30 搬到了拨号前的弹窗）', () async {
      final health = FakeBackgroundHealth(fullScreenIntent: false);
      final container = ProviderContainer(
        overrides: [backgroundHealthProvider.overrideWithValue(health)],
      );
      addTearDown(container.dispose);

      expect(
        (await container.read(systemHealthProvider.future)).hint,
        SystemHealthHint.none,
        reason: '设为里那一行还在，但不再挂在消息页顶上',
      );
    });
  });

  group('状态 provider', () {
    late FakeBackgroundHealth health;
    late ProviderContainer container;

    setUp(() {
      health = FakeBackgroundHealth();
      container = ProviderContainer(
        overrides: [backgroundHealthProvider.overrideWithValue(health)],
      );
      addTearDown(container.dispose);
    });

    test('「没关省电优化」不再产生任何提示（2026-09-27 去掉那条红横幅）', () async {
      health.battery = false;
      final state = await container.read(systemHealthProvider.future);
      expect(
        state.hint,
        SystemHealthHint.none,
        reason: '消息现在靠推送唤醒，电池那条横幅是个吓人的多余物',
      );
    });

    test('首查：把通知开关读回来，并给出该显示哪条', () async {
      health.notification = false;
      final state = await container.read(systemHealthProvider.future);
      expect(state.notificationGranted, isFalse);
      expect(state.hint, SystemHealthHint.notification);
    });

    test('切回前台自动重查 —— 用户去设置里改完回来，提示条必须自己消失', () async {
      health.notification = false;

      expect(
        (await container.read(systemHealthProvider.future)).hint,
        SystemHealthHint.notification,
      );

      // 用户手动打开了通知权限（这里直接改假实现），然后回到前台
      health.notification = true;
      final foreground = container.read(appForegroundProvider.notifier);
      foreground.update(false);
      foreground.update(true);
      await settle();

      expect(
        container.read(systemHealthProvider).value?.hint,
        SystemHealthHint.none,
      );
    });

    test('切到后台那一刻不重查（只认「回到前台」）', () async {
      await container.read(systemHealthProvider.future);

      final foreground = container.read(appForegroundProvider.notifier);
      health.notification = false;
      foreground.update(false);
      await settle();
      expect(
        container.read(systemHealthProvider).value?.hint,
        SystemHealthHint.none,
        reason: '切出去不管（那时候查也查不出新东西，白跑一次平台通道）',
      );

      foreground.update(true);
      await settle();
      expect(
        container.read(systemHealthProvider).value?.hint,
        SystemHealthHint.notification,
      );
    });

    test('点提示条：跳到对应的那一页，跳完立刻重查', () async {
      health.notification = false;
      await container.read(systemHealthProvider.future);

      await container
          .read(systemHealthProvider.notifier)
          .fixHint(SystemHealthHint.notification);
      expect(health.openedNotificationSettings, 1);
      expect(health.requestedBattery, 0, reason: '通知那条不该去动电池设置');
      expect(health.openedFullScreenIntentSettings, 0);
      expect(
        container.read(systemHealthProvider).value?.hint,
        SystemHealthHint.none,
        reason: '跳过去那一步假实现顺手把开关置为正常，回来就不该再提示',
      );
    });

    test('fixHint(none) 什么都不做', () async {
      await container.read(systemHealthProvider.future);
      await container
          .read(systemHealthProvider.notifier)
          .fixHint(SystemHealthHint.none);
      expect(health.openedNotificationSettings, 0);
      expect(health.requestedBattery, 0);
    });
  });
}
