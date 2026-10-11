import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/platform/background_health.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/features/notify/system_health_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_background_health.dart';

/// 会话列表顶上那条红提示条：**内容对不对**（通知优先）、**点一下去哪**。
///
/// 老端（`pages/message/index.vue`）是两条 `uni-notice-bar`，一条常驻在列表上方，
/// 点它跳系统设置；本端同样，只是把「点一下去哪儿」抽进了 `fixHint`。
void main() {
  late FakeBackgroundHealth health;

  setUp(() async {
    // 提示条的文案走 i18n，而 i18n 要读语言偏好（放在 CredentialStore 里）
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    health = FakeBackgroundHealth();
  });

  Future<void> pumpBanner(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [backgroundHealthProvider.overrideWithValue(health)],
        child: const MaterialApp(home: Scaffold(body: SystemHealthBanner())),
      ),
    );
    await tester.pump();
  }

  testWidgets('两道开关都正常：什么都不显示', (tester) async {
    await pumpBanner(tester);
    expect(find.textContaining('消息提醒'), findsNothing);
    expect(find.textContaining('省电优化'), findsNothing);
  });

  testWidgets('通知没开：显示「消息提醒」那条，点一下跳到通知设置页', (tester) async {
    health.notification = false;
    await pumpBanner(tester);

    expect(find.textContaining('消息提醒'), findsOneWidget);
    expect(find.textContaining('省电优化'), findsNothing);

    await tester.tap(find.textContaining('消息提醒'));
    await tester.pump();
    expect(health.openedNotificationSettings, 1);
    expect(health.requestedBattery, 0);
    // 假实现里用户顺手把开关打开了 → 提示条自己消失
    expect(find.textContaining('消息提醒'), findsNothing);
  });

  testWidgets('只有电池优化没关：什么都不显示（2026-09-27 去掉那条红横幅）', (tester) async {
    health.battery = false;
    await pumpBanner(tester);

    expect(
      find.textContaining('省电'),
      findsNothing,
      reason: '消息现在靠推送唤醒，电池那条横幅是个既丑又吓人的多余物（用户要求去掉）',
    );
    expect(find.textContaining('消息提醒'), findsNothing, reason: '通知是开着的，没有别的要说的');
    expect(health.requestedBattery, 0, reason: '也不该再去申请白名单了');
  });

  testWidgets('通知没开 + 电池也没白名单：只显示通知那条', (tester) async {
    health.notification = false;
    health.battery = false;
    await pumpBanner(tester);

    expect(find.textContaining('消息提醒'), findsOneWidget);
    expect(find.textContaining('省电'), findsNothing, reason: '电池那条已经不存在了');
  });

  testWidgets('通知开着、来电全屏没开：红条里**没有**这一条（2026-09-30 搬去拨号前弹窗）', (tester) async {
    health.fullScreenIntent = false;
    await pumpBanner(tester);

    expect(
      find.textContaining('全屏'),
      findsNothing,
      reason: '用户 2026-09-30：「红色横幅删掉，通话提醒就在发起通话之前弹窗提示就好了」',
    );
    expect(health.openedFullScreenIntentSettings, 0, reason: '红条都没有了，更谈不上点它');

    // 设置里那一行（以及拨号前那次弹窗）用的是同一个开关，仍在
    // `features/call/full_screen_intent_row.dart` 与
    // `core/ui/permission_gate.dart::remindFullScreenBeforeCall` 里。
  });
}
