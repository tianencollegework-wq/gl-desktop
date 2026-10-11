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
import 'package:gracelinkim/core/audio/call_tones.dart';
import 'package:gracelinkim/data/media/call_media_engine.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/domain/call/call_controller.dart';
import 'package:gracelinkim/features/call/call_page.dart';
import 'package:gracelinkim/features/chat/chat_page.dart';
import 'package:gracelinkim/features/contacts/friend_data_page.dart';
import 'package:gracelinkim/features/contacts/user_detail_page.dart';
import 'package:gracelinkim/features/mine/widgets/mine_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:gracelinkim/features/group_call/group_call_session.dart'
    show groupCallBusyProvider, GroupCallBusyNotifier;

import '../support/fake_call_media.dart';
import '../support/fake_call_ticker.dart';
import '../support/test_database.dart';

/// 「一场群通话正跑着」的替身：真造一个会话要一整条 SFU 假件，
/// 而这里要验的只是"那一颗钮拦不拦"。
class _FakeGroupCallBusy extends GroupCallBusyNotifier {
  _FakeGroupCallBusy(this.initial);

  final bool initial;

  @override
  bool build() => initial;
}

/// 用户详情页（S5.2）。
///
/// 跑整个 App：通讯录 → 点好友，验的是真实那段链路
/// （取详情 → 按钮可见性 → 各个动作 → 本地库联动）。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late StreamSubscription<AppNotice> noticeSub;
  late List<AppNotice> notices;
  late FakeCallMediaEngine media;
  late ManualCallTicker ticker;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    db = memoryDatabase();
    adapter = StubAdapter();
    media = FakeCallMediaEngine();
    ticker = ManualCallTicker();
    sessionGuard.update(ready: true, hasSession: true);
    notices = <AppNotice>[];
    noticeSub = noticeBus.stream.listen(notices.add);
  });

  tearDown(() async {
    await noticeSub.cancel();
    sessionGuard.update(ready: false, hasSession: false);
    await db.close();
  });

  Map<String, dynamic> detailJson({
    String userId = 'u2',
    String realname = '小明',
    String account = '13800000000',
    int sex = 1,
    String nickname = '',
    bool friend = true,
    bool withContactInfo = true,
  }) => <String, dynamic>{
    'user_id': userId,
    'realname': realname,
    'account': account,
    'avatar': 'https://cdn.test/$userId.png',
    'email': 'u2@example.test',
    'sex': sex,
    'last_login_ip': '1.2.3.4',
    'location': '广东深圳',
    'friend': friend
        ? <String, dynamic>{'friend_id': 2, 'nickname': nickname}
        : null,
    'contactInfo': withContactInfo ? <String, dynamic>{'id': userId} : null,
  };

  Iterable<String> toasts() =>
      notices.whereType<ToastNotice>().map((notice) => notice.message);

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// 起 App → 登录 → 通讯录（本地先放一个好友「小明」）。
  ///
  /// [groupCallBusy]：「一场群通话正跑着」的替身（真造一个会话要一整条 SFU 假件）
  Future<void> pumpContacts(
    WidgetTester tester, {
    bool groupCallBusy = false,
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
          // 通话链路走替身：真媒体要原生 WebRTC、真铃声要音频设备，
          // 真计时器又会让 pumpAndSettle 永远等不到静止（见各自注释）
          callMediaEngineProvider.overrideWithValue(media),
          callTonesProvider.overrideWithValue(SilentCallTones()),
          callTickerProvider.overrideWithValue(ticker),
          if (groupCallBusy)
            groupCallBusyProvider.overrideWith(() => _FakeGroupCallBusy(true)),
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
    addTearDown(() => disposeApp(tester));
  }

  /// 点通讯录里的好友进详情页
  Future<void> openDetail(WidgetTester tester, {String name = '小明'}) async {
    await tester.tap(find.text(name));
    await tester.pumpAndSettle();
    expect(find.byType(UserDetailPage), findsOneWidget);
  }

  /// [name] 是**通讯录里那一行的显示名**（设过备注时它就是备注）
  Future<void> seedFriend({String name = '小明'}) async {
    await db.upsertContacts(<Contact>[
      Contact(id: 'u2', displayName: name, indexLetter: 'X'),
    ]);
    adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
  }

  testWidgets('好友资料：头像 + 名字 + 恩信号 + 地区，没有邮箱也没有 IP', (tester) async {
    await seedFriend();
    adapter.ok(ChatPaths.userInfo, data: detailJson());

    await pumpContacts(tester);
    await openDetail(tester);

    expect(find.text('小明'), findsOneWidget);
    // 服务端会把账号打码（`138******00`），这里就照原样显示在「恩信号：」后面
    expect(find.text('恩信号：13800000000'), findsOneWidget);
    expect(find.text('地区：广东深圳'), findsOneWidget);
    // 这两样按用户要求从这一页去掉了
    expect(find.text('u2@example.test'), findsNothing);
    expect(find.text('邮箱'), findsNothing);
    expect(find.textContaining('1.2.3.4'), findsNothing);
    expect(find.text('IP'), findsNothing);

    // 微信这一页**没有标题**（只有左上返回箭头 + 右上「⋯」）
    expect(find.widgetWithText(AppBar, '个人信息'), findsNothing);

    // 底部是微信那种「图标 + 蓝字」的一栏一项
    expect(find.text('发消息'), findsOneWidget);
    expect(find.text('打电话'), findsOneWidget);
    expect(find.text('音视频通话'), findsOneWidget);
    expect(find.text('添加朋友'), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('朋友资料那一栏：标题 + 说明 + 箭头；点进去是备注名 / 个性签名 / 性别', (tester) async {
    await seedFriend();
    adapter.ok(ChatPaths.userInfo, data: detailJson());

    await pumpContacts(tester);
    await openDetail(tester);

    expect(find.text('朋友资料'), findsOneWidget);
    expect(find.text('设置这个朋友的备注名，查看对方的个性签名等资料。'), findsOneWidget);

    await tester.tap(find.text('朋友资料'));
    await tester.pumpAndSettle();

    expect(find.byType(FriendDataPage), findsOneWidget);
    expect(find.text('备注名'), findsOneWidget);
    expect(find.text('个性签名'), findsOneWidget);
    expect(find.text('性别'), findsOneWidget);
    // 备注没设过 → 「未设置」；签名那一栏也什么都没设
    expect(find.text('未设置'), findsWidgets);
    expect(find.text('男'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('朋友资料：个性签名显示的是对方的 motto', (tester) async {
    await seedFriend();
    adapter.ok(ChatPaths.userInfo, data: detailJson()..['motto'] = '今天也要好好写代码');

    await pumpContacts(tester);
    await openDetail(tester);
    await tester.tap(find.text('朋友资料'));
    await tester.pumpAndSettle();

    expect(find.text('今天也要好好写代码'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('不是好友就不显示「朋友资料」那一栏（写不进备注）', (tester) async {
    await seedFriend();
    adapter.ok(ChatPaths.userInfo, data: detailJson(friend: false));

    await pumpContacts(tester);
    await openDetail(tester);

    expect(find.text('朋友资料'), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('账号不是手机号就没有「打电话」', (tester) async {
    await seedFriend();
    adapter.ok(ChatPaths.userInfo, data: detailJson(account: 'u2'));

    await pumpContacts(tester);
    await openDetail(tester);

    expect(find.text('发消息'), findsOneWidget);
    expect(find.text('打电话'), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('不是好友：只有「添加朋友」，验证信息为空会拦下来', (tester) async {
    await seedFriend();
    adapter.ok(
      ChatPaths.userInfo,
      data: detailJson(friend: false, nickname: ''),
    );
    adapter.ok(FriendPaths.add, data: null);

    await pumpContacts(tester);
    await openDetail(tester);

    expect(find.text('添加朋友'), findsOneWidget);
    expect(find.text('发消息'), findsNothing);
    // 不是好友就没有「⋯」（那个菜单里只有删除好友）
    expect(find.byIcon(Icons.more_horiz), findsNothing);

    // 空的验证信息：老端弹「请输入备注！」，一个请求都不发
    await tester.tap(find.text('添加朋友'));
    await tester.pumpAndSettle();
    expect(find.text('请输入验证信息'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(toasts(), contains('请输入备注！'));
    expect(adapter.paths, isNot(contains(FriendPaths.add)));

    // 填了验证信息才发请求
    await tester.tap(find.text('添加朋友'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '我是老王');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(adapter.bodyOf(FriendPaths.add), <String, dynamic>{
      'user_id': 'u2',
      'remark': '我是老王',
    });

    await disposeApp(tester);
  });

  testWidgets('点「发消息」进聊天页，并补上本地会话', (tester) async {
    await seedFriend();
    adapter.ok(ChatPaths.userInfo, data: detailJson());

    await pumpContacts(tester);
    await openDetail(tester);
    expect(await db.findConversation('u2'), isNull);

    await tester.tap(find.text('发消息'));
    await tester.pumpAndSettle();

    expect(find.byType(ChatPage), findsOneWidget);
    expect((await db.findConversation('u2'))?.displayName, '小明');

    await disposeApp(tester);
  });

  testWidgets('改备注：在朋友资料页改，参数对、本地通讯录改了、返回后详情页也刷新', (tester) async {
    await seedFriend();
    adapter.ok(ChatPaths.userInfo, data: detailJson());
    adapter.ok(FriendPaths.setNickname, data: null);

    await pumpContacts(tester);
    await openDetail(tester);
    await tester.tap(find.text('朋友资料'));
    await tester.pumpAndSettle();

    // 点「备注名」那一行（右边的值也叫「未设置」，签名那栏也是，所以点行首）
    await tester.tap(find.text('备注名'));
    await tester.pumpAndSettle();
    expect(find.text('请输入备注！'), findsOneWidget);

    // 改完之后服务端会返回带备注的详情，重新拉一次能看到新备注
    adapter.ok(ChatPaths.userInfo, data: detailJson(nickname: '小明明'));
    await tester.enterText(find.byType(TextField), '小明明');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(adapter.bodyOf(FriendPaths.setNickname), <String, dynamic>{
      'friend_id': 2,
      'nickname': '小明明',
    });
    // 本地库里的显示名（通讯录列表读的就是它）
    expect((await db.findContact('u2'))?.displayName, '小明明');
    // 本页重新拉过，备注名那一栏显示新备注
    expect(find.text('小明明'), findsOneWidget);

    // 返回详情页：上一页收到 true 会再拉一次详情，名字也跟着变成备注
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(UserDetailPage), findsOneWidget);
    expect(find.text('小明明'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('清空备注：输入框删空点确定，备注回到对方的真实昵称', (tester) async {
    // 通讯录里那一行现在显示的是备注「小明明」
    await seedFriend(name: '小明明');
    adapter.ok(ChatPaths.userInfo, data: detailJson(nickname: '小明明'));
    adapter.ok(FriendPaths.setNickname, data: null);

    await pumpContacts(tester);
    await openDetail(tester, name: '小明明');
    await tester.tap(find.text('朋友资料'));
    await tester.pumpAndSettle();
    expect(find.text('小明明'), findsOneWidget);

    // 把备注删空（以前这里会被「请输入备注！」拦下，备注再也去不掉）
    await tester.tap(find.text('备注名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '');
    // 清空之后服务端返回的详情里备注就是空的
    adapter.ok(ChatPaths.userInfo, data: detailJson());
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // 空串要真的发出去（服务端 `Friend::setNickname` 得配合收下空串）
    expect(adapter.bodyOf(FriendPaths.setNickname), <String, dynamic>{
      'friend_id': 2,
      'nickname': '',
    });
    // 本地通讯录与会话名都回到真名
    expect((await db.findContact('u2'))?.displayName, '小明');
    // 本页备注名那一栏回到「未设置」
    expect(find.text('小明明'), findsNothing);
    expect(find.text('未设置'), findsWidgets);

    // 返回详情页：名字回落到真实昵称
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(UserDetailPage), findsOneWidget);
    expect(find.text('小明'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('朋友资料：右侧那栏贴着行尾，短值（未设置）不落在行中间', (tester) async {
    await seedFriend();
    adapter.ok(ChatPaths.userInfo, data: detailJson());

    await pumpContacts(tester);
    await openDetail(tester);
    await tester.tap(find.text('朋友资料'));
    await tester.pumpAndSettle();

    // 备注名那一行：右边是「未设置」+ 箭头，所以留白就是一个行内边距加一个箭头
    final remarkRow = tester.getRect(find.byType(MineListItem).at(0));
    final remarkValue = tester.getRect(find.text('未设置').at(0));
    expect(remarkRow.right - remarkValue.right, lessThan(90));
    expect(remarkValue.left, greaterThan(remarkRow.center.dx));

    // 个性签名那一行没有箭头，值的右边缘就该贴着行的右内边距
    final mottoRow = tester.getRect(find.byType(MineListItem).at(1));
    final mottoValue = tester.getRect(find.text('未设置').at(1));
    expect(mottoRow.right - mottoValue.right, lessThan(40));

    await disposeApp(tester);
  });

  testWidgets('删除好友搬进右上角「⋯」：弹层确认后发请求、本地那行消失、返回通讯录', (tester) async {
    await seedFriend();
    adapter.ok(ChatPaths.userInfo, data: detailJson());
    adapter.ok(FriendPaths.del, data: null);

    await pumpContacts(tester);
    await openDetail(tester);

    // 详情页上已经没有「删除好友」这一行/按钮了
    expect(find.text('删除好友'), findsNothing);
    // 右上角「⋯」点开才有
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(find.text('删除好友'), findsOneWidget);
    await tester.tap(find.text('删除好友'));
    await tester.pumpAndSettle();
    expect(find.text('确定要删除该好友吗？'), findsOneWidget);
    expect(find.text('加入黑名单'), findsOneWidget);

    // 先取消一次：什么都不该发生
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(adapter.paths, isNot(contains(FriendPaths.del)));

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除好友'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(adapter.bodyOf(FriendPaths.del), <String, dynamic>{
      'id': 'u2',
      'is_black': 0,
    });
    expect(await db.findContact('u2'), isNull);
    // 回到了上一页（通讯录），那行人也没了
    expect(find.byType(UserDetailPage), findsNothing);
    expect(find.text('小明'), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('正在群语音里：拨 1:1 被拦下（只提示一声，一通都不起）', (tester) async {
    await seedFriend();
    adapter.ok(ChatPaths.userInfo, data: detailJson());
    adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});

    await pumpContacts(tester, groupCallBusy: true);
    await openDetail(tester);

    await tester.tap(find.text('音视频通话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('语音通话'));
    await tester.pumpAndSettle();

    // 提示一句，通话页不开、信令也不发
    // （两套通话都要麦克风，而前台服务只有一份 —— 同时开着会互相把对方弄断）
    expect(toasts(), contains('你正在通话中，请先挂断'));
    expect(find.byType(CallPage), findsNothing);
    expect(adapter.paths, isNot(contains(ChatPaths.sendToMsg)));

    await disposeApp(tester);
  });

  testWidgets('音视频通话：底部弹层选语音 → 真的起一通电话（通话页 + calling 报文）', (tester) async {
    await seedFriend();
    adapter.ok(ChatPaths.userInfo, data: detailJson());
    adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});

    await pumpContacts(tester);
    await openDetail(tester);

    await tester.tap(find.text('音视频通话'));
    await tester.pumpAndSettle();
    expect(find.text('语音通话'), findsOneWidget);
    expect(find.text('视频通话'), findsOneWidget);

    await tester.tap(find.text('语音通话'));
    await tester.pumpAndSettle();

    // 通话页自己打开了（由 CallHost 跟着通话会话开，入口不再拼 URL 跳转）
    expect(find.byType(CallPage), findsOneWidget);
    expect(find.text('等待对方接受邀请..'), findsOneWidget);

    // 拨号那一条信令与老端逐字一致
    final body = adapter.bodyOf(ChatPaths.sendToMsg);
    expect(body['toContactId'], 'u2');
    expect(body['event'], 'calling');
    expect(body['type'], 0);
    expect(body['status'], 3);
    expect(body['code'], 901);
    expect(body['msg_id'], '');
    // 登录会让控制器重建一次（旧的那个 `close()` 记在轨迹里，所以用 contains）
    expect(media.calls, contains('open(video=false)'));

    // 挂断 → 通话页跟着关掉（老端 `closeCall`）；拨号中那颗红钮学微信写的是「取消」
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(CallPage), findsNothing);
    expect(adapter.lastBodyOf(ChatPaths.sendToMsg)['event'], 'hangup');

    await disposeApp(tester);
  });

  testWidgets('id 是空的时候干脆不发请求（服务端 `User::find(null)` 会 500）', (tester) async {
    await seedFriend();
    adapter.ok(ChatPaths.userInfo, data: detailJson());

    await pumpContacts(tester);
    ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    ).read(appRouterProvider).push('${AppRoutes.contactsDetail}?id=');
    await tester.pumpAndSettle();

    expect(find.byType(UserDetailPage), findsOneWidget);
    expect(adapter.paths, isNot(contains(ChatPaths.userInfo)));

    await disposeApp(tester);
  });

  testWidgets('取详情失败：把服务端那句话摆出来 + 给一个「重试」', (tester) async {
    await seedFriend();
    adapter.fail(ChatPaths.userInfo);

    await pumpContacts(tester);
    await openDetail(tester);

    // 老端这里只是一句「暂无数据」（看了也不知道为什么）；
    // 新端把服务端/repo 给的失败原因直接显示，并留一个重试（否则网络抖一下只能退出去重进）
    expect(find.text('炸了'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('发消息'), findsNothing);

    await disposeApp(tester);
  });

  // ===== 「群内管理」块（S5.2b，老端 `detail.vue` 55～94 行）=====

  Map<String, dynamic> groupInfoJson({
    Object? manageRole = 1,
    String ownerId = 'u1',
    Object? targetRole = 3,
    Object? noSpeakTime = 0,
  }) => <String, dynamic>{
    'groupInfo': <String, dynamic>{
      'name': '产品群',
      'owner_id': ownerId,
      'manageRole': manageRole,
      'userInfo': <String, dynamic>{
        'role': targetRole,
        'no_speak_time': noSpeakTime,
        'no_speak_day': 0,
      },
    },
  };

  /// 从群成员那一侧打开详情页（老端 `groupUser.vue` 跳详情时带 `group_id`）
  Future<void> openGroupMemberDetail(
    WidgetTester tester, {
    Map<String, dynamic> group = const <String, dynamic>{},
    String userId = 'u2',
  }) async {
    adapter.ok(
      ChatPaths.userInfo,
      data: detailJson(userId: userId)..addAll(group),
    );
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp)))
        .read(appRouterProvider)
        .push('${AppRoutes.contactsDetail}?id=$userId&group_id=g1');
    await tester.pumpAndSettle();
    expect(find.byType(UserDetailPage), findsOneWidget);
  }

  testWidgets('群内管理：群主看得到四行，移出成员参数对、移完返回上一页', (tester) async {
    await seedFriend();
    adapter.ok(GroupPaths.removeUser, data: null);

    await pumpContacts(tester);
    await openGroupMemberDetail(tester, group: groupInfoJson());

    expect(find.text('产品群'), findsOneWidget);
    expect(find.text('群成员管理'), findsOneWidget);
    expect(find.text('成员角色'), findsOneWidget);
    expect(find.text('群成员'), findsWidgets);
    expect(find.text('设置禁言'), findsOneWidget);
    expect(find.text('设置管理员'), findsOneWidget);
    expect(find.text('移除成员'), findsOneWidget);

    await tester.tap(find.text('移除成员'));
    await tester.pumpAndSettle();
    expect(find.text('你确定移除该成员吗？'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(adapter.bodyOf(GroupPaths.removeUser), <String, dynamic>{
      'id': 'g1',
      'user_id': 'u2',
      'is_black': 0,
    });
    // 老端移完 `uni.navigateBack()`：详情页关掉
    expect(find.byType(UserDetailPage), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('群内管理：设置禁言（1 小时）参数对', (tester) async {
    await seedFriend();
    adapter.ok(GroupPaths.setNoSpeak, data: null);

    await pumpContacts(tester);
    await openGroupMemberDetail(tester, group: groupInfoJson());

    await tester.tap(find.text('设置禁言'));
    await tester.pumpAndSettle();
    // 弹层里 4 个预设 + 自定义天数（老端那个 uni-popup）
    expect(find.text('10分钟'), findsOneWidget);
    expect(find.text('1小时'), findsOneWidget);
    expect(find.text('自定义'), findsOneWidget);

    await tester.tap(find.text('1小时'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(adapter.bodyOf(GroupPaths.setNoSpeak), <String, dynamic>{
      'id': 'g1',
      'user_id': 'u2',
      'noSpeakDay': 1,
      'noSpeakTimer': 2,
    });
    // 发完重新拉了一次详情
    expect(
      adapter.requests.where((r) => r.path == ChatPaths.userInfo).length,
      2,
    );

    await disposeApp(tester);
  });

  testWidgets('群内管理：正被禁言的人显示「禁言至 m-d H:i」', (tester) async {
    await seedFriend();
    await pumpContacts(tester);
    await openGroupMemberDetail(
      tester,
      group: groupInfoJson(
        noSpeakTime:
            DateTime.now()
                .add(const Duration(hours: 2))
                .millisecondsSinceEpoch ~/
            1000,
      ),
    );

    expect(find.textContaining('禁言至：'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('群内管理：设/撤管理员（我是群主，对方是管理员 → 取消管理员）', (tester) async {
    await seedFriend();
    adapter.ok(GroupPaths.setManager, data: null);

    await pumpContacts(tester);
    await openGroupMemberDetail(tester, group: groupInfoJson(targetRole: 2));

    expect(find.text('管理员'), findsOneWidget);
    await tester.tap(find.text('取消管理员'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(adapter.bodyOf(GroupPaths.setManager), <String, dynamic>{
      'id': 'g1',
      'user_id': 'u2',
      'role': 3,
    });

    await disposeApp(tester);
  });

  testWidgets('群内管理：我是管理员（不是群主）就没有「设为管理员」那行', (tester) async {
    await seedFriend();

    await pumpContacts(tester);
    await openGroupMemberDetail(
      tester,
      group: groupInfoJson(manageRole: 2, ownerId: 'u9'),
    );

    expect(find.text('群成员管理'), findsOneWidget);
    expect(find.text('设置禁言'), findsOneWidget);
    expect(find.text('设置管理员'), findsNothing);
    expect(find.text('移除成员'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('群内管理：对方就是群主 / 我只是普通成员 → 整块都没有', (tester) async {
    await seedFriend();

    await pumpContacts(tester);
    await openGroupMemberDetail(
      tester,
      group: groupInfoJson(ownerId: 'u2', targetRole: 1),
    );
    expect(find.text('群成员管理'), findsNothing);
    expect(find.text('移除成员'), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('群内管理：从通讯录点进来（没有 group_id）不显示这一块', (tester) async {
    await seedFriend();
    // 就算服务端回了 groupInfo，没有 group_id 也不该出现
    adapter.ok(ChatPaths.userInfo, data: detailJson()..addAll(groupInfoJson()));

    await pumpContacts(tester);
    await openDetail(tester);

    expect(find.text('群成员管理'), findsNothing);
    expect(find.text('设置禁言'), findsNothing);

    await disposeApp(tester);
  });
}
