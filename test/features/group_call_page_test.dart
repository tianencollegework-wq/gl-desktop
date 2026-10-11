import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCVideoViewObjectFit;
import 'package:go_router/go_router.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/platform/desktop_shell.dart';
import 'package:gracelinkim/core/notify/message_notification_presenter.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/data/model/sfu_models.dart';
import 'package:gracelinkim/domain/chat/group_members.dart';
import 'package:gracelinkim/domain/group_call/sfu_room.dart';
import 'package:gracelinkim/features/call/screen_share_picker.dart';
import 'package:gracelinkim/features/call/widgets/call_round_button.dart'
    show disabledOpacity;
import 'package:gracelinkim/features/call/widgets/call_video_view.dart';
import 'package:gracelinkim/domain/group_call/group_call_presence.dart';
import 'package:gracelinkim/features/group_call/group_call_controller.dart';
import 'package:gracelinkim/features/group_call/group_call_page.dart';
import 'package:gracelinkim/features/group_call/group_call_session.dart';
import 'package:gracelinkim/features/group_call/group_call_sync.dart'
    show groupCallPresenceProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../group_call/support/fake_sfu.dart';
import '../support/fake_call_keep_alive.dart';
import '../support/fake_call_pip.dart';
import '../support/fake_call_media.dart';
import '../support/fake_notification_presenter.dart';

/// 群通话页：主区域三个形态（共享屏 / 说话人 / 头像墙）+ 成员面板 + 三颗钮。
///
/// 真 WebRTC 只有设备能跑，所以这里用假控制面/假媒体喂状态，验的是**界面与动作**：
/// 谁的名字画出来、共享屏那块有没有出现、点麦克风/挂断有没有真的走那条链。
void main() {
  late FakeSfuControl control;
  late FakeSfuLocalMedia local;
  late FakeSfuConnections connections;
  late FakeCallKeepAlive keepAlive;
  late FakeCallPip pip;
  late SfuRoom room;
  late GroupCallController controller;
  late List<String> notices;
  late FakeNotificationPresenter notifications;
  late ProviderContainer container;
  late GoRouter router;
  late GroupCallPresenceTracker presence;

  void snapshotWith({bool u2Screen = false}) {
    control.snapshot = SfuRoomState(
      epoch: 1,
      members: <SfuRoomMember>[
        member('u1', 'sess-publish-1', <String>['mic']),
        member('u2', 'sess-pub-u2', <String>['mic', if (u2Screen) 'screen']),
      ],
    );
  }

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    control = FakeSfuControl();
    connections = FakeSfuConnections();
    keepAlive = FakeCallKeepAlive();
    notices = <String>[];
    notifications = FakeNotificationPresenter();
    snapshotWith();
  });

  /// 桌面那张「共享哪一块屏幕」面板被叫过几次（带上「允不允许连电脑的声音」
  /// 那座开关）；[sharePickerResult] 是用户的选择，`null` = 用户取消了
  late List<({bool allowAudio})> sharePickerCalls;
  late ScreenShareChoice? sharePickerResult;

  /// 把页面挂在一个最小路由上（挂断后要 `pop` 回上一页）。
  ///
  /// 画布默认是**手机尺寸**（1080x2280 @3x → 360x760）：默认那个 800x600 又宽又矮，
  /// 头像墙/说话人那条的排版不是手机上真实的样子（尺寸都是按 750 设计宽换算的）。
  ///
  /// 桌面那两档（S12.37）：
  /// * `logicalSize: 1280x800` + `desktopFeatures: true` → 窗口够宽（≥900），
  ///   走**桌面版式**（固定像素、主区域吃满窗口）；
  /// * `logicalSize: 700x760` + `desktopFeatures: true` → 桌面功能开着但窗口窄，
  ///   仍然是手机那套（与真机上的窄窗一个行为）；
  /// * `shell: true` 再把整页套进 [DesktopShell]：那条「宽窗把内容夹到 500 居中」
  ///   的规则就在树上，可以验群通话页跳出了它。
  /// * `supportsScreen: false` → 这台设备没有屏幕采集，那颗共享屏按钮不该画
  ///   （能力判据与手机版同一条：`view.supportsScreenShare`）。
  Future<GoRouter> pumpPage(
    WidgetTester tester, {
    Size logicalSize = const Size(360, 760),
    bool desktopFeatures = false,
    bool shell = false,
    bool supportsScreen = true,
  }) async {
    tester.view.physicalSize = logicalSize * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    presence = GroupCallPresenceTracker();
    addTearDown(presence.dispose);
    local = FakeSfuLocalMedia(supportsScreen: supportsScreen);
    sharePickerCalls = <({bool allowAudio})>[];
    sharePickerResult = const ScreenShareChoice('src-picked');
    pip = FakeCallPip();
    room = SfuRoom(
      roomId: '100',
      myUserId: 'u1',
      control: control,
      local: local,
      connectionFactory: connections.call,
      audioLevelPollInterval: null,
      heartbeatInterval: null,
      stateRefreshInterval: null,
      // 共享屏健康检查那支表也关掉：页面测试不 dispose 房间，留着它只会在收尾时
      // 报「A Timer is still pending」（与上面三支同一个道理，见 S12.41）
      screenHealthInterval: null,
      // 补订阅的快速重试同理（S12.42）
      reconcileRetryInterval: null,
    );
    controller = GroupCallController(
      groupName: '产品群',
      room: room,
      loadMembers: () async => <GroupMember>[
        const GroupMember(userId: 'u1', name: '我'),
        const GroupMember(userId: 'u2', name: '小明'),
        const GroupMember(userId: 'u3', name: '小红'),
      ],
      keepAlive: keepAlive,
      pip: pip,
      notify: (key) => notices.add(key),
    );
    router = GoRouter(
      // 从首页 **push** 进通话页：挂断要 `pop` 回上一页，而 initState 那条
      // 路由是 pop 不动的（栈里就它自己）
      initialLocation: '/',
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('home')),
        ),
        GoRoute(
          path: '/call',
          builder: (context, state) =>
              const GroupCallPage(conversationId: 'group-100', name: '产品群'),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          groupCallControllerFactoryProvider.overrideWithValue(
            ({required String conversationId, required String name}) =>
                controller,
          ),
          messageNotificationPresenterProvider.overrideWithValue(notifications),
          // 在线状态那本账注入一个空的（页面进来只调它的 `onJoinedRoom`）
          groupCallPresenceProvider.overrideWithValue(presence),
          // 桌面那一档：测试里默认关着（见 `desktopFeaturesEnabled`）
          if (desktopFeatures) desktopFeaturesProvider.overrideWithValue(true),
          if (shell) desktopShellProvider.overrideWithValue(true),
          // 桌面那张「共享哪一块屏幕 / 哪个窗口」面板：真身要问插件拿源列表，
          // 测试里整个换掉（它只是「用户选了什么」这一步）
          screenSharePickerProvider.overrideWithValue((
            context,
            i18n, {
            allowAudio = true,
          }) async {
            sharePickerCalls.add((allowAudio: allowAudio));
            return sharePickerResult;
          }),
        ],
        child: shell
            ? DesktopShell(child: MaterialApp.router(routerConfig: router))
            : MaterialApp.router(routerConfig: router),
      ),
    );
    container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    router.push('/call');
    // 进房间那一串是异步的（拉名单、采媒体、建会话、订阅），而且要**等页面
    // 滑进来那 300ms 走完** —— 半路上下手，整页还在屏幕外面（点不到按钮）
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    return router;
  }

  tearDown(() {
    notices.clear();
  });

  testWidgets('进来就把那条「群里有人开语音」的邀请通知收掉（S6.14）', (tester) async {
    await pumpPage(tester);

    // 两条路都要收到：点通知进来（那时收过一次，这里是幂等）
    // 与在群资料页点「群通话」进来（那时通知还挂着）
    expect(notifications.cancelledGroupRings, 1);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('头像墙：通话里每个人的名字都画出来，没进来的只在成员面板里', (tester) async {
    await pumpPage(tester);

    expect(find.byKey(const Key('group-call-member-u1')), findsOneWidget);
    expect(find.byKey(const Key('group-call-member-u2')), findsOneWidget);
    expect(find.byKey(const Key('group-call-member-u3')), findsNothing);
    expect(find.text('小明'), findsOneWidget);
    expect(find.text('产品群'), findsOneWidget);
    expect(find.textContaining('2 人在通话'), findsOneWidget);

    // 成员面板里能看到"还没进来"的那位
    await tester.tap(find.byKey(const Key('group-call-members')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('group-call-member-row-u3')), findsOneWidget);
    expect(find.text('未加入'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('谁在说话：说话人放大（带「正在说话」），其余人排在下面', (tester) async {
    await pumpPage(tester);
    expect(find.text('正在说话'), findsNothing);

    connections.receive.audioLevelsByMid = <String, double>{'mid-mic': 0.5};
    await room.pollAudioLevels();
    await tester.pump();

    expect(find.text('正在说话'), findsOneWidget);
    expect(find.text('小明'), findsOneWidget);
    // 其余人还在（说话人视图下面那条）
    expect(find.byKey(const Key('group-call-member-u1')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('共享屏：画面那块出现，并写明是谁在共享', (tester) async {
    snapshotWith(u2Screen: true);
    control.receivingMids['sess-pub-u2|screen'] = 'mid-screen-u2';
    await pumpPage(tester);

    connections.receive.emit(
      'mid-screen-u2',
      kind: 'video',
      stream: FakeMediaStream(),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(CallVideoView), findsOneWidget);
    expect(find.text('小明 正在共享屏幕'), findsOneWidget);
    // 共享屏必须用 `contain`（**完整放下**）：用 `cover` 会把对方的屏幕裁掉一圈，
    // 而屏幕共享的全部意义就是"看清每个角落" —— 用户报的"显示不完整"就是它。
    expect(
      tester.widget<CallVideoView>(find.byType(CallVideoView)).fit,
      RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('已经有人在共享：那颗钮弄灰，点了只提示、不抢着开', (tester) async {
    snapshotWith(u2Screen: true);
    await pumpPage(tester);

    // 弄灰：整颗钮上挂着禁用态那个透明度
    final opacities = tester
        .widgetList<Opacity>(
          find.ancestor(
            of: find.byKey(const Key('group-call-screen')),
            matching: find.byType(Opacity),
          ),
        )
        .map((widget) => widget.opacity);
    expect(opacities, contains(disabledOpacity));

    await tester.tap(find.byKey(const Key('group-call-screen')));
    await tester.pump();

    expect(notices, <String>['group.callShareTaken']);
    expect(local.permissionAsked, isFalse, reason: '连系统投屏框都不该弹');
    expect(local.screenSharing, isFalse);
    expect(sharePickerCalls, isEmpty, reason: '先拦下，再谈弹不弹面板');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('长按主区域：打开诊断面板（订阅建上了没有、重建了几次）', (tester) async {
    await pumpPage(tester);

    await tester.longPress(find.byKey(const Key('group-call-member-u2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('群通话诊断'), findsOneWidget);
    // 面板里能看到那一条订阅（u2 的 mic 订上了，mid 是接收侧分配的）
    expect(find.textContaining('u2|mic → mid-mic'), findsOneWidget);
    expect(find.textContaining('重建 0'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('麦克风那颗钮：点一下把本机麦克风关掉（人还在房间里）', (tester) async {
    await pumpPage(tester);
    expect(local.micEnabled, isTrue);

    await tester.tap(find.byKey(const Key('group-call-mic')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(local.micEnabled, isFalse);
    expect(find.text('麦克风已关'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('挂断：关会话、停保活、关页（不是留在那儿）', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byKey(const Key('group-call-hangup')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(control.countOf('leave'), 1);
    expect(keepAlive.stops, 1);
    expect(find.text('home'), findsOneWidget);
    // 会话也放掉了：小窗、群聊页那条提示都跟着消失
    expect(container.read(groupCallSessionProvider).active, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('返回键：只退出页面，通话还在（一次 leave 都不发）', (tester) async {
    await pumpPage(tester);
    final sessions = container.read(groupCallSessionProvider);
    expect(sessions.active, isNotNull);

    // 模拟系统返回键（安卓的返回、iOS 的边缘手势都走这条路）。
    // ⚠️ 时间要给够：退场动画走完页面才真的被拆掉（拆掉时才会 `closePage`）
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(GroupCallPage), findsNothing);
    expect(find.text('home'), findsOneWidget);
    // ⭐ 这一条就是 S6.17 的全部意义：退出去不等于挂断
    expect(control.countOf('leave'), 0);
    expect(keepAlive.stops, 0);
    expect(sessions.active, isNotNull);
    expect(sessions.pageOpen, isFalse, reason: '小窗接手（它只在页面不在时显示）');
    // 房间还在跑：房间里那两位还在名单上
    expect(sessions.active!.memberCount, 2);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('进房间就把小窗参数交给系统（语音比例 + 群名），但绝不自己缩窗', (tester) async {
    await pumpPage(tester);

    expect(pip.last, 'video=false title=产品群');
    expect(pip.enters, 0);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('左上角「缩成小窗」：点一下立刻进系统小窗（不用按 Home）', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byIcon(Icons.picture_in_picture_alt_rounded));
    await tester.pump();

    expect(pip.enters, 1);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('系统说进了小窗：只画内容 —— 四颗钮、顶上那块、缩窗那颗全都不画', (tester) async {
    await pumpPage(tester);
    expect(find.byKey(const Key('group-call-mic')), findsOneWidget);

    pip.emitMode(true);
    await tester.pump();

    expect(find.byKey(const Key('group-call-members')), findsNothing);
    expect(find.byKey(const Key('group-call-mic')), findsNothing);
    expect(find.byKey(const Key('group-call-screen')), findsNothing);
    expect(find.byKey(const Key('group-call-hangup')), findsNothing);
    expect(
      find.byIcon(Icons.picture_in_picture_alt_rounded),
      findsNothing,
      reason: 'PiP 里触摸被系统接管，按钮画上去也点不到',
    );
    expect(find.text('产品群'), findsNothing);
    // 卡上那行字：刚进来不足一秒，写人数（比「00:00」有信息量）
    expect(find.textContaining('人在通话'), findsOneWidget);

    // 用户在小窗上点展开：恢复成有按钮的样子
    pip.emitMode(false);
    await tester.pump();
    expect(find.byKey(const Key('group-call-mic')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('小窗里别人在共享屏幕：那一路画面仍然完整画出来（contain）', (tester) async {
    snapshotWith(u2Screen: true);
    control.receivingMids['sess-pub-u2|screen'] = 'mid-screen-u2';
    await pumpPage(tester);
    connections.receive.emit(
      'mid-screen-u2',
      kind: 'video',
      stream: FakeMediaStream(),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    pip.emitMode(true);
    await tester.pump();

    final view = tester.widget<CallVideoView>(find.byType(CallVideoView));
    expect(view.fit, RTCVideoViewObjectFit.RTCVideoViewObjectFitContain);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('这一通被外面收掉了（有人打 1:1 电话过来顶掉）：页面自己退回去', (tester) async {
    await pumpPage(tester);
    final sessions = container.read(groupCallSessionProvider);
    expect(sessions.active, isNotNull);

    // 「别人替我把这通挂了」：群通话让路给 1:1，或者登出。
    // ⚠️ 不能 `await`：收尾那几趟在测试里走的是假时区，`await` 会一直等不到
    // （页面上点红挂断那条路也是 `unawaited`，同一个理由）
    unawaited(sessions.end());
    await tester.pump(); // 登记处把「会话没了」推到界面
    await tester.pump(); // 帧后回调里 pop（不能在 build 里直接 pop）
    await tester.pump(const Duration(milliseconds: 500)); // 退场动画走完

    // 不留一个永远转的「正在加入...」
    expect(find.byType(GroupCallPage), findsNothing);
    expect(find.text('home'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('再进来：看着原来那一通（不重新加入、时间接着走）', (tester) async {
    await pumpPage(tester);
    final sessions = container.read(groupCallSessionProvider);
    final first = sessions.active!;
    final joinsBefore = control.countOf('createSession:publish');

    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    router.push('/call');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(sessions.active, same(first), reason: '还是同一通');
    expect(control.countOf('createSession:publish'), joinsBefore);
    expect(find.textContaining('2 人在通话'), findsOneWidget);
    expect(sessions.pageOpen, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  // ---------------------------------------------------------------- 桌面版式（S12.37）

  testWidgets('桌面宽窗：招牌换桌面那套 —— 头像墙按宽度分列、钮的键与手机版一样', (tester) async {
    await pumpPage(
      tester,
      logicalSize: const Size(1280, 800),
      desktopFeatures: true,
    );

    // 版式是桌面那一套：主区域吃满整窗（不是 500 宽的手机条）
    expect(tester.getSize(find.byType(GroupCallPage)).width, 1280);
    // 顶栏**贴左墙**：群名左边缘就在那 28 上（不能整块被摆到窗口中间 ——
    // 2026-10-06 真机截图量到的就是这个：群名跑到 x≈531，而窗口宽 1186）
    expect(tester.getTopLeft(find.text('产品群')).dx, closeTo(28, 1));
    // 头像墙这一行排不满一屏 → 摆到窗口中间：两块砖关于窗口中线对称
    final firstTile = tester.getCenter(
      find.byKey(const Key('group-call-member-u1')),
    );
    final lastTile = tester.getCenter(
      find.byKey(const Key('group-call-member-u2')),
    );
    expect((firstTile.dx + lastTile.dx) / 2, closeTo(1280 / 2, 0.5));
    // 头像墙的列数**按可用宽度自己分**（手机那套写死 2/3/4 列）
    final grid = tester.widget<GridView>(find.byType(GridView));
    expect(grid.gridDelegate, isA<SliverGridDelegateWithMaxCrossAxisExtent>());
    // 键与手机版完全一样：两种版式只是外面那圈尺寸不同
    expect(find.byKey(const Key('group-call-member-u1')), findsOneWidget);
    expect(find.byKey(const Key('group-call-member-u2')), findsOneWidget);
    expect(find.byKey(const Key('group-call-mic')), findsOneWidget);
    expect(find.byKey(const Key('group-call-members')), findsOneWidget);
    expect(find.byKey(const Key('group-call-hangup')), findsOneWidget);
    // 共享屏那颗：桌面版式与手机版走**同一条能力判据**
    // （`view.supportsScreenShare`），这里假件说支持 → 画出来。
    // 真实那条能力（`sfuScreenShareSupported`）从 S12.38 起也认桌面：
    // Windows/Linux/macOS 走原生 `getDisplayMedia`，与 1:1 那条同一个口径。
    expect(find.byKey(const Key('group-call-screen')), findsOneWidget);
    // 顶栏那颗「缩成小窗」在桌面版式里不画：Windows 上那套实现是 `NoopCallPip`，
    // 画出来是一颗点不动的钮
    expect(find.byIcon(Icons.picture_in_picture_alt_rounded), findsNothing);
    // 群名与副标题照旧（副标题那行写着人数与时长）
    expect(find.text('产品群'), findsOneWidget);
    expect(find.textContaining('2 人在通话'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('桌面宽窗：这台设备没有屏幕采集 —— 那颗按钮照样不画', (tester) async {
    await pumpPage(
      tester,
      logicalSize: const Size(1280, 800),
      desktopFeatures: true,
      supportsScreen: false,
    );

    expect(find.byKey(const Key('group-call-screen')), findsNothing);
    // 其余三颗照旧（能力只影响这一颗）
    expect(find.byKey(const Key('group-call-members')), findsOneWidget);
    expect(find.byKey(const Key('group-call-mic')), findsOneWidget);
    expect(find.byKey(const Key('group-call-hangup')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('桌面宽窗 + 外壳：群通话页跳出那条 500 封顶（吃满整窗）', (tester) async {
    await pumpPage(
      tester,
      logicalSize: const Size(1280, 800),
      desktopFeatures: true,
      shell: true,
    );
    // 框架标记晚一帧生效（见 `DesktopFrameScope`）：再推一帧
    await tester.pump();

    expect(
      tester.getSize(find.byType(GroupCallPage)).width,
      1280,
      reason: '桌面版式挂了框架标记，[DesktopShell] 就不该再夹到 500',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('桌面但窗口窄（700）：还是手机那套（缩窗那颗也还在）', (tester) async {
    await pumpPage(
      tester,
      logicalSize: const Size(700, 760),
      desktopFeatures: true,
    );

    // 手机版式的头像墙：列数是写死的 2/3/4
    final grid = tester.widget<GridView>(find.byType(GridView));
    expect(grid.gridDelegate, isA<SliverGridDelegateWithFixedCrossAxisCount>());
    // 并集：两颗钮都在（假 pip 支持画中画，手机那套才会画那颗缩窗）
    expect(find.byKey(const Key('group-call-mic')), findsOneWidget);
    expect(find.byIcon(Icons.picture_in_picture_alt_rounded), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('桌面：别人在共享屏幕 —— 那块画面仍然完整画出来（contain）', (tester) async {
    snapshotWith(u2Screen: true);
    control.receivingMids['sess-pub-u2|screen'] = 'mid-screen-u2';
    await pumpPage(
      tester,
      logicalSize: const Size(1280, 800),
      desktopFeatures: true,
    );
    connections.receive.emit(
      'mid-screen-u2',
      kind: 'video',
      stream: FakeMediaStream(),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final view = tester.widget<CallVideoView>(find.byType(CallVideoView));
    expect(
      view.fit,
      RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
      reason: '屏幕是一整幅要看清的画面：cover 会把它裁成中间一块',
    );
    expect(find.text('小明 正在共享屏幕'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('桌面：点共享屏那颗 → 真的开始共享（桌面这条也走同一条链）', (tester) async {
    // S12.38：桌面版式上那颗钮以前根本不画（能力判据只认安卓）。这里钉住
    // 「画出来了、并且点了真能开」。用例宿主就是 Windows：`isDesktopRuntime`
    // 为真 → 会先弹选择面板，而测试里 `desktopCapturer` 拿不到源列表
    // （插件不在），面板自己退成「系统默认源」，于是这一跳仍然会落地。
    await pumpPage(
      tester,
      logicalSize: const Size(1280, 800),
      desktopFeatures: true,
    );

    await tester.tap(find.byKey(const Key('group-call-screen')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(local.screenSharing, isTrue);
    // 选中的那个源一路带到取流那一步（原生只认它）
    expect(local.screenSourceId, 'src-picked');
    // 群通话也**带**「连电脑的声音一起发」那座开关（S12.39）：S12.38 曾经传
    // `false`（理由：抓系统声音会把别人的话也带回灌），改由一个**默认关着**、
    // 用户自己开的开关来管
    expect(sharePickerCalls.single.allowAudio, isTrue);
    // 这一次用户没开那座开关 → 底层不该去抓声音
    expect(local.screenWithAudio, isFalse);
    // 已经在共享 → 主区域换成「我正在共享」那张卡（两种版式各一张）
    expect(find.textContaining('正在共享屏幕'), findsWidgets);

    // 再点一下：停止共享（停止这一下**不该**再弹面板）
    await tester.tap(find.byKey(const Key('group-call-screen')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(local.screenSharing, isFalse);
    expect(sharePickerCalls, hasLength(1), reason: '停共享不入面板');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('桌面：面板上开了「连电脑的声音」→ 一路带到采集层', (tester) async {
    await pumpPage(
      tester,
      logicalSize: const Size(1280, 800),
      desktopFeatures: true,
    );
    // 用户在面板底下把「连电脑的声音一起发」打开了
    sharePickerResult = const ScreenShareChoice('src-picked', withAudio: true);

    await tester.tap(find.byKey(const Key('group-call-screen')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(local.screenSharing, isTrue);
    expect(local.screenSourceId, 'src-picked');
    expect(
      local.screenWithAudio,
      isTrue,
      reason: '那座开关要一路传到采集层（面板 → 控制器 → 房间 → 本机媒体）',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('桌面：在选择面板上取消 → 什么都不发生（取消 ≠ 用默认源）', (tester) async {
    await pumpPage(
      tester,
      logicalSize: const Size(1280, 800),
      desktopFeatures: true,
    );
    sharePickerResult = null; // 用户点外面关掉了

    await tester.tap(find.byKey(const Key('group-call-screen')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(local.screenStartCalls, 0, reason: '连流都不该取');
    expect(local.screenSharing, isFalse);
    expect(notices, isEmpty, reason: '取消不是失败，不弹提示');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('桌面：底排那几颗走的是同一条链（麦克风 / 成员面板）', (tester) async {
    await pumpPage(
      tester,
      logicalSize: const Size(1280, 800),
      desktopFeatures: true,
    );

    await tester.tap(find.byKey(const Key('group-call-mic')));
    await tester.pump();
    expect(find.text('麦克风已关'), findsOneWidget);

    await tester.tap(find.byKey(const Key('group-call-members')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('group-call-member-row-u3')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
