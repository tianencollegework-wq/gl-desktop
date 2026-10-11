import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/media/media_picker.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/router/app_router.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/store/cleared_chats.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/ws/ws_client.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
// 会话/通讯录的数据库方法都是 extension，必须 import
import 'package:gracelinkim/data/db/contact_dao.dart';
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/db/message_dao.dart';
import 'package:gracelinkim/data/model/contact.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/data/repo/chat_background_repository.dart';
import 'package:gracelinkim/features/chat/chat_info_page.dart';
import 'package:gracelinkim/features/chat/group_members_page.dart';
import 'package:gracelinkim/features/chat/group_notice_page.dart';
import 'package:gracelinkim/features/home/user_selection_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 聊天信息与群成员管理（S5.3）。
///
/// 跑整个 App：真正从聊天页右上角进聊天信息页，群里那几项（改名、公告、
/// 群管理、清空、退群/解散）与成员操作（移出、禁言）都走真实那一段链路。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    // 「清空聊天记录」的名单是单例，每个用例换一份干净的
    ClearedChatsStore.instance = ClearedChatsStore();
    await AppI18n.load('zh-Hans');
    db = memoryDatabase();
    adapter = StubAdapter();
    sessionGuard.update(ready: true, hasSession: true);
  });

  tearDown(() async {
    sessionGuard.update(ready: false, hasSession: false);
    await db.close();
  });

  final baseTime = DateTime(2026, 9, 18, 10).millisecondsSinceEpoch;

  /// 手机竖屏：群成员那一屏内容比较高，默认 800×600 会把底部的危险操作挤出屏幕
  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  /// `groupUserList` 里的一项，字段形态照老端：`{role, no_speak_time, userInfo}`
  Map<String, dynamic> member(
    String id,
    String name,
    int role, {
    int noSpeakTime = 0,
  }) => <String, dynamic>{
    'role': role,
    'no_speak_time': noSpeakTime,
    'no_speak_day': 0,
    'userInfo': <String, dynamic>{
      'id': id,
      'displayName': name,
      'avatar': '',
      'name_py': '',
    },
  };

  Contact friend(String id, {String name = '小明'}) =>
      Contact(id: id, displayName: name, indexLetter: 'X', namePy: '');

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// [chatBackground]：聊天背景那几条用例要注入「临时目录 + 假选图器」的仓库
  /// （`Override` 这个类型 flutter_riverpod 没导出，所以这里按具体 provider 传）
  Future<void> pumpApp(
    WidgetTester tester, {
    ChatBackgroundRepository? chatBackground,
  }) async {
    usePhoneViewport(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(adapter.apiClient()),
          wsStatusProvider.overrideWith(
            (ref) => Stream<WsStatus>.value(WsStatus.connected),
          ),
          if (chatBackground != null)
            chatBackgroundRepositoryProvider.overrideWithValue(chatBackground),
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

  /// 群聊（默认我是群主）
  Future<void> seedGroup({
    int role = 1,
    String notice = '',
    Map<String, dynamic> setting = const <String, dynamic>{},
  }) => db.upsertConversation(
    Conversation(
      id: 'g1',
      displayName: '产品群',
      isGroup: 1,
      role: role,
      lastSendTime: baseTime,
      lastContent: '你好',
      extra: <String, dynamic>{'notice': notice, 'setting': setting},
    ),
  );

  Future<void> pushChatInfo(
    WidgetTester tester, {
    String id = 'g1',
    int isGroup = 1,
  }) async {
    container
        .read(appRouterProvider)
        .push('${AppRoutes.chatDetail}?id=$id&is_group=$isGroup');
    await tester.pumpAndSettle();
  }

  /// 微信那两颗虚线格子（`＋` / `－`）只是图标，没有文字，用 key 找
  final addMemberTile = find.byKey(
    const ValueKey<String>('chatInfo-addMember'),
  );
  final removeMemberTile = find.byKey(
    const ValueKey<String>('chatInfo-removeMember'),
  );
  final createGroupTile = find.byKey(
    const ValueKey<String>('chatInfo-createGroup'),
  );

  testWidgets('群主进聊天信息：成员网格 + 群名称/公告/群管理 + 清空记录 + 解散群聊', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      GroupPaths.userList,
      data: <Map<String, dynamic>>[member('u1', '我', 1), member('u2', '小明', 3)],
      count: 2,
    );
    await seedGroup(notice: '今天放假', setting: <String, dynamic>{'invite': '1'});
    await pumpApp(tester);

    // 真实入口：聊天页右上角那个「⋯」
    container.read(appRouterProvider).push('${AppRoutes.chat}?id=g1');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();

    expect(find.byType(ChatInfoPage), findsOneWidget);
    // 微信标题带上人数：`聊天信息(2)`
    expect(find.text('聊天信息(2)'), findsOneWidget);
    // 成员网格：自己和小明 + 两个虚线格子（添加成员 / 移除成员）
    expect(find.text('我'), findsWidgets);
    expect(find.text('小明'), findsOneWidget);
    expect(addMemberTile, findsOneWidget);
    expect(removeMemberTile, findsOneWidget);
    expect(find.text('查看全部群成员 2 人'), findsOneWidget);
    // 老端 `count` 来自信封，这里就是传进去的 2（不是本页条数）
    expect(adapter.requestTo(GroupPaths.userList).data, <String, dynamic>{
      'group_id': 'g1',
    });
    // 群那几行
    expect(find.text('群聊名称'), findsOneWidget);
    expect(find.text('产品群'), findsWidgets);
    expect(find.text('群公告'), findsOneWidget);
    expect(find.text('今天放假'), findsOneWidget);
    expect(find.text('群管理'), findsOneWidget);
    // 群开着加群入口，所以有群二维码那一行（关了就不画，见后面那条用例）
    expect(find.text('群二维码'), findsOneWidget);
    // 开关与记录（微信的顺序：先查找聊天记录，再两个开关）
    expect(find.text('消息免打扰'), findsOneWidget);
    expect(find.text('置顶聊天'), findsOneWidget);
    expect(find.text('查找聊天记录'), findsOneWidget);
    expect(find.text('设置当前聊天背景'), findsOneWidget);
    // 「提醒」这个开关微信有、我们没有（用户明确说不要）
    expect(find.text('提醒'), findsNothing);
    // 清空记录 + 投诉（投诉只是「提交成功」的表面功夫）
    expect(find.text('清空聊天记录'), findsOneWidget);
    expect(find.text('投诉'), findsOneWidget);
    // 「群通话」那一行已经**不在这一页**了（S6.22）：入口只在聊天页的「＋」面板
    // （用户 2026-09-27 要求删掉群资料页这一栏）
    expect(find.text('群通话'), findsNothing);
    // 群主专属。⚠️ 这一页是懒建的 ListView，最底下那一块不滚下去连字都不会建出来
    await tester.scrollUntilVisible(find.text('解散群聊'), 200);
    await tester.pumpAndSettle();
    expect(find.text('解散群聊'), findsOneWidget);
    expect(find.text('退出群聊'), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('改群名：接口参数 + 本地会话和通讯录一起改名', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      GroupPaths.userList,
      data: <Map<String, dynamic>>[member('u1', '我', 1)],
      count: 1,
    );
    adapter.ok(GroupPaths.editName, data: null);
    await seedGroup();
    await db.upsertContacts(<Contact>[
      Contact(id: 'g1', displayName: '产品群', isGroup: 1),
    ]);
    await pumpApp(tester);
    await pushChatInfo(tester);

    await tester.tap(find.text('群聊名称'));
    await tester.pumpAndSettle();
    expect(find.text('修改群名称'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '新群名');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(adapter.lastBodyOf(GroupPaths.editName), <String, dynamic>{
      'id': 'g1',
      'displayName': '新群名',
    });
    // 本地两份都跟着改（老端这里有个 `updateContacts({id: ...})` 的笔误，
    // 通讯录一直是旧名字）
    final conversation = await db.findConversation('g1');
    expect(conversation?.displayName, '新群名');
    final contact = await db.findContact('g1');
    expect(contact?.displayName, '新群名');
    // 界面上的值也跟着流变了
    expect(find.text('新群名'), findsWidgets);

    await disposeApp(tester);
  });

  testWidgets('群成员页：角色标签、自己那行没有操作入口、移出成员', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      GroupPaths.userList,
      data: <Map<String, dynamic>>[
        member('u1', '我', 1),
        member('u2', '小明', 3),
        member(
          'u3',
          '小红',
          2,
          noSpeakTime:
              DateTime.now()
                  .add(const Duration(hours: 3))
                  .millisecondsSinceEpoch ~/
              1000,
        ),
      ],
      count: 3,
    );
    adapter.ok(GroupPaths.removeUser, data: null);
    await seedGroup();
    await pumpApp(tester);
    await pushChatInfo(tester);

    await tester.tap(find.text('查看全部群成员 3 人'));
    await tester.pumpAndSettle();

    expect(find.byType(GroupMembersPage), findsOneWidget);
    expect(find.text('群成员'), findsOneWidget);
    expect(find.text('群主'), findsOneWidget);
    expect(find.text('管理员'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    // 「禁言至：9-19 15:00」——同一段文字里，所以用 textContaining
    expect(find.textContaining('禁言至'), findsOneWidget);
    // 小明（普通成员）+ 小红（管理员）有「⋯」，自己的那行没有
    expect(find.byIcon(Icons.more_horiz), findsNWidgets(2));

    await tester.tap(find.byIcon(Icons.more_horiz).first);
    await tester.pumpAndSettle();
    for (final label in <String>['转让管理权限', '设置管理员', '设置禁言', '移出群聊']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }

    await tester.tap(find.text('移出群聊'));
    await tester.pumpAndSettle();
    expect(find.text('你确定移除该成员吗？'), findsOneWidget);
    expect(find.text('加入黑名单'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(adapter.lastBodyOf(GroupPaths.removeUser), <String, dynamic>{
      'id': 'g1',
      'user_id': 'u2',
      'is_black': 0,
    });
    // 移出之后重新拉了一遍成员
    expect(
      adapter.paths.where((path) => path == GroupPaths.userList).length,
      greaterThan(1),
    );

    await disposeApp(tester);
  });

  testWidgets('非群主：没有群管理，底部是「退出群聊」，退出后回消息页', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      GroupPaths.userList,
      data: <Map<String, dynamic>>[
        member('u2', '群主大人', 1),
        member('u1', '我', 3),
      ],
      count: 2,
    );
    adapter.ok(GroupPaths.removeUser, data: null);
    // 群设置开着「允许成员邀请」，所以普通成员也有「添加成员」
    await seedGroup(role: 3, setting: <String, dynamic>{'invite': '1'});
    await db.upsertContacts(<Contact>[
      Contact(id: 'g1', displayName: '产品群', isGroup: 1),
    ]);
    await pumpApp(tester);
    await pushChatInfo(tester);

    expect(find.text('群管理'), findsNothing);
    expect(find.text('解散群聊'), findsNothing);
    // 「清空聊天记录」不是管理员专属：普通成员清的是**本机**这份记录
    expect(find.text('清空聊天记录'), findsOneWidget);
    // 没权限：连「移除成员」那个虚线格子也没有，但「添加成员」还在（群设置允许邀请）
    expect(removeMemberTile, findsNothing);
    expect(addMemberTile, findsOneWidget);

    // 同上：底部那颗「退出群聊」在首屏之外，先滚到它可见再点
    await tester.scrollUntilVisible(find.text('退出群聊'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出群聊'));
    await tester.pumpAndSettle();
    expect(find.text('确定要退出群聊吗？'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // 退群 = 把自己移出成员列表
    expect(adapter.lastBodyOf(GroupPaths.removeUser), <String, dynamic>{
      'id': 'g1',
      'user_id': 'u1',
      'is_black': 0,
    });
    // 本地会话和联系人一起删（不然列表上会留一条点进去报错的死行）
    expect(await db.findConversation('g1'), isNull);
    expect(await db.findContact('g1'), isNull);
    // 回到首页（消息/通讯录/我的）
    expect(find.byType(ChatInfoPage), findsNothing);
    expect(find.text('通讯录'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('单聊信息页：没有群那几项，也不去请求群成员', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    await db.upsertConversation(
      Conversation(
        id: 'u9',
        displayName: '小明',
        lastSendTime: baseTime,
        lastContent: '在吗',
      ),
    );
    await pumpApp(tester);
    await pushChatInfo(tester, id: 'u9', isGroup: 0);

    expect(find.text('小明'), findsWidgets);
    expect(find.text('聊天信息'), findsOneWidget);
    expect(find.text('消息免打扰'), findsOneWidget);
    expect(find.text('置顶聊天'), findsOneWidget);
    expect(find.text('查找聊天记录'), findsOneWidget);
    expect(find.text('群聊名称'), findsNothing);
    expect(find.text('群公告'), findsNothing);
    expect(find.text('群管理'), findsNothing);
    expect(find.text('退出群聊'), findsNothing);
    expect(find.text('解散群聊'), findsNothing);
    expect(find.text('设置当前聊天背景'), findsOneWidget);
    // 单聊的「清空聊天记录」是**本机**清（服务端没有只清我那边的接口）
    expect(find.text('清空聊天记录'), findsOneWidget);
    expect(find.text('投诉'), findsOneWidget);
    expect(adapter.paths, isNot(contains(GroupPaths.userList)));
    // 单聊多出来的那一个入口（微信那颗虚线「＋」= 发起群聊）
    expect(find.byKey(const ValueKey<String>('chatInfo-peer')), findsOneWidget);
    expect(createGroupTile, findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('我的收藏（is_group==3）：不当群处理，没有成员/群名/公告', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    // 服务端把收藏那条会话存成 `to_user = -1` → `is_group = 3`
    await db.upsertConversation(
      Conversation(
        id: '-1',
        displayName: '我的收藏',
        isGroup: 3,
        lastSendTime: baseTime,
        lastContent: '你好',
      ),
    );
    await pumpApp(tester);
    await pushChatInfo(tester, id: '-1', isGroup: 3);

    // 群里那一套一个都不该有（用户 2026-09-21 报的：群成员0人 / 群名 / 群公告）
    expect(find.textContaining('群成员'), findsNothing);
    expect(find.text('群聊名称'), findsNothing);
    expect(find.text('群公告'), findsNothing);
    expect(find.text('群管理'), findsNothing);
    expect(find.text('群二维码'), findsNothing);
    expect(find.text('退出群聊'), findsNothing);
    expect(find.text('解散群聊'), findsNothing);
    // 也不该有「对方」那一格，更不该去请求群成员
    expect(find.byKey(const ValueKey<String>('chatInfo-peer')), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('chatInfo-createGroup')),
      findsNothing,
    );
    expect(adapter.paths, isNot(contains(GroupPaths.userList)));
    // 公共那几行还在
    expect(find.text('消息免打扰'), findsOneWidget);
    expect(find.text('置顶聊天'), findsOneWidget);
    expect(find.text('查找聊天记录'), findsOneWidget);
    expect(find.text('设置当前聊天背景'), findsOneWidget);
    expect(find.text('投诉'), findsOneWidget);
    // 标题就是普通那句，带不上人数
    expect(find.text('聊天信息'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('单聊点对方头像：**不带** group_id（带了服务端会 500）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      ChatPaths.userInfo,
      data: <String, dynamic>{
        'user_id': 'u9',
        'realname': '小明',
        'account': 'u9',
        'friend': <String, dynamic>{'friend_id': 9},
        'contactInfo': <String, dynamic>{'id': 'u9'},
      },
    );
    await db.upsertConversation(
      Conversation(
        id: 'u9',
        displayName: '小明',
        lastSendTime: baseTime,
        lastContent: '在吗',
      ),
    );
    await pumpApp(tester);
    await pushChatInfo(tester, id: 'u9', isGroup: 0);

    await tester.tap(find.byKey(const ValueKey<String>('chatInfo-peer')));
    await tester.pumpAndSettle();

    // 单聊的会话 id 就是对方的 user_id，**不能**当 group_id 发出去：
    // 服务端 `Im::getUserInfo` 里 `explode('-', $group_id)[1]` 会踩 undefined offset，
    // ThinkPHP 把 notice 抛成异常 → HTTP 500 → 界面只看到「服务器繁忙，请稍后再试」
    // （用户 2026-09-21 从单聊点进好友资料页就是这么炸的；老端那里有 `is_group==1` 判断）
    expect(adapter.bodyOf(ChatPaths.userInfo), <String, dynamic>{
      'user_id': 'u9',
    });

    await disposeApp(tester);
  });

  testWidgets('群成员点头像：带上群会话 id（详情页那块「群内管理」要用）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      GroupPaths.userList,
      data: <Map<String, dynamic>>[member('u1', '我', 1), member('u2', '小明', 3)],
      count: 2,
    );
    adapter.ok(
      ChatPaths.userInfo,
      data: <String, dynamic>{
        'user_id': 'u2',
        'realname': '小明',
        'account': 'u2',
        'contactInfo': <String, dynamic>{'id': 'u2'},
      },
    );
    // 群会话 id 的形状是服务端那种 `group-7`
    await db.upsertConversation(
      Conversation(
        id: 'group-7',
        displayName: '产品群',
        isGroup: 1,
        role: 1,
        lastSendTime: baseTime,
        lastContent: '你好',
        extra: <String, dynamic>{'notice': '', 'setting': <String, dynamic>{}},
      ),
    );
    await pumpApp(tester);
    await pushChatInfo(tester, id: 'group-7');

    await tester.tap(find.byKey(const ValueKey<String>('chatInfo-member-u2')));
    await tester.pumpAndSettle();

    expect(adapter.bodyOf(ChatPaths.userInfo), <String, dynamic>{
      'user_id': 'u2',
      'group_id': 'group-7',
    });

    await disposeApp(tester);
  });

  testWidgets('每一栏的箭头都贴最右边（用户 2026-09-21 反馈：以前停在屏幕中间）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    await db.upsertConversation(
      Conversation(
        id: 'u9',
        displayName: '小明',
        lastSendTime: baseTime,
        lastContent: '在吗',
      ),
    );
    await pumpApp(tester);
    await pushChatInfo(tester, id: 'u9', isGroup: 0);

    // 屏幕右边那条线：卡片没有左右内缩，所以箭头右边距就是行的 30rpx 内边距
    final screenRight =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    for (final label in <String>['查找聊天记录', '设置当前聊天背景', '清空聊天记录', '投诉']) {
      final row = find
          .ancestor(of: find.text(label), matching: find.byType(Row))
          .first;
      final arrow = find.descendant(
        of: row,
        matching: find.byIcon(Icons.chevron_right),
      );
      expect(arrow, findsOneWidget, reason: '「$label」这一行该有一个箭头');
      final gap = screenRight - tester.getBottomRight(arrow).dx;
      expect(gap, lessThan(40), reason: '「$label」的箭头该贴右边，不该停在中间');
    }

    await disposeApp(tester);
  });

  testWidgets('单聊的「创建群聊」：把对方预选上，建群参数带上他', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      GroupPaths.add,
      data: <String, dynamic>{'id': 'g9', 'displayName': '新群', 'is_group': 1},
    );
    await db.upsertConversation(
      Conversation(
        id: 'u9',
        displayName: '小明',
        lastSendTime: baseTime,
        lastContent: '在吗',
      ),
    );
    await db.upsertContacts(<Contact>[
      friend('u9', name: '小明'),
      friend('u2', name: '小红'),
    ]);
    await pumpApp(tester);
    await pushChatInfo(tester, id: 'u9', isGroup: 0);

    await tester.tap(createGroupTile);
    await tester.pumpAndSettle();

    expect(find.byType(UserSelectionPage), findsOneWidget);
    // 对方已经替人选上（老端的 `contact_id`）
    expect(find.text('已选 1 人'), findsOneWidget);
    expect(find.text('小红'), findsOneWidget);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(adapter.bodyOf(GroupPaths.add), <String, dynamic>{
      'user_ids': <String>['u9'],
    });

    await disposeApp(tester);
  });

  testWidgets('单聊「清空聊天记录」：本机这页清掉、列表预览也抹掉', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    await db.upsertConversation(
      Conversation(
        id: 'u9',
        displayName: '小明',
        lastSendTime: baseTime,
        lastContent: '在吗',
      ),
    );
    await db.upsertMessages(<Message>[
      Message(
        serverId: 11,
        msgId: 'm-11',
        conversationId: 'u9',
        content: '在吗',
        sendTime: baseTime,
      ),
    ]);
    await pumpApp(tester);
    await pushChatInfo(tester, id: 'u9', isGroup: 0);

    await tester.tap(find.text('清空聊天记录'));
    await tester.pumpAndSettle();
    // 单聊清的是**本机**这份记录，服务端那批一条都不删
    expect(find.textContaining('清空后本机的聊天记录'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(await db.messagesFor('u9', limit: 100), isEmpty);
    expect((await db.findConversation('u9'))!.lastContent, isEmpty);
    // 名单记下了 msgId 与 serverId，服务端再拉回来也进不去（见 message_repository）
    expect(ClearedChatsStore.instance.hides('u9', 'm-11'), isTrue);
    expect(ClearedChatsStore.instance.hides('u9', '11'), isTrue);
    // 清空不是退群，这一页还在
    expect(find.byType(ChatInfoPage), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('投诉：只做一个「提交成功 + 一个勾」的动画，不发任何请求', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    await db.upsertConversation(
      Conversation(
        id: 'u9',
        displayName: '小明',
        lastSendTime: baseTime,
        lastContent: '在吗',
      ),
    );
    await pumpApp(tester);
    await pushChatInfo(tester, id: 'u9', isGroup: 0);
    final requests = adapter.paths.length;

    await tester.tap(find.text('投诉'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('提交成功'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);

    // 过场动画自己关掉（不用点确认）：跑完 1.4 秒后弹层自己 pop
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();
    expect(find.text('提交成功'), findsNothing);
    // 服务端与协议都不动：这段只是表面功夫
    expect(adapter.paths.length, requests);

    await disposeApp(tester);
  });

  testWidgets('添加成员：从好友里挑，已经在群里的人不出现', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      GroupPaths.userList,
      data: <Map<String, dynamic>>[member('u1', '我', 1), member('u3', '小红', 3)],
      count: 2,
    );
    adapter.ok(GroupPaths.addUser, data: null);
    await seedGroup();
    await db.upsertContacts(<Contact>[
      friend('u2', name: '小明'),
      friend('u3', name: '小红'),
    ]);
    await pumpApp(tester);
    await pushChatInfo(tester);

    await tester.tap(addMemberTile);
    await tester.pumpAndSettle();

    expect(find.text('小明'), findsOneWidget);
    // 小红已经是群成员了，不该出现在候选里
    expect(find.text('小红'), findsNothing);

    await tester.tap(find.text('小明'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1'), findsOneWidget);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(adapter.lastBodyOf(GroupPaths.addUser), <String, dynamic>{
      'id': 'g1',
      'user_ids': <String>['u2'],
    });

    await disposeApp(tester);
  });

  testWidgets('普通成员点群公告：只读整页（输入框不可编辑、也没有「保存」）', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      GroupPaths.userList,
      data: <Map<String, dynamic>>[
        member('u2', '群主大人', 1),
        member('u1', '我', 3),
      ],
      count: 2,
    );
    await seedGroup(
      role: 3,
      notice: '今天放假',
      setting: <String, dynamic>{'invite': '1'},
    );
    await pumpApp(tester);
    await pushChatInfo(tester);

    await tester.tap(find.text('群公告'));
    await tester.pumpAndSettle();

    // 「不要弹窗，变成一页输入」（用户 2026-09-27）：真的是一页
    expect(find.byType(GroupNoticePage), findsOneWidget);
    // 能看
    expect(find.text('今天放假'), findsWidgets);
    // 但不能改：老端这一句靠 `disabled="!isAuth"`，新端连「保存」都不画
    expect(find.text('保存'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);

    // 返回（顶栏那颗箭头；`pageBack` 找的是英文 tooltip，这套界面是中文）
    await tester.tap(find.byType(BackButton).last);
    await tester.pumpAndSettle();
    expect(find.byType(ChatInfoPage), findsOneWidget);
    expect(adapter.paths, isNot(contains(GroupPaths.setNotice)));

    await disposeApp(tester);
  });

  testWidgets('群主点群公告：可编辑，点「保存」才发请求', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      GroupPaths.userList,
      data: <Map<String, dynamic>>[member('u1', '我', 1)],
      count: 1,
    );
    adapter.ok(GroupPaths.setNotice, data: null);
    await seedGroup(notice: '旧公告', setting: <String, dynamic>{'invite': '1'});
    await pumpApp(tester);
    await pushChatInfo(tester);

    await tester.tap(find.text('群公告'));
    await tester.pumpAndSettle();

    // 群主：整页可写，右上角一颗「保存」（老端 `common.save`）
    expect(find.byType(GroupNoticePage), findsOneWidget);
    // 旧公告已经预填在这一页里（内容从本地库取）
    expect(find.text('旧公告'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isFalse);

    await tester.enterText(find.byKey(const Key('group-notice-input')), '新公告');
    await tester.tap(find.byKey(const Key('group-notice-save')));
    await tester.pumpAndSettle();

    expect(adapter.lastBodyOf(GroupPaths.setNotice), <String, dynamic>{
      'id': 'g1',
      'notice': '新公告',
    });
    // 保存完自己退回群资料页，那一行的值也变了（`setNotice` 顺手覆盖了本地那一格）
    expect(find.byType(ChatInfoPage), findsOneWidget);
    expect(find.text('新公告'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('聊天背景：选一张留下预览、再点移除就清掉（单聊也有这一行）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    await db.upsertConversation(
      Conversation(
        id: 'u9',
        displayName: '小明',
        lastSendTime: baseTime,
        lastContent: '在吗',
      ),
    );

    // 背景是**设备本地偏好**：文档目录注入临时目录，选图走假的 picker。
    // 建目录 / 删目录都用**同步** API：组件测试跑在假时钟里，
    // 这里的 `await` 真实 I/O 会永远不返回（选图那一下同理，见下面 runAsync）
    final docs = Directory.systemTemp.createTempSync('chat-bg-page');
    addTearDown(() {
      if (docs.existsSync()) docs.deleteSync(recursive: true);
    });
    final source = File('${docs.path}/bg.png')
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final picker = _FakePicker()
      ..files = <PickedMedia>[
        PickedMedia(
          path: source.path,
          name: 'bg.png',
          size: 3,
          kind: MediaKind.image,
        ),
      ];
    final repo = ChatBackgroundRepository(
      CredentialStore.instance,
      picker,
      documentsDir: () async => docs,
    );

    await pumpApp(tester, chatBackground: repo);
    await pushChatInfo(tester, id: 'u9', isGroup: 0);

    // 老端这一行的文案（`chat.setBg`）就是「设置当前聊天背景」
    expect(find.text('设置当前聊天背景'), findsOneWidget);
    await tester.tap(find.text('设置当前聊天背景'));
    await tester.pumpAndSettle();

    // 没设过：只有「选取背景图片」，没有预览与移除
    expect(find.text('选取背景图片'), findsOneWidget);
    expect(find.text('移除背景图片'), findsNothing);

    // 选图那条路有**真实文件 I/O**（拷进应用目录），假时钟里跑不动 → runAsync
    await tester.runAsync(() async {
      await tester.tap(find.text('选取背景图片'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();

    // 选完弹层自己关了，路径已经存进 `chat-bg-info<会话 id>`
    expect(
      CredentialStore.instance.chatBackground('u9').image,
      '${docs.path}/chat-bg/u9.png',
    );

    await tester.tap(find.text('设置当前聊天背景'));
    await tester.pumpAndSettle();
    expect(find.text('移除背景图片'), findsOneWidget);
    expect(find.byType(Image), findsWidgets);

    // 移除也会删本地那份文件，同样是真实 I/O
    await tester.runAsync(() async {
      await tester.tap(find.text('移除背景图片'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(CredentialStore.instance.chatBackground('u9').image, isEmpty);

    await disposeApp(tester);
  });

  testWidgets('群关了加群入口（setting.invite != 1）：不画群二维码那一行', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      GroupPaths.userList,
      data: <Map<String, dynamic>>[member('u1', '我', 1)],
      count: 1,
    );
    // 老端那一行挂着 `v-if="contact.setting.invite"`：关了加群，这颗码扫了也进不来
    await seedGroup(setting: <String, dynamic>{'invite': '0'});
    await pumpApp(tester);
    await pushChatInfo(tester);

    expect(find.text('群公告'), findsOneWidget);
    expect(find.text('群二维码'), findsNothing);

    await disposeApp(tester);
  });
}

/// 假的选图器：聊天背景那条路只关心「选到了什么」
class _FakePicker implements MediaPicker {
  List<PickedMedia> files = const <PickedMedia>[];

  @override
  Future<List<PickedMedia>> pickImages({int limit = 9}) async => files;

  @override
  Future<PickedMedia?> pickVideo() async => null;

  @override
  Future<PickedMedia?> pickCamera() async => null;

  @override
  Future<List<PickedMedia>> pickFiles({int limit = 5}) async =>
      const <PickedMedia>[];
}
