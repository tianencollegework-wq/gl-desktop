import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/router/app_router.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/ui/notice_handler.dart';
import 'package:gracelinkim/core/ws/ws_client.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 全局提示的宿主（S7.6 / S7.7）。
///
/// 这一条是**线上真会出现**的那种重复提示：接口层默认自己弹一次
/// （`ApiClient` 的 `notify: true`），页面 catch 到之后再弹一次同一句话 ——
/// 老实现是两条 `SnackBar` 前后脚各播一遍。现在提示走 [WeChatToastLayer]，
/// 同一句还在屏幕上就不弹第二遍，屏幕上**只会有一块**。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late ProviderContainer container;
  late NoticeHandler handler;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    db = memoryDatabase();
    adapter = StubAdapter();
    sessionGuard.update(ready: true, hasSession: true);
  });

  tearDown(() async {
    sessionGuard.update(ready: false, hasSession: false);
    await db.close();
  });

  Future<void> pumpApp(WidgetTester tester) async {
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
    // 真机是 `main.dart` 里起的那一份（`NoticeHandler(container).start()`）
    handler = NoticeHandler(container)..start();
  }

  /// 拆掉整棵树（并让 drift 收流时那些零时长定时器跑完）。
  ///
  /// **必须在用例体里调**：测试框架查「还有没有定时器在跑」是在用例体结束那一刻，
  /// 放在 `addTearDown` 里已经晚了。
  Future<void> disposeApp(WidgetTester tester) async {
    handler.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('接口层与页面弹的是同一句话时，屏幕上只出现一块提示', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      GroupPaths.userList,
      data: <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 1,
          'no_speak_time': 0,
          'no_speak_day': 0,
          'userInfo': <String, dynamic>{'id': 'u1', 'displayName': '我'},
        },
      ],
      count: 1,
    );
    adapter.fail(GroupPaths.editName, code: 400, msg: '服务器说改不了');
    await db.upsertConversation(
      Conversation(id: 'g1', displayName: '产品群', isGroup: 1, role: 1),
    );
    await pumpApp(tester);

    container
        .read(appRouterProvider)
        .push('${AppRoutes.chatDetail}?id=g1&is_group=1');
    await tester.pumpAndSettle();

    await tester.tap(find.text('群聊名称'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '新群名');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // 提示在屏幕正中，而且只有一块（老实现这里会前后脚弹两遍）
    expect(find.text('服务器说改不了'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('wechatToast')), findsOneWidget);

    // 提示自带一个「到点收掉」的定时器：收掉它再结束，
    // 否则测试框架会报「widget 树拆了还有定时器在跑」
    await disposeApp(tester);
  });
}
