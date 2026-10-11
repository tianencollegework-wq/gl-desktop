import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/theme/app_colors.dart';
import 'package:gracelinkim/core/ws/ws_client.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
// 会话/通讯录的数据库方法都是 extension，必须 import
import 'package:gracelinkim/data/db/contact_dao.dart';
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/model/contact.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/features/chat/chat_page.dart';
import 'package:gracelinkim/features/contacts/group_list_page.dart';
import 'package:gracelinkim/features/contacts/new_friends_page.dart';
import 'package:gracelinkim/features/contacts/user_detail_page.dart';
import 'package:gracelinkim/features/contacts/widgets/contact_index_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 通讯录 tab（S5.1）。
///
/// 跑整个 App：从底部 tab 切进通讯录，验的是真实那段链路
/// （本地库的流 → 分组 → 索引条 → 路由跳转）。
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

  Contact friend(
    String id, {
    String name = '小明',
    String index = 'X',
    String py = 'xiaoming',
    int isGroup = 0,
    int online = 0,
  }) => Contact(
    id: id,
    displayName: name,
    namePy: py,
    indexLetter: index,
    isGroup: isGroup,
    isOnline: online,
  );

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// 手机竖屏尺寸（默认的 800×600 装不下通讯录那几行，会看不到后面的分组）
  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpContacts(WidgetTester tester) async {
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

    // 底部 tab：通讯录
    await tester.tap(find.text('通讯录'));
    await tester.pumpAndSettle();
    addTearDown(() => disposeApp(tester));
  }

  testWidgets('好友按字母分组，顶部有入口，底部有总数', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    await db.upsertContacts(<Contact>[
      friend('u2', name: '小明', index: 'X', online: 1),
      friend('u3', name: '小红', index: 'X'),
      friend('u4', name: 'Alice', index: 'A'),
      // 字母、拼音都没有 → 落到 `#` 组（helper 的 py 默认是 xiaoming，得显式清掉）
      friend('u5', name: '没有拼音的人', index: '', py: ''),
      friend('g1', name: '产品群', index: 'C', isGroup: 1),
      friend('system', name: '系统通知', isGroup: 2),
    ]);

    await pumpContacts(tester);

    // 顶部三块入口
    expect(find.text('新的朋友'), findsOneWidget);
    expect(find.text('群聊'), findsOneWidget);
    expect(find.text('系统通知'), findsOneWidget);
    // 分组字母（A / X / #；群聊与系统通知不参与分组）。
    // 「X」在分组表头和右侧索引条上各有一个，所以分开断言
    for (final letter in <String>['A', 'X', '#']) {
      expect(
        find.descendant(
          of: find.byType(SingleChildScrollView),
          matching: find.text(letter),
        ),
        findsOneWidget,
        reason: '分组表头 $letter',
      );
      expect(
        find.descendant(
          of: find.byType(ContactIndexBar),
          matching: find.text(letter),
        ),
        findsOneWidget,
        reason: '索引条 $letter',
      );
    }
    // 好友行
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('小明'), findsOneWidget);
    expect(find.text('小红'), findsOneWidget);
    expect(find.text('没有拼音的人'), findsOneWidget);
    // 群聊不进好友列表
    expect(find.text('产品群'), findsNothing);
    // 底部计数只数好友
    expect(find.text('4 位朋友'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('一进页面就对齐通讯录（好友 + 群聊两个接口）', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(FriendPaths.applyList, data: <Map<String, dynamic>>[]);

    await pumpContacts(tester);

    expect(adapter.paths, contains(ChatPaths.friendList));
    expect(adapter.paths, contains(ChatPaths.groupList));
    // 申请列表的 body 与老端一致
    expect(adapter.bodyOf(FriendPaths.applyList), <String, dynamic>{
      'page': 1,
      'limit': 50,
      'is_mine': 0,
    });

    await disposeApp(tester);
  });

  testWidgets('接口推来的好友会直接出现在列表里（两端对齐后落库）', (tester) async {
    adapter.ok(
      ChatPaths.friendList,
      data: <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'u9',
          'displayName': '新朋友',
          'is_group': 0,
          'index': 'X',
          'name_py': 'xinyou',
        },
      ],
    );
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);

    await pumpContacts(tester);

    expect(find.text('新朋友'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('待处理的好友申请数挂在「新的朋友」后面', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      FriendPaths.applyList,
      data: <Map<String, dynamic>>[
        <String, dynamic>{'id': 1, 'status': 2},
        <String, dynamic>{'id': 2, 'status': 2},
        <String, dynamic>{'id': 3, 'status': 1},
      ],
    );

    await pumpContacts(tester);

    expect(find.text('2'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('点好友进用户详情页（S5.2），带的是对方的 user_id', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(
      ChatPaths.userInfo,
      data: <String, dynamic>{
        'user_id': 'u2',
        'realname': '小明',
        'account': '13800000000',
        'friend': <String, dynamic>{'friend_id': 2, 'nickname': ''},
      },
    );
    await db.upsertContacts(<Contact>[friend('u2', name: '小明')]);

    await pumpContacts(tester);
    await tester.tap(find.text('小明'));
    await tester.pumpAndSettle();

    expect(find.byType(UserDetailPage), findsOneWidget);
    // 微信那一页没有标题，顶上只有返回箭头 + 右上「⋯」，所以认名字
    expect(find.text('小明'), findsWidgets);
    expect(adapter.bodyOf(ChatPaths.userInfo), <String, dynamic>{
      'user_id': 'u2',
    });

    await disposeApp(tester);
  });

  testWidgets('点群聊进群聊列表页，点新的朋友进新朋友页', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);

    await pumpContacts(tester);

    await tester.tap(find.text('群聊'));
    await tester.pumpAndSettle();
    expect(find.byType(GroupListPage), findsOneWidget);
    // 用 AppBar 自带的返回按钮（`pageBack` 找的是英文 tooltip，这套界面是中文）
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新的朋友'));
    await tester.pumpAndSettle();
    expect(find.byType(NewFriendsPage), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('点系统通知直接进聊天页', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await db.upsertContacts(<Contact>[
      friend('system', name: '系统通知', isGroup: 2),
    ]);
    await db.upsertConversation(
      const Conversation(id: 'system', displayName: '系统通知', isGroup: 2),
    );

    await pumpContacts(tester);
    await tester.tap(find.text('系统通知'));
    await tester.pumpAndSettle();

    expect(find.byType(ChatPage), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('索引条能跳到最后一个分组（省得一直滑）', (tester) async {
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    // 先塞一批 A 组好友把列表撑到超出屏幕
    await db.upsertContacts(<Contact>[
      for (var i = 0; i < 20; i++)
        friend('a$i', name: 'A组好友$i', index: 'A', py: 'afriend$i'),
      friend('z1', name: '最后的人', index: 'Z', py: 'zuihou'),
    ]);

    await pumpContacts(tester);

    // 一开始 Z 组在屏幕外（列表是滚动的，只是被渲染在了可视区下方）
    final viewportBottom = tester.view.physicalSize.height / 3;
    double zTop() => tester.getTopLeft(find.text('最后的人')).dy;
    expect(zTop(), greaterThan(viewportBottom), reason: 'Z 组一开始应在屏幕外');

    // 点索引条上的 Z（分组表头也叫 Z，所以要限定在索引条里找）
    await tester.tap(
      find.descendant(
        of: find.byType(ContactIndexBar),
        matching: find.text('Z'),
      ),
    );
    await tester.pumpAndSettle();

    expect(zTop(), lessThan(viewportBottom), reason: '点 Z 应该滚到 Z 组');

    await disposeApp(tester);
  });

  // ------------------------------------------------------------ 微信那套观感
  //
  // 下面这些色值和尺寸都不是「差不多」估的，是从微信截图（1080×2316，3x）里
  // 实采出来的。照抄的地方错了，这几条会先红。

  group('微信那套观感', () {
    testWidgets('入口是彩色圆角方块 + 白色字形', (tester) async {
      adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
      // 系统通知那行要有东西才会画出来
      await db.upsertContacts(<Contact>[
        friend('system', name: '系统通知', isGroup: 2),
      ]);
      await pumpContacts(tester);

      /// 取某个入口方块（方块就是那个图标最近的一层 Container）
      Container tileOf(IconData icon) => tester.widget<Container>(
        find
            .ancestor(of: find.byIcon(icon), matching: find.byType(Container))
            .first,
      );

      BoxDecoration decorationOf(IconData icon) =>
          tileOf(icon).decoration! as BoxDecoration;

      // 新的朋友 = 橙、群聊 = 微信的品牌绿（色值取自截图）
      expect(decorationOf(Icons.person_add_alt_1).color, AppColors.entryOrange);
      expect(decorationOf(Icons.groups).color, AppColors.wechatGreen);
      // 系统通知 = 蓝（截图里 标签/企业联系人 那一档）
      expect(decorationOf(Icons.campaign).color, AppColors.entryBlue);

      // 字形是白的（微信那几块方块全是实心白字形，不是彩色描边图标）
      expect(
        tester.widget<Icon>(find.byIcon(Icons.groups)).color,
        AppColors.white,
      );

      // 方块是正方形，而且不小（微信 36dp，这里 80rpx ≈ 38dp）
      final size = tester.getSize(
        find
            .ancestor(
              of: find.byIcon(Icons.groups),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(size.width, closeTo(size.height, 0.01));
      expect(size.width, greaterThan(30));

      await disposeApp(tester);
    });

    testWidgets('行细线是微信那条 #E5E5E5，而且从这行文字左边才开始', (tester) async {
      adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
      await db.upsertContacts(<Contact>[friend('u2', name: '小明', index: 'X')]);

      await pumpContacts(tester);

      final dividers = find.byWidgetPredicate(
        (widget) => widget is Container && widget.color == AppColors.rowDivider,
      );
      expect(dividers, findsWidgets);

      final indents = tester
          .widgetList<Container>(dividers)
          .map((box) => (box.margin! as EdgeInsets).left)
          .toSet();

      // 行本身是通栏的（左边缘就是 0），所以「缩进」正好等于文字的左边缘
      double labelLeft(String label) => tester.getTopLeft(find.text(label)).dx;
      expect(
        indents,
        contains(closeTo(labelLeft('群聊'), 0.5)),
        reason: '入口行的线要对齐文字左边',
      );
      expect(
        indents,
        contains(closeTo(labelLeft('小明'), 0.5)),
        reason: '好友行的线要对齐名字左边',
      );
      // 老端（以及我们上一版）是通栏的线，微信不是
      expect(indents.every((value) => value > 20), isTrue, reason: '没有一条是通栏');

      await disposeApp(tester);
    });

    testWidgets('分组字母是浅灰整条 + 小灰字', (tester) async {
      adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
      await db.upsertContacts(<Contact>[friend('u2', name: '小明', index: 'X')]);

      await pumpContacts(tester);

      // 分组表头与索引条上都叫 X，这里只要列表里那个
      final header = find.descendant(
        of: find.byType(SingleChildScrollView),
        matching: find.text('X'),
      );
      expect(header, findsOneWidget);

      final box = tester.widget<Container>(
        find
            .ancestor(
              of: header,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Container && widget.decoration is BoxDecoration,
              ),
            )
            .first,
      );
      // 微信那条字母带就是这个灰（跟顶部栏同一档，不是白底）
      expect((box.decoration! as BoxDecoration).color, AppColors.navBar);

      // 高 ≈ 28dp（微信量出来 86px / 3）
      final size = tester.getSize(
        find
            .ancestor(
              of: header,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Container && widget.decoration is BoxDecoration,
              ),
            )
            .first,
      );
      expect(size.height, inInclusiveRange(26, 34));

      // 字母是灰的，不是黑的
      expect(tester.widget<Text>(header).style?.color, AppColors.text666);

      await disposeApp(tester);
    });

    testWidgets('索引条浮在列表上（没有白底方块），最上面那格是「↑」', (tester) async {
      adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
      await db.upsertContacts(<Contact>[friend('u2', name: '小明', index: 'X')]);

      await pumpContacts(tester);

      final bar = find.byType(ContactIndexBar);
      expect(bar, findsOneWidget);
      expect(
        find.descendant(of: bar, matching: find.text('↑')),
        findsOneWidget,
      );

      // 微信的索引条就是字母浮在列表上：没有白底、没有圆角盒、没有阴影
      // （老端 `indexBar` 是白底圆角 + 投影）
      for (final box in tester.widgetList<Container>(
        find.descendant(of: bar, matching: find.byType(Container)),
      )) {
        expect(box.decoration, isNull, reason: '索引条不该有自己的底色/阴影');
      }

      await disposeApp(tester);
    });

    testWidgets('点索引条上的「↑」回顶部', (tester) async {
      adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
      await db.upsertContacts(<Contact>[
        for (var i = 0; i < 20; i++)
          friend('a$i', name: 'A组好友$i', index: 'A', py: 'afriend$i'),
        friend('z1', name: '最后的人', index: 'Z', py: 'zuihou'),
      ]);

      await pumpContacts(tester);

      double topEntryY() => tester.getTopLeft(find.text('新的朋友')).dy;
      final restY = topEntryY();
      expect(restY, greaterThanOrEqualTo(0), reason: '一开始就在顶部');

      // 先跳到 Z 组（顶部的入口已经滚出屏幕）
      await tester.tap(
        find.descendant(
          of: find.byType(ContactIndexBar),
          matching: find.text('Z'),
        ),
      );
      await tester.pumpAndSettle();
      expect(topEntryY(), lessThan(restY - 100), reason: '这时已滚上去');

      // 「↑」= 回到顶部，微信索引条最上面那一格
      await tester.tap(
        find.descendant(
          of: find.byType(ContactIndexBar),
          matching: find.text('↑'),
        ),
      );
      await tester.pumpAndSettle();
      expect(topEntryY(), closeTo(restY, 1), reason: '点 ↑ 应该回到顶部');

      await disposeApp(tester);
    });

    testWidgets('顶部右边是「放大镜 + ＋」，＋ 里只有通讯录那几项', (tester) async {
      adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);

      await pumpContacts(tester);

      final add = find.byIcon(Icons.add_circle_outline);
      expect(find.byIcon(Icons.search), findsOneWidget);
      expect(add, findsOneWidget);

      // 微信的通讯录是「左边空着，两颗都在右边」（老端是搜索在左）
      final middle =
          tester.view.physicalSize.width / tester.view.devicePixelRatio / 2;
      expect(
        tester.getCenter(find.byIcon(Icons.search)).dx,
        greaterThan(middle),
      );
      expect(tester.getCenter(add).dx, greaterThan(middle));

      // 微信通讯录那颗「＋」里是「发起群聊 / 添加朋友 / 扫一扫 / 收付款」
      // ——收付款我们没有，其余三项按老端的叫法摆着
      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.text('创建群聊'), findsOneWidget);
      expect(find.text('添加朋友'), findsOneWidget);
      expect(find.text('扫 一 扫'), findsOneWidget);
      // 「更新消息」是消息页那颗 ＋ 才有的
      expect(find.text('更新消息'), findsNothing);

      await disposeApp(tester);
    });
  });
}
