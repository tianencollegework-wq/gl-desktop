import 'dart:async';

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
import 'package:gracelinkim/core/ws/ws_client.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/features/chat/widgets/chat_input.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// @ 群成员（S4.4c）：`im-input.vue` 的「@」按钮 → `usermodel` 弹层
/// → `user-select.vue`（type 4）→ 发送时带 `at`。
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

  const baseTime = 1700000000000;

  /// 成员列表：自己是 u1（要被排除）、有个管理员、一个普通成员
  List<Map<String, dynamic>> members() => <Map<String, dynamic>>[
    <String, dynamic>{
      'role': 1,
      'userInfo': <String, dynamic>{'id': 'u1', 'displayName': '我'},
    },
    <String, dynamic>{
      'role': 2,
      'userInfo': <String, dynamic>{'id': 'u9', 'displayName': '管理员'},
    },
    <String, dynamic>{
      'role': 3,
      'userInfo': <String, dynamic>{
        'id': 'u3',
        'displayName': '小明',
        'name_py': 'xiaoming',
      },
    },
  ];

  Future<void> seedConversation({int isGroup = 1}) => db.upsertConversation(
    Conversation(
      id: 'g1',
      displayName: '同学群',
      isGroup: isGroup,
      role: 3,
      lastSendTime: baseTime,
      lastContent: '你好',
    ),
  );

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<void> pumpApp(WidgetTester tester) async {
    // 默认视口只有 800×600，成员弹层里第三行就掉到可见区外了（SliverList 不会
    // 挂载它，`find` 找不到）——换成手机竖屏尺寸
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
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
    container.read(appRouterProvider).push('/message/chat?id=g1');
    await tester.pumpAndSettle();
    addTearDown(() => disposeApp(tester));
  }

  Future<void> focusField(WidgetTester tester) async {
    await tester.tap(
      find.descendant(
        of: find.byType(ChatInput),
        matching: find.byType(TextField),
      ),
    );
    await tester.pumpAndSettle();
  }

  String fieldText(WidgetTester tester) => tester
      .widget<TextField>(
        find.descendant(
          of: find.byType(ChatInput),
          matching: find.byType(TextField),
        ),
      )
      .controller!
      .text;

  testWidgets('群里聚焦 → @ 按钮 → 选人 → 文本里出现 @名字 → 发送带 at', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
    adapter.ok(GroupPaths.userList, data: members());
    await seedConversation();
    await pumpApp(tester);

    // 没聚焦时不显示 @（老端 `v-show="isFocus && is_group==1"`）
    expect(find.byIcon(Icons.alternate_email), findsNothing);

    await focusField(tester);
    expect(find.byIcon(Icons.alternate_email), findsOneWidget);

    await tester.tap(find.byIcon(Icons.alternate_email));
    await tester.pumpAndSettle();

    // 走的是群成员接口，参数是 group_id
    expect(adapter.paths, contains(GroupPaths.userList));
    expect(adapter.bodyOf(GroupPaths.userList)['group_id'], 'g1');

    // 列表里没有自己；群里有管理员 → 有「所有人」入口
    expect(find.text('我'), findsNothing);
    expect(find.text('小明'), findsOneWidget);
    expect(find.text('管理员'), findsOneWidget);
    expect(find.text('所有人'), findsOneWidget);

    await tester.tap(find.text('小明'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已选 1 人'), findsOneWidget);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    // 输入框里插进了 @名字（老端 addLink 的效果）
    expect(fieldText(tester), '@小明 ');

    // 补点字再发
    await tester.enterText(
      find.descendant(
        of: find.byType(ChatInput),
        matching: find.byType(TextField),
      ),
      '@小明 你看这个',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(ChatInput), matching: find.text('发送')),
    );
    await tester.pumpAndSettle();

    final body = adapter.bodyOf(ChatPaths.sendMessage);
    expect(body['at'], <String>['u3']);
    expect(body['content'], '@小明 你看这个');

    await disposeApp(tester);
  });

  testWidgets('文本里把 @ 删掉：不带这个 at（老端从富文本 link 节点抓）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
    adapter.ok(GroupPaths.userList, data: members());
    await seedConversation();
    await pumpApp(tester);

    await focusField(tester);
    await tester.tap(find.byIcon(Icons.alternate_email));
    await tester.pumpAndSettle();
    await tester.tap(find.text('小明'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(fieldText(tester), '@小明 ');

    // 全删掉重新写一句
    await tester.enterText(
      find.descendant(
        of: find.byType(ChatInput),
        matching: find.byType(TextField),
      ),
      '你猜',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(ChatInput), matching: find.text('发送')),
    );
    await tester.pumpAndSettle();

    expect(
      adapter.bodyOf(ChatPaths.sendMessage).containsKey('at'),
      isFalse,
      reason: '@ 被删了就不该再带上这个人',
    );

    await disposeApp(tester);
  });

  testWidgets('@ 所有人：群主/管理员才有这个入口，user_id 是 0', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
    // 这次群里没有管理员（我自己的 role 不进这个列表，老端也是过滤掉自己）
    adapter.ok(
      GroupPaths.userList,
      data: <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 3,
          'userInfo': <String, dynamic>{'id': 'u3', 'displayName': '小明'},
        },
      ],
    );
    await seedConversation();
    await pumpApp(tester);

    await focusField(tester);
    await tester.tap(find.byIcon(Icons.alternate_email));
    await tester.pumpAndSettle();

    expect(find.text('所有人'), findsNothing, reason: '没有群主/管理员时不给这个入口');

    await disposeApp(tester);
  });

  testWidgets('单聊：没有 @ 按钮', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await db.upsertConversation(
      const Conversation(
        id: 'g1',
        displayName: '小明',
        lastSendTime: baseTime,
        lastContent: '你好',
      ),
    );
    await pumpApp(tester);
    await focusField(tester);

    expect(find.byIcon(Icons.alternate_email), findsNothing);
    // 单聊也没有群成员请求
    expect(adapter.paths, isNot(contains(GroupPaths.userList)));

    await disposeApp(tester);
  });

  testWidgets('群成员接口失败：弹层里给个空态，不崩', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.fail(GroupPaths.userList, code: 500);
    await seedConversation();
    await pumpApp(tester);

    await focusField(tester);
    await tester.tap(find.byIcon(Icons.alternate_email));
    await tester.pumpAndSettle();

    expect(find.text('暂无数据'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget, reason: '弹层还能关掉');

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(fieldText(tester), isEmpty);

    await disposeApp(tester);
  });
}
