import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/audio/call_tones.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/platform/call_pip.dart';
import 'package:gracelinkim/core/platform/callkit.dart';
import 'package:gracelinkim/core/platform/push_token.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/media/call_media_engine.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/domain/call/call_controller.dart';
import 'package:gracelinkim/domain/call/call_machine.dart';
import 'package:gracelinkim/domain/call/call_signal.dart';
import 'package:gracelinkim/domain/call/call_sync_service.dart';
import 'package:gracelinkim/domain/notify/push_registrar.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_call_media.dart';
import '../support/fake_call_pip.dart';
import '../support/fake_call_ticker.dart';
import '../support/fake_callkit.dart';
import '../support/fake_web_socket.dart';
import '../support/test_database.dart';

/// **系统来电界面（CallKit）的接线**（2026-10-15）。
///
/// 这一层验的不是原生（那只有真机能验，见 `integration_test/ios_callkit_smoke_test.dart`），
/// 而是**「什么时候该把它交给系统、什么时候该收回来」这套判断**：
///
/// * 后台 / 锁屏收到来电 → 报（那时我们自己那张通话页用户看不到）；
/// * **前台收到来电 → 不报**（再叠一层系统界面等于同一通电话响两次）；
/// * 同一通只报一次（否则锁屏上是两条一模一样的来电）；
/// * 通话结束了 → 一定告诉系统收尾（不然那个界面一直挂着，用户以为对方还在打）；
/// * 用户在系统界面上按接听 → **接电话的是我们这套状态机**（发 `acceptRtc`）；
/// * 冷启动：原生替我们存下的报文要能接起来。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late FakeCallMediaEngine media;
  late SilentCallTones tones;
  late ManualCallTicker ticker;
  late FakeCallPip pip;
  late FakeCallKit callKit;

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
    callKit = FakeCallKit();
    sessionGuard.update(ready: true, hasSession: true);

    // WS 必须在 setUp 里建（与 `call_page_test.dart` 里那段同一个理由：
    // `startTestWsService` 里有真 await，放进 `testWidgets` 的假时区会卡死）
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

  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    // 要看「VoIP 标识登记」那条链时注入一个假登记器（默认走真 provider）
    PushRegistrar? registrar,
  }) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(adapter.apiClient()),
          wsServiceProvider.overrideWithValue(ws),
          callMediaEngineProvider.overrideWithValue(media),
          callTonesProvider.overrideWithValue(tones),
          callPipProvider.overrideWithValue(pip),
          callTickerProvider.overrideWithValue(ticker),
          callKitProvider.overrideWithValue(callKit),
          if (registrar != null)
            pushRegistrarProvider.overrideWithValue(registrar),
        ],
        child: const GracelinkApp(),
      ),
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    container.read(callSyncServiceProvider).start();
    container
        .read(sessionStoreProvider.notifier)
        .applyLogin(const UserInfo(userId: 'u1', displayName: '我'));
    await tester.pumpAndSettle();
    // 收尾用 `disposeApp`，而且**在用例体里**调（不能在 `tearDown` 里）：
    // 界面一拆，drift 的流查询会挂一个零延迟定时器，得再用 `pump(Duration)` 把它走掉
    //（`addTearDown` 跑在「还有定时器没清」那道检查之后，来不及）。
    return container;
  }

  /// 服务端推一条 `webrtc` 事件（裹在 `runAsync` 里：那条链的续点都在真时区）
  Future<void> push(WidgetTester tester, Map<String, dynamic> data) async {
    await tester.runAsync(() async {
      channel.emit(
        jsonEncode(<String, dynamic>{'type': 'webrtc', 'data': data}),
      );
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    // 用**有上限**的 pump，不用 `pumpAndSettle`：后者默认等十分钟，
    // 一旦有东西一直排帧（长连接心跳、界面动画），卡住的是整条流水线。
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// 让 App「进后台 / 锁屏」。
  ///
  /// 必须**按顺序**走完 `inactive → hidden → paused`：Flutter 会丢掉不合法的状态迁移
  /// （从 resumed 直接跳 paused），那种情况下用例看到的是「什么都没发生」，
  /// 而原因不在被测代码里。
  Future<void> backgroundApp(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
  }

  /// 回到前台（收尾用：让剩下的定时器能正常被拆掉）
  Future<void> foregroundApp(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  }

  /// 等一件「跨真时区（原生回调 / 长连接）与假时区（界面）」的事发生。
  ///
  /// 两边都推一推：`runAsync` 放真事件循环，`pump(Duration)` 推假时钟
  ///（`_awaitSession` 那种 `Future.delayed` 只在假时钟里走）。
  Future<void> waitFor(
    WidgetTester tester,
    bool Function() check, {
    String label = '等的东西没发生',
    // 轮数要够走完 `_deliver` 里那段「等会话恢复」的 2 秒假时钟
    int rounds = 200,
  }) async {
    for (var i = 0; i < rounds; i++) {
      if (check()) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(
      check(),
      isTrue,
      reason: '$label（生命周期=${WidgetsBinding.instance.lifecycleState?.name}）',
    );
  }

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
    'content': '通话中',
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

  group('把来电报给系统', () {
    testWidgets('后台（锁屏）收到 calling：报给系统界面，字段是这一通的', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      final container = await pumpApp(tester);
      await backgroundApp(tester);

      await push(tester, frame(event: CallEvent.calling, type: CallType.video));
      await waitFor(
        tester,
        () => callKit.reported.isNotEmpty,
        label: '后台收到来电却没报给系统',
      );

      expect(controllerOf(container).session.phase, CallPhase.incoming);
      expect(
        callKit.lastReported,
        'call-1|u2|老B|true',
        reason: '报的必须是**这一通**的 id / 对方 / 语音还是视频',
      );
      await foregroundApp(tester);
      await disposeApp(tester);
    });

    testWidgets('前台收到 calling：**不报**（我们自己那张通话页就够了）', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      final container = await pumpApp(tester);

      await push(tester, frame(event: CallEvent.calling));
      await waitFor(
        tester,
        () => controllerOf(container).session.phase == CallPhase.incoming,
        label: '来电没进来（那这条用例就没验到东西）',
      );

      expect(callKit.reported, isEmpty, reason: '前台再弹一层系统界面 = 同一通电话响两次、两个接听键');
      await disposeApp(tester);
    });

    testWidgets('同一通只报一次（状态一变就再报一遍，锁屏上就是两条来电）', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      final container = await pumpApp(tester);
      await backgroundApp(tester);

      await push(tester, frame(event: CallEvent.calling));
      await waitFor(
        tester,
        () => callKit.reported.isNotEmpty,
        label: '后台收到来电却没报给系统',
      );

      // 同一通里状态会来回变好几次（这里手动推一次、再推一条信令，模拟那种情况）
      controllerOf(container).toggleLayout();
      await push(tester, frame(event: CallEvent.calling));

      expect(callKit.reported.length, 1);
      await foregroundApp(tester);
      await disposeApp(tester);
    });

    testWidgets('响铃中锁屏（会话状态一点没变）：也要把它交给系统', (tester) async {
      // 真机上的一常见场景：电话响着，用户按下电源键（或切到别的 App）。
      // 会话状态没变（还是 incoming），变的只是「App 在不在屏幕上」——
      // 只盯状态变化的话，这一幕永远不会走到 reportIncomingCall：
      // 我们自己那张通话页在锁屏上画不出来，于是电话一直响、锁屏上什么都没有。
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      final container = await pumpApp(tester);

      await push(tester, frame(event: CallEvent.calling));
      await waitFor(
        tester,
        () => controllerOf(container).session.phase == CallPhase.incoming,
        label: '来电没进来（那这条用例就没验到东西）',
      );
      expect(callKit.reported, isEmpty, reason: '前台还是不该报');

      await backgroundApp(tester);
      await waitFor(
        tester,
        () => callKit.reported.isNotEmpty,
        label: '锁屏 / 切走之后没交给系统 —— 锁屏上一条来电都看不到',
      );
      expect(callKit.lastReported, 'call-1|u2|老B|false');
      await foregroundApp(tester);
      await disposeApp(tester);
    });

    testWidgets('系统没接住（模拟器上必然如此）：不抛、通话照走', (tester) async {
      callKit.accept = false;
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      final container = await pumpApp(tester);
      await backgroundApp(tester);

      await push(tester, frame(event: CallEvent.calling));
      await waitFor(
        tester,
        () => callKit.reported.isNotEmpty,
        label: '没报（那这条就不是「报失败」，而是根本没报）',
      );

      expect(controllerOf(container).session.phase, CallPhase.incoming);
      await foregroundApp(tester);
      await disposeApp(tester);
    });
  });

  group('接电话的是状态机', () {
    testWidgets('用户在系统界面上按接听：真的发出 acceptRtc 并走到 connecting', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      final container = await pumpApp(tester);
      await backgroundApp(tester);
      await push(tester, frame(event: CallEvent.calling));
      await waitFor(
        tester,
        () => callKit.reported.isNotEmpty,
        label: '后台收到来电却没报给系统',
      );

      callKit.emit(
        const CallKitAction(kind: CallKitActionKind.answer, callId: 'call-1'),
      );
      await waitFor(
        tester,
        () => controllerOf(container).session.phase == CallPhase.connecting,
        label: '按了接听但状态机没动 —— 那原生那个界面就是个死按钮',
      );

      final body = adapter.lastBodyOf(ChatPaths.sendToMsg);
      expect(body['event'], CallEvent.acceptRtc);
      expect(body['code'], CallCode.accept);
      await foregroundApp(tester);
      await disposeApp(tester);
    });

    testWidgets('按的那一通不是当前这一通：忽略（不能「按的是 A、接起来的是 B」）', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      final container = await pumpApp(tester);
      await backgroundApp(tester);
      await push(tester, frame(event: CallEvent.calling));
      await waitFor(
        tester,
        () => callKit.reported.isNotEmpty,
        label: '后台收到来电却没报给系统',
      );

      // 锁屏上那个界面已经过期了（那一通刚被换掉 / 已经结束），用户才按的接听
      callKit.emit(
        const CallKitAction(kind: CallKitActionKind.answer, callId: 'call-99'),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(
        controllerOf(container).session.phase,
        CallPhase.incoming,
        reason: '过期的 id 不该把**现在**这一通接起来',
      );

      // 而当前这一通的字号真的按下去，是接得起来的（证明上面那条不是因为「按钮坏了」）
      callKit.emit(
        const CallKitAction(kind: CallKitActionKind.answer, callId: 'call-1'),
      );
      await waitFor(
        tester,
        () => controllerOf(container).session.phase == CallPhase.connecting,
        label: '当前这一通反而接不起来',
      );
      await foregroundApp(tester);
      await disposeApp(tester);
    });

    testWidgets('冷启动：原生替我们存下的那条报文被接起来', (tester) async {
      // App 被 PushKit 叫醒时，Dart 还没起来 —— 报文先存在原生那儿。
      //
      // `sendTime` 这里必须自己改一遍：报文里那个字段是**毫秒**
      //（`IncomingCallPush.sentAt`），而 `frame()` 造的是秒（WS 那条路只拿它
      //  排会话列表）。差这一个单位，"刚响的来电"会被当成 1970 年的、直接超龄丢掉。
      final pending = frame(event: CallEvent.calling, id: 'call-7');
      pending['sendTime'] = DateTime.now().millisecondsSinceEpoch;
      callKit.pending.add(jsonEncode(pending));
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      final container = await pumpApp(tester);

      await waitFor(
        tester,
        () => controllerOf(container).session.phase == CallPhase.incoming,
        label: '取回来的那条报文没被接起来（冷启动这一格就是空的）',
      );
      expect(controllerOf(container).session.peerId, 'u2');
      expect(controllerOf(container).session.messageId, 'call-7');
      await disposeApp(tester);
    });
  });

  group('收尾', () {
    testWidgets('通话结束：告诉系统收尾（不收的话那个界面会一直挂着）', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      await pumpApp(tester);
      await backgroundApp(tester);
      await push(tester, frame(event: CallEvent.calling));
      await waitFor(
        tester,
        () => callKit.reported.isNotEmpty,
        label: '后台收到来电却没报给系统',
      );

      // 对方挂了（老端那套码：906 = 通话中挂断）
      await push(
        tester,
        frame(
          event: CallEvent.hangup,
          code: CallCode.hangupInCall,
          status: CallStatus.none,
        ),
      );
      await waitFor(
        tester,
        () => callKit.ended.isNotEmpty,
        label: '对端挂了却不收尾 —— 用户会一直以为对方还在打',
      );
      expect(callKit.ended.first.split('|').first, 'call-1');
      await foregroundApp(tester);
      await disposeApp(tester);
    });

    testWidgets('本机挂断（来电时那颗「挂断」）：也要收尾', (tester) async {
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});
      final container = await pumpApp(tester);
      await backgroundApp(tester);
      await push(tester, frame(event: CallEvent.calling));
      await waitFor(
        tester,
        () => callKit.reported.isNotEmpty,
        label: '后台收到来电却没报给系统',
      );

      // 不 await：`hangup()` 里有靠假时钟走的收尾动作，干等它就会死锁
      unawaited(controllerOf(container).hangup());
      await waitFor(
        tester,
        () => callKit.ended.isNotEmpty,
        label: '本机挂断之后系统那个界面还挂着',
      );
      expect(callKit.ended.first.split('|').first, 'call-1');
      await foregroundApp(tester);
      await disposeApp(tester);
    });
  });

  group('VoIP 标识登记（S8.2）', () {
    testWidgets('拿到 PushKit 的标识：上报成 apns_voip:xxx', (tester) async {
      // 这条标识是**锁屏来电**唯一的通路：没上报成功，服务端就发不出 VoIP 推送，
      // 被划掉的 App 也就叫不醒（用户看到的是「电话响了，我这边什么反应都没有」）。
      callKit.token = 'aabbccddeeff';
      final reported = <String>[];
      var storedVoip = '';
      final registrar = PushRegistrar(
        source: const NoopPushTokenSource(),
        readCid: () => null,
        saveCid: (cid) async {},
        report: (cid) async {
          reported.add(cid);
          return true;
        },
        readVoipCid: () => storedVoip.isEmpty ? null : storedVoip,
        saveVoipCid: (cid) async => storedVoip = cid,
        log: (message) {},
      );
      adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{});

      await pumpApp(tester, registrar: registrar);
      await waitFor(
        tester,
        () => reported.isNotEmpty,
        label: 'VoIP 标识没上报 —— 那 iPhone 上锁屏来电根本发不出去',
      );
      await disposeApp(tester);

      expect(reported, <String>['apns_voip:aabbccddeeff']);
      expect(storedVoip, 'apns_voip:aabbccddeeff');
    });
  });
}
