import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCVideoViewObjectFit;
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/audio/call_tones.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/platform/call_pip.dart';
import 'package:gracelinkim/core/router/app_router.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
// 会话/消息的数据库方法都是 extension，必须 import
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/db/message_dao.dart';
import 'package:gracelinkim/data/media/call_media_engine.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/global_config.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/domain/call/call_controller.dart';
import 'package:gracelinkim/domain/call/call_machine.dart';
import 'package:gracelinkim/domain/call/call_signal.dart';
import 'package:gracelinkim/domain/call/call_sync_service.dart';
import 'package:gracelinkim/features/call/call_page.dart';
import 'package:gracelinkim/features/call/call_window_bridge.dart';
import 'package:gracelinkim/features/call/call_window_host.dart';
import 'package:gracelinkim/features/call/call_window_media_engine.dart';
import 'package:gracelinkim/features/call/widgets/call_video_view.dart';
import 'package:gracelinkim/features/chat/widgets/chat_input.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_call_media.dart';
import '../support/fake_call_pip.dart';
import '../support/fake_call_ticker.dart';
import '../support/fake_web_socket.dart';
import '../support/test_database.dart';

/// 通话页（S6.3）。
///
/// 跑整个 App：来电从假 WS 推进来、通话页由 `CallHost` 自己开关，
/// 验的是真实那条链路（信令 → 状态机 → 控制器 → 界面 → 请求体）。
///
/// 三个替身是必须的（都在 support/ 下）：假媒体层（真 WebRTC 要原生）、
/// 假铃声（要音频设备）、手动计时器（真 `Timer.periodic` 会让
/// `pumpAndSettle` 永远等不到静止）。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late FakeCallMediaEngine media;
  late SilentCallTones tones;
  late ManualCallTicker ticker;
  late FakeCallPip pip;

  late FakeWebSocketChannel channel;
  late WsService ws;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    db = memoryDatabase();
    adapter = StubAdapter();
    media = FakeCallMediaEngine();
    tones = SilentCallTones();
    ticker = ManualCallTicker();
    pip = FakeCallPip();
    sessionGuard.update(ready: true, hasSession: true);

    // WS 必须在 `setUp` 里建：`startTestWsService` 里有 `await Future.delayed`，
    // 而 `testWidgets` 的用例体跑在假时区里 —— 把真定时器放到用例体里，
    // 那个 await 永远不会有人推（实测直接卡死到超时）。
    channel = FakeWebSocketChannel();
    ws = await startTestWsService(channel);
  });

  tearDown(() async {
    sessionGuard.update(ready: false, hasSession: false);
    ws.dispose();
    await db.close();
  });

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  ProviderContainer containerOf(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));

  /// 起 App：假 WS + 假媒体 + 假铃声 + 手动计时器，登录成 u1，
  /// 需要时进单聊 `u2`（小明）。
  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    bool openChat = false,
    // 桌面那条路（通话窗）用：把媒体换成主窗口那份代理（默认还是假引擎），
    // 并把「那颗窗」换成替身（`CallWindowTransport` 抽出来就是为了这个）
    CallMediaEngine? engine,
    CallWindowTransport? windowTransport,
  }) async {
    // 按手机尺寸来：+ 面板那些条目在小屏上才看得出真实的换行与遮挡
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(adapter.apiClient()),
          wsServiceProvider.overrideWithValue(ws),
          callMediaEngineProvider.overrideWithValue(engine ?? media),
          callTonesProvider.overrideWithValue(tones),
          callPipProvider.overrideWithValue(pip),
          callTickerProvider.overrideWithValue(ticker),
          if (windowTransport != null)
            callWindowTransportProvider.overrideWithValue(windowTransport),
        ],
        child: const GracelinkApp(),
      ),
    );
    await tester.pumpAndSettle();

    final container = containerOf(tester);
    // 信令要有人接（main() 里做的事，测试里自己做一遍）
    container.read(callSyncServiceProvider).start();
    container
        .read(sessionStoreProvider.notifier)
        .applyLogin(const UserInfo(userId: 'u1', displayName: '我'));
    await tester.pumpAndSettle();

    if (openChat) {
      await db.upsertConversation(
        Conversation(
          id: 'u2',
          displayName: '小明',
          avatar: 'https://a.test/u2.png',
          lastSendTime: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      container.read(appRouterProvider).push('/message/chat?id=u2');
      await tester.pumpAndSettle();
    }
    addTearDown(() => disposeApp(tester));
    return container;
  }

  /// 服务端推一条 `webrtc` 事件。
  ///
  /// 必须裹在 `runAsync` 里推：WS 服务是在 `setUp`（真时区）建的，
  /// 它那条事件链（落库 → 状态机 → 发信令）的续点全在真时区，
  /// 而 `tester.pump` 只推假时区 —— 直接 emit 的话链子会卡在半路，
  /// 现象是「什么都没有发生」，特别难查。`runAsync` 里放一会儿真事件循环，
  /// 再 `pump` 两次把界面画出来。
  Future<void> push(WidgetTester tester, Map<String, dynamic> data) async {
    await tester.runAsync(() async {
      channel.emit(
        jsonEncode(<String, dynamic>{'type': 'webrtc', 'data': data}),
      );
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    // 通话页是 `CallHost` 在真时区里 push 的，路由过渡动画得用假时钟推完，
    // 否则页面停在屏幕外一半的位置，按钮点不到（实测：页面左边界在 97.5）。
    await tester.pumpAndSettle();
  }

  /// 一条通话消息（事件/码/类型都在 `extends` 里，外层 `id` 是通话 id）
  Map<String, dynamic> frame({
    required String event,
    String fromUserId = 'u2',
    String fromName = '老B',
    String toContactId = 'u1',
    String toUser = 'u2',
    String id = 'call-1',
    String msgId = 's1',
    int type = CallType.voice,
    int code = 0,
    int status = CallStatus.ringing,
    String content = '通话中',
  }) => <String, dynamic>{
    'id': id,
    'msg_id': msgId,
    'fromUser': <String, dynamic>{
      'id': fromUserId,
      'realname': fromName,
      'avatar': 'https://a.test/$fromUserId.png',
    },
    'toContactId': toContactId,
    'toUser': toUser,
    'type': 'webrtc',
    'content': content,
    'sendTime': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    'is_group': 0,
    'at': <String>[],
    'extends': <String, dynamic>{
      'event': event,
      'type': type,
      'code': code,
      'status': status,
      'sdp': '',
      'iceCandidate': '',
    },
  };

  CallController controllerOf(ProviderContainer container) =>
      container.read(callControllerProvider);

  /// 客户端发出去的最后一条 `sendToMsg` 报文
  Map<String, dynamic> lastSignal(StubAdapter adapter) =>
      adapter.lastBodyOf(ChatPaths.sendToMsg);

  group('来电', () {
    testWidgets('收到 calling：通话页自己打开，显示来电文案与两个按钮', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      final container = await pumpApp(tester);
      expect(find.byType(CallPage), findsNothing);

      await push(tester, frame(event: CallEvent.calling));

      expect(find.byType(CallPage), findsOneWidget);
      expect(find.text('老B 正在请求与您语音通话'), findsOneWidget);
      expect(find.text('接听'), findsOneWidget);
      expect(find.text('挂断'), findsOneWidget);
      // 老端 `status<3` 的规矩：还没接起来，不给静音 / 免提
      expect(find.text('麦克风已开'), findsNothing);
      expect(find.text('麦克风已关'), findsNothing);
      expect(find.text('扬声器已开'), findsNothing);
      expect(find.text('扬声器已关'), findsNothing);
      // 响铃时左上角也不给「缩成小窗」（那一刻要的是接听/拒接两颗大钮）
      expect(find.byTooltip('缩成小窗'), findsNothing);
      expect(tones.ringStarts, 1);
      expect(controllerOf(container).session.phase, CallPhase.incoming);

      await disposeApp(tester);
    });

    testWidgets('点接听：回 acceptRtc(904)、开始计时、按钮变成静音 / 扬声器', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      final container = await pumpApp(tester);
      await push(tester, frame(event: CallEvent.calling));

      await tester.tap(find.text('接听'));
      await tester.pumpAndSettle();

      final body = lastSignal(adapter);
      expect(body['event'], CallEvent.acceptRtc);
      expect(body['code'], CallCode.accept);
      expect(body['id'], 'call-1');
      expect(body['toContactId'], 'u2');

      expect(controllerOf(container).session.phase, CallPhase.connecting);
      expect(media.calls, contains('open(video=false)'));
      expect(ticker.running, isTrue);

      // 接起来之后：名字 + 三个按钮（老端 status==2）
      expect(find.text('老B'), findsOneWidget);
      expect(find.text('麦克风已开'), findsOneWidget);
      // 接听时把路由固定到扬声器（老端 plusready），所以一开始就是「已开」
      expect(find.text('扬声器已开'), findsOneWidget);
      expect(find.text('接听'), findsNothing);
      // 接起来之后就有「缩成小窗」了
      expect(find.byTooltip('缩成小窗'), findsOneWidget);

      // 计时器往前推 3 秒 → 界面显示 00:00:03（老端 HH:MM:SS）
      ticker.tick(3);
      await tester.pump();
      expect(find.text('00:00:03'), findsOneWidget);
      expect(controllerOf(container).view.value.session.callTime, 3);

      await disposeApp(tester);
    });

    testWidgets('静音 / 免提：假媒体层收到指令，按钮文案跟着翻', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      final container = await pumpApp(tester);
      await push(tester, frame(event: CallEvent.calling));
      await tester.tap(find.text('接听'));
      await tester.pumpAndSettle();

      // 接听时把音频路由固定到扬声器（老端 plusready 那一步）
      expect(media.calls, contains('setSpeakerEnabled(true)'));

      // 微信那套：文字写的是**状态**（麦克风已开 → 点一下变「麦克风已关」）
      await tester.tap(find.text('麦克风已开'));
      await tester.pumpAndSettle();
      expect(media.microphoneEnabled, isFalse);
      expect(controllerOf(container).view.value.microphoneEnabled, isFalse);
      expect(find.text('麦克风已关'), findsOneWidget);

      await tester.tap(find.text('扬声器已开'));
      await tester.pumpAndSettle();
      expect(media.speakerEnabled, isFalse);
      expect(find.text('扬声器已关'), findsOneWidget);

      await disposeApp(tester);
    });

    testWidgets('换账号把控制器换掉：通话页也跟着关掉（不能留一个卡死的页）', (tester) async {
      // 2026-09-20 真机上：控制器被重建后，旧的通话页永远没人 pop ——
      // 页面上「接听」属于已放掉的控制器（点了毫无反应），界面就那么卡着。
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      final container = await pumpApp(tester);
      await push(tester, frame(event: CallEvent.calling));
      expect(find.byType(CallPage), findsOneWidget);

      container
          .read(sessionStoreProvider.notifier)
          .applyLogin(const UserInfo(userId: 'u9', displayName: '别人'));
      await tester.pumpAndSettle();

      expect(find.byType(CallPage), findsNothing);

      await disposeApp(tester);
    });

    testWidgets('对方挂断：页面自己关掉（不用点任何东西）', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      await pumpApp(tester);
      await push(tester, frame(event: CallEvent.calling));
      await tester.tap(find.text('接听'));
      await tester.pumpAndSettle();
      expect(find.byType(CallPage), findsOneWidget);

      await push(
        tester,
        frame(
          event: CallEvent.hangup,
          fromUserId: 'u2',
          toContactId: 'u1',
          code: CallCode.hangupInCall,
        ),
      );

      expect(find.byType(CallPage), findsNothing);
      expect(media.closed, isTrue);

      await disposeApp(tester);
    });

    testWidgets('通话中又来一通：回忙线 907，当前这通不受影响', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      final container = await pumpApp(tester);
      await push(tester, frame(event: CallEvent.calling));
      await tester.tap(find.text('接听'));
      await tester.pumpAndSettle();

      await push(
        tester,
        frame(
          event: CallEvent.calling,
          fromUserId: 'u3',
          fromName: '老C',
          id: 'call-2',
          msgId: 's2',
        ),
      );

      final busy = lastSignal(adapter);
      expect(busy['event'], CallEvent.busy);
      expect(busy['code'], CallCode.busy);
      expect(busy['toContactId'], 'u3');
      // 当前这通还在
      expect(controllerOf(container).session.peerId, 'u2');
      expect(find.text('老B'), findsOneWidget);

      await disposeApp(tester);
    });

    testWidgets('点挂断：回 906 + 关闭页面', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      final container = await pumpApp(tester);
      await push(tester, frame(event: CallEvent.calling));
      await tester.tap(find.text('接听'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('挂断'));
      await tester.pumpAndSettle();

      final body = lastSignal(adapter);
      expect(body['event'], CallEvent.hangup);
      expect(body['code'], CallCode.hangupInCall);
      expect(find.byType(CallPage), findsNothing);
      expect(tones.ringStops, greaterThanOrEqualTo(1));
      // 页面关掉之后控制器回 idle（老端 `onUnload` 也是把这一通整个清掉），
      // 所以这里断言的不是 `ended` —— `ended` 只在页面还没关的那一瞬间存在。
      expect(controllerOf(container).session.phase, CallPhase.idle);
      expect(media.closed, isTrue);

      await disposeApp(tester);
    });

    testWidgets('来电中按返回键 = 挂断（老端会直接退出、通话僵在那儿）', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      final container = await pumpApp(tester);
      await push(tester, frame(event: CallEvent.calling));

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(lastSignal(adapter)['event'], CallEvent.hangup);
      // 来电中拒接：903（老端 `status==3` 那一档）
      expect(lastSignal(adapter)['code'], CallCode.reject);
      // 一键把页面收了（老端是把页面 pop 掉、通话僵在那儿）
      expect(find.byType(CallPage), findsNothing);
      expect(controllerOf(container).session.phase, CallPhase.idle);

      await disposeApp(tester);
    });
  });

  group('去电', () {
    testWidgets('聊天「＋」里的语音通话：通话页打开 + calling 报文', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      final container = await pumpApp(tester, openChat: true);

      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pumpAndSettle();
      expect(find.text('语音通话'), findsOneWidget);
      expect(find.text('视频通话'), findsOneWidget);

      await tester.tap(find.text('语音通话'));
      await tester.pumpAndSettle();

      expect(find.byType(CallPage), findsOneWidget);
      // 拨号中的状态文案与红钮上的文字都学微信：等待对方接受邀请.. / 取消
      expect(find.text('等待对方接受邀请..'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(tones.ringStarts, 1);

      final body = lastSignal(adapter);
      expect(body['event'], CallEvent.calling);
      expect(body['toContactId'], 'u2');
      expect(body['type'], CallType.voice);
      expect(body['status'], CallStatus.ringing);
      expect(body['code'], CallCode.dialing);
      // 主叫自己生成的 uuid，老端 `$util.getUuid()`
      expect((body['id'] as String).isNotEmpty, isTrue);
      expect(controllerOf(container).session.messageId, body['id']);

      await disposeApp(tester);
    });

    testWidgets('通话卡片点一下 = 回拨（老端 chat.vue 的 calling(item.extends.type)）', (
      tester,
    ) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      await pumpApp(tester, openChat: true);
      await db.upsertMessages(<Message>[
        Message(
          serverId: 5,
          msgId: 'w5',
          conversationId: 'u2',
          fromUserId: 'u1',
          fromUserName: '我',
          type: 'webrtc',
          content: '通话时长 00:35',
          sendTime: DateTime.now().millisecondsSinceEpoch,
          ext: <String, dynamic>{'type': CallType.video, 'event': 'hangup'},
        ),
      ]);
      await tester.pumpAndSettle();

      await tester.tap(find.text('通话时长 00:35'));
      await tester.pumpAndSettle();

      expect(find.byType(CallPage), findsOneWidget);
      expect(find.text('等待对方接受邀请..'), findsOneWidget);
      final body = lastSignal(adapter);
      expect(body['event'], CallEvent.calling);
      expect(body['toContactId'], 'u2');
      // 卡片是视频通话 → 回拨也是视频
      expect(body['type'], CallType.video);
      expect(media.openedWithVideo, isTrue);

      await disposeApp(tester);
    });

    testWidgets('视频通话：两个画面、点小窗互换、点大画面收起按钮', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      final container = await pumpApp(tester, openChat: true);

      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('视频通话'));
      await tester.pumpAndSettle();

      expect(media.openedWithVideo, isTrue);
      // 只有本机画面时是「一个大窗」
      expect(find.byType(CallVideoView), findsOneWidget);
      // 视频通话：三颗带文字的开关（麦克风/扬声器/摄像头）+ 底部的翻转摄像头
      expect(find.text('麦克风已开'), findsOneWidget);
      expect(find.text('扬声器已开'), findsOneWidget);
      expect(find.text('摄像头已开'), findsOneWidget);
      expect(find.byTooltip('切换摄像头'), findsOneWidget);
      // 小窗入口只有左上角那一颗；底部左边那颗是**共享屏幕**
      // （微信在那个位置是「模糊背景」，逐帧虚化我们做不了，见 S6.7）
      expect(find.byTooltip('缩成小窗'), findsOneWidget);
      expect(find.byTooltip('共享屏幕'), findsOneWidget);

      // 对方画面到了 → 多出右上角小窗，并且大窗换成对方（老端 streamType=2）
      media.emitRemoteStream();
      await tester.pumpAndSettle();
      expect(find.byType(CallVideoView), findsNWidgets(2));
      expect(controllerOf(container).view.value.remoteBig, isTrue);

      // 点小窗 → 大小窗互换。
      // 点它的**上沿**而不是正中间：测试画布只有 800×600（不像手机那么高），
      // 视频通话那两排按钮会盖到屏幕中间，正中间那一下就落在「摄像头」那颗上了。
      // 真机上按钮都在底部，不存在这个重叠。
      final smallWindow = tester.getRect(find.byType(CallVideoView).at(1));
      await tester.tapAt(Offset(smallWindow.center.dx, smallWindow.top + 8));
      await tester.pumpAndSettle();
      expect(controllerOf(container).view.value.remoteBig, isFalse);

      // 点大画面 → 收起浮层（老端 displayBtn）：按钮与左上角小窗入口都收起来
      await tester.tap(find.byType(CallVideoView).at(0));
      await tester.pumpAndSettle();
      expect(find.text('取消'), findsNothing);
      expect(find.byTooltip('缩成小窗'), findsNothing);

      await disposeApp(tester);
    });

    testWidgets('大画面长按：铺满 ⇄ 完整（「共享屏幕看不全」那条逃生口）', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      await pumpApp(tester, openChat: true);

      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('视频通话'));
      await tester.pumpAndSettle();
      media.emitRemoteStream();
      await tester.pumpAndSettle();
      expect(find.byType(CallVideoView), findsNWidgets(2));

      // 组件测试里没有原生渲染器 → 画面尺寸报不上来 → 先按「铺满」那一档
      // （真机上第一帧一到就会按比例自己算：电脑屏幕 16:10 放进手机那块
      // 竖长条，`cover` 只留中间三成半 —— `call_video_fit.dart` 里那条单测）
      RTCVideoViewObjectFit bigFit() => tester
          .widgetList<CallVideoView>(find.byType(CallVideoView))
          .first
          .fit;
      expect(bigFit(), RTCVideoViewObjectFit.RTCVideoViewObjectFitCover);

      // 长按一下 → 换成「完整」（屏幕左右两边不再被裁掉）
      await tester.longPress(find.byType(CallVideoView).at(0));
      await tester.pumpAndSettle();
      expect(bigFit(), RTCVideoViewObjectFit.RTCVideoViewObjectFitContain);

      // 再长按 → 翻回「铺满」（用户自己挑过之后就不再自动了）
      await tester.longPress(find.byType(CallVideoView).at(0));
      await tester.pumpAndSettle();
      expect(bigFit(), RTCVideoViewObjectFit.RTCVideoViewObjectFitCover);

      // 单击那一下**不能**被长按/双击拖慢：浮层当场就收起来（老端 displayBtn）
      await tester.longPress(find.byType(CallVideoView).at(0));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CallVideoView).at(0));
      await tester.pump();
      expect(find.text('取消'), findsNothing);

      await disposeApp(tester);
    });
  });

  // 小窗（画中画，S6.6）：**只画内容、一个按钮都不画** —— 进了 PiP 之后触摸被
  // 系统接管（点一下是「展开 / 菜单」，不是我们的界面），按钮画上去也点不到。
  // 微信那个小窗就是这样（产品要求）。
  group('小窗（画中画）', () {
    testWidgets('语音通话：白底绿卡片（等待接听 → 通话时长），按钮全收起来', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      final container = await pumpApp(tester);

      await push(tester, frame(event: CallEvent.calling));
      await tester.tap(find.text('接听'));
      await tester.pumpAndSettle();

      // 还没接通（计时还没起）：窗口里显示「等待接听」
      pip.emitMode(true);
      await tester.pumpAndSettle();
      expect(find.text('等待接听'), findsOneWidget);
      // 卡片上那颗绿话机（2026-09-19 起整套图标换成 Material 圆角变体 + 一颗苹果字形）
      expect(find.byIcon(Icons.call_rounded), findsOneWidget);
      expect(find.text('挂断'), findsNothing);
      expect(find.text('麦克风已开'), findsNothing);
      expect(find.text('扬声器已开'), findsNothing);
      expect(find.byTooltip('缩成小窗'), findsNothing);

      // 接通之后：换成通话时长
      media.emitConnected();
      ticker.tick(3);
      await tester.pumpAndSettle();
      expect(find.text('00:00:03'), findsOneWidget);
      expect(find.text('等待接听'), findsNothing);
      expect(controllerOf(container).view.value.inPip, isTrue);

      // 出了小窗：回到正常通话界面（按钮都回来）
      pip.emitMode(false);
      await tester.pumpAndSettle();
      expect(find.text('挂断'), findsOneWidget);

      await disposeApp(tester);
    });

    testWidgets('视频通话：对方画面还没到时是绿卡片；到了之后对方铺满 + 右上角自己的小窗', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      await pumpApp(tester, openChat: true);

      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('视频通话'));
      await tester.pumpAndSettle();

      // 还没接通：小窗里跟语音一样是那张绿卡片（产品要求）
      pip.emitMode(true);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.call_rounded), findsOneWidget);
      expect(find.text('等待接听'), findsOneWidget);
      expect(find.byType(CallVideoView), findsNothing);

      // 对方画面到了：两块画面（对方铺满 + 右上角自己），依旧没有按钮
      media.emitRemoteStream();
      await tester.pumpAndSettle();
      expect(find.byType(CallVideoView), findsNWidgets(2));
      expect(find.byTooltip('切换摄像头'), findsNothing);
      expect(find.text('挂断'), findsNothing);

      await disposeApp(tester);
    });
  });

  // 2026-09-19 改版：界面按微信那套重排（用户给的截图）。这里钉住新加的东西：
  // 左上角「缩成小窗」入口、视频通话里的摄像头/免提开关、拨号中写「取消」。
  group('微信那套界面（改版）', () {
    testWidgets('点左上角「缩成小窗」：让系统立刻进画中画（不用按 Home）', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      await pumpApp(tester);
      await push(tester, frame(event: CallEvent.calling));
      await tester.tap(find.text('接听'));
      await tester.pumpAndSettle();

      // 接通中：红钮写「挂断」（拨号中才写「取消」）
      expect(find.text('挂断'), findsOneWidget);
      expect(pip.enters, 0);

      await tester.tap(find.byTooltip('缩成小窗'));
      await tester.pumpAndSettle();
      expect(pip.enters, 1);

      // 原生回报「进了小窗」之后：界面切成只有内容（白底绿卡片），按钮全不见
      pip.emitMode(true);
      await tester.pumpAndSettle();
      expect(find.text('等待接听'), findsOneWidget);
      expect(find.text('挂断'), findsNothing);

      await disposeApp(tester);
    });

    testWidgets('视频通话：摄像头开关与免提（老端视频通话没有这两颗）', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      final container = await pumpApp(tester, openChat: true);
      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('视频通话'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('摄像头已开'));
      await tester.pumpAndSettle();
      expect(media.calls, contains('setCameraEnabled(false)'));
      expect(controllerOf(container).view.value.cameraEnabled, isFalse);
      expect(find.text('摄像头已关'), findsOneWidget);

      await tester.tap(find.text('扬声器已开'));
      await tester.pumpAndSettle();
      expect(media.calls, contains('setSpeakerEnabled(false)'));
      expect(find.text('扬声器已关'), findsOneWidget);

      await disposeApp(tester);
    });

    testWidgets('视频通话：点「共享屏幕」→ 变「停止共享」，摄像头那两颗弄灰', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      final container = await pumpApp(tester, openChat: true);
      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('视频通话'));
      await tester.pumpAndSettle();

      // 对方画面到了：共享前是「对方大窗 + 自己小窗」两块
      media.emitRemoteStream();
      await tester.pumpAndSettle();
      expect(find.byType(CallVideoView), findsNWidgets(2));

      await tester.tap(find.byTooltip('共享屏幕'));
      await tester.pumpAndSettle();

      // 真的走了那两步（前台服务那块在测试里是空实现，只有真机才跑原生）
      expect(media.calls, contains('requestScreenSharePermission()'));
      expect(media.calls, contains('startScreenShare(audio=off)'));
      expect(controllerOf(container).view.value.screenSharing, isTrue);

      // 共享期间：只留对方那一路（自己那块小窗收掉，不再镜一层屏幕），
      // 并且名字/计时下面多一行「正在共享屏幕」（对方也能看到这行字）
      expect(find.byType(CallVideoView), findsOneWidget);
      expect(find.text('正在共享屏幕'), findsOneWidget);

      // 那颗钮换成「停止共享」；摄像头那两颗变成灰的（发出去的是屏幕）
      expect(find.byTooltip('停止共享'), findsOneWidget);
      expect(find.byTooltip('共享屏幕'), findsNothing);
      final before = media.calls.length;
      await tester.tap(find.text('摄像头已开'));
      await tester.pumpAndSettle();
      expect(media.calls.length, before, reason: '共享期间摄像头开关是灰的，点了没反应');

      // 再点一次 = 停止共享（换回摄像头）
      await tester.tap(find.byTooltip('停止共享'));
      await tester.pumpAndSettle();
      expect(media.calls, contains('stopScreenShare()'));
      expect(controllerOf(container).view.value.screenSharing, isFalse);
      expect(find.byTooltip('共享屏幕'), findsOneWidget);
      // 收工：自己那块小窗回来了、状态字也没了
      expect(find.byType(CallVideoView), findsNWidgets(2));
      expect(find.text('正在共享屏幕'), findsNothing);

      await disposeApp(tester);
    });

    testWidgets('共享屏幕期间进小窗：也只有对方那一路（不套娃）', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      await pumpApp(tester, openChat: true);
      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('视频通话'));
      await tester.pumpAndSettle();

      media.emitRemoteStream();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('共享屏幕'));
      await tester.pumpAndSettle();

      pip.emitMode(true);
      await tester.pumpAndSettle();
      expect(find.byType(CallVideoView), findsOneWidget);

      await disposeApp(tester);
    });
  });

  group('入口可见性', () {
    testWidgets('群聊里没有语音/视频通话两项（老端 !contact.is_group）', (tester) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      await db.upsertConversation(
        Conversation(
          id: 'g1',
          displayName: '同学群',
          isGroup: 1,
          lastSendTime: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      final container = await pumpApp(tester);
      container.read(appRouterProvider).push('/message/chat?id=g1');
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pumpAndSettle();
      expect(find.text('语音通话'), findsNothing);
      expect(find.text('视频通话'), findsNothing);
      // 其余那几项还在
      expect(find.text('相册'), findsOneWidget);

      await disposeApp(tester);
    });

    testWidgets('单聊里两项都在（并且面板真的把回调递进来了）', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      await pumpApp(tester, openChat: true);

      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pumpAndSettle();

      expect(find.text('语音通话'), findsOneWidget);
      expect(find.text('视频通话'), findsOneWidget);
      expect(
        tester.widget<ChatInput>(find.byType(ChatInput)).onStartCall,
        isNotNull,
      );

      await disposeApp(tester);
    });

    testWidgets('服务端把 webrtc 关了：面板里就没有这两项（老端 v-if 的条件）', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      final container = await pumpApp(tester, openChat: true);
      // 服务端关掉音视频（WS `updateConfig` 走的是同一份配置）
      container
          .read(sessionStoreProvider.notifier)
          .applyConfig(
            GlobalConfig.fromJson(<String, dynamic>{
              'chatInfo': <String, dynamic>{'webrtc': 0},
            }),
          );
      await tester.pumpAndSettle();

      expect(
        tester.widget<ChatInput>(find.byType(ChatInput)).onStartCall,
        isNull,
      );
      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pumpAndSettle();
      expect(find.text('语音通话'), findsNothing);
      expect(find.text('视频通话'), findsNothing);
      // 其余那几项还在
      expect(find.text('相册'), findsOneWidget);

      await disposeApp(tester);
    });
  });

  group('桌面那条路（通话窗）', () {
    /// 桌面那条路：媒体是主窗口那份代理，传输层是假的 `desktop_multi_window`。
    ///
    /// 与上面那几组同一个口径：跑整个 App（`CallHost` 自己接线），
    /// 一条电话从状态机走到媒体层，验的是「这一枪到底发给谁、界面摆在哪边」。
    (CallWindowMediaEngine, _FakeWindowTransport, List<String>) windowApp({
      bool lost = false,
      bool unreachable = false,
    }) {
      final transport = _FakeWindowTransport()
        ..lost = lost
        ..unreachable = unreachable;
      final fallbacks = <String>[];
      final proxy = CallWindowMediaEngine(
        transport: transport,
        // 兜底那份记一笔：它被建出来就说明媒体真的退回主窗口了
        fallbackFactory: () {
          final engine = FakeCallMediaEngine(label: 'fallback');
          fallbacks.add('created');
          return engine;
        },
      );
      return (proxy, transport, fallbacks);
    }

    /// 起一通去电（老端与真机都是聊天页那颗钮调进来的同一个入口）
    Future<void> startCall(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      await tester.runAsync(() async {
        await controllerOf(container).start(
          peerId: 'u2',
          peerName: '小明',
          type: CallType.voice,
          webrtcEnabled: true,
          simpleChatEnabled: true,
        );
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
    }

    testWidgets('窗起来过又被关掉（✕）：这一通按挂断收尾，不退回主窗口那张页', (tester) async {
      final apps = windowApp(lost: true);
      final proxy = apps.$1;
      final transport = apps.$2;
      final fallbacks = apps.$3;

      final container = await pumpApp(
        tester,
        engine: proxy,
        windowTransport: transport,
      );
      await startCall(tester, container);

      // 那颗窗里的媒体已经随窗口销毁了：退回主窗口只能画出一张没声音没画面、
      // 连「挂断」都点不到的空壳页，所以那条路**不能**走
      expect(fallbacks, isEmpty, reason: '不该另建一份本地引擎');
      // 收尾是「挂断」（拨号中 → 902），对方那边不会看到一通永远不响的电话
      final body = lastSignal(adapter);
      expect(body['event'], CallEvent.hangup);
      expect(body['code'], CallCode.cancel);
      expect(controllerOf(container).session.phase, CallPhase.ended);
      // 主窗口里也不该冒出那张通话页（界面本来就只在通话窗里）
      expect(find.byType(CallPage), findsNothing);
      // 那扇已经不存在的窗被收干净（`closeWindow` 一次）
      expect(transport.closed, greaterThanOrEqualTo(1));

      await disposeApp(tester);
    });

    testWidgets('窗从来没起来过：退回主窗口里的引擎，通话照样能打', (tester) async {
      final apps = windowApp(unreachable: true);
      final proxy = apps.$1;
      final transport = apps.$2;
      final fallbacks = apps.$3;

      final container = await pumpApp(
        tester,
        engine: proxy,
        windowTransport: transport,
      );
      await startCall(tester, container);

      // 这一条（与上一条相反）是刻意的兜底：媒体还没建在那颗窗里，
      // 退回主窗口是真的能打 —— 电话继续走 calling(901)，页面摆回主窗口
      expect(proxy.degraded, isTrue);
      expect(fallbacks, <String>['created']);
      expect(lastSignal(adapter)['event'], CallEvent.calling);
      expect(lastSignal(adapter)['code'], CallCode.dialing);
      expect(find.byType(CallPage), findsOneWidget);

      await disposeApp(tester);
    });

    testWidgets('窗里点「诊断」：面板弹在**主窗口**（那颗窗里没有状态机）', (tester) async {
      // 真机上那条线由插件提供：挂 handler 那一下得有人接（不然 `attach`
      // 拿到 MissingPluginException，后面推上来的动作没人听）
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('mixin.one/desktop_multi_window/channels'),
        (call) async => null,
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(
          const MethodChannel('mixin.one/desktop_multi_window/channels'),
          null,
        );
      });

      final apps = windowApp();
      final container = await pumpApp(
        tester,
        engine: apps.$1,
        windowTransport: apps.$2,
      );
      await startCall(tester, container);

      // 通话窗那份界面右键 → 一条动作顺着 `gracelink/call/events` 上来
      await messenger.handlePlatformMessage(
        'mixin.one/desktop_multi_window/channels',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('methodCall', <String, dynamic>{
            'channel': callWindowEventChannelName,
            'method': callWindowAction,
            'arguments': <String, dynamic>{'action': 'diagnostics'},
          }),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();

      // 面板要的那份数据（候选/信令/时间线）只存在主窗口里，所以它得弹在主窗口
      expect(find.text('通话诊断'), findsOneWidget);

      await disposeApp(tester);
    });
  });
}

/// 假传输层（主窗口那侧的「通话窗」句柄）。
///
/// 只记「主窗口对那颗窗说了什么」，另外两个开关对应真机上两种完全不同的失败，
/// 处理也相反（见 `call_window_host.dart::CallWindowLost`）。
class _FakeWindowTransport implements CallWindowTransport {
  /// 媒体指令的名字（按顺序）
  final List<String> invoked = <String>[];

  /// `closeWindow()` 被叫了几次
  int closed = 0;

  /// 那颗窗**起来过又被关掉**（✕）：每条媒体指令都抛 [CallWindowLost]
  bool lost = false;

  /// 窗口那条路整个不通（原生建不出引擎 / 冷启动拿不到）
  bool unreachable = false;

  @override
  void plan(CallWindowSpec spec) {}

  @override
  Future<void> pushState(Map<String, dynamic> state) async {}

  @override
  Future<Object?> invokeMedia(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    invoked.add(method);
    if (lost) throw CallWindowLost(method);
    if (unreachable) {
      throw const CallMediaException('测试里这条窗开不出来');
    }
    return null;
  }

  @override
  Future<void> closeWindow() async => closed += 1;

  @override
  Future<bool> alive() async => !unreachable && !lost;
}
