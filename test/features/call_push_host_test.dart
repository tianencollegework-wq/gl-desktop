import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/audio/call_tones.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/notify/message_notification_presenter.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/media/call_media_engine.dart';
import 'package:gracelinkim/domain/call/call_controller.dart';
import 'package:gracelinkim/domain/call/call_machine.dart';
import 'package:gracelinkim/domain/call/call_signal.dart';
import 'package:gracelinkim/domain/call/call_sync_service.dart';
import 'package:gracelinkim/domain/chat/message_notification.dart';
import 'package:gracelinkim/features/call/call_push_host.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_call_media.dart';
import '../support/fake_call_ticker.dart';
import '../support/fake_web_socket.dart';
import '../support/test_database.dart';

/// 「推送来的来电」怎么进到通话链路（S8.1h）—— 冷启动那条路。
///
/// 这是整条离线来电链里最绕的一段：后台 isolate 只能弹一条通知、把整条 `calling`
/// 报文留在通知里，而**真正把电话建起来**得在主 isolate 做；App 当时很可能是死的
/// （用户点通知才把进程拉起来）。
///
/// 这里刻意只挂 [CallPushHost]（不跑整个 App）：要验的是「通知里那份报文被捞出来、
/// 变成了状态机里的一通来电」，界面怎么开关是 `call_page_test` 的事。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late FakeCallMediaEngine media;
  late SilentCallTones tones;
  late ManualCallTicker ticker;
  late FakeWebSocketChannel channel;
  late WsService ws;
  late _FakePresenter presenter;

  /// 服务端 `pushOffline()` 推出去的那条来电报文（FCM 里是字符串）。
  /// 通知栏里存的就是**这一整条**（`IncomingCallNotification.payload`）。
  String callingPayload({
    String id = 'call-push-1',
    int callType = CallType.voice,
    DateTime? sentAt,
  }) => json.encode(<String, dynamic>{
    'id': id,
    'msg_id': 'srv-push-1',
    'fromUser': <String, dynamic>{
      'id': 'u2',
      'realname': '老B',
      'avatar': 'https://a.test/b.png',
    },
    'toContactId': 'u1',
    'toUser': 'u2',
    'type': 'webrtc',
    'sendTime': (sentAt ?? DateTime.now()).millisecondsSinceEpoch,
    'is_group': 0,
    'extends': <String, dynamic>{
      'event': 'calling',
      'type': callType,
      'code': 901,
      'status': CallStatus.ringing,
      'sdp': '',
      'iceCandidate': '',
    },
  });

  setUp(() async {
    // 冷启动的真实形态：**登录态已经在本地**（进程是被通知拉起来的，没人重新登录），
    // 所以 `sessionStore` 第一帧就能给出 myUserId —— 状态机靠它认「这通电话是找我的」。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'authToken': 'token-1',
      'userInfo': json.encode(<String, dynamic>{
        'user_id': 'u1',
        'displayName': '我',
      }),
    });
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    db = memoryDatabase();
    adapter = StubAdapter();
    media = FakeCallMediaEngine();
    tones = SilentCallTones();
    ticker = ManualCallTicker();
    presenter = _FakePresenter();

    channel = FakeWebSocketChannel();
    // WS 必须在 setUp 里建：startTestWsService 里有真定时器，用例体跑在假时区里
    ws = await startTestWsService(channel);
  });

  tearDown(() async {
    ws.dispose();
    await db.close();
  });

  /// 只挂 `CallPushHost`（它要 Riverpod + 一个 MaterialApp 才能跑）
  Future<ProviderContainer> pumpHost(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        apiClientProvider.overrideWithValue(adapter.apiClient()),
        wsServiceProvider.overrideWithValue(ws),
        callMediaEngineProvider.overrideWithValue(media),
        callTonesProvider.overrideWithValue(tones),
        callTickerProvider.overrideWithValue(ticker),
        messageNotificationPresenterProvider.overrideWithValue(presenter),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) =>
              CallPushHost(child: child ?? const SizedBox.shrink()),
          home: const Scaffold(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 信令要有人接（main() 里做的事，测试里自己做一遍）
    container.read(callSyncServiceProvider).start();
    expect(
      container.read(sessionStoreProvider).userId,
      'u1',
      reason: '冷启动时登录态必须已经从本地恢复了（否则状态机认不出这通电话是找我的）',
    );
    return container;
  }

  /// 把这通电话收掉（顺带把响铃兜底计时器停掉 —— 不然测试会以「还有 pending timer」失败）。
  ///
  /// 刻意**不用 `pumpAndSettle`**：挂断之后控制器还有一串异步收尾，
  /// 它会把「等画面静止」拖成很久（真机上无所谓，测试里就是白等）。
  Future<void> endCall(WidgetTester tester, ProviderContainer container) async {
    // 不等它：挂断会把「发信令 + 收尾」一串异步跑完，而我们要的只是
    // 「状态机归零、响铃计时器停掉」这两件事，它们在 `hangup()` 里是同步做完的
    unawaited(container.read(callControllerProvider).hangup());
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 5));
    }
  }

  // 说明：这里把 `await hangup()` 写成 `unawaited` 不是将就 —— 挂断的收尾里的
  // 画中画那一环在测试环境没有平台实现，那条 await 永远不回来。
  // 状态机归零与响铃计时器停掉都是同步完成的，所以断言照样有效。

  Future<void> disposeHost(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // 把 provider 销毁时排下的那点收尾（drift 的流查询收尾是个零延时 timer）跑完，
    // 否则测试框架会以「还有 pending timer」判失败
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('App 被来电通知拉起来：这通电话真的建起来了', (tester) async {
    presenter.launchCall = callingPayload();
    final container = await pumpHost(tester);
    addTearDown(() => disposeHost(tester));

    await tester.pumpAndSettle();

    final session = container.read(callControllerProvider).session;
    expect(session.phase, CallPhase.incoming);
    expect(session.peerId, 'u2');
    expect(session.peerName, '老B');
    expect(session.messageId, 'call-push-1');

    // 挂掉之后通知栏那条来电也要收掉（不然它会比电话活得久）
    await endCall(tester, container);
    expect(presenter.cancelledCalls, 1);
  });

  testWidgets('视频来电也一样（推送里的 extends.type 决定）', (tester) async {
    presenter.launchCall = callingPayload(callType: CallType.video);
    final container = await pumpHost(tester);
    addTearDown(() => disposeHost(tester));

    await tester.pumpAndSettle();

    expect(container.read(callControllerProvider).session.isVideo, isTrue);
    await endCall(tester, container);
  });

  testWidgets('超龄的来电报文不建电话（主叫早挂了，不能响一声就断）', (tester) async {
    presenter.launchCall = callingPayload(
      sentAt: DateTime.now().subtract(const Duration(minutes: 3)),
    );
    final container = await pumpHost(tester);
    addTearDown(() => disposeHost(tester));

    await tester.pumpAndSettle();

    expect(
      container.read(callControllerProvider).session.phase,
      CallPhase.idle,
    );
  });

  testWidgets('报文不是来电（比如普通消息的 payload）时不接', (tester) async {
    presenter.launchCall = json.encode(<String, dynamic>{
      'id': 'm1',
      'type': 'text',
      'content': '在吗',
      'extends': <String, dynamic>{'event': 'simple'},
    });
    final container = await pumpHost(tester);
    addTearDown(() => disposeHost(tester));

    await tester.pumpAndSettle();

    expect(
      container.read(callControllerProvider).session.phase,
      CallPhase.idle,
    );
  });

  testWidgets('用户点开那条来电通知（App 还活着）：同一条报文只建一通电话', (tester) async {
    final payload = callingPayload(id: 'call-push-2');
    presenter.launchCall = payload;
    final container = await pumpHost(tester);
    addTearDown(() => disposeHost(tester));
    await tester.pumpAndSettle();

    // App 已经被冷启动叫起来过一次；再点一次同一条通知不该变成「又来一通」
    presenter.onCallOpen?.call(payload);
    await tester.pumpAndSettle();

    final session = container.read(callControllerProvider).session;
    expect(session.phase, CallPhase.incoming);
    expect(session.messageId, 'call-push-2');
    await endCall(tester, container);
  });
}

/// 通知层的替身：只负责「通知栏里放着哪条来电报文」和「点通知的回调」
class _FakePresenter implements MessageNotificationPresenter {
  /// 「App 是被这条来电通知拉起来的」——就是那份整条 calling 报文
  String? launchCall;

  /// 点通知（App 还活着）时 `CallPushHost` 注册进来的那个 handler
  ValueChanged<String>? onCallOpen;

  final List<IncomingCallNotification> calls = <IncomingCallNotification>[];
  int cancelledCalls = 0;

  @override
  Future<String?> initialize({required ValueChanged<String> onOpen}) async =>
      null;

  @override
  Future<bool> enabled() async => true;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> show(MessageNotification notification) async {}

  @override
  Future<void> cancel(String conversationId) async {}

  @override
  Future<void> cancelAll() async {}

  @override
  Future<void> showIncomingCall(IncomingCallNotification call) async =>
      calls.add(call);

  @override
  Future<void> cancelIncomingCall() async => cancelledCalls += 1;

  @override
  void onIncomingCallOpen(ValueChanged<String> handler) => onCallOpen = handler;

  @override
  Future<String?> takeLaunchIncomingCall() async {
    final payload = launchCall;
    launchCall = null; // 只能取一次（进程当时已经没了）
    return payload;
  }

  // 群通话邀请那几条本文件用不到（GroupCallPushHost 才是它们的宿主，
  // 而且它们**不该**走到来电这条链上）
  @override
  Future<void> showGroupCallRing(IncomingCallNotification invite) async {}

  @override
  Future<void> cancelGroupCallRing() async {}

  @override
  void onGroupCallOpen(ValueChanged<String> handler) {}

  @override
  Future<String?> takeLaunchGroupCall() async => null;
}
