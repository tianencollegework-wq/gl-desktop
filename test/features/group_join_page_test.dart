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
// 会话/通讯录的数据库方法都是 extension，必须 import
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/domain/chat/group_join.dart';
import 'package:gracelinkim/features/chat/chat_page.dart';
import 'package:gracelinkim/features/contacts/group_join_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 群资料 / 加入群聊（S7.1，老端 `pages/message/group/info.vue`）。
///
/// 跑整个 App：这一页只有扫码一个来路（`groupInfo` action → `/message/group/info`），
/// 所以用例直接 push 那个路由（等价于扫到群二维码），剩下的按真实链路走
/// ——拉群资料、点按钮、加群成功之后落本地并进聊天页。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late ProviderContainer container;

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

  /// 把整棵树拆掉：drift 的流订阅与定时器会一直拽住测试
  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<void> pumpPage(
    WidgetTester tester, {
    String groupId = 'g9',
    // 扫码那一步服务端给的群资料（未入群也拿得到）——真机上由扫码页当 `extra` 带进来
    GroupJoinInfo? scanned,
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
    container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    container
        .read(sessionStoreProvider.notifier)
        .applyLogin(const UserInfo(userId: 'u1', displayName: '我'));
    await tester.pumpAndSettle();

    container
        .read(appRouterProvider)
        .push('${AppRoutes.groupInfo}?group_id=$groupId', extra: scanned);
    await tester.pumpAndSettle();

    addTearDown(() => disposeApp(tester));
  }

  testWidgets('已经在群里：按钮是「进入群聊」，点了进聊天页', (tester) async {
    adapter.ok(
      GroupPaths.info,
      data: <String, dynamic>{'name': '扫码群', 'groupUserCount': 12, 'isJoin': 1},
    );
    // 已经在群里 → 本地本来就该有这条会话（列表里点进去用的就是它）
    await db.upsertConversation(
      const Conversation(id: 'g9', displayName: '扫码群', isGroup: 1),
    );

    await pumpPage(tester);

    // 名字后面跟着人数（老端也是拼在一起显示）
    expect(find.text('扫码群 (12)'), findsOneWidget);
    expect(find.text('加入群聊'), findsNothing);

    await tester.tap(find.text('进入群聊'));
    await tester.pumpAndSettle();

    expect(find.byType(ChatPage), findsOneWidget);
    expect(adapter.paths, isNot(contains(GroupPaths.joinGroup)));

    await disposeApp(tester);
  });

  testWidgets('还没进群：点「加入群聊」→ 带上 inviteUid、落本地、进聊天页', (tester) async {
    adapter
      ..ok(
        GroupPaths.info,
        data: <String, dynamic>{
          'name': '扫码群',
          'groupUserCount': 12,
          'isJoin': 0,
          'inviteUid': 'u9',
          'setting': <String, dynamic>{'invite': 1},
        },
      )
      ..ok(GroupPaths.joinGroup, data: <String, dynamic>{'id': 'g9'});

    await pumpPage(tester);

    expect(find.text('加入群聊'), findsOneWidget);
    await tester.tap(find.text('加入群聊'));
    await tester.pumpAndSettle();

    // 老端就是这两个字段：group_id 与 inviteUid
    expect(adapter.bodyOf(GroupPaths.joinGroup), <String, dynamic>{
      'group_id': 'g9',
      'inviteUid': 'u9',
    });
    // 不赌推送：本地立刻有这条会话（名字/头像从这一页带过去），且进群
    expect((await db.findConversation('g9'))?.displayName, '扫码群');
    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.byType(GroupJoinPage), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('未入群（群资料接口拒绝）：用扫码带过来的那份照常显示，并真能加入', (tester) async {
    // 服务端的「群资料」接口**只给群成员**：不在群里就回一句「您没有操作权限！」。
    // 而群二维码本来就是给还没进群的人扫的 —— 所以扫码那一步服务端给的群资料
    // （`extra`）要能撑起这一页，否则就成了「扫码加不了群」（用户 2026-09-29 报的）。
    final notices = <AppNotice>[];
    final subscription = noticeBus.stream.listen(notices.add);
    addTearDown(subscription.cancel);

    adapter
      ..fail(GroupPaths.info, code: 403, msg: '您没有操作权限！')
      ..ok(GroupPaths.joinGroup, data: <String, dynamic>{'id': 'group-9'});

    await pumpPage(
      tester,
      groupId: 'group-9',
      scanned: const GroupJoinInfo(
        id: 'group-9',
        name: '扫码群',
        avatar: 'https://cdn.test/g.png',
        // 服务端在扫码回包里给的是 `invite_id`（生成这张码的那个人，必然在群里）；
        // 加群时服务端会拿它验一次，编不出来
        inviteUid: 'u9',
      ),
    );

    // 名字来自扫码那份（没有被服务端那句拒绝顶掉）
    expect(find.text('扫码群'), findsOneWidget);
    expect(find.text('您没有操作权限！'), findsNothing);
    // 那句拒绝连提示都不该冒（notify: false）
    expect(notices, isEmpty);
    expect(find.text('加入群聊'), findsOneWidget);

    await tester.tap(find.text('加入群聊'));
    await tester.pumpAndSettle();

    // 路由里的群 id（`group-9`）原样发给服务端（服务端自己 `explode('-')` 取数字）
    expect(adapter.bodyOf(GroupPaths.joinGroup), <String, dynamic>{
      'group_id': 'group-9',
      'inviteUid': 'u9',
    });
    expect((await db.findConversation('group-9'))?.displayName, '扫码群');
    expect(find.byType(ChatPage), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('扫码带过来的那份 + 群资料拉得到：换成更全的那份（人数 / 进入群聊）', (tester) async {
    // 我本来就在这个群里：`groupInfo` 拉得到，那就得有群人数、按钮是「进入群聊」。
    // 扫码那份只是**兜底**，不能把拉得到的信息也盖掉。
    adapter.ok(
      GroupPaths.info,
      data: <String, dynamic>{'name': '扫码群', 'groupUserCount': 12, 'isJoin': 1},
    );

    await pumpPage(
      tester,
      groupId: 'group-9',
      scanned: const GroupJoinInfo(id: 'group-9', name: '扫码群'),
    );

    expect(find.text('扫码群 (12)'), findsOneWidget);
    expect(find.text('进入群聊'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('群已关闭加群（setting.invite == 0）：只提示，不发请求', (tester) async {
    adapter.ok(
      GroupPaths.info,
      data: <String, dynamic>{
        'name': '扫码群',
        'setting': <String, dynamic>{'invite': 0},
      },
    );

    await pumpPage(tester);

    // 提示走全局通知流（真机上由 `NoticeHandler` 弹 SnackBar），这里直接盯流
    final notices = <AppNotice>[];
    final subscription = noticeBus.stream.listen(notices.add);
    addTearDown(subscription.cancel);

    await tester.tap(find.text('加入群聊'));
    await tester.pumpAndSettle();

    expect(adapter.paths, isNot(contains(GroupPaths.joinGroup)));
    expect(notices.map((notice) => notice.message), contains('该群聊已经关闭加群申请'));

    await disposeApp(tester);
  });

  testWidgets('拉群资料失败：给错误 + 重试，重试成功后正常显示', (tester) async {
    adapter.fail(GroupPaths.info, code: 500, msg: '服务器开小差了');

    await pumpPage(tester);

    expect(find.text('服务器开小差了'), findsOneWidget);
    expect(find.text('加入群聊'), findsNothing);

    adapter.ok(
      GroupPaths.info,
      data: <String, dynamic>{'name': '扫码群', 'isJoin': 0},
    );
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('扫码群'), findsOneWidget);
    expect(find.text('加入群聊'), findsOneWidget);

    await disposeApp(tester);
  });
}
