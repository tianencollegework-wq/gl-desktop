import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/router/app_router.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/domain/call/call_busy.dart';
import 'package:gracelinkim/domain/group_call/group_call_presence.dart';
import 'package:gracelinkim/features/group_call/group_call_banner_host.dart';
import 'package:gracelinkim/features/group_call/group_call_sync.dart'
    show groupCallPresenceProvider;
import 'package:shared_preferences/shared_preferences.dart';

/// 「群里有人开语音」那条**应用内横幅**（S6.15）。
///
/// 与离线推送那条（`group_call_push_host_test.dart`）是互补的两半：那条给 App 没在跑
/// 的人（系统通知 + 响铃），这条给**人就在 App 里**的人。这里刻意只挂横幅宿主，
/// 验的是「横幅出不出现、点了去哪儿、什么时候自己走」——
/// 真正的群通话页要 SfuRoom、媒体一整套，那是 `group_call_page_test` 的地盘。
void main() {
  late GroupCallPresenceTracker presence;

  /// 服务端那条 `sfuRoom` 事件（`data` 层）
  Map<String, dynamic> startEvent({
    String roomId = '100',
    String callId = 'c1',
    String name = '产品群',
    String starter = '小明',
  }) => <String, dynamic>{
    'room_id': roomId,
    'epoch': 2,
    'live': true,
    'call_id': callId,
    'started': true,
    'name': name,
    'starter': starter,
  };

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    // 回查定时器关掉：这不是它的用例
    presence = GroupCallPresenceTracker(verifyInterval: null);
  });

  tearDown(() => presence.dispose());

  /// 挂上宿主（群通话那条路由用一句文字当替身：真正的页面在这里没有意义）。
  /// 返回路由与那个 1:1 通话状态的替身（后者能在用例中途翻转）。
  Future<(GoRouter, _FakeCallBusy)> pumpHost(
    WidgetTester tester, {
    bool callBusy = false,
  }) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      initialLocation: '/',
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('home')),
        ),
        GoRoute(
          path: AppRoutes.groupCall,
          builder: (context, state) => Scaffold(
            body: Text(
              'call ${state.uri.queryParameters['id']} '
              '@${state.uri.queryParameters['name']}',
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    final busy = _FakeCallBusy(callBusy);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appRouterProvider.overrideWithValue(router),
          groupCallPresenceProvider.overrideWithValue(presence),
          callBusyProvider.overrideWith(() => busy),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) =>
              GroupCallBannerHost(child: child ?? const SizedBox.shrink()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (router, busy);
  }

  /// 让横幅的进/出场动画跑完（横幅挂着的那些用例结尾都要过一遍，
  /// 不然 `bannerDuration` 那个定时器会挂到测试结束）
  Future<void> settleBanner(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(seconds: 21));
    await tester.pumpAndSettle();
  }

  testWidgets('有人开语音：横幅飘出来（群名 + 谁发起的 + 两颗按钮）', (tester) async {
    await pumpHost(tester);
    expect(find.text('加入'), findsNothing, reason: '没人开语音时什么都不该有');

    presence.onRoomEvent(startEvent());
    await tester.pumpAndSettle();

    expect(find.text('产品群'), findsOneWidget);
    expect(find.text('小明 邀请你加入群语音'), findsOneWidget);
    expect(find.text('加入'), findsOneWidget);
    expect(find.text('忽略'), findsOneWidget);
    // 人就在手机前面：不再弹系统通知、不响铃（那条是离线推送的事）

    await settleBanner(tester);
  });

  testWidgets('点「加入」：进那个群的群通话页（带群名），横幅收掉', (tester) async {
    final (router, _) = await pumpHost(tester);
    presence.onRoomEvent(startEvent());
    await tester.pumpAndSettle();

    await tester.tap(find.text('加入'));
    await tester.pumpAndSettle();

    expect(find.text('call group-100 @产品群'), findsOneWidget);
    expect(router.state.uri.path, AppRoutes.groupCall);
    expect(find.text('加入'), findsNothing, reason: '人已经进去了，横幅让位给页面');
    expect(presence.liveIn('group-100'), isNotNull, reason: '语音还在开，标记照留');
    expect(presence.pendingInvite, isNull);
  });

  testWidgets('点「忽略」：横幅收掉，但列表那一行的标记照留', (tester) async {
    await pumpHost(tester);
    presence.onRoomEvent(startEvent());
    await tester.pumpAndSettle();

    await tester.tap(find.text('忽略'));
    await tester.pumpAndSettle();

    expect(find.text('加入'), findsNothing);
    expect(find.text('call group-100 @产品群'), findsNothing);
    expect(presence.liveIn('group-100'), isNotNull);
  });

  testWidgets('没人点它：过一会儿自己收掉（不是待办清单）', (tester) async {
    await pumpHost(tester);
    presence.onRoomEvent(startEvent());
    await tester.pumpAndSettle();
    expect(find.text('加入'), findsOneWidget);

    await tester.pump(GroupCallBannerHost.bannerDuration);
    await tester.pumpAndSettle();

    expect(find.text('加入'), findsNothing);
    expect(presence.pendingInvite, isNull);
  });

  testWidgets('那通语音散了（live=false）：横幅马上收掉', (tester) async {
    await pumpHost(tester);
    presence.onRoomEvent(startEvent());
    await tester.pumpAndSettle();
    expect(find.text('加入'), findsOneWidget);

    presence.onRoomEvent(<String, dynamic>{
      'room_id': '100',
      'epoch': 3,
      'live': false,
      'call_id': 'c1',
    });
    await tester.pumpAndSettle();

    expect(find.text('加入'), findsNothing);
  });

  testWidgets('我正在打 1:1 电话：不弹（那时也进不去）', (tester) async {
    await pumpHost(tester, callBusy: true);

    presence.onRoomEvent(startEvent());
    await tester.pumpAndSettle();

    expect(find.text('加入'), findsNothing);
    expect(presence.pendingInvite, isNotNull, reason: '只是不显示，不是把这一通丢了');

    await settleBanner(tester);
  });

  testWidgets('1:1 电话一挂，横幅就能出来（不用等下一次推送）', (tester) async {
    final (_, busy) = await pumpHost(tester, callBusy: true);
    presence.onRoomEvent(startEvent());
    await tester.pumpAndSettle();
    expect(find.text('加入'), findsNothing);

    // 真实现里这个是 `CallController.view.isActive` 变了；替身直接把状态写进去
    busy.set(false);
    await tester.pumpAndSettle();

    expect(find.text('加入'), findsOneWidget);
    await settleBanner(tester);
  });

  testWidgets('群名里带空格与 & 也能带着走（路由参数要编码）', (tester) async {
    await pumpHost(tester);
    presence.onRoomEvent(startEvent(name: '产品 群&测试'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('加入'));
    await tester.pumpAndSettle();

    expect(find.text('call group-100 @产品 群&测试'), findsOneWidget);
  });

  testWidgets('发起人的名字取不到时退回一句通用的（不显示半句话）', (tester) async {
    await pumpHost(tester);
    presence.onRoomEvent(startEvent(starter: ''));
    await tester.pumpAndSettle();

    expect(find.text('群里有人在语音通话'), findsOneWidget);
    await settleBanner(tester);
  });

  testWidgets('群名取不到时用通用标题（横幅不会空着一行）', (tester) async {
    await pumpHost(tester);
    presence.onRoomEvent(startEvent(name: ''));
    await tester.pumpAndSettle();

    expect(find.text('群语音通话'), findsOneWidget);
    await settleBanner(tester);
  });
}

/// 1:1 通话状态的替身（真控制器要一整条媒体链路才能造出「正在通话」）
class _FakeCallBusy extends CallBusyNotifier {
  _FakeCallBusy(this.initial);

  final bool initial;

  /// 用例中途翻转（等价于那通 1:1 电话接通 / 挂断）
  void set(bool busy) => state = busy;

  @override
  bool build() => initial;
}
