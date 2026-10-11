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
// 会话/消息的数据库方法是以 extension 形式提供的，必须 import
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/db/message_dao.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/data/model/sfu_models.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/domain/chat/group_members.dart';
import 'package:gracelinkim/domain/group_call/group_call_presence.dart';
import 'package:gracelinkim/domain/group_call/sfu_room.dart';
import 'package:gracelinkim/features/chat/chat_page.dart';
import 'package:gracelinkim/features/chat/widgets/message_bubble.dart';
import 'package:gracelinkim/features/group_call/group_call_controller.dart';
import 'package:gracelinkim/features/group_call/group_call_page.dart';
import 'package:gracelinkim/features/group_call/group_call_session.dart'
    show groupCallSessionProvider;
import 'package:gracelinkim/features/group_call/group_call_sync.dart'
    show groupCallPresenceProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../group_call/support/fake_sfu.dart';
import '../support/fake_call_keep_alive.dart';
import '../support/test_database.dart';

/// 聊天页（S4.2）。
///
/// 跑整个 App（真路由 + 内存库 + 假网络），因为要验的正是「从会话列表点进来」这条链路：
/// 路由参数、进入清未读、本地缓存与接口历史的配合、正在看时上报已读。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late ProviderContainer container;

  /// 群通话那间屋子的假控制面（房间里是「我 + 小明」两位）
  late FakeSfuControl groupControl;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    // 装上语言包（`AppI18n.load` 会替换静态单例，界面靠它取词）
    await AppI18n.load('zh-Hans');
    db = memoryDatabase();
    adapter = StubAdapter();
    groupControl = FakeSfuControl()
      ..snapshot = SfuRoomState(
        epoch: 1,
        members: <SfuRoomMember>[
          member('u1', 'sess-publish-1', <String>['mic']),
          member('u2', 'sess-pub-u2', <String>['mic']),
        ],
      );
    sessionGuard.update(ready: true, hasSession: true);
  });

  tearDown(() async {
    sessionGuard.update(ready: false, hasSession: false);
    await db.close();
  });

  /// 2026-09-18 10:00:00（跟 buildChatItems 的测试同一套时间口径）
  final baseTime = DateTime(2026, 9, 18, 10).millisecondsSinceEpoch;

  Map<String, dynamic> serverMessage({
    required int id,
    required String msgId,
    String content = '你好',
    int? sendTime,
    String type = 'text',
  }) => <String, dynamic>{
    'id': id,
    'msg_id': msgId,
    'content': content,
    'type': type,
    'sendTime': sendTime ?? baseTime ~/ 1000,
    'at': <String>[],
    'is_group': 0,
    'fromUser': <String, dynamic>{'id': 'u2', 'displayName': '小明'},
    'toContactId': 'u2',
  };

  Message localMessage(
    int index, {
    String fromUserId = 'u2',
    String? content,
    int? sendTime,
  }) => Message(
    serverId: index,
    msgId: 'm$index',
    conversationId: 'u2',
    fromUserId: fromUserId,
    fromUserName: fromUserId == 'u2' ? '小明' : '我',
    type: 'text',
    content: content ?? '消息$index',
    sendTime: sendTime ?? baseTime + index * 1000,
    isGroup: 0,
  );

  Future<void> seedConversation({int unread = 0, int isGroup = 0}) =>
      db.upsertConversation(
        Conversation(
          id: 'u2',
          displayName: '小明',
          unread: unread,
          isGroup: isGroup,
          lastSendTime: baseTime,
          lastContent: '你好',
        ),
      );

  /// 把整棵树拆掉：drift 的流订阅与定时器会一直拽住测试，不拆会拖累后面所有用例
  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// [groupCall]：群通话那一条用例要注入本地替身
  /// [presence]：群语音在线状态那本账（聊天页顶上那条「N 人正在语音通话」靠它）
  /// （`Override` 这个类型 flutter_riverpod 没导出，所以这里按具体 provider 传）
  Future<void> pumpApp(
    WidgetTester tester, {
    String? id = 'u2',
    GroupCallControllerFactory? groupCall,
    GroupCallPresenceTracker? presence,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(adapter.apiClient()),
          wsStatusProvider.overrideWith(
            (ref) => Stream<WsStatus>.value(WsStatus.connected),
          ),
          if (groupCall != null)
            groupCallControllerFactoryProvider.overrideWithValue(groupCall),
          if (presence != null)
            groupCallPresenceProvider.overrideWithValue(presence),
        ],
        child: const GracelinkApp(),
      ),
    );
    await tester.pumpAndSettle();
    // 切到登录用户（会话/消息里的“我”靠它判断左右）
    container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    container
        .read(sessionStoreProvider.notifier)
        .applyLogin(const UserInfo(userId: 'u1', displayName: '我'));
    await tester.pumpAndSettle();

    // 直接进聊天页（等价于从会话列表点进来）
    final router = container.read(appRouterProvider);
    router.push('/message/chat?id=$id');
    await tester.pumpAndSettle();

    // 兜底：用例中途失败时也要把树拆掉，否则 drift 的定时器会拖住后面所有用例
    addTearDown(() => disposeApp(tester));
  }

  /// 列表当前有多少行（`ListView.builder` 会把 `itemCount` 挂到 semanticChildCount 上）
  int listRows(WidgetTester tester) =>
      tester.widget<ListView>(find.byType(ListView)).semanticChildCount!;

  testWidgets('本地有缓存：先出缓存，同时补一次最新一页', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      localMessage(1, content: '早', sendTime: baseTime),
      localMessage(2, content: '晚', sendTime: baseTime + 60 * 1000),
    ]);

    await pumpApp(tester);

    expect(find.text('早'), findsOneWidget);
    expect(find.text('晚'), findsOneWidget);
    // 进页面必须补一次「最新一页」（空 last_id / page 1，与老端每次进聊天页一致）：
    // 离线 / 断线期间漏掉的推送只在服务端，不补就是「列表有预览、点进去什么都没有」
    expect(adapter.paths, contains(ChatPaths.messageList));
    expect(adapter.bodyOf(ChatPaths.messageList), <String, dynamic>{
      'is_group': 0,
      'toContactId': 'u2',
      'last_id': '',
      'page': 1,
      'limit': 20,
    });
    // 但「往上翻历史」仍然是本地优先（见下一个用例），这一步不动窗口，
    // 也没确认「这就是会话的开头」，所以最旧那条上方先不画时间条
    expect(find.byType(ChatTimeDivider), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('本地没有缓存：拉第一页历史，参数与老端一致', (tester) async {
    adapter.ok(
      ChatPaths.messageList,
      data: <Map<String, dynamic>>[
        serverMessage(id: 1, msgId: 'm1', content: '来自服务端'),
      ],
    );
    await seedConversation();

    await pumpApp(tester);

    expect(find.text('来自服务端'), findsOneWidget);
    expect(adapter.bodyOf(ChatPaths.messageList), <String, dynamic>{
      'is_group': 0,
      'toContactId': 'u2',
      'last_id': '',
      'page': 1,
      'limit': 20,
    });
    // 服务端给的是一页不满（1 < 20）→ 说明已经到头了，最旧那条上方补时间分隔
    final divider = tester.widget<ChatTimeDivider>(
      find.byType(ChatTimeDivider),
    );
    // 当天显示「时:分」，不是当天会带月日，所以只断言时间部分
    expect(divider.text, contains('10:00'));

    await disposeApp(tester);
  });

  testWidgets('进页面：清本地未读，并按发送人把未读在服务端标掉', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.setMsgIsRead);
    await seedConversation(unread: 3);
    await db.upsertMessages(<Message>[localMessage(1)]);

    await pumpApp(tester);

    final stored = await db.findConversation('u2');
    expect(stored!.unread, 0);
    // 老端进页面只清本地，服务端未读还在 → 下拉刷新（getContacts）角标又回来了。
    // 新端把「未读是谁发的」提前记下来，进页面时补一次上报
    expect(adapter.bodyOf(ChatPaths.setMsgIsRead), <String, dynamic>{
      'toContactId': 'u2',
      'is_group': 0,
      'fromUser': 'u2',
      // `messages` 必须有：服务端第一行就读 `$param['messages']`，
      // 少了它 PHP notice → HTTP 500（线上日志里一条条都是这个）
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{'fromUser': 'u2'},
      ],
    });

    await disposeApp(tester);
  });

  testWidgets('正在看时收到新消息：本地清未读 + 上报已读', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.setMsgIsRead);
    await seedConversation();
    await db.upsertMessages(<Message>[localMessage(1)]);

    await pumpApp(tester);

    // 模拟服务端推来一条新消息（追加更晚的一条）
    await db.upsertMessages(<Message>[
      localMessage(2, content: '刚发的', sendTime: baseTime + 5000),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('刚发的'), findsOneWidget);
    expect(adapter.bodyOf(ChatPaths.setMsgIsRead), <String, dynamic>{
      'toContactId': 'u2',
      'is_group': 0,
      'fromUser': 'u2',
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{'fromUser': 'u2'},
      ],
    });

    await disposeApp(tester);
  });

  testWidgets('自己发的消息不上报已读', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();

    await pumpApp(tester);

    await db.upsertMessages(<Message>[
      localMessage(2, fromUserId: 'u1', content: '我发的'),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('我发的'), findsOneWidget);
    expect(adapter.paths, isNot(contains(ChatPaths.setMsgIsRead)));

    await disposeApp(tester);
  });

  testWidgets('标题显示会话名；别人发来的消息带名字与群角色标签', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[localMessage(1)]);

    await pumpApp(tester);

    // 顶栏是自己画的（不是 AppBar），标题显示会话名
    expect(find.byType(AppBar), findsNothing);
    expect(find.text('小明'), findsWidgets);
    expect(find.byType(MessageBubble), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('往上滑先吃本地缓存：窗口从 20 放大到 40，本地吃光才去服务端', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      for (var i = 1; i <= 24; i++) localMessage(i),
    ]);

    await pumpApp(tester);
    // 窗口只有 20 条（最新的那 20 条），最旧的 4 条还没进列表
    expect(listRows(tester), 20);
    // 进页面这一次只是「补最新一页」（last_id 空），还没有往更早翻
    expect(adapter.bodyOf(ChatPaths.messageList), <String, dynamic>{
      'is_group': 0,
      'toContactId': 'u2',
      'last_id': '',
      'page': 1,
      'limit': 20,
    });

    // reverse 列表（`AxisDirection.up`）：手指往下拖 = 往上看更早的消息。
    // 拖到头（`extentAfter` 进 400 以内）才会触发「加载更多」，
    // 这里一直拖到最旧那条露出来为止
    // 第一个 Scrollable 是聊天列表；输入框里的 TextField 自己也是一个 Scrollable，
    // 不限定的话会报 “Too many elements”
    await tester.scrollUntilVisible(
      find.text('消息1'),
      400,
      scrollable: find.byType(Scrollable).first,
    );

    // 库里那 4 条旧消息进来了——接口这份存根返回的是空数组，
    // 所以它们只能来自本地缓存：这就是「先吃本地」
    expect(find.text('消息1'), findsOneWidget);
    // 本地吃光（24 < 窗口 40）之后才轮到服务端，
    // 游标是「当前手里最旧那条」的 msg_id（老端取列表第一个）
    // ——取最后一次请求：进页面那一次是补最新一页（last_id 空）
    expect(adapter.lastBodyOf(ChatPaths.messageList), <String, dynamic>{
      'is_group': 0,
      'toContactId': 'u2',
      'last_id': 'm1',
      'page': 1,
      'limit': 20,
    });

    await disposeApp(tester);
  });

  testWidgets('加载更多不会把界面弹回最底下（用户 2026-09-21 反馈的那个跳）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[
      for (var i = 1; i <= 40; i++) localMessage(i),
    ]);
    await pumpApp(tester);

    final scrollable = find.byType(Scrollable).first;
    double offset() =>
        tester.state<ScrollableState>(scrollable).position.pixels;

    // reverse 列表：手指往下拖 = 往上看更早的消息（pixels 从 0 往大走）。
    // 一直拖到最旧那条（`extentAfter` 进 400 以内）才会触发「加载更多」
    await tester.drag(scrollable, const Offset(0, 4000));
    await tester.pumpAndSettle();

    // 这一拖会触发「加载更多」把窗口一页页放大。以前每放大一页就换了一个
    // provider，而它头一帧只有 loading、列表是空的 —— 反向列表的位移被夹回 0，
    // 界面直接跳回最新那条（用户 2026-09-21 反馈：转完圈就回到最底下）。
    expect(find.text('消息40'), findsNothing, reason: '窗口放大不该把视线弹回最底下');
    expect(offset(), greaterThan(1000), reason: '还应该停在上面的历史里');

    await disposeApp(tester);
  });

  testWidgets('系统会话（is_group == 2）：不给输入框，也没有「更多」按钮', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation(isGroup: 2);
    await db.upsertMessages(<Message>[localMessage(1)]);

    await pumpApp(tester);

    expect(find.text('消息1'), findsOneWidget);
    // 老端 chat.vue：`v-if="is_group!=2"` 同时管着「更多」按钮与输入框
    expect(find.byIcon(Icons.more_horiz), findsNothing);
    expect(find.text('发送'), findsNothing);

    await disposeApp(tester);
  });

  /// 打开「＋」面板（照片 / 视频 / 文件 / [通话] / 名片）
  Future<void> openMorePanel(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();
  }

  testWidgets('单聊：「＋」面板里有语音/视频通话', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[localMessage(1)]);

    await pumpApp(tester);
    await openMorePanel(tester);

    expect(find.text('语音通话'), findsOneWidget);
    expect(find.text('视频通话'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('「我的收藏」这类会话（is_group == 3）：不给通话入口', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await db.upsertConversation(
      const Conversation(id: 'favors', displayName: '我的收藏', isGroup: 3),
    );
    await db.upsertMessages(<Message>[
      Message(
        serverId: 1,
        msgId: 'm1',
        conversationId: 'favors',
        fromUserId: 'u2',
        content: '消息1',
        sendTime: baseTime,
      ),
    ]);

    await pumpApp(tester, id: 'favors');
    await openMorePanel(tester);

    // 老端 `im-input.vue` 的条件是 `!contact.is_group && webrtc`：
    // 非 0（群聊 1 / 系统通知 2 / 应用号·收藏 3）一律不给这两项，
    // 新端之前只排了群聊，所以在收藏里也冒出了通话按钮
    expect(find.text('语音通话'), findsNothing);
    expect(find.text('视频通话'), findsNothing);
    // 面板本身是开的（不然上面的 findsNothing 什么都没验到）
    expect(find.text('相册'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('跟自己聊（会话 id 就是自己）：不给通话入口', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await db.upsertConversation(
      const Conversation(id: 'u1', displayName: '我', isGroup: 0),
    );
    await db.upsertMessages(<Message>[
      Message(
        serverId: 1,
        msgId: 'm1',
        conversationId: 'u1',
        fromUserId: 'u1',
        content: '消息1',
        sendTime: baseTime,
      ),
    ]);

    await pumpApp(tester, id: 'u1');
    await openMorePanel(tester);

    expect(find.text('语音通话'), findsNothing);
    expect(find.text('视频通话'), findsNothing);
    expect(find.text('相册'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('设过聊天背景：聊天页把本机那张图铺在消息后面', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    // 老端存的就是**本机文件路径**（`uni.saveFile` 的产物）
    await CredentialStore.instance.saveChatBackground(
      'u2',
      image: '/definitely/not/here.jpg',
      filter: false,
    );

    await pumpApp(tester);

    final images = tester.widgetList<Image>(find.byType(Image));
    expect(
      images.any(
        (image) =>
            image.image is FileImage &&
            (image.image as FileImage).file.path == '/definitely/not/here.jpg',
      ),
      isTrue,
      reason: '聊天页该用 Image.file 铺本机那张背景图',
    );

    await disposeApp(tester);
  });

  testWidgets('输入区与聊天区分得开：底色比聊天区浅一档 + 顶上一条细线', (tester) async {
    // 用户 2026-09-29：「底部栏跟聊天信息区域高一点颜色区别啊分割一下，
    // 现在完全是融合在一起的」，并给了微信截图。两件事要同时成立：
    // 输入区底色**不等于**聊天区那层灰，而且**更浅**（微信 #F7F7F7 vs #EDEDED），
    // 再加一条上分割线把两块切开。
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();

    await pumpApp(tester);

    final bar = tester.widget<Container>(
      find.byKey(const ValueKey<String>('chatInputBar')),
    );
    final decoration = bar.decoration! as BoxDecoration;
    final chatArea = tester
        .widget<Scaffold>(
          find
              .descendant(
                of: find.byType(ChatPage),
                matching: find.byType(Scaffold),
              )
              .first,
        )
        .backgroundColor!;

    expect(
      decoration.color,
      isNot(chatArea),
      reason: '输入区与聊天区同一档灰就是用户说的「融合在一起」',
    );
    expect(
      decoration.color!.computeLuminance(),
      greaterThan(chatArea.computeLuminance()),
      reason: '微信里输入区比聊天区**浅**一档',
    );
    final border = decoration.border! as Border;
    expect(border.top.width, greaterThan(0), reason: '两块之间那条分割线');

    await disposeApp(tester);
  });

  testWidgets('没设过背景：不铺任何背景图（消息列表直接用）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();

    await pumpApp(tester);

    final images = tester.widgetList<Image>(find.byType(Image));
    expect(
      images.any((image) => image.image is FileImage),
      isFalse,
      reason: '没设过背景就不该有本机图片',
    );

    await disposeApp(tester);
  });

  /// 打完一通留在群里那条记录：type 还是 webrtc（老端的 `im-webrtc.vue` 直接显示
  /// `content`），多一个 `group_call` 记号告诉新端「点一下该弹详情卡」。
  Future<void> seedGroupConversation() => db.upsertConversation(
    Conversation(
      id: 'group-9',
      displayName: '产品群',
      isGroup: 1,
      lastSendTime: baseTime,
      lastContent: '群通话 00:45',
    ),
  );

  Future<void> seedGroupCallRecord() async {
    await seedGroupConversation();
    await db.upsertMessages(<Message>[
      Message(
        serverId: 9,
        msgId: 'm9',
        conversationId: 'group-9',
        fromUserId: 'u2',
        fromUserName: '小明',
        type: 'webrtc',
        content: '群通话 00:45',
        sendTime: baseTime,
        isGroup: 1,
        ext: <String, dynamic>{
          'type': 0,
          'group_call': 1,
          'callTime': 45,
          'participants': 3,
        },
      ),
    ]);
  }

  /// 群通话页自己那一套（真 WebRTC 要原生）换成本地替身
  GroupCallController groupCallController() => GroupCallController(
    groupName: '产品群',
    room: SfuRoom(
      roomId: '9',
      myUserId: 'u1',
      control: groupControl,
      local: FakeSfuLocalMedia(),
      connectionFactory: FakeSfuConnections().call,
      audioLevelPollInterval: null,
      heartbeatInterval: null,
      stateRefreshInterval: null,
    ),
    loadMembers: () async => const <GroupMember>[],
    keepAlive: FakeCallKeepAlive(),
    notify: (key) => debugPrint('提示：$key'),
  );

  testWidgets('群里的通话记录：先弹详情卡，点「再次发起」才进群通话页', (tester) async {
    // 画布设成**手机尺寸**（1080x2280 @3x → 360x760）：默认那个 800x600 又宽又矮，
    // 弹层里的尺寸是按 750 设计宽换算的，在那个画布上会算出比屏幕还高的内容
    // （与 `group_call_page_test.dart` 同一个坑）。
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedGroupCallRecord();

    await pumpApp(
      tester,
      id: 'group-9',
      groupCall: ({required String conversationId, required String name}) =>
          groupCallController(),
    );

    // 没人开语音：顶上那条不画
    expect(find.text('语音通话中'), findsNothing);

    await tester.tap(find.text('群通话 00:45'));
    await tester.pumpAndSettle();

    // 详情卡：时长（与气泡里那个数同一个口径）、人数、主操作
    expect(find.text('通话时长'), findsOneWidget);
    expect(find.text('00:45'), findsOneWidget);
    expect(find.text('参与人数'), findsOneWidget);
    expect(find.text('3 人在通话'), findsOneWidget);
    // 这一通早散了 → 主操作是「再次发起」（还在开的话才是「加入」）
    expect(find.text('再次发起'), findsOneWidget);
    // **点记录本身不会进房间**：进去就是加入，会把离线群成员的手机叫醒
    expect(find.byType(GroupCallPage), findsNothing);
    expect(adapter.paths, isNot(contains(ChatPaths.sendToMsg)));

    await tester.tap(find.text('再次发起'));
    await tester.pumpAndSettle();

    expect(find.byType(GroupCallPage), findsOneWidget);
    expect(find.text('产品群'), findsWidgets);
    // 不要去拨一通 1:1：老端 `calling(item.extends.type)` 那条路只该给 1:1 的记录走
    expect(adapter.paths, isNot(contains(ChatPaths.sendToMsg)));

    await disposeApp(tester);
  });

  testWidgets('群聊的「＋」面板里有「群通话」（与私聊同一个位置），点一下进会', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedGroupConversation();

    await pumpApp(
      tester,
      id: 'group-9',
      groupCall: ({required String conversationId, required String name}) =>
          groupCallController(),
    );

    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pumpAndSettle();

    // 群里给「群通话」——与私聊那两颗同一个位置。
    // 群资料页那一栏已经删了（S6.22，用户要求：入口只留「＋」面板这一处）
    expect(find.text('群通话'), findsOneWidget);
    // 单聊那两项群里不给（群通话只有语音，没有全员视频）
    expect(find.text('语音通话'), findsNothing);
    expect(find.text('视频通话'), findsNothing);

    await tester.tap(find.text('群通话'));
    await tester.pumpAndSettle();

    expect(find.byType(GroupCallPage), findsOneWidget);
    expect(find.text('产品群'), findsWidgets);

    await disposeApp(tester);
  });

  testWidgets('群里有人开语音：聊天页顶上挂一条「N 人在通话 · 加入」，点一下进会', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedGroupConversation();

    // 服务端推来一条 `sfuRoom`（没带 `started`：不是「刚开」那一下，所以不弹横幅，
    // 但「这个群有人在语音」这个事实成立了）
    final presence = GroupCallPresenceTracker()
      ..onRoomEvent(<String, dynamic>{
        'room_id': '9',
        'live': true,
        'call_id': 'c1',
        'members': 3,
      });
    addTearDown(presence.dispose);

    await pumpApp(
      tester,
      id: 'group-9',
      presence: presence,
      groupCall: ({required String conversationId, required String name}) =>
          groupCallController(),
    );

    expect(find.text('3 人在通话'), findsOneWidget);
    expect(find.text('加入'), findsOneWidget);

    await tester.tap(find.text('加入'));
    await tester.pumpAndSettle();

    expect(find.byType(GroupCallPage), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('在线条：人数没推下来时不带数字（这条提示别因一个数字就不显示）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedGroupConversation();

    final presence = GroupCallPresenceTracker()
      ..onRoomEvent(<String, dynamic>{
        'room_id': '9',
        'live': true,
        'call_id': 'c1',
      });
    addTearDown(presence.dispose);

    await pumpApp(tester, id: 'group-9', presence: presence);

    expect(find.text('语音通话中'), findsOneWidget);
    expect(find.text('加入'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('我自己就在这一通里：顶上那条是「回到通话」，点一下回页面', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedGroupConversation();

    await pumpApp(
      tester,
      id: 'group-9',
      groupCall: ({required String conversationId, required String name}) =>
          groupCallController(),
    );

    // 我在通话里（页面关着：退出通话页不等于挂断），聊天页顶上那条该变成「回到通话」
    await container
        .read(groupCallSessionProvider)
        .join(conversationId: 'group-9', name: '产品群');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();

    final bar = find.byKey(const Key('group-call-bar'));
    expect(bar, findsOneWidget);
    expect(
      find.descendant(of: bar, matching: find.text('2 人在通话')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: bar, matching: find.text('回到通话')),
      findsOneWidget,
      reason: '我自己就在这一通里，右边那颗不该再写「加入」',
    );
    // （同一屏上还有一颗小窗 —— 那是「退出通话页之后」的提示，不在这一条上）
    expect(find.text('加入'), findsNothing);

    await tester.tap(find.descendant(of: bar, matching: find.text('回到通话')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(GroupCallPage), findsOneWidget);

    await disposeApp(tester);
  });
}
