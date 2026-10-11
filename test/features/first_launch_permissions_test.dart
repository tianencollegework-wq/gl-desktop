import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/notify/message_notification_presenter.dart';
import 'package:gracelinkim/core/platform/app_permissions.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/features/notify/first_launch_permissions.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_notification_presenter.dart';
import '../support/fake_permission_gateway.dart';

/// 第一次打开 App 时把「基本权限」问一遍（用户 2026-09-27 的要求：
/// 「确保一下，是不是软件下载完第一次打开会自动申请系统的这几个基本权限？」）。
///
/// 三条要钉住：
/// 1. **只在第一次**问 —— 存了标记之后冷启动多少次都不再问
///    （从前是「每个进程问一次」，冷启动十次问十次）；
/// 2. 已经有权限就一声不响（老用户升级上来时不该弹）；
/// 3. 通知这条**只问一次**，而且不问两遍：通道认它就自己问，
///    通道不认（iOS / 桌面）才交给通知那一层。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakePermissionGateway gateway;
  late FakeNotificationPresenter presenter;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    // 默认当成「通道认这条权限、且现在没给」
    gateway = FakePermissionGateway(status: PermissionStatus.denied);
    presenter = FakeNotificationPresenter()..permissionGranted = true;
  });

  bool asked() => CredentialStore.instance.getBool(firstLaunchPermissionsKey);

  Future<void> runPrompt(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          permissionGatewayProvider.overrideWithValue(gateway),
          messageNotificationPresenterProvider.overrideWithValue(presenter),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => runFirstLaunchPermissionPrompt(ref),
                child: const Text('boot'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('boot'));
    await tester.pumpAndSettle();
  }

  testWidgets('没授权：直接弹系统的通知授权框（安卓那条路）', (tester) async {
    await runPrompt(tester);

    expect(gateway.requested, <AppPermission>[AppPermission.notifications]);
    expect(presenter.permissionRequests, 0, reason: '通道能问就别再去戳通知那一层，免得弹两次系统框');
    expect(asked(), isTrue, reason: '问过一次就该记一笔');
  });

  testWidgets('通道不认这条权限（iOS / 桌面）：交给通知那一层去问', (tester) async {
    gateway.status = PermissionStatus.unsupported;
    presenter.permissionGranted = false;
    await runPrompt(tester);

    expect(gateway.requests, 0);
    expect(presenter.permissionRequests, 1);
    expect(asked(), isTrue);
  });

  testWidgets('早就允许了（老用户升级上来）：一声不响，只记一笔', (tester) async {
    gateway.status = PermissionStatus.granted;
    await runPrompt(tester);

    expect(gateway.requests, 0);
    expect(presenter.permissionRequests, 0);
    expect(asked(), isTrue);
  });

  testWidgets('问过了：再启动多少次都不再问', (tester) async {
    await runPrompt(tester);
    expect(gateway.requests, 1);

    // 模拟「杀进程再打开」两次（标记还在本地）
    gateway.requests = 0;
    await runPrompt(tester);
    await runPrompt(tester);

    expect(gateway.requests, 0);
    expect(presenter.permissionRequests, 0);
  });
}
