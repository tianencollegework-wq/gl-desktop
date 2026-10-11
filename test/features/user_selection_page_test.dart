import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/router/app_router.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/ui/notice_bus.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/ws/ws_client.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
// 通讯录/会话的数据库方法都是 extension，必须 import
import 'package:gracelinkim/data/db/contact_dao.dart';
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/model/contact.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/features/chat/chat_page.dart';
import 'package:gracelinkim/features/home/user_selection_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 用户选择页（S5.6）：老端 `pages/index/userSelection.vue` 的 `type == 1`
/// ——「＋」菜单里的创建群聊。
///
/// 跑整个 App：从消息首页那颗「＋」进去，验的是真实那条链路
/// （本地通讯录的流 → 搜索筛选 → 建群接口 → 本地落库 → 进新群聊天页）。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;

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

  Contact friend(String id, {String name = '小明', String py = ''}) =>
      Contact(id: id, displayName: name, namePy: py, isGroup: 0);

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// 起 App → 登录 → 打开用户选择页（创建群聊）
  Future<ProviderContainer> pumpPage(
    WidgetTester tester, {
    String query = '',
  }) async {
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
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    container
        .read(sessionStoreProvider.notifier)
        .applyLogin(const UserInfo(userId: 'u1', displayName: '我'));
    await tester.pumpAndSettle();

    container
        .read(appRouterProvider)
        .push('${AppRoutes.userSelection}?type=1$query');
    await tester.pumpAndSettle();
    addTearDown(() => disposeApp(tester));
    return container;
  }

  testWidgets('列出好友；点一个进一个、再点取消；底部显示已选人数', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await db.upsertContacts(<Contact>[
      friend('u2', name: '小明', py: 'xiaoming'),
      friend('u3', name: '小红', py: 'xiaohong'),
      // 群聊不该出现在「创建群聊」的候选里（老端只取 is_group == 0）
      const Contact(id: 'g9', displayName: '老群', isGroup: 1),
    ]);

    await pumpPage(tester);

    expect(find.byType(UserSelectionPage), findsOneWidget);
    expect(find.text('小明'), findsOneWidget);
    expect(find.text('小红'), findsOneWidget);
    expect(find.text('老群'), findsNothing);

    await tester.tap(find.text('小明'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 人'), findsOneWidget);

    await tester.tap(find.text('小红'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 人'), findsOneWidget);

    // 再点一下取消选中
    await tester.tap(find.text('小红'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 人'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('搜索：按名字筛，筛不出来给空态', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await db.upsertContacts(<Contact>[
      friend('u2', name: '小明', py: 'xiaoming'),
      friend('u3', name: '小红', py: 'xiaohong'),
    ]);

    await pumpPage(tester);

    await tester.enterText(find.byType(TextField), 'hong');
    await tester.pumpAndSettle();
    expect(find.text('小红'), findsOneWidget);
    expect(find.text('小明'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('未搜索到数据'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('没选人时「完成」点不动', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await db.upsertContacts(<Contact>[friend('u2', name: '小明')]);

    await pumpPage(tester);

    final complete = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '完成'),
    );
    expect(complete.onPressed, isNull);

    await disposeApp(tester);
  });

  testWidgets('完成：带上选中的 user_ids 建群，本地会话落库并直接进新群', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.messageContext, data: <Map<String, dynamic>>[]);
    adapter.ok(
      GroupPaths.add,
      data: <String, dynamic>{'id': 'g2', 'displayName': '新群', 'is_group': 1},
    );
    await db.upsertContacts(<Contact>[
      friend('u2', name: '小明'),
      friend('u3', name: '小红'),
    ]);

    await pumpPage(tester);
    expect(await db.findConversation('g2'), isNull);

    await tester.tap(find.text('小明'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('小红'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(adapter.bodyOf(GroupPaths.add), <String, dynamic>{
      'user_ids': <String>['u2', 'u3'],
    });
    expect((await db.findContact('g2'))?.isGroup, 1);
    expect(await db.findConversation('g2'), isNotNull);
    // 选择页被换掉，停在聊天页
    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.byType(UserSelectionPage), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('带预选的人进来（老端 contact_id）：已选 1 人，完成只带他', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      GroupPaths.add,
      data: <String, dynamic>{'id': 'g3', 'is_group': 1},
    );
    await db.upsertContacts(<Contact>[
      friend('u2', name: '小明'),
      friend('u3', name: '小红'),
    ]);

    await pumpPage(tester, query: '&contact_id=u3');

    // 一进来就是「已选 1 人」，底部头像栏里那个人也在
    expect(find.text('已选 1 人'), findsOneWidget);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(adapter.bodyOf(GroupPaths.add), <String, dynamic>{
      'user_ids': <String>['u3'],
    });

    await disposeApp(tester);
  });

  testWidgets('预选多个（逗号分隔）与空值都不炸', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await db.upsertContacts(<Contact>[
      friend('u2', name: '小明'),
      friend('u3', name: '小红'),
    ]);

    await pumpPage(tester, query: '&contact_id=u2,u3');
    expect(find.text('已选 2 人'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('建群失败：留在选择页并把服务端的话弹出来', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.fail(GroupPaths.add, code: 400, msg: '群聊功能已关闭');
    await db.upsertContacts(<Contact>[friend('u2', name: '小明')]);

    await pumpPage(tester);

    // 提示是全局通知流（真机上由 `NoticeHandler` 弹 SnackBar），这里直接盯流
    final notices = <AppNotice>[];
    final subscription = noticeBus.stream.listen(notices.add);
    addTearDown(subscription.cancel);

    await tester.tap(find.text('小明'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(UserSelectionPage), findsOneWidget);
    expect(
      notices.whereType<ToastNotice>().map((notice) => notice.message),
      contains('群聊功能已关闭'),
    );

    await disposeApp(tester);
  });
}
