import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/platform/app_permissions.dart';
import 'package:gracelinkim/core/platform/app_settings.dart';
import 'package:gracelinkim/core/platform/background_health.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/ui/permission_gate.dart';
import 'package:gracelinkim/core/ui/wechat_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_background_health.dart';
import '../support/fake_permission_gateway.dart';

/// 「用之前先拿到权限」那条路（`core/ui/permission_gate.dart`）。
///
/// 它要保证三件事：
/// 1. 已授权时**一声不响**（不能每次拨号都弹一个框）；
/// 2. 没授权时**先弹系统框**（`request`），用户同意就直接往下走；
/// 3. 还是没给就弹自家那只白框，并带一颗能真的跳到系统设置的「去授权」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePermissionGateway gateway;
  late List<bool> results;
  late int settingsOpened;

  setUpAll(() async {
    // 提示文案走的是 `AppI18n.instance`（与通话那几处同一个口径）
    await AppI18n.load('zh-Hans');
  });

  setUp(() {
    gateway = FakePermissionGateway();
    results = <bool>[];
    settingsOpened = 0;
    // 「去授权」跳的是本应用在系统设置里的页面：真机上是一条平台通道
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(appSettingsChannelName), (
          call,
        ) async {
          if (call.method == 'openAppSettings') settingsOpened += 1;
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(appSettingsChannelName),
            null,
          );
    });
  });

  /// 点一下那颗钮，把 `ensurePermission` 的结果收进 [results]
  Future<void> tapGate(
    WidgetTester tester,
    Future<bool> Function(BuildContext context, WidgetRef ref) action,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [permissionGatewayProvider.overrideWithValue(gateway)],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () async => results.add(await action(context, ref)),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  Future<bool> askCamera(BuildContext context, WidgetRef ref) =>
      ensurePermission(
        context,
        gateway: ref.read(permissionGatewayProvider),
        permission: AppPermission.camera,
        messageKey: 'perm.needCamera',
      );

  testWidgets('已经授权：直接放行，不弹任何框', (tester) async {
    gateway.status = PermissionStatus.granted;
    await tapGate(tester, askCamera);

    expect(results, <bool>[true]);
    expect(gateway.requests, 0, reason: '有权限就别再去弹系统框');
    expect(find.byType(WeChatDialogBox), findsNothing);
  });

  testWidgets('没授权但系统框里同意了：放行，且不弹自家那个框', (tester) async {
    gateway
      ..status = PermissionStatus.denied
      ..afterRequest = PermissionStatus.granted;
    await tapGate(tester, askCamera);

    expect(results, <bool>[true]);
    expect(gateway.requested, <AppPermission>[AppPermission.camera]);
    expect(find.byType(WeChatDialogBox), findsNothing);
  });

  testWidgets('两次都被拒：拦下来 + 说清要哪个权限 + 给「去授权」', (tester) async {
    gateway.status = PermissionStatus.permanentlyDenied;
    await tapGate(tester, askCamera);

    // 那只框是**模态**的：它没关之前调用方还没拿到「不行」这个结论
    expect(find.byType(WeChatDialogBox), findsOneWidget);
    expect(find.textContaining('摄像头权限'), findsOneWidget);
    expect(find.text('去授权'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(settingsOpened, 0, reason: '还没点它，不该自己跳');
    expect(results, isEmpty, reason: '用户还在看着这只框，调用方不该先往下走');

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(results, <bool>[false], reason: '没权限就别往下走（进去只会再失败一次）');
    expect(settingsOpened, 0, reason: '点了取消就不该跳设置');
  });

  testWidgets('点「去授权」把框关掉并把结论交回调用方', (tester) async {
    // 注：这里**不**去断言那条平台通道被调了 —— `openAppSettings()` 里是按
    // `Platform.isAndroid` 分派的，而单测跑在桌面上（dart:io 的 Platform
    // 不会因为测试而变成安卓），在 Windows 上它本来就是空操作。
    // 这里能钉住的是「点它会把框收掉、结论还是 false」；真机上那一下会跳到
    // 应用详情页，由 `call_page_test` 那类用例在各自的替身上看着。
    gateway.status = PermissionStatus.permanentlyDenied;
    await tapGate(tester, askCamera);
    expect(settingsOpened, 0);

    await tester.tap(find.text('去授权'));
    await tester.pumpAndSettle();
    expect(find.byType(WeChatDialogBox), findsNothing);
    expect(results, <bool>[false], reason: '去开权限 ≠ 这一次就有权限了');
  });

  group('通话前那两下', () {
    testWidgets('语音通话：只问麦克风', (tester) async {
      gateway.status = PermissionStatus.granted;
      await tapGate(
        tester,
        (context, ref) => ensureCallPermissions(context, ref, video: false),
      );

      expect(results, <bool>[true]);
      expect(gateway.checked, <AppPermission>[AppPermission.microphone]);
    });

    testWidgets('视频通话：麦克风过了再问摄像头', (tester) async {
      gateway.status = PermissionStatus.granted;
      await tapGate(
        tester,
        (context, ref) => ensureCallPermissions(context, ref, video: true),
      );

      expect(gateway.checked, <AppPermission>[
        AppPermission.microphone,
        AppPermission.camera,
      ]);
    });

    testWidgets('麦克风被拒：就此打住，**不去问摄像头**（免得连弹两个框）', (tester) async {
      gateway.status = PermissionStatus.permanentlyDenied;
      await tapGate(
        tester,
        (context, ref) => ensureCallPermissions(context, ref, video: true),
      );

      expect(gateway.checked, <AppPermission>[AppPermission.microphone]);
      expect(gateway.requested, <AppPermission>[AppPermission.microphone]);
      expect(find.textContaining('麦克风权限'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(results, <bool>[false]);
    });
  });

  group('拨号前那句「来电全屏显示」提醒（S12.8：从红条搬到这里）', () {
    late FakeBackgroundHealth health;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await CredentialStore.init();
      health = FakeBackgroundHealth(fullScreenIntent: false);
    });

    /// 立一个按钮，点一下就走一次拨号前的那句提醒
    Future<void> pumpHint(
      WidgetTester tester, {
      FakeBackgroundHealth? background,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            backgroundHealthProvider.overrideWithValue(background ?? health),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () => remindFullScreenBeforeCall(context, ref),
                  child: const Text('call'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('call'));
      await tester.pumpAndSettle();
    }

    testWidgets('没开时：弹一次白框，点「去授权」跳全屏设置页', (tester) async {
      await pumpHint(tester);

      expect(find.byType(WeChatDialogBox), findsOneWidget);
      expect(find.textContaining('来电全屏显示未开启'), findsOneWidget);

      await tester.tap(find.text('去授权'));
      await tester.pumpAndSettle();
      expect(health.openedFullScreenIntentSettings, 1);
    });

    testWidgets('一台机器只打扰一次：第二次拨号不再弹', (tester) async {
      await pumpHint(tester);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('call'));
      await tester.pumpAndSettle();
      expect(find.byType(WeChatDialogBox), findsNothing);
      expect(health.openedFullScreenIntentSettings, 0);
    });

    testWidgets('已经开启（或平台没这道开关）：一句话都不说', (tester) async {
      final allowed = FakeBackgroundHealth();
      await pumpHint(tester, background: allowed);

      expect(find.byType(WeChatDialogBox), findsNothing);
      expect(allowed.openedFullScreenIntentSettings, 0);
    });
  });
}
