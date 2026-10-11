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
// 通讯录/会话的数据库方法都是 extension，必须 import
import 'package:gracelinkim/data/db/contact_dao.dart';
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/model/contact.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/features/chat/chat_page.dart';
import 'package:gracelinkim/features/contacts/group_list_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 群聊列表页（S5.1）。
///
/// 跑整个 App：通讯录 →「群聊」，验的是真实那段链路（本地库的流 → 分组筛选 →
/// 起会话 → 进聊天页）。
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

  Contact grp(
    String id, {
    String name = '产品群',
    String index = 'C',
    int role = 0,
    String ownerId = '',
    String py = '',
  }) => Contact(
    id: id,
    displayName: name,
    indexLetter: index,
    namePy: py,
    isGroup: 1,
    role: role,
    ownerId: ownerId,
  );

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// 手机竖屏尺寸（默认 800×600 装不下列表）
  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  /// 起 App → 登录 → 通讯录 tab →「群聊」→ 群聊列表页
  Future<void> pumpGroupList(WidgetTester tester) async {
    usePhoneViewport(tester);
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
    await tester.tap(find.text('群聊'));
    await tester.pumpAndSettle();

    expect(find.byType(GroupListPage), findsOneWidget);
    addTearDown(() => disposeApp(tester));
  }

  testWidgets('四个分段能筛出各自的群', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await db.upsertContacts(<Contact>[
      grp('g1', name: '我建的群', index: 'W', role: 1, ownerId: 'u1'),
      grp('g2', name: '我管的群', index: 'W', role: 2),
      grp('g3', name: '我加的群', index: 'W', role: 3),
    ]);

    await pumpGroupList(tester);

    // 默认「全部」
    expect(find.text('我建的群'), findsOneWidget);
    expect(find.text('我管的群'), findsOneWidget);
    expect(find.text('我加的群'), findsOneWidget);

    await tester.tap(find.text('我管理的'));
    await tester.pumpAndSettle();
    expect(find.text('我管的群'), findsOneWidget);
    expect(find.text('我建的群'), findsNothing);
    expect(find.text('我加的群'), findsNothing);

    await tester.tap(find.text('我加入的'));
    await tester.pumpAndSettle();
    expect(find.text('我加的群'), findsOneWidget);
    expect(find.text('我管的群'), findsNothing);

    await tester.tap(find.text('我创建的'));
    await tester.pumpAndSettle();
    expect(find.text('我建的群'), findsOneWidget);
    expect(find.text('我加的群'), findsNothing);

    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(find.text('我管的群'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('只有我当群主的那行显示群主图标', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await db.upsertContacts(<Contact>[
      grp('g1', name: '我建的群', ownerId: 'u1'),
      grp('g2', name: '别人的群', ownerId: 'u9'),
    ]);

    await pumpGroupList(tester);

    expect(find.byIcon(Icons.people_alt), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('点一行直接进群聊，并且补上本地会话', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await db.upsertContacts(<Contact>[grp('g1', name: '产品群')]);

    await pumpGroupList(tester);

    // 进群聊页之前本地没有这个会话
    expect(await db.findConversation('g1'), isNull);

    await tester.tap(find.text('产品群'));
    await tester.pumpAndSettle();

    expect(find.byType(ChatPage), findsOneWidget);
    final conversation = await db.findConversation('g1');
    expect(conversation, isNotNull);
    expect(conversation!.displayName, '产品群');
    expect(conversation.isGroup, 1);

    await disposeApp(tester);
  });

  testWidgets('搜索跳过分段，关掉搜索框恢复全部', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await db.upsertContacts(<Contact>[
      grp('g1', name: '公司大群', py: 'gongsidaqun'),
      grp('g2', name: '同事群', py: 'tongshiqun'),
    ]);

    await pumpGroupList(tester);

    // 先切到「我管理的」（只有 g2 属于它，role 是 0 → 其实一个都不剩）
    await tester.tap(find.text('我管理的'));
    await tester.pumpAndSettle();
    expect(find.text('公司大群'), findsNothing);

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '公司');
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();

    // 搜索不管当前分段
    expect(find.text('公司大群'), findsOneWidget);
    expect(find.text('同事群'), findsNothing);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('同事群'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('一个群都没有时给空态', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);

    await pumpGroupList(tester);

    expect(find.text('暂无数据'), findsOneWidget);

    await disposeApp(tester);
  });
}
