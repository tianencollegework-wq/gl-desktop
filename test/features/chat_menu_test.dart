import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/platform/desktop_shell.dart';
import 'package:gracelinkim/core/router/app_router.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/theme/app_colors.dart';
import 'package:gracelinkim/core/ws/ws_client.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/db/message_dao.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/features/chat/widgets/chat_input.dart';
import 'package:gracelinkim/domain/chat/message_actions.dart';
import 'package:gracelinkim/features/chat/widgets/message_bubble.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 长按菜单与它背后的几个动作（S4.5）：撤回 / 复制 / 转发 / 引用 / 删除 /
/// 撤回后重新编辑 / 「N 人提到我」。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late List<MethodCall> platformCalls;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    db = memoryDatabase();
    adapter = StubAdapter();
    platformCalls = <MethodCall>[];
    // 剪贴板要经过平台通道，测试里截下来看看复制了什么
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          platformCalls.add(call);
          return null;
        });
    sessionGuard.update(ready: true, hasSession: true);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    sessionGuard.update(ready: false, hasSession: false);
    await db.close();
  });

  /// 消息时间戳（相对"现在"取，不写死日期）。
  ///
  /// 不能写死：撤回时间窗是按「现在 - 发送时间」算的（默认 24 小时），
  /// 写死成某一天之后，过了一天这个用例自己就红了（S6.3 那轮真实踩到）。
  final baseTime = DateTime.now()
      .subtract(const Duration(minutes: 5))
      .millisecondsSinceEpoch;

  Message message(
    int serverId, {
    String type = 'text',
    String content = '你好',
    String fromUserId = 'u1',
    List<String> at = const <String>[],
    Map<String, dynamic> extra = const <String, dynamic>{},
  }) => Message(
    serverId: serverId,
    msgId: 'm$serverId',
    conversationId: 'g1',
    fromUserId: fromUserId,
    fromUserName: fromUserId == 'u1' ? '我' : '小明',
    type: type,
    content: content,
    sendTime: baseTime + serverId * 1000,
    at: at,
    extra: extra,
  );

  Future<void> seedConversation({
    int isGroup = 1,
    int role = 3,
    int isAt = 0,
  }) => db.upsertConversation(
    Conversation(
      id: 'g1',
      displayName: '同学群',
      isGroup: isGroup,
      role: role,
      isAt: isAt,
      lastSendTime: baseTime,
      lastContent: '你好',
    ),
  );

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// [desktop] 打开桌面行为开关（菜单形态、回车发送……），默认关着：
  /// `flutter test` 里默认就是关的（见 `desktop_shell.dart`）。
  Future<void> pumpApp(WidgetTester tester, {bool desktop = false}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(adapter.apiClient()),
          if (desktop) desktopFeaturesProvider.overrideWithValue(true),
          wsStatusProvider.overrideWith(
            (ref) => Stream<WsStatus>.value(WsStatus.connected),
          ),
        ],
        child: const GracelinkApp(),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() => disposeApp(tester));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    container
        .read(sessionStoreProvider.notifier)
        .applyLogin(const UserInfo(userId: 'u1', displayName: '我'));
    await tester.pumpAndSettle();
    container.read(appRouterProvider).push('/message/chat?id=g1');
    await tester.pumpAndSettle();
  }

  /// 长按某条消息的气泡，打开菜单。
  ///
  /// [text] 用 `find.text` 找（表情 token 混排的消息会渲染成 `RichText`，
  /// 那种情况直接传 null 用气泡本身）。
  Future<void> openMenu(WidgetTester tester, [String? text]) async {
    await tester.longPress(
      text == null ? find.byType(MessageBubble).first : find.text(text).first,
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

  testWidgets('自己的文本消息：菜单里是撤回/复制/转发/引用/删除', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[message(1, content: '发出去的话')]);
    await pumpApp(tester);

    await openMenu(tester, '发出去的话');

    for (final label in <String>['撤回', '复制', '转发', '引用', '删除']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }

    await disposeApp(tester);
  });

  testWidgets('桌面：右键消息弹的是微信 PC 那种**白底列表**，不是手机那张深色卡片', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    // 塞一屏多条：右键打在**最上面那条**上，菜单下方有地方铺开（不然会被窗口
    // 底边拱上去，那样量到的位置就不是「指针那儿」了）
    await db.upsertMessages(<Message>[
      for (var i = 1; i <= 30; i++) message(i, content: '第$i条'),
    ]);
    await pumpApp(tester, desktop: true);

    // 鼠标上没有「长按」这个动作：右键就是那个入口（`onSecondaryTapDown`）。
    // 打在最上面那条**文字**上（列表是反向的：最新在下面，顶上那条下面才有
    // 地方把菜单铺开，菜单才不会被窗口底边拱上去）；也要点正文上 ——
    // 气泡那一行中间是空的，点空白处命中不了气泡自己的手势。
    final visible = <Finder>[
      for (var i = 1; i <= 30; i++)
        if (find.text('第$i条').evaluate().isNotEmpty) find.text('第$i条'),
    ];
    expect(visible, isNotEmpty, reason: '屏上总有几条消息');
    // 最上面那条太贴上沿的话退一条（它可能只露出下半截）
    var target = visible.first;
    if (visible.length > 1 && tester.getCenter(target).dy < 50) {
      target = visible[1];
    }
    final where = tester.getCenter(target);
    await tester.tapAt(where, buttons: kSecondaryButton);
    await tester.pumpAndSettle();

    // 动作一个不少（与手机那张卡片同一批）
    for (final label in <String>['撤回', '复制', '转发', '引用', '删除']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // 形态：白底列表（原来手机那张深色大卡片不能出现在桌面上）
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Container &&
            widget.decoration is BoxDecoration &&
            (widget.decoration! as BoxDecoration).color == AppColors.menuDark,
      ),
      findsNothing,
      reason: '深色大卡片是手指的语言，鼠标上不该出现',
    );
    for (final label in <String>['撤回', '复制', '转发', '引用', '删除']) {
      expect(
        tester.widget<Text>(find.text(label)).style?.color,
        AppColors.text333,
        reason: '$label 落在白底列表上（那档近黑）',
      );
    }
    // 位置：**就在指针那儿** —— 菜单顶 = 指针那一行（`showMenu` 的语义），横向
    // 贴着指针那条边（指针在左半边就左对齐、右半边就右对齐）。
    final item = tester.getRect(
      find.ancestor(
        of: find.text('撤回'),
        matching: find.byType(PopupMenuItem<MessageAction>),
      ),
    );
    expect(item.top, closeTo(where.dy + 8, 3), reason: '顶边贴着指针（8 是菜单自己的上内边距）');
    expect(
      math.min((item.left - where.dx).abs(), (item.right - where.dx).abs()),
      lessThan(3),
      reason: '菜单的左边或右边落在指针上',
    );

    // 点一下「复制」：真的复制（与手机那条路同一个动作）
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();
    expect(
      platformCalls.any((call) => call.method == 'Clipboard.setData'),
      isTrue,
      reason: '「复制」落到剪贴板（内容由手机那条用例钉着）',
    );
    expect(find.text('复制'), findsNothing, reason: '选完菜单关掉');

    await disposeApp(tester);
  });

  testWidgets('长按菜单是微信那张深色小卡片：白字、压在气泡上方、点别处关掉', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[message(1, content: '发出去的话')]);
    await pumpApp(tester);

    final bubbleTop = tester.getTopLeft(find.text('发出去的话')).dy;
    await openMenu(tester, '发出去的话');

    // 卡片是那个**深色**底（不是以前的白底弹层）
    final card = find.byWidgetPredicate(
      (widget) =>
          widget is Container &&
          widget.decoration is BoxDecoration &&
          (widget.decoration! as BoxDecoration).color == AppColors.menuDark,
    );
    expect(card, findsOneWidget);

    // 字是白的（老端那套深色卡片就是白图标 + 白字）
    for (final label in <String>['撤回', '复制', '转发', '引用', '删除']) {
      final text = tester.widget<Text>(find.text(label));
      expect(text.style?.color, AppColors.white, reason: label);
    }

    // 卡片压在气泡上方（下面那个尖角就是指着气泡的）
    expect(tester.getBottomLeft(card).dy, lessThanOrEqualTo(bubbleTop));

    // 点卡片外面：关掉
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('撤回'), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('撤回 → 气泡变撤回提示 → 点「重新编辑」原文回到输入框', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.undoMessage, data: null);
    await seedConversation();
    await db.upsertMessages(<Message>[message(1, content: '打错字了')]);
    await pumpApp(tester);

    await openMenu(tester, '打错字了');
    await tester.tap(find.text('撤回'));
    await tester.pumpAndSettle();

    // 接口带上服务端 id；本地那条立刻变成撤回提示（老端 updateMessage 的活）
    expect(adapter.bodyOf(ChatPaths.undoMessage)['id'], 1);
    final stored = (await db.messagesFor('g1')).single;
    expect(stored.isUndo, 1);
    expect(find.text('打错字了'), findsNothing);
    expect(find.text('你撤回了一条消息'), findsOneWidget);

    // 点「重新编辑」把原文填回输入框
    await tester.tap(find.text('重新编辑'));
    await tester.pumpAndSettle();
    expect(fieldText(tester), '打错字了');

    await disposeApp(tester);
  });

  testWidgets('复制：把文字（表情 token 变成系统表情）放进剪贴板', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    await db.upsertMessages(<Message>[message(1, content: '你好[!1f600]')]);
    await pumpApp(tester);

    // 内容是「你好[!1f600]」→ 渲染成 RichText；按气泡里那行字长按
    // （气泡本身的中心点现在落在空白处，长按会打偏）
    await openMenu(tester, '你好😀');
    await tester.tap(find.text('复制'));
    await tester.pumpAndSettle();

    final copy = platformCalls.firstWhere(
      (call) => call.method == 'Clipboard.setData',
    );
    expect((copy.arguments as Map<Object?, Object?>)['text'], '你好😀');

    await disposeApp(tester);
  });

  testWidgets('删除：先弹确认，确认后调接口并删掉本地那条', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.delMessage, data: null);
    await seedConversation();
    await db.upsertMessages(<Message>[message(1, content: '要删掉的')]);
    await pumpApp(tester);

    await openMenu(tester, '要删掉的');
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    // 老端那句确认文案
    expect(find.text('删除消息会从所有人的聊天记录中抹掉，是否确定?'), findsOneWidget);

    // 先取消：什么也不该发生
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(adapter.paths, isNot(contains(ChatPaths.delMessage)));

    await openMenu(tester, '要删掉的');
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(adapter.bodyOf(ChatPaths.delMessage)['id'], 1);
    expect(await db.messagesFor('g1'), isEmpty);
    expect(find.text('要删掉的'), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('转发：选一个目标 → forwardMessage 带 user_ids 与 msg_id', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      ChatPaths.friendList,
      data: <Map<String, dynamic>>[
        <String, dynamic>{'id': 'u2', 'displayName': '小明', 'is_group': 0},
      ],
    );
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.forwardMessage, data: null);
    await seedConversation();
    await db.upsertMessages(<Message>[message(1, content: '转发的原文')]);
    await pumpApp(tester);

    await openMenu(tester, '转发的原文');
    await tester.tap(find.text('转发'));
    await tester.pumpAndSettle();

    // 选择器里是好友 + 群聊（当前会话排掉）
    expect(find.text('小明'), findsOneWidget);
    await tester.tap(find.text('小明'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    final body = adapter.bodyOf(ChatPaths.forwardMessage);
    expect(body['user_ids'], <String>['u2']);
    expect(body['msg_id'], 'm1');

    await disposeApp(tester);
  });

  testWidgets('别人的消息：单聊里没有撤回也没有删除', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation(isGroup: 0);
    await db.upsertMessages(<Message>[
      message(1, content: '对方说的话', fromUserId: 'u2'),
    ]);
    await pumpApp(tester);

    await openMenu(tester, '对方说的话');

    expect(find.text('复制'), findsOneWidget);
    expect(find.text('转发'), findsOneWidget);
    expect(find.text('引用'), findsOneWidget);
    expect(find.text('撤回'), findsNothing);
    expect(find.text('删除'), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('群里管理员：别人的消息能给撤回，但不给删除', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation(role: 1);
    await db.upsertMessages(<Message>[
      message(1, content: '群员说的话', fromUserId: 'u2'),
    ]);
    await pumpApp(tester);

    await openMenu(tester, '群员说的话');

    expect(find.text('撤回'), findsOneWidget);
    expect(find.text('删除'), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('动态表情：菜单里有「存表情」，点了会调 emoji/add', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(EmojiPaths.add, data: null);
    await seedConversation();
    await db.upsertMessages(<Message>[
      message(
        1,
        type: 'emoji',
        content: 'https://a.test/e.gif',
        fromUserId: 'u2',
        extra: <String, dynamic>{'file_id': 31},
      ),
    ]);
    await pumpApp(tester);

    await openMenu(tester);
    expect(find.text('存表情'), findsOneWidget);
    // 老端对表情消息只给「存表情 / 转发 / 引用」
    expect(find.text('复制'), findsNothing);

    await tester.tap(find.text('存表情'));
    await tester.pumpAndSettle();
    expect(adapter.bodyOf(EmojiPaths.add)['file_id'], 31);

    await disposeApp(tester);
  });

  testWidgets('撤回时间窗过了：撤回那一项就没了（redoTime=86400 秒）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation();
    // 三天前发的，远超默认的 24 小时窗
    await db.upsertMessages(<Message>[
      Message(
        serverId: 1,
        msgId: 'm1',
        conversationId: 'g1',
        fromUserId: 'u1',
        fromUserName: '我',
        content: '很久以前',
        sendTime: DateTime.now().millisecondsSinceEpoch - 3 * 86400 * 1000,
      ),
    ]);
    await pumpApp(tester);

    await openMenu(tester, '很久以前');

    expect(find.text('撤回'), findsNothing);
    expect(find.text('复制'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('群里引用别人的消息：自动 @ 对方（老端 quoteMessage）', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
    await seedConversation();
    await db.upsertMessages(<Message>[
      message(1, content: '他说的话', fromUserId: 'u2'),
    ]);
    await pumpApp(tester);

    await openMenu(tester, '他说的话');
    await tester.tap(find.text('引用'));
    await tester.pumpAndSettle();

    // 引用条出现，输入框里也自动塞了 @小明
    expect(find.textContaining('小明：他说的话'), findsOneWidget);
    expect(fieldText(tester), '@小明 ');

    // 补一句发出去：请求体同时带 pid 与 at
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
    expect(body['at'], <String>['u2']);
    expect(body['pid'], 'm1');

    await disposeApp(tester);
  });

  testWidgets('「N 人提到我」：点开上报 readAtMsg、清掉角标、列出 @ 我的消息', (tester) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.readAtMsg, data: null);
    await seedConversation(isAt: 2);
    await db.upsertMessages(<Message>[
      message(1, content: '有人喊你', fromUserId: 'u2', at: <String>['u1']),
      message(2, content: '这条没提到我', fromUserId: 'u2'),
    ]);
    await pumpApp(tester);

    expect(find.text('2人提到我'), findsOneWidget);
    await tester.tap(find.text('2人提到我'));
    await tester.pumpAndSettle();

    // 老端 openAtModel → readAtMsg({toContactId})，本地 isAt 清零
    expect(adapter.bodyOf(ChatPaths.readAtMsg)['toContactId'], 'g1');
    final conversation = await db.findConversation('g1');
    expect(conversation!.isAt, 0);

    // 面板里只列 @ 我那条：它在「聊天气泡 + 面板」里各出现一次，
    // 而没提到我的那条只在聊天列表里（面板里不该有）
    expect(find.text('有人喊你'), findsNWidgets(2));
    expect(find.text('这条没提到我'), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('2人提到我'), findsNothing, reason: '清完之后角标要消失');

    await disposeApp(tester);
  });
}
