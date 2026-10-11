import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/manual_unread.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/theme/app_colors.dart';
import 'package:gracelinkim/core/ws/ws_client.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
// 会话的数据库方法是以 extension 形式提供的，必须 import 才会进作用域
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/domain/group_call/group_call_presence.dart';
import 'package:gracelinkim/features/chat/chat_page.dart';
import 'package:gracelinkim/features/conversations/conversation_list_page.dart';
import 'package:gracelinkim/features/conversations/widgets/conversation_tile.dart';
import 'package:gracelinkim/features/group_call/group_call_sync.dart'
    show groupCallPresenceProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 列表行里那个红点（Container + 圆形 + `#FA5151`）。
///
/// 用形状区分：数字角标和底部 tab 的角标都是**圆角矩形**，只有这个点是正圆。
Finder findUnreadDot() => find.byWidgetPredicate((widget) {
  if (widget is! Container) return false;
  final decoration = widget.decoration;
  return decoration is BoxDecoration &&
      decoration.shape == BoxShape.circle &&
      decoration.color == AppColors.unreadRed;
});

/// 会话列表（S4.1）。
///
/// 跑的是完整的 App（真路由 + 真数据库 + 真仓库 + 假网络），
/// 因为这里要验的恰好是两者之间的衔接：推送/同步落库 → 列表动起来 → 点进聊天页。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late AppI18n i18n;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    i18n = await AppI18n.load('zh-Hans');
    db = memoryDatabase();
    adapter = StubAdapter();
    sessionGuard.update(ready: true, hasSession: true);
  });

  tearDown(() async {
    sessionGuard.update(ready: false, hasSession: false);
    await db.close();
  });

  /// [wsStatus] 直接给一条连接状态流（不传就按 [wsConnected] 给一条已经发完的流）；
  /// 传 `Stream.empty()` 可以复现「状态流还没吐出第一帧」的冷启动那一瞬。
  Future<void> pumpApp(
    WidgetTester tester, {
    bool wsConnected = false,
    Stream<WsStatus>? wsStatus,
  }) async {
    // 用手机尺寸的视口。默认的 800×600 是桌面尺寸，而列表行高是按 rpx
    // （相对屏宽）算的 —— 桌面尺寸下行的物理尺寸被放大两倍多，一屏只放得下
    // 两行，断言会莫名其妙地少一行。
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(adapter.apiClient()),
          // 连接状态默认停在一个流上：测试环境不会真的去连服务器
          wsStatusProvider.overrideWith(
            (ref) =>
                wsStatus ??
                Stream<WsStatus>.value(
                  wsConnected ? WsStatus.connected : WsStatus.closed,
                ),
          ),
          // 「谁在开群语音」（S6.15）：真实现会回查房间（那是网络），
          // 测试里换成一个没有回查定时器的替身，用例自己往里喂事件
          groupCallPresenceProvider.overrideWith(
            (ref) => GroupCallPresenceTracker(verifyInterval: null),
          ),
        ],
        child: const GracelinkApp(),
      ),
    );
    await tester.pumpAndSettle();
    // 同步流程里的 debugPrint 是节流的，会留一个定时器；
    // 往前推一点时间让它跑完，否则框架会报「Timer 未结束」
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> seed(List<Conversation> conversations) async {
    for (final conversation in conversations) {
      await db.upsertConversation(conversation);
    }
  }

  /// 收尾：把整棵树拆掉，让 drift 关闭查询流时留下的那个零延迟定时器跑完。
  ///
  /// drift 的 `StreamQueryStore.markAsClosed` 会 `Timer(Duration.zero, ...)`，
  /// 而框架在测试体结束时会断言「没有未完结的 Timer」。这里主动卸载一次再推一帧，
  /// 定时器就消化掉了（不这样做，测试会红、且整个文件后续用例会挂住）。
  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // 必须往前推一点时间：零时长定时器靠 elapse(Duration.zero) 不会触发
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('列表按老端规则排序：置顶在前，其余按最后消息时间倒序', (tester) async {
    adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);
    await seed(<Conversation>[
      const Conversation(
        id: 'u1',
        displayName: '张三',
        lastContent: '早上好',
        lastSendTime: 1000,
      ),
      const Conversation(
        id: 'u2',
        displayName: '李四',
        lastContent: '在吗',
        lastSendTime: 3000,
      ),
      const Conversation(
        id: 'u3',
        displayName: '置顶的群',
        isGroup: 1,
        isTop: 1,
        lastSendTime: 500,
      ),
    ]);

    await pumpApp(tester);

    final names = tester
        .widgetList<ConversationTile>(find.byType(ConversationTile))
        .map((tile) => tile.conversation.displayName)
        .toList();
    expect(names, <String>['置顶的群', '李四', '张三']);

    await disposeApp(tester);
  });

  testWidgets('未读角标：免打扰的会话只点一个小灰点，完全免打扰且无未读显示静音图标', (tester) async {
    adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);
    await seed(<Conversation>[
      const Conversation(id: 'u1', displayName: '张三', unread: 5),
      const Conversation(id: 'u2', displayName: '李四', unread: 2, isNotice: 0),
      const Conversation(id: 'u3', displayName: '王五', isNotice: 0),
    ]);

    await pumpApp(tester);

    // 非免打扰的未读报数字
    expect(find.text('5'), findsOneWidget);
    // 免打扰的不报数字（微信只有一个小灰点）
    expect(find.text('2'), findsNothing);
    // 静音图标只给第三个（免打扰且无未读）
    expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('进页面自动对齐一次会话列表（老端是每次 onShow 都拉）', (tester) async {
    adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);

    await pumpApp(tester);

    expect(adapter.paths.where((path) => path == ChatPaths.contacts).length, 1);

    await disposeApp(tester);
  });

  testWidgets('长按弹菜单（左滑不再有任何动作）', (tester) async {
    adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);
    await seed(<Conversation>[const Conversation(id: 'u1', displayName: '张三')]);

    await pumpApp(tester);

    // 左滑什么都不该发生（这一套手势已经去掉了）
    await tester.drag(find.byType(ConversationTile), const Offset(-150, 0));
    await tester.pumpAndSettle();
    expect(find.text(i18n.t('chat.isTop')), findsNothing);

    await tester.longPress(find.byType(ConversationTile));
    await tester.pumpAndSettle();

    // 默认会话是「提醒开着」，所以给的是「免扰」（老端这个按钮就是这么反着写的）
    expect(find.text(i18n.t('chat.isTop')), findsOneWidget);
    expect(find.text(i18n.t('chat.noVoice')), findsOneWidget);
    expect(find.text(i18n.t('chat.delChat')), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('长按菜单按微信的内容：标为未读 / 置顶 / 不显示该聊天 / 删除该聊天', (tester) async {
    adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);
    await seed(<Conversation>[const Conversation(id: 'u1', displayName: '张三')]);

    await pumpApp(tester);
    await tester.longPress(find.byType(ConversationTile));
    await tester.pumpAndSettle();

    expect(find.text(i18n.t('chat.markUnread')), findsOneWidget);
    expect(find.text(i18n.t('chat.isTop')), findsOneWidget);
    expect(find.text(i18n.t('chat.hideChat')), findsOneWidget);
    expect(find.text(i18n.t('chat.delChat')), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('「标为未读」：本机顶一个红点（微信不带数字）', (tester) async {
    adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);
    await seed(<Conversation>[const Conversation(id: 'u1', displayName: '张三')]);

    await pumpApp(tester);
    expect(findUnreadDot(), findsNothing);

    await tester.longPress(find.byType(ConversationTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text(i18n.t('chat.markUnread')));
    await tester.pumpAndSettle();

    // 红点出来了、数字没有（微信「标为未读」只点一个红点）
    expect(findUnreadDot(), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ConversationTile),
        matching: find.text('1'),
      ),
      findsNothing,
    );
    // 标记本身是落盘的（下次进列表还认得）
    expect(
      CredentialStore.instance.getString(ManualUnreadNotifier.storageKey),
      contains('u1'),
    );

    await disposeApp(tester);
  });

  testWidgets('进了会话页，那个红点标记就消掉', (tester) async {
    adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.setMsgIsRead);
    await seed(<Conversation>[const Conversation(id: 'u1', displayName: '张三')]);

    await pumpApp(tester);
    await tester.longPress(find.byType(ConversationTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text(i18n.t('chat.markUnread')));
    await tester.pumpAndSettle();
    expect(findUnreadDot(), findsOneWidget);

    await tester.tap(find.byType(ConversationTile));
    await tester.pumpAndSettle();
    expect(find.byType(ChatPage), findsOneWidget);
    expect(
      CredentialStore.instance.getString(ManualUnreadNotifier.storageKey),
      isNot(contains('u1')),
    );

    await disposeApp(tester);
  });

  testWidgets('「不显示该聊天」：本地藏起来，底部红点也一起不计', (tester) async {
    adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);
    await seed(<Conversation>[
      const Conversation(id: 'u1', displayName: '张三', unread: 3),
      const Conversation(id: 'u2', displayName: '李四'),
    ]);

    await pumpApp(tester);
    expect(find.byType(ConversationTile), findsNWidgets(2));
    // 底部 tab 的红角标
    expect(find.text('3'), findsOneWidget);

    await tester.longPress(find.byType(ConversationTile).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(i18n.t('chat.hideChat')));
    await tester.pumpAndSettle();

    expect(find.byType(ConversationTile), findsOneWidget);
    expect(find.text('张三'), findsNothing);
    // 藏起来的会话不该继续让底部冒红点
    expect(find.text('3'), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('置顶超过 2 条折成一行「折叠置顶聊天」，点一下展开', (tester) async {
    adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);
    await seed(<Conversation>[
      const Conversation(id: 'p1', displayName: '置顶一', isTop: 1),
      const Conversation(id: 'p2', displayName: '置顶二', isTop: 1),
      const Conversation(id: 'p3', displayName: '置顶三', isTop: 1),
      const Conversation(id: 'u1', displayName: '普通会话'),
    ]);

    await pumpApp(tester);

    // 默认折起来：只剩非置顶那条 + 末尾一行折叠入口
    expect(find.byType(ConversationTile), findsOneWidget);
    expect(find.text('普通会话'), findsOneWidget);
    expect(find.text(i18n.t('chat.foldPinned')), findsOneWidget);

    await tester.tap(find.text(i18n.t('chat.foldPinned')));
    await tester.pumpAndSettle();

    // 展开后四条都在
    expect(find.byType(ConversationTile), findsNWidgets(4));
    expect(find.text('置顶一'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('长按菜单里点「免扰」真的生效（本地先改，不等接口）', (tester) async {
    adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);
    await seed(<Conversation>[const Conversation(id: 'u1', displayName: '张三')]);

    await pumpApp(tester);
    // 一开始不是免打扰：不该有静音图标
    expect(find.byIcon(Icons.notifications_off_outlined), findsNothing);

    await tester.longPress(find.byType(ConversationTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text(i18n.t('chat.noVoice')));
    await tester.pumpAndSettle();

    // 免打扰了 → 静音图标出来，菜单也收了
    expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);
    expect(find.text(i18n.t('chat.noVoice')), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('群聊（is_group == 2）长按菜单里没有「删除」（与老端一致）', (tester) async {
    adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);
    await seed(<Conversation>[
      const Conversation(id: 'g1', displayName: '大群', isGroup: 2),
    ]);

    await pumpApp(tester);
    await tester.longPress(find.byType(ConversationTile));
    await tester.pumpAndSettle();

    expect(find.text(i18n.t('chat.isTop')), findsOneWidget);
    expect(find.text(i18n.t('chat.delChat')), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('行高按微信压过：一行不高于 70dp', (tester) async {
    adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);
    await seed(<Conversation>[const Conversation(id: 'u1', displayName: '张三')]);

    await pumpApp(tester);

    // 视口设成了 1080×2340 @3x → 逻辑宽 360dp，rpx(80) 的头像就是 38.4dp
    final height = tester.getSize(find.byType(ConversationTile)).height;
    expect(height, lessThan(70));
    expect(height, greaterThan(50));

    await disposeApp(tester);
  });

  testWidgets('语音/图片这类消息的预览是「[语音]」占位，不是文件路径', (tester) async {
    adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);
    await seed(<Conversation>[
      const Conversation(
        id: 'u1',
        displayName: '张三',
        lastType: 'voice',
        lastContent: '/storage/voice/2026-09-21/21/abc.m4a',
      ),
      const Conversation(
        id: 'u2',
        displayName: '李四',
        lastType: 'image',
        lastContent: '/storage/image/2026-09-21/21/abc.jpg',
      ),
      const Conversation(id: 'u3', displayName: '王五', lastContent: '晚上一起吃饭'),
    ]);

    await pumpApp(tester);

    expect(find.text('[${i18n.t('common.voice')}]'), findsOneWidget);
    expect(find.text('[${i18n.t('common.image')}]'), findsOneWidget);
    expect(find.text('晚上一起吃饭'), findsOneWidget);
    expect(find.textContaining('/storage/'), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('列表不再有「所有 / 未读 / @我」筛选页签（改成全面模仿微信）', (tester) async {
    adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);
    await seed(<Conversation>[
      const Conversation(id: 'u1', displayName: '完全已读'),
      const Conversation(id: 'u2', displayName: '有未读', unread: 2),
      const Conversation(id: 'u3', displayName: '有人提到我', isAt: 1),
    ]);

    await pumpApp(tester);

    // 三个会话照常都在，但页签文案应该一条都找不到了
    expect(find.byType(ConversationTile), findsNWidgets(3));
    expect(find.text(i18n.t('chat.all')), findsNothing);
    expect(find.text(i18n.t('chat.unread')), findsNothing);
    expect(find.text('@${i18n.t('chat.me')}'), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('连接断开时显示「通信断开」，可点重连', (tester) async {
    adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);

    await pumpApp(tester);

    expect(find.text(i18n.t('chat.wsDisconnect')), findsOneWidget);
    expect(find.text(i18n.t('chat.pcOnline')), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('冷启动还没拿到连接状态时显示「连接中…」，而不是「通信断开」', (tester) async {
    adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);

    // 状态流一帧都还没吐（真机上这一瞬就是 WS 还没开始连）。
    // 老实现拿「不是 connected」当断开，于是冷启动会先闪一条红色的「通信断开」，
    // 一两秒后连上了又自己消失（用户 2026-09-26 反馈）。
    await pumpApp(tester, wsStatus: const Stream<WsStatus>.empty());

    expect(find.text(i18n.t('chat.wsConnecting')), findsOneWidget);
    expect(find.text(i18n.t('chat.wsDisconnect')), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('列表第一行紧贴上面那条（外壳吃掉的状态栏高度不会被再吃一遍）', (tester) async {
    adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);
    await seed(<Conversation>[const Conversation(id: 'u1', displayName: '张三')]);

    // 真机上状态栏占掉一截（三星 76px ≈ 29dp）。外壳的导航栏已经按它撑高了，
    // 而 Flutter 的 ScrollView 在 `padding == null` 时会自动把 MediaQuery.padding
    // 当自己的 padding —— 不去掉的话第一行上方就会凭空多出一段状态栏高度的空白
    // （用户 2026-09-26 反馈的「第一栏和顶部栏中间那段空白」）。
    tester.view.padding = const FakeViewPadding(top: 76);
    await pumpApp(tester);

    final listTop = tester.getRect(find.byType(RefreshIndicator)).top;
    final firstRowTop = tester.getRect(find.byType(ConversationTile).first).top;
    expect(firstRowTop, closeTo(listTop, 1), reason: '列表第一行上方不该再留状态栏那一段');
    // 列表拿到的 MediaQuery 里，顶部内边距已经被外壳去掉了
    expect(
      MediaQuery.paddingOf(
        tester.element(find.byType(ConversationTile).first),
      ).top,
      0,
    );

    await disposeApp(tester);
  });

  testWidgets('状态从 connecting 走到 connected：提示从「连接中…」直接消失', (tester) async {
    adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);
    final statuses = StreamController<WsStatus>();
    addTearDown(statuses.close);

    await pumpApp(tester, wsStatus: statuses.stream);
    statuses.add(WsStatus.connecting);
    await tester.pumpAndSettle();
    expect(find.text(i18n.t('chat.wsConnecting')), findsOneWidget);

    statuses.add(WsStatus.connected);
    await tester.pumpAndSettle();
    // 连上之后两句话都不该出现（连上了就没什么好提示的）
    expect(find.text(i18n.t('chat.wsConnecting')), findsNothing);
    expect(find.text(i18n.t('chat.wsDisconnect')), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('多端在线且连接正常时显示「电脑端已登录」', (tester) async {
    adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);
    await seed(<Conversation>[const Conversation(id: 'u1', displayName: '张三')]);

    await pumpApp(tester, wsConnected: true);
    expect(find.text(i18n.t('chat.pcOnline')), findsNothing);

    // 「多端在线」的真实来源是 WS 的 pong 事件，这里直接写会话状态
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ConversationListPage)),
    );
    container.read(sessionStoreProvider.notifier).applyMultiport(true);
    await tester.pumpAndSettle();

    expect(find.text(i18n.t('chat.pcOnline')), findsOneWidget);
    expect(find.text(i18n.t('chat.wsDisconnect')), findsNothing);

    // 微信把这条挂在列表最上面（会话行之上），不是挂在导航栏里
    final bannerY = tester.getTopLeft(find.text(i18n.t('chat.pcOnline'))).dy;
    final firstRowY = tester.getTopLeft(find.byType(ConversationTile).first).dy;
    expect(bannerY, lessThan(firstRowY));

    await disposeApp(tester);
  });

  testWidgets('有人在开语音的群：那一行挂上「语音通话中」', (tester) async {
    adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);
    await seed(<Conversation>[
      const Conversation(
        id: 'group-100',
        displayName: '产品群',
        isGroup: 1,
        lastContent: '在吗',
      ),
      const Conversation(id: 'u1', displayName: '张三', lastContent: '早上好'),
    ]);

    await pumpApp(tester);
    expect(find.text(i18n.t('group.callInProgress')), findsNothing);

    // 服务端推来「这个群有人开语音」（长连接那条 `sfuRoom`）
    final presence = ProviderScope.containerOf(
      tester.element(find.byType(ConversationListPage)),
    ).read(groupCallPresenceProvider);
    presence.onRoomEvent(<String, dynamic>{
      'room_id': '100',
      'epoch': 2,
      'live': true,
      'call_id': 'c1',
    });
    await tester.pump();

    // 标记只上那一行：预览那一位换成它，好友那一行不动
    expect(find.text(i18n.t('group.callInProgress')), findsOneWidget);
    expect(find.text('在吗'), findsNothing);
    expect(find.text('早上好'), findsOneWidget);

    // 散场了：标记收掉，预览回到最后一条消息
    presence.onRoomEvent(<String, dynamic>{
      'room_id': '100',
      'epoch': 3,
      'live': false,
      'call_id': 'c1',
    });
    await tester.pump();

    expect(find.text(i18n.t('group.callInProgress')), findsNothing);
    expect(find.text('在吗'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('点会话进聊天页', (tester) async {
    adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);
    await seed(<Conversation>[const Conversation(id: 'u1', displayName: '张三')]);

    await pumpApp(tester);
    await tester.tap(find.byType(ConversationTile));
    await tester.pumpAndSettle();

    // S4.2 起落到真聊天页：标题就是会话名，说明路由与 `?id=` 都传对了
    expect(find.byType(ChatPage), findsOneWidget);
    expect(find.text('张三'), findsWidgets);

    await disposeApp(tester);
  });

  testWidgets('没有会话时显示占位文案，且仍能下拉刷新', (tester) async {
    adapter.ok(ChatPaths.contacts, data: <Map<String, dynamic>>[]);

    await pumpApp(tester);

    expect(find.text(i18n.t('common.noData')), findsOneWidget);
    expect(find.byType(ConversationListPage), findsOneWidget);
    expect(find.byType(RefreshIndicator), findsOneWidget);

    await disposeApp(tester);
  });
}
