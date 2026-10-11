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
import 'package:gracelinkim/core/ui/notice_bus.dart';
import 'package:gracelinkim/core/ws/ws_client.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
// 通讯录/会话的数据库方法都是 extension，必须 import
import 'package:gracelinkim/data/db/contact_dao.dart';
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/model/contact.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/global_config.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/features/chat/chat_page.dart';
import 'package:gracelinkim/features/chat/chat_record_page.dart';
import 'package:gracelinkim/features/chat/widgets/media/contact_bubble.dart';
import 'package:gracelinkim/features/contacts/user_detail_page.dart';
import 'package:gracelinkim/features/contacts/user_search_page.dart';
import 'package:gracelinkim/features/search/search_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 搜索三件套（S5.4）：搜人页、本地搜索页、会话内聊天记录页。
///
/// 跑整个 App：从消息页的搜索图标 /「＋」菜单真进那几个页面，验的是真实
/// 那一段链路（路由参数 → 接口参数 → 界面反应）。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late ProviderContainer container;
  late StreamSubscription<AppNotice> noticeSub;
  late List<AppNotice> notices;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    db = memoryDatabase();
    adapter = StubAdapter();
    sessionGuard.update(ready: true, hasSession: true);
    notices = <AppNotice>[];
    noticeSub = noticeBus.stream.listen(notices.add);
  });

  tearDown(() async {
    await noticeSub.cancel();
    sessionGuard.update(ready: false, hasSession: false);
    await db.close();
  });

  final baseTime = DateTime(2026, 9, 18, 10).millisecondsSinceEpoch;

  Iterable<String> toasts() =>
      notices.whereType<ToastNotice>().map((notice) => notice.message);

  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  Map<String, dynamic> message(int id, {String type = 'text'}) =>
      <String, dynamic>{
        'id': id,
        'msg_id': 'm$id',
        'type': type,
        'content': '第 $id 条消息',
        'sendTime': baseTime + id * 1000,
        'toContactId': 'g1',
        'fromUser': <String, dynamic>{'id': 'u2', 'realname': '小明'},
      };

  Contact contact(
    String id, {
    String name = '小明',
    String py = 'xiaoming',
    int isGroup = 0,
  }) => Contact(
    id: id,
    displayName: name,
    namePy: py,
    indexLetter: name.isEmpty ? '' : 'X',
    isGroup: isGroup,
  );

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<void> pumpApp(WidgetTester tester) async {
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
    addTearDown(() => disposeApp(tester));
    container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    container
        .read(sessionStoreProvider.notifier)
        .applyLogin(const UserInfo(userId: 'u1', displayName: '我'));
    await tester.pumpAndSettle();
  }

  Future<void> seedGroupChat() => db.upsertConversation(
    Conversation(
      id: 'g1',
      displayName: '产品群',
      isGroup: 1,
      role: 3,
      lastSendTime: baseTime,
      lastContent: '你好',
    ),
  );

  group('搜人页（/contacts/search）', () {
    testWidgets('从消息页「＋」→ 添加朋友进来，搜出来一行能看资料', (tester) async {
      adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
      adapter.ok(
        ChatPaths.searchUser,
        data: <Map<String, dynamic>>[
          <String, dynamic>{
            'user_id': 'u9',
            'realname': '张三',
            'avatar': '',
            'friend': 0,
          },
        ],
      );
      adapter.ok(ChatPaths.userInfo, data: <String, dynamic>{});
      await pumpApp(tester);

      // ＋ 菜单（老端那个 add-modal 里的「添加朋友」）
      // 导航栏右上角那个「＋」：微信是圆框加号
      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加朋友'));
      await tester.pumpAndSettle();

      expect(find.byType(UserSearchPage), findsOneWidget);
      expect(find.text('搜索朋友'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '张三');
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();

      expect(adapter.bodyOf(ChatPaths.searchUser), <String, dynamic>{
        'keywords': '张三',
      });
      // 输入框里一个、结果行一个
      expect(find.text('张三'), findsNWidgets(2));
      // 还不是好友 → 右侧是「查看」
      expect(find.text('查看'), findsOneWidget);

      // 点行（最后那个「张三」是结果行）进用户详情页
      await tester.tap(find.text('张三').last);
      await tester.pumpAndSettle();
      expect(find.byType(UserDetailPage), findsOneWidget);

      await disposeApp(tester);
    });

    testWidgets('是好友给「发消息」：本地没有会话时先 getUserInfo 补一条再进聊天', (tester) async {
      adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
      adapter.ok(
        ChatPaths.searchUser,
        data: <Map<String, dynamic>>[
          <String, dynamic>{'user_id': 'u9', 'realname': '张三', 'friend': 1},
        ],
      );
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      adapter.ok(
        ChatPaths.userInfo,
        data: <String, dynamic>{
          'contactInfo': <String, dynamic>{
            'id': 'u9',
            'displayName': '张三',
            'is_group': 0,
          },
        },
      );
      await pumpApp(tester);

      container.read(appRouterProvider).push(AppRoutes.contactSearch);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '张三');
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();

      expect(find.text('发消息'), findsOneWidget);
      await tester.tap(find.text('发消息'));
      await tester.pumpAndSettle();

      expect(adapter.paths, contains(ChatPaths.userInfo));
      expect((await db.findConversation('u9'))?.displayName, '张三');
      expect(find.byType(ChatPage), findsOneWidget);

      await disposeApp(tester);
    });

    testWidgets('站点不需要加好友（runMode != 2）时，「＋」菜单里没有「添加朋友」', (tester) async {
      adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);
      await pumpApp(tester);
      // 老端 `v-if="parseInt(globalConfig.sysInfo.runMode)==2"`
      container
          .read(sessionStoreProvider.notifier)
          .applyConfig(
            const GlobalConfig(
              sysInfo: SysInfo(runMode: 1),
              chatInfo: ChatInfo(groupChat: 0),
              compass: CompassConfig(),
              demonMode: false,
            ),
          );
      await tester.pumpAndSettle();

      // 导航栏右上角那个「＋」：微信是圆框加号
      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pumpAndSettle();

      expect(find.text('更新消息'), findsOneWidget);
      expect(find.text('添加朋友'), findsNothing);
      expect(find.text('创建群聊'), findsNothing);
      expect(find.text('扫 一 扫'), findsOneWidget);

      // 「更新消息」= 老端 `initContacts()`：重新拉一次会话列表
      await tester.tap(find.text('更新消息'));
      await tester.pumpAndSettle();
      expect(adapter.paths, contains(ChatPaths.contacts));

      await disposeApp(tester);
    });

    testWidgets('空关键词点搜索：提示一句，不打接口', (tester) async {
      adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
      await pumpApp(tester);

      container.read(appRouterProvider).push(AppRoutes.contactSearch);
      await tester.pumpAndSettle();
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();

      expect(toasts(), contains('请输入用户账号进行搜索'));
      expect(adapter.paths, isNot(contains(ChatPaths.searchUser)));
      // 没搜过 → 空态还是「暂无数据」
      expect(find.text('暂无数据'), findsOneWidget);

      await disposeApp(tester);
    });

    testWidgets('搜不到：空态换成「未搜索到用户数据」', (tester) async {
      adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.searchUser, data: <Map<String, dynamic>>[]);
      await pumpApp(tester);

      container.read(appRouterProvider).push(AppRoutes.contactSearch);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '查无此人');
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();

      expect(find.text('未搜索到用户数据'), findsOneWidget);

      await disposeApp(tester);
    });
  });

  group('本地搜索页（/index/search）', () {
    testWidgets('从消息页搜索图标进（type=1）：好友与群聊两段，输入即搜', (tester) async {
      adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      await db.upsertContacts(<Contact>[
        contact('u2', name: '小明'),
        contact('g1', name: '小明的群', py: 'xiaomingde', isGroup: 1),
        contact('u3', name: '小红', py: 'xiaohong'),
      ]);
      await pumpApp(tester);

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      expect(find.byType(SearchPage), findsOneWidget);
      expect(find.text('搜索'), findsOneWidget);
      // 没输入 → 空态
      expect(find.text('暂无数据'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '小明');
      await tester.pumpAndSettle();

      expect(find.text('朋友'), findsOneWidget);
      expect(find.text('群聊'), findsOneWidget);
      expect(find.text('小红'), findsNothing);

      // 点群聊 → 补会话进聊天页
      await tester.tap(find.text('小明的群'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatPage), findsOneWidget);
      expect(await db.findConversation('g1'), isNotNull);

      await disposeApp(tester);
    });

    testWidgets('type=3（群聊列表进）只搜群，不显示好友段', (tester) async {
      adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
      await db.upsertContacts(<Contact>[
        contact('u2', name: '小明'),
        contact('g1', name: '小明的群', isGroup: 1),
      ]);
      await pumpApp(tester);

      container.read(appRouterProvider).push('${AppRoutes.indexSearch}?type=3');
      await tester.pumpAndSettle();
      expect(find.text('搜索群聊'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '小明');
      await tester.pumpAndSettle();

      expect(find.text('小明的群'), findsOneWidget);
      expect(find.text('朋友'), findsNothing);

      await disposeApp(tester);
    });

    testWidgets('type=2（通讯录进）点好友看资料，不直接进聊天', (tester) async {
      adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
      adapter.ok(
        ChatPaths.userInfo,
        data: <String, dynamic>{
          'user_id': 'u2',
          'realname': '小明',
          'friend': <String, dynamic>{'friend_id': 2, 'nickname': ''},
          'contactInfo': <String, dynamic>{'id': 'u2'},
        },
      );
      await db.upsertContacts(<Contact>[contact('u2', name: '小明')]);
      await pumpApp(tester);

      container.read(appRouterProvider).push('${AppRoutes.indexSearch}?type=2');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '小明');
      await tester.pumpAndSettle();

      // 输入框里一个「小明」、结果行一个
      await tester.tap(find.text('小明').last);
      await tester.pumpAndSettle();
      expect(find.byType(UserDetailPage), findsOneWidget);

      await disposeApp(tester);
    });
  });

  group('聊天记录页（/message/record）', () {
    testWidgets('从聊天信息页「查找聊天记录」进：分段、分页、搜索', (tester) async {
      adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
      adapter.ok(
        ChatPaths.messageList,
        data: <Map<String, dynamic>>[],
        count: 0,
      );
      await seedGroupChat();
      await pumpApp(tester);

      // 聊天信息页 → 查找聊天记录（S5.3 接的入口；微信这一行就叫「查找聊天记录」）
      container
          .read(appRouterProvider)
          .push('${AppRoutes.chatDetail}?id=g1&is_group=1');
      await tester.pumpAndSettle();
      await tester.tap(find.text('查找聊天记录'));
      await tester.pumpAndSettle();

      expect(find.byType(ChatRecordPage), findsOneWidget);
      expect(find.text('聊天记录'), findsOneWidget);
      // 首屏请求：默认 all / 第 1 页
      expect(adapter.bodyOf(ChatPaths.messageList), <String, dynamic>{
        'toContactId': 'g1',
        'is_group': 1,
        'type': 'all',
        'keywords': '',
        'page': 1,
        'limit': 10,
      });

      // 切到「图片」分段 → 重新拉第 1 页
      adapter.ok(
        ChatPaths.messageList,
        data: <Map<String, dynamic>>[message(1, type: 'image')],
        count: 25,
      );
      await tester.tap(find.text('图片'));
      await tester.pumpAndSettle();
      // 同一个接口被调了多次，取最后一次
      expect(adapter.lastBodyOf(ChatPaths.messageList)['type'], 'image');
      expect(find.text('第 1 条消息'), findsNothing); // 图片气泡里没有文字
      // 25 条 → 3 页
      expect(find.text('1 / 3'), findsOneWidget);

      // 翻页
      await tester.tap(find.text('›'));
      await tester.pumpAndSettle();
      expect(adapter.lastBodyOf(ChatPaths.messageList)['page'], 2);
      expect(find.text('2 / 3'), findsOneWidget);

      await disposeApp(tester);
    });

    testWidgets('搜索：关键字送服务端，每条多出「查看上下文」，点开能加载更多', (tester) async {
      adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.messageContext, data: <Map<String, dynamic>>[]);
      await seedGroupChat();
      await pumpApp(tester);

      adapter.ok(
        ChatPaths.messageList,
        data: <Map<String, dynamic>>[message(3), message(7)],
        count: 2,
      );
      container
          .read(appRouterProvider)
          .push('${AppRoutes.chatRecord}?id=g1&is_group=1');
      await tester.pumpAndSettle();
      expect(find.text('查看上下文'), findsNothing);

      // 右上角放大镜 → 搜索框
      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '你好');
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();

      expect(adapter.lastBodyOf(ChatPaths.messageList)['keywords'], '你好');
      // 两条结果各有一个「查看上下文」
      expect(find.text('查看上下文'), findsNWidgets(2));

      // 点第一条 → 拉中心前后文（direction 0）
      adapter.ok(
        ChatPaths.messageContext,
        data: <Map<String, dynamic>>[message(3), message(7)],
      );
      await tester.tap(find.text('查看上下文').first);
      await tester.pumpAndSettle();

      expect(adapter.lastBodyOf(ChatPaths.messageContext), <String, dynamic>{
        'msg_id': 'm3',
        'is_group': 1,
        'direction': 0,
      });
      expect(find.text('消息详情'), findsOneWidget);

      // 弹层里往两头加载：先「更早」（direction 1）
      await tester.tap(find.text('加载更多').first);
      await tester.pumpAndSettle();
      expect(adapter.lastBodyOf(ChatPaths.messageContext)['direction'], 1);

      await disposeApp(tester);
    });

    testWidgets('记录页里的名片也能点（老端 record.vue 也是 openContact）', (tester) async {
      adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.userInfo, data: <String, dynamic>{});
      await seedGroupChat();
      await pumpApp(tester);

      adapter.ok(
        ChatPaths.messageList,
        data: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 1,
            'msg_id': 'm1',
            'type': 'contact',
            'content': '[个人名片] 小红',
            'sendTime': baseTime,
            'toContactId': 'g1',
            'fromUser': <String, dynamic>{'id': 'u2', 'realname': '小明'},
            'extends': <String, dynamic>{
              'avatar': '',
              'displayName': '小红',
              'id': 'u3',
            },
          },
        ],
        count: 1,
      );
      container
          .read(appRouterProvider)
          .push('${AppRoutes.chatRecord}?id=g1&is_group=1');
      await tester.pumpAndSettle();

      await tester.tap(find.byType(ContactBubble));
      await tester.pumpAndSettle();

      expect(find.byType(UserDetailPage), findsOneWidget);
      expect(adapter.bodyOf(ChatPaths.userInfo)['user_id'], 'u3');

      await disposeApp(tester);
    });

    testWidgets('会话在本地不存在：提示一句并回首页', (tester) async {
      adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
      await pumpApp(tester);

      container
          .read(appRouterProvider)
          .push('${AppRoutes.chatRecord}?id=不存在&is_group=0');
      await tester.pumpAndSettle();

      expect(toasts(), contains('联系人不存在'));
      expect(find.byType(ChatRecordPage), findsNothing);
      expect(find.text('通讯录'), findsOneWidget);

      await disposeApp(tester);
    });
  });
}
