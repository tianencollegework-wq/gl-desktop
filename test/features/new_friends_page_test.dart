import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/ws/ws_client.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
// 会话的数据库方法都是 extension，必须 import
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/features/chat/chat_page.dart';
import 'package:gracelinkim/features/contacts/new_friends_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 「新朋友」页（S5.1，对应老端 `pages/contacts/friend.vue`）。
///
/// 跑整个 App：通讯录 →「新邀请」，验的是真实那段链路
/// （分页请求 → 状态分支 → 同意/拒绝 → 起会话进聊天页）。
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

  Map<String, dynamic> incoming({
    Object id = 1,
    Object friendId = 3,
    Object status = 2,
    String name = '老王',
    String remark = '加个好友',
  }) => <String, dynamic>{
    'id': id,
    'friend_id': friendId,
    'status': status,
    'remark': remark,
    'create_user_info': <String, dynamic>{
      'user_id': 'u3',
      'realname': name,
      'avatar': 'https://cdn.test/u3.png',
    },
  };

  Map<String, dynamic> outgoing({
    Object id = 1,
    Object status = 2,
    String name = '小美',
  }) => <String, dynamic>{
    'id': id,
    'friend_id': 7,
    'status': status,
    'remark': '',
    'user_id_info': <String, dynamic>{
      'user_id': 'u7',
      'realname': name,
      'avatar': 'https://cdn.test/u7.png',
    },
  };

  /// 本页发出的分页请求（「新邀请」红点也会打同一个接口，但它 limit 是 50）
  int pageRequests() => adapter.requests.where((request) {
    final data = request.data;
    final body = data is Map ? data.cast<String, dynamic>() : null;
    return request.path == FriendPaths.applyList && body?['limit'] == 10;
  }).length;

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// 起 App → 登录 → 通讯录 →「新邀请」
  Future<void> pumpNewFriends(WidgetTester tester) async {
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

    await tester.tap(find.text('通讯录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新的朋友'));
    await tester.pumpAndSettle();

    expect(find.byType(NewFriendsPage), findsOneWidget);
    addTearDown(() => disposeApp(tester));
  }

  testWidgets('进页面就拉第一页（is_mine 是 0），两个分段都在', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      FriendPaths.applyList,
      data: <Map<String, dynamic>>[incoming()],
      count: 1,
    );

    await pumpNewFriends(tester);

    expect(find.text('我收到的'), findsOneWidget);
    expect(find.text('我发起的'), findsOneWidget);
    expect(adapter.lastBodyOf(FriendPaths.applyList), <String, dynamic>{
      'page': 1,
      'limit': 10,
      'is_mine': 0,
    });
    // 收到的口径：名字 + 「申请添加您为好友」+ 验证信息
    expect(find.textContaining('老王'), findsOneWidget);
    expect(find.textContaining('申请添加您为好友'), findsOneWidget);
    expect(find.text('加个好友'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('待处理的申请点「操作」→ 弹窗里接受 → status 1，并重拉列表', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      FriendPaths.applyList,
      data: <Map<String, dynamic>>[incoming(friendId: 3)],
      count: 1,
    );
    adapter.ok(FriendPaths.acceptApply, data: null);

    await pumpNewFriends(tester);
    expect(pageRequests(), 1);

    await tester.tap(find.text('操作'));
    await tester.pumpAndSettle();

    // 老端那个 showModal 的文案与两个按钮
    expect(find.text('你确定同意该好友的请求吗'), findsOneWidget);
    expect(find.text('拒绝'), findsOneWidget);

    await tester.tap(find.text('接受'));
    await tester.pumpAndSettle();

    expect(adapter.bodyOf(FriendPaths.acceptApply), <String, dynamic>{
      'friend_id': 3,
      'status': 1,
    });
    // 处理完要重新拉一遍列表（老端 `this.getList()`）
    expect(pageRequests(), 2);

    await disposeApp(tester);
  });

  testWidgets('拒绝走 status 0', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      FriendPaths.applyList,
      data: <Map<String, dynamic>>[incoming()],
      count: 1,
    );
    adapter.ok(FriendPaths.acceptApply, data: null);

    await pumpNewFriends(tester);
    await tester.tap(find.text('操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拒绝'));
    await tester.pumpAndSettle();

    expect(adapter.bodyOf(FriendPaths.acceptApply), <String, dynamic>{
      'friend_id': 3,
      'status': 0,
    });

    await disposeApp(tester);
  });

  testWidgets('弹窗点外面关掉 = 什么都不做（不发请求）', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      FriendPaths.applyList,
      data: <Map<String, dynamic>>[incoming()],
      count: 1,
    );
    adapter.ok(FriendPaths.acceptApply, data: null);

    await pumpNewFriends(tester);
    await tester.tap(find.text('操作'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(adapter.paths, isNot(contains(FriendPaths.acceptApply)));
    expect(pageRequests(), 1);

    await disposeApp(tester);
  });

  testWidgets('已同意的点「发消息」进聊天页，并补上本地会话', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      FriendPaths.applyList,
      data: <Map<String, dynamic>>[incoming(status: 1, name: '老王')],
      count: 1,
    );
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);

    await pumpNewFriends(tester);

    expect(find.text('发消息'), findsOneWidget);
    expect(find.text('操作'), findsNothing);
    expect(await db.findConversation('u3'), isNull);

    await tester.tap(find.text('发消息'));
    await tester.pumpAndSettle();

    expect(find.byType(ChatPage), findsOneWidget);
    final conversation = await db.findConversation('u3');
    expect(conversation, isNotNull);
    expect(conversation!.displayName, '老王');

    await disposeApp(tester);
  });

  testWidgets('已拒绝的显示「已拒绝」，没有操作入口', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      FriendPaths.applyList,
      data: <Map<String, dynamic>>[incoming(status: 0)],
      count: 1,
    );

    await pumpNewFriends(tester);

    expect(find.text('已拒绝'), findsOneWidget);
    expect(find.text('操作'), findsNothing);
    expect(find.text('发消息'), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('我发起的：报文是「添加 XX 为好友」，待处理显示「待同意」', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      FriendPaths.applyList,
      data: <Map<String, dynamic>>[outgoing()],
      count: 1,
    );

    await pumpNewFriends(tester);

    await tester.tap(find.text('我发起的'));
    await tester.pumpAndSettle();

    expect(adapter.lastBodyOf(FriendPaths.applyList), <String, dynamic>{
      'page': 1,
      'limit': 10,
      'is_mine': 1,
    });
    expect(find.textContaining('添加'), findsOneWidget);
    expect(find.textContaining('为好友'), findsOneWidget);
    expect(find.textContaining('小美'), findsOneWidget);
    expect(find.text('待同意'), findsOneWidget);
    expect(find.text('操作'), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('超过一页才出现翻页条，点右箭头翻到第 2 页', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      FriendPaths.applyList,
      data: <Map<String, dynamic>>[incoming()],
      count: 25,
    );

    await pumpNewFriends(tester);

    expect(find.text('1 / 3'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();

    expect(find.text('2 / 3'), findsOneWidget);
    expect(adapter.lastBodyOf(FriendPaths.applyList), <String, dynamic>{
      'page': 2,
      'limit': 10,
      'is_mine': 0,
    });

    await disposeApp(tester);
  });

  testWidgets('接口挂了给空态（不崩、也不显示半截列表）', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.fail(FriendPaths.applyList);

    await pumpNewFriends(tester);

    expect(find.text('暂无数据'), findsOneWidget);

    await disposeApp(tester);
  });
}
