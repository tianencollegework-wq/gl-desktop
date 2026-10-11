import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/notify/message_notification_presenter.dart';
import 'package:gracelinkim/core/router/app_router.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/data/model/sfu_models.dart';
import 'package:gracelinkim/domain/chat/group_members.dart';
import 'package:gracelinkim/domain/group_call/group_call_presence.dart';
import 'package:gracelinkim/domain/group_call/sfu_room.dart';
import 'package:gracelinkim/features/group_call/group_call_controller.dart';
import 'package:gracelinkim/features/group_call/group_call_mini_bar.dart';
import 'package:gracelinkim/features/group_call/group_call_page.dart';
import 'package:gracelinkim/features/group_call/group_call_session.dart';
import 'package:gracelinkim/features/group_call/group_call_sync.dart'
    show groupCallPresenceProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../group_call/support/fake_sfu.dart';
import '../support/fake_call_keep_alive.dart';
import '../support/fake_notification_presenter.dart';

/// 群通话小窗（S6.17）：退出通话页之后，那颗告诉用户「你还在通话里」的药丸。
///
/// 它只有真机（或者说整棵树都在的时候）才看得出问题：什么时候该出现、什么时候该让位
/// 给通话页、点一下是不是回到原来那一通、能不能真的挂断。
void main() {
  late FakeSfuControl control;
  late FakeCallKeepAlive keepAlive;
  late FakeSfuConnections connections;
  late FakeSfuLocalMedia local;
  late GroupCallPresenceTracker presence;
  late ProviderContainer container;
  late GoRouter router;
  late GroupCallSessionHost sessions;

  GroupCallController buildController({
    required String conversationId,
    required String name,
  }) {
    local = FakeSfuLocalMedia();
    connections = FakeSfuConnections();
    return GroupCallController(
      groupName: name,
      room: SfuRoom(
        roomId: '100',
        myUserId: 'u1',
        control: control,
        local: local,
        connectionFactory: connections.call,
        audioLevelPollInterval: null,
        heartbeatInterval: null,
        stateRefreshInterval: null,
      ),
      loadMembers: () async => <GroupMember>[
        const GroupMember(userId: 'u1', name: '我'),
        const GroupMember(userId: 'u2', name: '小明'),
      ],
      keepAlive: keepAlive,
      notify: (_) {},
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    control = FakeSfuControl();
    control.snapshot = SfuRoomState(
      epoch: 1,
      members: <SfuRoomMember>[
        member('u1', 'sess-publish-1', <String>['mic']),
        member('u2', 'sess-pub-u2', <String>['mic']),
      ],
    );
    keepAlive = FakeCallKeepAlive();
    presence = GroupCallPresenceTracker();
  });

  // ⚠️ 这里用的是**抓下来的那个实例**（不是再 `read` 一次）：用例末尾把树拆掉时
  // ProviderScope 会整个放掉，再 read 就是「container 已经 dispose」
  tearDown(() async {
    await sessions.end();
    presence.dispose();
  });

  /// 把整棵树挂起来：小窗挂在 `MaterialApp.router` 的 `builder` 上（与 `app.dart`
  /// 同一个位置），里面是真路由 —— 点小窗要能真的进通话页。
  Future<void> pumpTree(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2280);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    router = GoRouter(
      initialLocation: '/',
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          builder: (context, state) =>
              const Scaffold(body: Center(child: Text('home'))),
        ),
        // 小窗点「回到通话」走的是**真实那条路由**（与群资料页那个入口同一个），
        // 所以这里让它落到真的通话页上
        GoRoute(
          path: AppRoutes.groupCall,
          builder: (context, state) => GroupCallPage(
            conversationId: state.uri.queryParameters['id'] ?? '',
            name: state.uri.queryParameters['name'] ?? '',
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // 小窗与横幅一样，用 `appRouterProvider` 跳页（它挂在 Navigator 之上，
          // 没有自己的 context 在栈顶）
          appRouterProvider.overrideWithValue(router),
          groupCallControllerFactoryProvider.overrideWithValue(buildController),
          groupCallPresenceProvider.overrideWithValue(presence),
          messageNotificationPresenterProvider.overrideWithValue(
            FakeNotificationPresenter(),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) =>
              GroupCallMiniBarHost(child: child ?? const SizedBox.shrink()),
        ),
      ),
    );
    container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    sessions = container.read(groupCallSessionProvider);
    await tester.pump();
  }

  /// 进通话、等房间里那一串跑完
  Future<void> joinCall(WidgetTester tester) async {
    await sessions.openPage(conversationId: 'group-100', name: '产品群');
    for (var i = 0; i < 6; i += 1) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// 打开通话页（与群资料页/小窗同一条路由）
  void openCallPage() => router.push(
    '${AppRoutes.groupCall}?id=group-100&name=%E4%BA%A7%E5%93%81%E7%BE%A4',
  );

  /// 退出通话页（页面关掉、通话还在）：登记处的通知走一个微任务，
  /// 所以要多铺一帧才看得见屏幕上那颗小窗
  Future<void> leavePage(WidgetTester tester) async {
    sessions.closePage();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('退出通话页：小窗浮上来，写着群名与人数', (tester) async {
    await pumpTree(tester);
    await joinCall(tester);

    // ⭐ 关键前提：页面没开着（这就是「退出页面」之后的状态）
    await leavePage(tester);

    expect(find.byType(GroupCallMiniBarHost), findsOneWidget);
    expect(find.text('产品群'), findsOneWidget);
    expect(find.textContaining('2 人在通话'), findsOneWidget);
    expect(find.text('回到通话'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('通话页开着时：小窗让位（页面上已经有一样的四颗钮）', (tester) async {
    await pumpTree(tester);
    await joinCall(tester);
    await leavePage(tester);
    expect(find.text('回到通话'), findsOneWidget);

    openCallPage();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(GroupCallPage), findsOneWidget);
    expect(find.text('回到通话'), findsNothing, reason: '页面上不该再飘一颗小窗');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('点小窗：回到原来那一通（不重新加入、人还是原来那两位）', (tester) async {
    await pumpTree(tester);
    await joinCall(tester);
    await leavePage(tester);

    final before = control.countOf('createSession:publish');
    await tester.tap(find.text('回到通话'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(GroupCallPage), findsOneWidget);
    expect(find.textContaining('2 人在通话'), findsOneWidget);
    expect(control.countOf('createSession:publish'), before, reason: '还是同一通');
    expect(find.text('回到通话'), findsNothing, reason: '进了页面小窗就该收掉');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('小窗上的挂断：这通真的结束（会话、保活都收）', (tester) async {
    await pumpTree(tester);
    await joinCall(tester);
    await leavePage(tester);

    await tester.tap(find.byKey(const Key('group-call-mini-hangup')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(sessions.active, isNull);
    expect(control.countOf('leave'), 1);
    expect(keepAlive.stops, 1);
    expect(find.text('回到通话'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('还没进房间：小窗也浮着（写着「正在连接…」，但没有回到通话那颗）', (tester) async {
    await pumpTree(tester);
    // 建会话卡住不返回 → 会话定格在「正在加入」
    control.createSessionBlocker = Completer<void>();
    await sessions.openPage(conversationId: 'group-100', name: '产品群');
    await leavePage(tester);

    expect(find.text('产品群'), findsOneWidget);
    expect(find.text('正在连接恩信全球智能网络'), findsOneWidget);
    expect(find.text('回到通话'), findsNothing, reason: '还没进去，没有「回到」一说');

    control.releaseCreateSession();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('拖着走：位置跟着手指动，也不会被拖出屏幕', (tester) async {
    await pumpTree(tester);
    await joinCall(tester);
    await leavePage(tester);

    final pill = find.text('产品群');
    final before = tester.getTopLeft(pill);
    await tester.drag(pill, const Offset(0, 220));
    await tester.pump();
    expect(tester.getTopLeft(pill).dy, greaterThan(before.dy));

    // 往屏幕外拖：钳在屏内（拿得到位置就说明没跑出去）
    await tester.drag(pill, const Offset(-900, -900));
    await tester.pump();
    final after = tester.getTopLeft(pill);
    expect(after.dx, greaterThanOrEqualTo(0));
    expect(after.dy, greaterThanOrEqualTo(0));

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
