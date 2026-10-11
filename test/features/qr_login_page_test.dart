import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/router/app_router.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/ui/notice_bus.dart';
import 'package:gracelinkim/core/ws/ws_client.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/features/login/qr_login_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 扫码登录确认页（S7.1 遗留，老端 `pages/login/qrlogin.vue`）。
///
/// 扫到网页端登录码之后进来：确认 → `POST /enterprise/im/tokenLogin` →
/// 把服务端那句 `msg` 提示出来 → 1.5 秒后自己退回。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late ProviderContainer container;
  late List<AppNotice> notices;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    db = memoryDatabase();
    adapter = StubAdapter();
    sessionGuard.update(ready: true, hasSession: true);
    notices = <AppNotice>[];
    final subscription = noticeBus.stream.listen(notices.add);
    addTearDown(subscription.cancel);
  });

  tearDown(() async {
    sessionGuard.update(ready: false, hasSession: false);
    await db.close();
  });

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<void> pumpPage(WidgetTester tester, {String token = 'tk-1'}) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(adapter.apiClient()),
          wsStatusProvider.overrideWith(
            (ref) => Stream<WsStatus>.value(WsStatus.connected),
          ),
        ],
        child: const GracelinkApp(),
      ),
    );
    await tester.pumpAndSettle();
    container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    container
        .read(sessionStoreProvider.notifier)
        .applyLogin(const UserInfo(userId: 'u1', displayName: '我'));
    await tester.pumpAndSettle();

    container.read(appRouterProvider).push('${AppRoutes.qrLogin}?token=$token');
    await tester.pumpAndSettle();

    addTearDown(() => disposeApp(tester));
  }

  testWidgets('确认登录：参数只带 token，提示服务端那句 msg，1.5 秒后自己退回', (tester) async {
    adapter.ok(ChatPaths.tokenLogin, data: <String, dynamic>{'id': 'u1'});
    // 信封里的 msg 就是老端要弹的那句话，这里靠它确认真的读出来了
    // （`StubAdapter.ok` 固定写 'ok'）
    await pumpPage(tester);

    expect(find.text('您正在登录电脑端，是否确定是你本人登录？'), findsOneWidget);
    await tester.tap(find.text('登录'));
    await tester.pump(); // 请求发出
    await tester.pump(const Duration(milliseconds: 100)); // 回执处理完

    expect(adapter.paths, contains(ChatPaths.tokenLogin));
    expect(adapter.bodyOf(ChatPaths.tokenLogin), <String, dynamic>{
      'token': 'tk-1',
    });
    expect(notices.map((notice) => notice.message), contains('ok'));

    // 老端是 1.5 秒后 `navigateBack()`
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byType(QrLoginPage), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('取消：不发请求、直接退回', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.byType(QrLoginPage), findsNothing);
    expect(adapter.paths, isNot(contains(ChatPaths.tokenLogin)));

    await disposeApp(tester);
  });

  testWidgets('没带 token：上来就退回，也不发请求（老端 onLoad 就是这么写的）', (tester) async {
    await pumpPage(tester, token: '');

    expect(find.byType(QrLoginPage), findsNothing);
    expect(adapter.paths, isNot(contains(ChatPaths.tokenLogin)));

    await disposeApp(tester);
  });

  testWidgets('服务端拒绝：留在这一页并提示原因', (tester) async {
    adapter.fail(ChatPaths.tokenLogin, code: 400, msg: '登录令牌已过期');

    await pumpPage(tester);

    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();

    expect(find.byType(QrLoginPage), findsOneWidget);
    expect(notices.map((notice) => notice.message), contains('登录令牌已过期'));

    await disposeApp(tester);
  });
}
