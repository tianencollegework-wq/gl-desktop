import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/audio/call_tones.dart';
import 'package:gracelinkim/core/net/api_exception.dart';
import 'package:gracelinkim/core/util/json_value.dart';
import 'package:gracelinkim/data/media/call_media_engine.dart';
import 'package:gracelinkim/domain/call/call_controller.dart';
import 'package:gracelinkim/domain/call/call_diagnostics.dart';
import 'package:gracelinkim/domain/call/call_machine.dart';
import 'package:gracelinkim/domain/call/call_signal.dart';

import '../support/fake_call_keep_alive.dart';
import '../support/fake_call_media.dart';
import '../support/fake_call_pip.dart';
import '../support/fake_call_window.dart';

/// 通话控制器（S6.2）：把状态机产出的 `CallEffect` 落到媒体层 / 信令 / 铃声上。
///
/// 这里跑的是**内存里的两端对打**：真状态机 + 真控制器 + 假媒体层 +
/// 一条按服务端形态转发的「假服务端」。除了真实 WebRTC 与真实网络，
/// 整条信令链路都被跑到，老端那套字段与码都在断言里钉着。
void main() {
  _callWindowGroup();

  group('完整握手（主叫 → 被叫 → 接通）', () {
    test('语音通话从拨号到通话中，两端状态与报文都对', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      final server = FakeServer(<Peer>[a, b]);

      // ① 主叫拨号：先取本机媒体，取到才发 calling
      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      // 取到流之后顺手把音频路由切到扬声器（老端 `plusready` 里那一步）
      expect(a.media.calls, <String>[
        'open(video=false)',
        'setSpeakerEnabled(true)',
      ]);
      expect(a.media.openedWithVideo, isFalse);
      expect(a.tones.ringStarts, 1, reason: '拨号中要响铃');
      expect(a.view.session.phase, CallPhase.outgoing);
      expect(a.view.hasLocalStream, isTrue);

      // 那条 calling：status 3 / code 901 / id 是自己的 uuid / msg_id 空
      final calling = server.wire.single;
      expect(calling['event'], CallEvent.calling);
      expect(calling['status'], CallStatus.ringing);
      expect(calling['code'], CallCode.dialing);
      expect(calling['toContactId'], 'u2');
      expect(calling['msg_id'], '');
      expect(calling['callTime'], '');
      expect(calling['sdp'], '');
      expect(calling['iceCandidate'], '');

      // ② 被叫收到：进入来电中、响铃、锁上这个联系人
      expect(b.view.session.phase, CallPhase.incoming);
      expect(b.view.session.peerId, 'u1');
      expect(b.view.session.isCaller, isFalse);
      expect(b.tones.ringStarts, 1);
      expect(b.controller.machine.lock.isLocked, isTrue);

      // ③ 被叫点接听：取流 → 发 acceptRtc（904）
      // 注意这一句 `await` 之后，主叫已经收到 acceptRtc、造了 offer、被叫也回了 answer
      //（假服务端是同步转发的），所以下面按顺序断言整条链上的每一环。
      await b.controller.accept();
      expect(b.media.calls.first, 'open(video=false)');

      final acceptRtc = server.wire[1];
      expect(acceptRtc['event'], CallEvent.acceptRtc);
      expect(acceptRtc['code'], CallCode.accept);
      expect(acceptRtc['id'], calling['id'], reason: '两端共用同一个通话 id');
      expect(acceptRtc['msg_id'], isNotEmpty, reason: '收到过服务端回执后要带上');
      expect(b.tones.ringing, isFalse, reason: '接听就停铃');

      // ④ 主叫收到 acceptRtc：停铃、起表、造 offer
      expect(a.tones.ringing, isFalse);
      expect(a.view.session.phase, CallPhase.connecting);
      expect(a.media.calls, contains('createOffer(video=false)'));

      final offer = server.wire[2];
      expect(offer['event'], CallEvent.offer);
      expect(offer['sdp'], 'offer-sdp-media');
      expect(offer['code'], '');
      expect(offer['status'], '');

      // ⑤ 被叫收到 offer：设远端 + 造 answer
      expect(
        b.media.calls,
        contains('acceptOffer(video=false, sdp=offer-sdp-media)'),
      );

      final answer = server.wire[3];
      expect(answer['event'], CallEvent.answer);
      expect(answer['sdp'], 'answer-sdp-media');

      // ⑥ 主叫收到 answer
      expect(a.media.appliedAnswer, 'answer-sdp-media');

      // ⑦ 双向 ICE：本机每条候选都发出去，对方的每条都加进来
      a.media.emitIceCandidate(<String, dynamic>{
        'candidate': 'cand-a1',
        'sdpMid': 'audio',
        'sdpMLineIndex': 0,
      });
      b.media.emitIceCandidate(<String, dynamic>{
        'candidate': 'cand-b1',
        'sdpMid': 'audio',
        'sdpMLineIndex': 0,
      });
      await pump();

      expect(a.media.addedCandidates.single['candidate'], 'cand-b1');
      expect(b.media.addedCandidates.single['candidate'], 'cand-a1');
      final iceSent = server.wire
          .where((request) => request['event'] == CallEvent.iceCandidate)
          .toList();
      expect(iceSent, hasLength(2));
      // 候选在报文里是 JSON 字符串（老端 JSON.stringify）
      expect(iceSent.first['iceCandidate'], contains('cand-a1'));

      // ⑧ ICE 连上 → 两端都进通话中，计时开始
      a.media.emitConnected();
      b.media.emitConnected();
      await pump();

      expect(a.view.session.phase, CallPhase.connected);
      expect(b.view.session.phase, CallPhase.connected);

      a.ticker.tick();
      a.ticker.tick();
      await pump();
      expect(a.view.session.callTime, 2);

      // ⑨ 主叫挂断：906 + 通话时长；两端都收尾
      await a.controller.hangup();

      final hangup = server.wire.last;
      expect(hangup['event'], CallEvent.hangup);
      expect(hangup['code'], CallCode.hangupInCall);
      expect(hangup['callTime'], 2);
      expect(a.view.session.phase, CallPhase.ended);
      expect(a.tones.hangupTones, 1);
      expect(b.view.session.phase, CallPhase.ended);
      expect(b.tones.hangupTones, 1);

      expect(a.media.closed, isFalse, reason: '媒体由通话页关闭时释放（reset）');
      await a.controller.reset();
      expect(a.media.closed, isTrue);
      expect(a.view.session.phase, CallPhase.idle);
      expect(a.view.hasLocalStream, isFalse);
    });

    test('视频通话：取流带 video，两端都按视频协商', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      final server = FakeServer(<Peer>[a, b]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.video,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      expect(a.media.calls, <String>[
        'open(video=true)',
        'setSpeakerEnabled(true)',
      ]);
      expect(a.view.isVideo, isTrue);
      expect(server.wire.single['type'], CallType.video);
      expect(b.view.session.isVideo, isTrue);

      await b.controller.accept();
      expect(b.media.calls.first, 'open(video=true)');
      expect(a.media.calls, contains('createOffer(video=true)'));
      expect(
        b.media.calls.any((call) => call.startsWith('acceptOffer(video=true')),
        isTrue,
      );
    });

    test('远端流到了就把大窗切给对面（老端 streamType）', () async {
      final a = Peer(userId: 'u1', name: '我');
      FakeServer(<Peer>[a]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.video,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      expect(a.view.remoteBig, isFalse);
      expect(a.view.showLocalVideo, isTrue);

      a.media.emitRemoteStream();
      expect(a.view.hasRemoteStream, isTrue);
      expect(a.view.remoteBig, isTrue);
      expect(a.view.showRemoteVideo, isTrue);

      a.controller.toggleLayout();
      expect(a.view.remoteBig, isFalse);
    });

    test('静音、关摄像头、切镜头都落到媒体层，状态也同步', () async {
      final a = Peer(userId: 'u1', name: '我');
      FakeServer(<Peer>[a]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.video,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      await a.controller.toggleMicrophone();
      expect(a.media.microphoneEnabled, isFalse);
      expect(a.view.microphoneEnabled, isFalse);

      await a.controller.toggleCamera();
      expect(a.media.cameraEnabled, isFalse);
      expect(a.view.cameraEnabled, isFalse);

      await a.controller.switchCamera();
      expect(a.media.cameraSwitches, 1);

      // 再取反回来
      await a.controller.toggleMicrophone();
      await a.controller.toggleCamera();
      expect(a.media.microphoneEnabled, isTrue);
      expect(a.media.cameraEnabled, isTrue);
    });
  });

  group('没接通的那几条路', () {
    test('被叫拒接：主叫收到 903 后结束', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      final server = FakeServer(<Peer>[a, b]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await b.controller.hangup();

      expect(server.wire.last['event'], CallEvent.hangup);
      expect(server.wire.last['code'], CallCode.reject);
      expect(a.view.session.code, CallCode.reject);
      expect(a.view.session.phase, CallPhase.ended);
      expect(a.tones.hangupTones, 1);
      expect(b.tones.hangupTones, 1);
    });

    test('主叫取消：902，被叫那边也结束', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      final server = FakeServer(<Peer>[a, b]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await a.controller.hangup();

      expect(server.wire.last['code'], CallCode.cancel);
      expect(b.view.session.phase, CallPhase.ended);
    });

    test('拨号 40 秒没人接 → 自动 902（老端 WebView 的倒计时）', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      final server = FakeServer(<Peer>[a, b]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      for (var i = 0; i < CallMachine.dialTimeoutSeconds - 1; i++) {
        a.ticker.tick();
        await pump();
      }
      expect(a.view.session.phase, CallPhase.outgoing, reason: '还差一秒');
      expect(a.view.session.callTime, 0, reason: '拨号中不算通话时长');

      a.ticker.tick();
      await pump();

      expect(a.view.session.phase, CallPhase.ended);
      expect(a.view.session.code, CallCode.cancel);
      expect(server.wire.last['event'], CallEvent.hangup);
      expect(server.wire.last['code'], CallCode.cancel);
      expect(b.view.session.phase, CallPhase.ended);
    });

    test('取不到本机媒体：提示 + 关页，**一条信令都不发**（老端行为）', () async {
      final a = Peer(userId: 'u1', name: '我');
      final server = FakeServer(<Peer>[a]);
      a.media.openError = StateError('没有麦克风');

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      expect(server.wire, isEmpty, reason: '取不到流时对方根本还不知道这通电话');
      expect(a.tips, <String>['message.checkWebtc']);
      expect(a.view.session.phase, CallPhase.ended);
      expect(a.tones.hangupTones, 1);
      expect(a.tones.ringing, isFalse);
    });

    test('服务端在回执里说对方不在线（907）→ 提示并关页', () async {
      final a = Peer(userId: 'u1', name: '我');
      final server = FakeServer(<Peer>[a])..offline = true;

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      expect(server.wire.single['event'], CallEvent.calling);
      expect(a.tips, <String>['message.notOnline']);
      expect(a.view.session.phase, CallPhase.ended);
      expect(a.tones.hangupTones, 1);
    });

    test('服务端开关关着 / 已经在通话中：只提示，不建会话', () async {
      final a = Peer(userId: 'u1', name: '我');
      FakeServer(<Peer>[a]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: false,
        simpleChatEnabled: true,
      );
      expect(a.tips, <String>['chat.closeWebrtc']);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: false,
      );
      expect(a.tips.last, 'chat.notTalk');

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await a.controller.start(
        peerId: 'u3',
        peerName: '老C',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      expect(a.tips.last, 'message.otherCalling');
      expect(a.view.session.phase, CallPhase.outgoing);
      expect(a.view.session.peerId, 'u2');
      // 取到流之后顺手把音频路由切到扬声器（老端 `plusready` 里那一步）
      expect(a.media.calls, <String>[
        'open(video=false)',
        'setSpeakerEnabled(true)',
      ]);
    });

    test('造不出 offer（没摄像头）→ 提示 + 挂断，对方不会一直等', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      final server = FakeServer(<Peer>[a, b]);
      a.media.offerError = StateError('没有摄像头');

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.video,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await b.controller.accept();

      expect(a.tips, <String>['message.checkWebtc']);
      expect(a.view.session.phase, CallPhase.ended);
      expect(server.wire.last['event'], CallEvent.hangup);
      expect(server.wire.last['code'], CallCode.hangupInCall);
      expect(
        b.view.session.phase,
        CallPhase.ended,
        reason: '主叫造不出 offer 也得告诉对方，不能让人一直响铃',
      );
    });

    test('响应 offer 出错也一样收场', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      final server = FakeServer(<Peer>[a, b]);
      b.media.acceptError = StateError('原生层报错');

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await b.controller.accept();

      expect(b.tips, <String>['message.checkWebtc']);
      expect(b.view.session.phase, CallPhase.ended);
      expect(server.wire.last['event'], CallEvent.hangup);
      expect(a.view.session.phase, CallPhase.ended);
    });

    test('ICE 怎么都连不上 → 提示网络问题并结束（老端会一直僵着）', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      final server = FakeServer(<Peer>[a, b]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await b.controller.accept();

      a.media.emitConnectionFailed(StateError('ICE failed'));
      await pump();

      expect(a.tips, <String>['network.disconnect']);
      expect(a.view.session.phase, CallPhase.ended);
      expect(server.wire.last['event'], CallEvent.hangup);
      expect(b.view.session.phase, CallPhase.ended);
    });

    test('已经结束之后再报连接失败不会又挂一次', () async {
      final a = Peer(userId: 'u1', name: '我');
      FakeServer(<Peer>[a]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await a.controller.hangup();
      final wireCount = a.sent.length;

      a.media.emitConnectionFailed(StateError('late failure'));
      await pump();

      expect(a.sent, hasLength(wireCount));
      expect(a.tips, isEmpty);
    });
  });

  group('忙线', () {
    test('被叫正在通话中，又来一通 → 回 907，第一通不受影响', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      final c = Peer(userId: 'u3', name: '老C');
      final server = FakeServer(<Peer>[a, b, c]);

      // a 与 b 先接通
      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await b.controller.accept();

      // c 这时打给 b：b 已经有一通，回 busy/907，自己那通不动
      await c.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      final busy = b.sent.last;
      expect(busy['event'], CallEvent.busy);
      expect(busy['code'], CallCode.busy);
      expect(busy['toContactId'], 'u3');
      expect(b.view.session.peerId, 'u1');
      expect(b.view.session.phase, CallPhase.connecting);

      // c 收到忙线：提示「对方忙~~」并关页
      expect(c.tips, <String>['message.toBusy']);
      expect(c.view.session.phase, CallPhase.ended);
      expect(c.tones.hangupTones, 1);
      expect(server.wire, isNotEmpty);
    });

    test('通话页开着时又来一通 → 也回忙线', () async {
      final a = Peer(userId: 'u1', name: '我');
      final server = FakeServer(<Peer>[a]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      await a.controller.remote(
        server.signal(
          event: CallEvent.calling,
          from: 'u3',
          messageId: 'other-call',
        ),
        pageActive: true,
      );

      expect(a.sent.last['event'], CallEvent.busy);
      expect(a.sent.last['code'], CallCode.busy);
      expect(a.view.session.peerId, 'u2');
      expect(a.tips, isEmpty, reason: '自己那通照常，不要弹提示');
    });
  });

  group('自己发的信令被服务端推回来', () {
    test('自己那条 calling 不会被当成来电', () async {
      final a = Peer(userId: 'u1', name: '我');
      FakeServer(<Peer>[a], echoToSender: true);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      expect(a.view.session.phase, CallPhase.outgoing);
      expect(a.view.session.isCaller, isTrue);
      expect(a.tones.ringStarts, 1, reason: '不该多响一次');
    });

    test('自己那条 902 回来 → 解开多端锁（老端的解锁路径）', () async {
      final a = Peer(userId: 'u1', name: '我');
      FakeServer(<Peer>[a], echoToSender: true);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await a.controller.hangup();

      expect(a.controller.machine.lock.isLocked, isFalse);
      expect(a.sent.last['code'], CallCode.cancel);
    });
  });

  group('收尾', () {
    test('reset 之后还能再打一通', () async {
      final a = Peer(userId: 'u1', name: '我');
      FakeServer(<Peer>[a]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await a.controller.hangup();
      await a.controller.reset();

      expect(a.view.session.phase, CallPhase.idle);
      expect(a.view.microphoneEnabled, isTrue);
      expect(a.tones.ringing, isFalse);

      await a.controller.start(
        peerId: 'u3',
        peerName: '老C',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      expect(a.view.session.phase, CallPhase.outgoing);
      expect(a.view.session.peerId, 'u3');
      expect(a.tips, isEmpty);
    });

    test('对方下线 → 解锁（老端 App.vue 那条在线状态规则）', () async {
      final a = Peer(userId: 'u1', name: '我');
      final server = FakeServer(<Peer>[a]);

      await a.controller.remote(
        server.signal(event: CallEvent.calling, from: 'u2'),
      );
      expect(a.controller.machine.lock.isLocked, isTrue);

      await a.controller.peerOffline('u3');
      expect(a.controller.machine.lock.isLocked, isTrue);

      await a.controller.peerOffline('u2');
      expect(a.controller.machine.lock.isLocked, isFalse);
    });

    test('dispose 会放掉媒体与铃声', () async {
      final a = Peer(userId: 'u1', name: '我');
      FakeServer(<Peer>[a]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      await a.controller.dispose();

      expect(a.media.closed, isTrue);
      expect(a.tones.ringing, isFalse);
    });

    test('结束信令到达后不用 reset 也能再接一通新来电', () async {
      final a = Peer(userId: 'u1', name: '我');
      final server = FakeServer(<Peer>[a]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      // 对方的结束信令一定带「本通电话的 id」（带错了在协议里等于「在忙线」）
      final callId = a.view.session.messageId;
      await a.controller.remote(
        server.signal(
          event: CallEvent.hangup,
          from: 'u2',
          messageId: callId,
          code: CallCode.reject,
        ),
      );
      expect(a.view.session.phase, CallPhase.ended);

      await a.controller.remote(
        server.signal(
          event: CallEvent.calling,
          from: 'u3',
          messageId: 'new-call',
        ),
      );

      expect(a.view.session.phase, CallPhase.incoming);
      expect(a.view.session.peerId, 'u3');
    });
  });

  group('保活（S6.5：通话期间的前台服务）', () {
    test('取到媒体就起服务（参数对），挂断就停', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      FakeServer(<Peer>[a, b]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await pump();

      // 本机媒体就绪那一刻就起（此刻才真的在用麦克风）
      expect(a.keepAlive.starts, <String>['video=false peer=老B']);
      expect(a.keepAlive.running, isTrue);
      expect(a.keepAlive.stops, 0);
      expect(
        a.controller.diagnostics.value.events.map((event) => event.label),
        contains('后台保活已开启（前台服务：麦克风）'),
      );

      await a.controller.hangup();
      expect(a.keepAlive.stops, 1, reason: '挂断立刻停，别留常驻通知');
      expect(a.keepAlive.running, isFalse);
    });

    test('视频通话带摄像头类型；被叫接听后也会起', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      FakeServer(<Peer>[a, b]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.video,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      expect(a.keepAlive.starts, <String>['video=true peer=老B']);

      await b.controller.accept();
      await pump();
      expect(b.keepAlive.starts, <String>['video=true peer=我']);
    });

    test('每一条结束路径都停：拒接 / 忙线 / 拨号超时 / 对方挂断', () async {
      // ① 被叫拒接（903）→ 主叫停
      final a1 = Peer(userId: 'u1', name: '我');
      final b1 = Peer(userId: 'u2', name: '老B');
      FakeServer(<Peer>[a1, b1]);
      await a1.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await b1.controller.hangup();
      await pump();
      expect(a1.keepAlive.stops, 1, reason: '主叫收到拒接就停');
      // 被叫在「来电中」阶段还没取媒体，所以压根没起过服务（也就没什么可停）
      expect(b1.keepAlive.starts, isEmpty);
      expect(b1.keepAlive.stops, 0);

      // ①b 被叫接听后自己挂断 → 它的服务也要停
      final a1b = Peer(userId: 'ua', name: '我');
      final b1b = Peer(userId: 'ub', name: '老B');
      FakeServer(<Peer>[a1b, b1b]);
      await a1b.controller.start(
        peerId: 'ub',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await b1b.controller.accept();
      await pump();
      expect(b1b.keepAlive.starts, hasLength(1), reason: '接听取到媒体后起服务');

      await b1b.controller.hangup();
      await pump();
      expect(b1b.keepAlive.stops, 1);
      expect(a1b.keepAlive.stops, 1);

      // ② 忙线（907）
      final a2 = Peer(userId: 'u3', name: '我');
      final b2 = Peer(userId: 'u4', name: '老B');
      final c2 = Peer(userId: 'u5', name: '老C');
      FakeServer(<Peer>[a2, b2, c2]);
      await a2.controller.start(
        peerId: 'u4',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await b2.controller.accept();
      await c2.controller.start(
        peerId: 'u4',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await pump();
      expect(c2.keepAlive.stops, 1, reason: '收到忙线就结束，服务跟着停');
      expect(b2.keepAlive.stops, 0, reason: '正在通话的那一通不受影响');

      // ③ 拨号 40 秒超时
      final a3 = Peer(userId: 'u6', name: '我');
      FakeServer(<Peer>[a3]);
      await a3.controller.start(
        peerId: 'u7',
        peerName: '老D',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      for (var i = 0; i < CallMachine.dialTimeoutSeconds; i++) {
        a3.ticker.tick();
      }
      await pump();
      expect(a3.keepAlive.stops, 1, reason: '超时自动挂断也要停');

      // ④ 对方挂断
      final a4 = Peer(userId: 'u8', name: '我');
      final b4 = Peer(userId: 'u9', name: '老E');
      final server4 = FakeServer(<Peer>[a4, b4]);
      await a4.controller.start(
        peerId: 'u9',
        peerName: '老E',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await b4.controller.accept();
      await a4.controller.remote(
        server4.signal(
          event: CallEvent.hangup,
          from: 'u9',
          messageId: a4.view.session.messageId,
          code: CallCode.hangupInCall,
        ),
      );
      await pump();
      expect(a4.keepAlive.stops, 1);
    });

    test('ICE 连不上 / reset / dispose 也都会停（而且只停一次）', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      FakeServer(<Peer>[a, b]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await b.controller.accept();
      a.media.emitConnectionFailed(StateError('ICE failed'));
      await pump();
      expect(a.keepAlive.stops, 1);

      await a.controller.reset();
      expect(a.keepAlive.stops, 1, reason: 'reset 是兜底（幂等）：不重复发通道调用');

      final c = Peer(userId: 'u3', name: '我');
      FakeServer(<Peer>[c]);
      await c.controller.start(
        peerId: 'u4',
        peerName: '老F',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await c.controller.dispose();
      expect(c.keepAlive.stops, 1, reason: '登出/换账号会把控制器换掉，保活也得停');
    });

    test('取不到媒体：压根不起服务（也没得停）', () async {
      final a = Peer(userId: 'u1', name: '我');
      FakeServer(<Peer>[a]);
      a.media.openError = StateError('Permission denied: audio');

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await pump();

      expect(a.keepAlive.starts, isEmpty);
      expect(a.keepAlive.stops, 0);
    });

    test('服务起不来（如 Android 14 的 while-in-use 拒绝）：只记诊断，通话照常', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      FakeServer(<Peer>[a, b]);
      a.keepAlive.startError =
          'Starting FGS with type microphone … while-in-use';

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await pump();

      expect(a.keepAlive.starts, isEmpty);
      expect(
        a.controller.diagnostics.value.events.any(
          (event) => event.label.startsWith('后台保活失败：'),
        ),
        isTrue,
        reason: '诊断面板要能看见「保活没起来」和原因',
      );
      // 通话本身完全不受影响：照旧拨号、接通
      expect(a.view.session.phase, CallPhase.outgoing);
      expect(a.keepAlive.stops, 0);

      await b.controller.accept();
      a.media.emitConnected();
      await pump();
      expect(a.view.session.phase, CallPhase.connected);
    });

    test('起服务还没回来就挂断（拨出去立刻取消）：不会留幽灵通知', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      FakeServer(<Peer>[a, b]);
      // 卡住 start，模拟真实的「起服务要几百毫秒」
      final blocker = Completer<void>();
      a.keepAlive.startBlocker = blocker;

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      // 还没起来就挂断
      await a.controller.hangup();
      expect(a.keepAlive.starts, isEmpty);

      // 原生那边这时才把服务 foregound 起来
      blocker.complete();
      await pump();

      expect(a.keepAlive.running, isFalse, reason: '不能留下一条幽灵通知');
      expect(
        a.keepAlive.stops,
        greaterThanOrEqualTo(1),
        reason: '挂断那一枪 + 起完之后补的那一枪',
      );
    });

    test('通知权限没给：不影响保活，但诊断里会记一行', () async {
      final a = Peer(userId: 'u1', name: '我');
      FakeServer(<Peer>[a]);
      a.keepAlive.notificationGranted = false;

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await pump();

      expect(a.keepAlive.running, isTrue, reason: '没通知权限也要保活');
      expect(a.keepAlive.permissionChecks, greaterThan(0));
      expect(
        a.controller.diagnostics.value.events.any(
          (event) => event.label.startsWith('通知权限未给'),
        ),
        isTrue,
      );
    });
  });

  group('诊断（安卓端「打不通」的第一排查工具）', () {
    test('接通之后：候选按类型计数、结论是直连、ICE 服务器记下来了', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      FakeServer(<Peer>[a, b]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      // 会话一起来就开始记（主叫/被叫都在这里开始）
      expect(a.controller.diagnostics.value.startedAt, isNotNull);
      expect(a.controller.diagnostics.value.caller, isTrue);
      expect(a.controller.diagnostics.value.peer, '老B');
      expect(a.controller.diagnostics.value.video, isFalse);

      await b.controller.accept();
      expect(b.controller.diagnostics.value.caller, isFalse);
      expect(b.controller.diagnostics.value.peer, '我');

      a.media.emitIceCandidate(<String, dynamic>{
        'candidate': 'candidate:1 1 udp 2130706431 192.168.1.5 5000 typ host',
        'sdpMid': 'audio',
        'sdpMLineIndex': 0,
      });
      a.media.emitIceCandidate(<String, dynamic>{
        'candidate':
            'candidate:2 1 udp 1 203.0.113.7 5001 typ srflx raddr 0 rport 0',
        'sdpMid': 'audio',
        'sdpMLineIndex': 0,
      });
      a.media.emitConnected();
      await pump();

      final diagnostics = a.controller.diagnostics.value;
      expect(diagnostics.localCandidates[IceCandidateKind.host], 1);
      expect(diagnostics.localCandidates[IceCandidateKind.srflx], 1);
      expect(diagnostics.localCandidateCount, 2);
      expect(diagnostics.iceServers.single, contains('stun.example.com'));
      expect(diagnostics.signals['calling'], 1);
      expect(diagnostics.hint, contains('P2P'));
      expect(
        diagnostics.events.map((event) => event.label),
        contains('ICE 已连通'),
      );

      // 挂断之后快照**留着**（打完电话还能在「设置 → 通话诊断」里回看）
      await a.controller.hangup();
      expect(
        a.controller.diagnostics.value.events.last.label,
        startsWith('通话结束'),
      );
      expect(a.controller.diagnostics.value.hint, isNotEmpty);
    });

    test('建连接之后把实际用的那份 ICE 列表补记进诊断（TURN 凭据那时才并进来）', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      FakeServer(<Peer>[a, b]);

      // 老B 拨过来：会话一起来就记了一笔，此时只有站内那一栏
      await b.controller.start(
        peerId: 'u1',
        peerName: '我',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      expect(
        a.controller.diagnostics.value.iceServers.single,
        contains('stun.example.com'),
      );

      // 我点接听：媒体层取到流那一刻才知道「服务端签发的 TURN 凭据」
      // 到底有没有拿到（真引擎里就是那时把这份列表交给插件的）——
      // 假引擎用 iceServers 字段模拟这件事。
      a.media.holdOpen();
      final accepting = a.controller.accept();
      await pump();
      a.media.iceServers = const <String>[
        'stun:stun.example.com:3478（无账号）',
        'turn:turn.cloudflare.com:3478?transport=udp（带账号）',
      ];
      a.media.releaseOpen();
      await accepting;
      await pump();

      final diagnostics = a.controller.diagnostics.value;
      expect(diagnostics.iceServers, hasLength(2));
      expect(diagnostics.iceServers.last, contains('turn.cloudflare.com'));
      expect(
        diagnostics.summary,
        contains('turn.cloudflare.com'),
        reason: '导出的报告里也要看得到 TURN 用上了没有',
      );
    });

    test('一条本机候选都没有 → 结论指到 ICE 配置上', () async {
      final a = Peer(userId: 'u1', name: '我');
      FakeServer(<Peer>[a]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      expect(
        a.controller.diagnostics.value.hint,
        contains('一条本机候选都没有'),
        reason: '一直卡在「正在接通…」的头号原因',
      );
    });

    test('麦克风权限被拒：说的是麦克风，不是那句笼统的「检查通话设置」', () async {
      final a = Peer(userId: 'u1', name: '我');
      FakeServer(<Peer>[a]);
      a.media.openError = StateError('Permission denied: audio capture');

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      // 状态机那句是笼统的，后面补的那句才告诉用户是麦克风（后一句才会被看到），
      // 而且权限那条走的是**带「去授权」按钮**的那条提示
      expect(a.tips, <String>['message.checkWebtc']);
      expect(a.permissionTips, <String>['call.micAuth']);
      expect(a.view.session.phase, CallPhase.ended);
    });

    test('视频通话：摄像头被拒 / 没设备各有各的说法', () async {
      final camera = Peer(userId: 'u1', name: '我');
      FakeServer(<Peer>[camera]);
      camera.media.openError = StateError('NotAllowedError: camera permission');

      await camera.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.video,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      expect(camera.permissionTips.last, 'call.cameraAuth');

      final missing = Peer(userId: 'u3', name: '老C');
      FakeServer(<Peer>[missing]);
      missing.media.openError = StateError('NotFoundError: no device');

      await missing.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      expect(missing.tips.last, 'call.deviceMissing');
      expect(missing.permissionTips, isEmpty, reason: '没设备要的不是权限，提示上不该挂「去授权」');
    });

    test('每 3 秒采一次统计（RTT / 丢包进快照），不需要额外定时器', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      FakeServer(<Peer>[a, b]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await b.controller.accept();
      a.media.emitConnected();
      b.media.emitConnected();
      await pump();
      a.media.statsSample = const CallMediaSample(
        bytesSent: 3000,
        bytesReceived: 4000,
        roundTripMs: 55,
        packetsLost: 2,
        jitterMs: 7,
      );

      // 前两秒不采（统计没那么快变），第三秒采一次
      a.ticker.tick();
      a.ticker.tick();
      await pump();
      expect(a.controller.diagnostics.value.sampleCount, 0);

      a.ticker.tick();
      await pump();
      final diagnostics = a.controller.diagnostics.value;
      expect(diagnostics.sampleCount, 1);
      expect(diagnostics.latestSample?.roundTripMs, 55);
      expect(diagnostics.latestSample?.packetsLost, 2);
      expect(
        a.media.calls.where((call) => call == 'sampleStats()'),
        hasLength(1),
      );
    });
  });

  // 真机（2026-09-19）上的两个坑：视频通话里对端的 offer 要么**早到**（本机还在
  // 取摄像头），要么**迟到**（这通电话已经结束了）。两种都不能把通话干掉，
  // 更不能弹一句「请检查音视频」——用户看到的就是「一接通就闪退」。
  group('ICE 候选信令：串行 + 重试（2026-09-26 真机「15 发 13 败」的收尾）', () {
    /// 发一条候选（`_inCall` 之后才发得出去）
    void emit(Peer peer, String candidate) =>
        peer.media.emitIceCandidate(<String, dynamic>{
          'candidate': candidate,
          'sdpMid': 'audio',
          'sdpMLineIndex': 0,
        });

    /// 两个 Peer + 假服务端，并把握手推完
    ///
    /// 候选只在 `connecting / connected` 才发得出去（`CallMachine._inCall`），
    /// 所以要先拨号 + 接听，把通话推到 offer/answer 已交换的阶段。
    Future<Peer> connectedCaller() async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      FakeServer(<Peer>[a, b]);
      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await b.controller.accept();
      expect(a.controller.machine.session.phase, CallPhase.connecting);
      return a;
    }

    test('媒体层一次回调一整批候选时，同时只有一条在飞（不再集体撞超时）', () async {
      final a = await connectedCaller();
      final delivered = <String>[];
      final gates = <Completer<void>>[];
      var inFlight = 0;
      var maxInFlight = 0;

      // 假服务端：候选要「放行」才返回（模拟弱网里的慢请求），其它信令照常
      a.send = (request) async {
        if (request['event'] == CallEvent.iceCandidate) {
          inFlight += 1;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          final gate = Completer<void>();
          gates.add(gate);
          await gate.future;
          inFlight -= 1;
        }
        delivered.add('${request['event']}');
        return <String, dynamic>{'msg_id': 'm-1'};
      };

      // 媒体层连着回调三条（真机上就是这一批同时打出去撞的 10 秒超时）
      emit(a, 'candidate:1 1 udp 1 192.168.1.5 5001 typ host');
      emit(a, 'candidate:2 1 udp 1 192.168.1.5 5002 typ host');
      emit(a, 'candidate:3 1 udp 1 192.168.1.5 5003 typ relay');
      for (var i = 0; i < 4; i++) {
        await pump();
      }

      expect(gates.length, 1, reason: '只有第一条在飞，后两条在队列里等');
      expect(maxInFlight, 1);

      gates[0].complete();
      for (var i = 0; i < 4; i++) {
        await pump();
      }
      expect(gates.length, 2, reason: '第一条回来之后第二条才出发');
      expect(maxInFlight, 1);

      gates[1].complete();
      for (var i = 0; i < 4; i++) {
        await pump();
      }
      gates[2].complete();
      for (var i = 0; i < 4; i++) {
        await pump();
      }

      expect(maxInFlight, 1, reason: '全程同时只有一条候选在飞');
      expect(
        delivered.where((event) => event == CallEvent.iceCandidate).length,
        3,
        reason: '三条候选最后都得发出去（包括那条 relay）',
      );
    });

    test('候选发失败要重试：中途成功不算失败，三次都不成才记一次', () async {
      final a = await connectedCaller();
      final attemptsByCandidate = <String, int>{};

      a.send = (request) async {
        if (request['event'] == CallEvent.iceCandidate) {
          final raw = request['iceCandidate'];
          final key = raw is Map ? '${raw['candidate']}' : '$raw';
          final attempt = (attemptsByCandidate[key] ?? 0) + 1;
          attemptsByCandidate[key] = attempt;
          // 第一条：头两次失败；第二条：永远失败
          if (key.contains('host-a') && attempt < 3) {
            throw const NetworkUnavailableException('请求超时，请检查网络后重试');
          }
          if (key.contains('host-b')) {
            throw const NetworkUnavailableException('请求超时，请检查网络后重试');
          }
        }
        return <String, dynamic>{'msg_id': 'm-1'};
      };

      emit(a, 'candidate:1 1 udp 1 192.168.1.5 5001 typ host-a');
      emit(a, 'candidate:2 1 udp 1 192.168.1.5 5002 typ host-b');
      for (var i = 0; i < 24; i++) {
        await pump();
      }

      final diagnostics = a.controller.diagnostics.value;
      expect(
        attemptsByCandidate.values,
        containsAll(<int>[3]),
        reason: '失败的最多重试到 3 次',
      );
      expect(
        diagnostics.signals[CallEvent.iceCandidate],
        2,
        reason: '计数口径是「想发几条」：两这条候选都算发过',
      );
      expect(
        diagnostics.failedSignals[CallEvent.iceCandidate],
        1,
        reason: '只有彻底发不出去的那一条算失败，重试不算',
      );
      final labels = diagnostics.events.map((event) => event.label).toList();
      expect(
        labels.where((label) => label.contains('次未发出，重试')).length,
        4,
        reason: '两条候选各重试两次，都在时间线里看得见',
      );
      expect(
        labels.where((label) => label.contains('发送失败')).length,
        1,
        reason: '失败的最终结论只记一次',
      );
    });

    test('候选卡在队列里不影响关键信令：挂断立刻发得出去', () async {
      final a = await connectedCaller();
      final delivered = <String>[];
      var candidatesStuck = 0;

      a.send = (request) async {
        if (request['event'] == CallEvent.iceCandidate) {
          candidatesStuck += 1;
          await Completer<void>().future; // 永远不返回：模拟卡死的弱网
        }
        delivered.add('${request['event']}');
        return <String, dynamic>{'msg_id': 'm-1'};
      };

      emit(a, 'candidate:1 1 udp 1 192.168.1.5 5001 typ host');
      for (var i = 0; i < 4; i++) {
        await pump();
      }
      expect(candidatesStuck, 1);

      await a.controller.hangup();
      expect(
        delivered,
        contains(CallEvent.hangup),
        reason: '关键信令走自己的路，不被候选队列拖住',
      );
    });
  });

  group('早到 / 迟到的 offer', () {
    test('视频通话：offer 在本机还在取摄像头时到达 → 不挂断、不提示，取到流后照常应答', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      final server = FakeServer(<Peer>[a, b]);

      // 老B 拨一个视频过来
      await b.controller.start(
        peerId: 'u1',
        peerName: '我',
        type: CallType.video,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      final callId = b.controller.machine.session.messageId;
      expect(a.controller.machine.session.phase, CallPhase.incoming);

      // 我点接听：真机上视频取摄像头要 1~3 秒，这里把 open 卡住来模拟那段窗口
      a.media.holdOpen();
      final accepting = a.controller.accept();
      await pump();

      // 就在这段窗口里，对端那条 offer 到了
      await a.controller.remote(
        server.signal(
          event: CallEvent.offer,
          from: 'u2',
          messageId: callId,
          sdp: 'early-offer',
          type: CallType.video,
        ),
      );
      await pump();

      expect(a.tips, isEmpty, reason: '不能弹「请检查音视频」');
      expect(a.controller.machine.session.phase, CallPhase.connecting);
      expect(
        a.media.calls.where((call) => call.startsWith('acceptOffer')),
        isEmpty,
        reason: '连接还没建出来时不该去响应它',
      );

      // 流取到了：补发 acceptRtc，并把那条早到的 offer 应答掉
      a.media.releaseOpen();
      await accepting;
      await pump();

      expect(
        a.media.calls,
        contains('acceptOffer(video=true, sdp=early-offer)'),
      );
      final answer = server.wire.firstWhere(
        (request) => request['event'] == CallEvent.answer,
      );
      expect(answer['sdp'], 'answer-sdp-media');
      expect(
        server.wire.where((request) => request['event'] == CallEvent.acceptRtc),
        hasLength(1),
      );
    });

    test('本端没有通话时收到 offer → 忽略，不提示也不发挂断', () async {
      final a = Peer(userId: 'u1', name: '我');
      final server = FakeServer(<Peer>[a]);

      await a.controller.remote(
        server.signal(event: CallEvent.offer, from: 'u2', sdp: 'stale-offer'),
      );
      await pump();

      expect(a.controller.machine.session.phase, CallPhase.idle);
      expect(a.tips, isEmpty);
      expect(a.sent, isEmpty, reason: '也不该补一枪挂断');
      expect(a.media.calls, isEmpty, reason: '连媒体层都不该碰');
    });

    test('这通电话已经挂断之后对端的 offer 才推到 → 忽略', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      final server = FakeServer(<Peer>[a, b]);

      await b.controller.start(
        peerId: 'u1',
        peerName: '我',
        type: CallType.video,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      final callId = b.controller.machine.session.messageId;
      await a.controller.accept();
      await a.controller.hangup();

      final tipsBefore = a.tips.length;
      final callsBefore = a.media.calls.length;

      await a.controller.remote(
        server.signal(
          event: CallEvent.offer,
          from: 'u2',
          messageId: callId,
          sdp: 'late-offer',
          type: CallType.video,
        ),
      );
      await pump();

      expect(a.controller.machine.session.phase, CallPhase.ended);
      expect(a.tips.length, tipsBefore, reason: '已经结束了就别再吓人');
      expect(a.media.calls.length, callsBefore);
      expect(a.sent.last['event'], CallEvent.hangup, reason: '最后发出的还是那次挂断');
    });
  });

  // 小窗（画中画，S6.6）—— 按用户要求：**只有点按钮才进小窗**（见 minimizeToPip），
  // 回到桌面/切走不进小窗（那几种情况只靠前台服务 + 常驻通知）。
  // 所以这里钉的是两件事：① 比例与标题跟着这一通走；② 每条结束路径都要把
  // 已经打开的小窗收掉（否则会留一个「小窗里是聊天列表」的怪状态）。
  group('小窗（画中画）', () {
    test('拨号中就把参数交给系统（语音 1:1、标题是对面名字）；被叫响铃也一样交', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      FakeServer(<Peer>[a, b]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await pump();

      expect(a.pip.last, 'video=false title=老B');
      expect(b.controller.machine.session.phase, CallPhase.incoming);
      // 被叫这边只是「把比例备好」：响铃时界面上根本没有那颗缩窗按钮
      expect(b.pip.last, 'video=false title=我');
    });

    test('视频通话的参数是 3:4；挂断时把已经打开的小窗收掉', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      FakeServer(<Peer>[a, b]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.video,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await b.controller.accept();
      await pump();

      expect(a.pip.last, 'video=true title=老B');
      expect(b.pip.last, 'video=true title=我');

      // 用户点了「缩成小窗」→ 原生说进了 → 挂断时应该收掉
      a.pip.emitMode(true);
      await a.controller.hangup();
      await pump();

      expect(a.pip.exits, 1);
      expect(a.pip.inPip, isFalse);
      expect(
        a.controller.diagnostics.value.events.map((event) => event.label),
        contains('通话结束，小窗已收起'),
      );
    });

    test('没在小窗里就不去打扰系统（不白调 exit）', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      FakeServer(<Peer>[a, b]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await a.controller.hangup();
      await pump();

      expect(a.pip.exits, 0);
    });

    test('reset（通话页关掉）也会把小窗收掉', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      FakeServer(<Peer>[a, b]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      a.pip.emitMode(true);
      await a.controller.reset();
      await pump();

      expect(a.pip.exits, 1);
      expect(a.pip.inPip, isFalse);
    });

    test('dispose（登出换账号）也会把小窗收掉', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      FakeServer(<Peer>[a, b]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      a.pip.emitMode(true);

      await a.controller.dispose();

      expect(a.pip.exits, 1);
      expect(a.pip.inPip, isFalse);
    });

    test('原生说「进了小窗」→ 界面状态 inPip 为真（出来就恢复）', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      FakeServer(<Peer>[a, b]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      expect(a.view.inPip, isFalse);

      a.pip.emitMode(true);
      await pump();
      expect(a.view.inPip, isTrue);

      a.pip.emitMode(false);
      await pump();
      expect(a.view.inPip, isFalse);

      // 进出小窗要留在诊断时间线里：真机上「怎么没缩窗」只能靠它定位
      final timeline = a.controller.diagnostics.value.events
          .map((event) => event.label)
          .join('\n');
      expect(timeline, contains('已缩成小窗'));
      expect(timeline, contains('已回到通话页'));
    });

    test('点「缩成小窗」：让系统立刻进小窗，并记一行诊断', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      FakeServer(<Peer>[a, b]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      await a.controller.minimizeToPip();

      expect(a.pip.enters, 1);
      expect(
        a.controller.diagnostics.value.events.map((event) => event.label),
        contains('手动缩成小窗'),
      );
    });

    test('系统不给进（ROM 关了画中画）只记一行诊断，通话照走', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      FakeServer(<Peer>[a, b]);
      a.pip.acceptEnter = false;

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      await a.controller.minimizeToPip();

      expect(a.pip.enters, 1);
      expect(
        a.controller.diagnostics.value.events.map((event) => event.label),
        contains('想缩成小窗，但系统没接受'),
      );
      expect(a.controller.machine.session.phase, CallPhase.outgoing);
    });

    test('这个 ROM 没有画中画 → 什么都不做，也不影响通话', () async {
      final a = Peer(userId: 'u1', name: '我', pipSupported: false);
      final b = Peer(userId: 'u2', name: '老B');
      FakeServer(<Peer>[a, b]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await pump();

      expect(a.pip.settings, isEmpty);
      expect(a.controller.machine.session.phase, CallPhase.outgoing);
      expect(a.media.calls.first, 'open(video=false)');
    });

    test('系统没设上（拒了）只记一行诊断，通话照走', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      FakeServer(<Peer>[a, b]);
      a.pip.available = false;

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await pump();

      expect(a.controller.machine.session.phase, CallPhase.outgoing);
      expect(
        a.controller.diagnostics.value.events.map((event) => event.label),
        contains('画中画参数没设上（这个系统/机型可能关掉了小窗）'),
      );
    });
  });

  // 共享屏幕（S6.7）—— 视频通话底部左边那颗。微信在那个位置是「模糊背景」，
  // 那要逐帧处理本机画面，我们这套插件不给口子（结论见规划书 S6.7），
  // 所以换成同一位置上一件真能做到的事。这里钉三件事：
  // ① 三步的**硬顺序**（投屏授权 → 前台服务类型 → 取屏幕流）；
  // ② 每一步失败都只提示、不影响这一通电话；
  // ③ 通话一结束状态就收干净。
  group('共享屏幕（S6.7）', () {
    /// 打一通视频电话并接通（那颗钮只在视频通话里）
    Future<void> talk(Peer a, Peer b) async {
      FakeServer(<Peer>[a, b]);
      await a.controller.start(
        peerId: b.userId,
        peerName: b.name,
        type: CallType.video,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await b.controller.accept();
      await pump();
    }

    test('硬顺序：先要投屏授权 → 再升前台服务类型 → 最后才取屏幕流', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      await talk(a, b);

      // 两个替身往同一条轨迹里写字：跨层的顺序也钉得住
      final trace = <String>[];
      a.media.trace = trace;
      a.keepAlive.trace = trace;

      expect(a.view.canShareScreen, isTrue, reason: '视频通话 + 安卓 → 界面该画那颗钮');

      await a.controller.toggleScreenShare();
      await pump();

      expect(trace, <String>[
        'media.requestScreenSharePermission()',
        'service.sharing=true',
        'media.startScreenShare()',
      ], reason: 'Android 14 要求取投影之前已经有 mediaProjection 类型的前台服务在跑');
      expect(a.keepAlive.sharing, isTrue);
      expect(a.view.screenSharing, isTrue);
      expect(a.media.screenSharing, isTrue);
      expect(
        a.controller.diagnostics.value.events.map((event) => event.label),
        contains('已开始共享屏幕'),
      );
    });

    test('用户在系统框里点了拒绝：不升类型、不取流，只提示一句', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      await talk(a, b);

      final trace = <String>[];
      a.media.trace = trace;
      a.keepAlive.trace = trace;
      a.media.screenShareGranted = false;

      await a.controller.toggleScreenShare();
      await pump();

      expect(trace, <String>['media.requestScreenSharePermission()']);
      expect(a.view.screenSharing, isFalse);
      expect(a.keepAlive.sharingChanges, isEmpty);
      expect(a.tips, contains('call.shareRefused'));
      expect(
        a.controller.diagnostics.value.events.map((event) => event.label),
        contains('用户拒绝了共享屏幕'),
      );
    });

    test('前台服务类型升不上去（系统拒绝）：不去取流，提示一句失败', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      await talk(a, b);

      a.keepAlive.sharingError = '不允许从后台启动 mediaProjection 类型的服务';

      await a.controller.toggleScreenShare();
      await pump();

      expect(a.media.calls, isNot(contains('startScreenShare(')));
      expect(a.view.screenSharing, isFalse);
      expect(a.tips, contains('call.shareFailed'));
      expect(
        a.controller.diagnostics.value.events.map((event) => event.label),
        contains('共享屏幕失败（前台服务类型没升上去）'),
      );
    });

    test('取屏幕流失败：把服务类型位回滚掉，通话照旧', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      await talk(a, b);

      a.media.screenShareError = '用户撤销了投屏';

      await a.controller.toggleScreenShare();
      await pump();

      expect(a.keepAlive.sharingChanges, <bool>[
        true,
        false,
      ], reason: '升了就要降回去');
      expect(a.keepAlive.sharing, isFalse);
      expect(a.view.screenSharing, isFalse);
      expect(a.tips, contains('call.shareFailed'));
      expect(
        a.controller.diagnostics.value.events.map((event) => event.label),
        anyElement(startsWith('共享屏幕失败：')),
      );
      // 通话照旧（共享失败不该把这一通弄断）
      expect(a.controller.machine.session.isActive, isTrue);
      expect(a.controller.machine.session.phase, CallPhase.connecting);
    });

    test('桌面：面板里选中哪一块屏幕，原样交给媒体层（sourceId 一路透传）', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      await talk(a, b);

      // 桌面上「共享屏幕」先弹选择面板（整个屏幕 / 某个窗口），选中的源就是它
      await a.controller.toggleScreenShare(sourceId: 'screen:0:0');
      await pump();

      expect(a.media.calls, contains('startScreenShare(screen:0:0,audio=off)'));
      expect(a.media.lastScreenShareSourceId, 'screen:0:0');
      expect(a.view.screenSharing, isTrue);
    });

    test('桌面：勾了「同时共享电脑的声音」，withAudio 一路透传到媒体层', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      await talk(a, b);

      await a.controller.toggleScreenShare(
        sourceId: 'screen:0:0',
        withAudio: true,
      );
      await pump();

      expect(a.media.calls, contains('startScreenShare(screen:0:0,audio=on)'));
      expect(a.media.lastScreenShareWithAudio, isTrue);
      expect(a.view.screenSharing, isTrue);
      // 顺顺当当发出去了（独立音频轨），就不用吓唬用户
      expect(a.tips, isEmpty);
      expect(
        a.controller.diagnostics.value.events.map((event) => event.label),
        contains('已开始共享屏幕（电脑声音：separate）'),
      );
    });

    test('电脑声音发不出去、退成「换成麦克风」：提一嘴对方听到的是电脑的声音', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      await talk(a, b);

      a.media.screenShareAudioRoute = ScreenShareAudioRoute.microphone;

      await a.controller.toggleScreenShare(withAudio: true);
      await pump();

      expect(a.view.screenSharing, isTrue, reason: '声音这条退化了，画面照共享');
      expect(a.tips, contains('call.shareAudioFallback'));
      expect(
        a.controller.diagnostics.value.events.map((event) => event.label),
        contains('已开始共享屏幕（电脑声音：microphone）'),
      );
    });

    test('这台机器上环路采集起不来：提醒这次只有画面、没有声音', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      await talk(a, b);

      a.media.screenShareAudioRoute = ScreenShareAudioRoute.unavailable;

      await a.controller.toggleScreenShare(withAudio: true);
      await pump();

      expect(a.view.screenSharing, isTrue);
      expect(a.tips, <String>['call.shareAudioNone']);
    });

    test('没勾声音时不管媒体层回报什么，都不弹那两句提示', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      await talk(a, b);

      a.media.screenShareAudioRoute = ScreenShareAudioRoute.microphone;

      await a.controller.toggleScreenShare(withAudio: false);
      await pump();

      expect(a.view.screenSharing, isTrue);
      expect(a.tips, isEmpty);
    });

    test('再点一次就是停止共享：换回摄像头 + 类型位降回去', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      await talk(a, b);

      await a.controller.toggleScreenShare();
      await pump();
      expect(a.view.screenSharing, isTrue);

      await a.controller.toggleScreenShare();
      await pump();

      expect(a.media.calls, contains('stopScreenShare()'));
      expect(a.keepAlive.sharingChanges, <bool>[true, false]);
      expect(a.view.screenSharing, isFalse);
      expect(a.media.screenSharing, isFalse);
      expect(
        a.controller.diagnostics.value.events.map((event) => event.label),
        contains('已停止共享屏幕'),
      );
    });

    test('语音通话里调它是空操作（那颗钮只在视频通话里）', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      FakeServer(<Peer>[a, b]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await b.controller.accept();
      await pump();

      expect(a.view.canShareScreen, isFalse, reason: '语音通话没有视频轨，共享不了');
      await a.controller.toggleScreenShare();
      await pump();

      expect(a.media.calls, isNot(contains('requestScreenSharePermission()')));
    });

    test('平台不支持（iOS）时什么都不做，界面也不画那颗钮', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      a.media.screenShareSupported = false;
      await talk(a, b);

      expect(a.view.canShareScreen, isFalse);

      await a.controller.toggleScreenShare();
      await pump();

      expect(a.media.calls, isNot(contains('requestScreenSharePermission()')));
      expect(a.tips, isEmpty);
    });

    test('通话结束（自己挂断）→ 共享状态收干净', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      await talk(a, b);

      await a.controller.toggleScreenShare();
      await pump();
      expect(a.view.screenSharing, isTrue);

      await a.controller.hangup();
      await pump();

      expect(a.view.screenSharing, isFalse);
      expect(a.view.canShareScreen, isFalse);
      // 屏幕流要先放掉（Android 14：投影得在带 mediaProjection 的服务停之前结束）
      expect(a.media.calls, contains('stopScreenShare()'));
      expect(a.media.screenSharing, isFalse);
    });

    test('通话页关掉（reset）→ 共享状态与那颗钮都收起来', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      await talk(a, b);

      await a.controller.toggleScreenShare();
      await pump();

      await a.controller.reset();
      await pump();

      expect(a.view.screenSharing, isFalse);
      expect(a.view.canShareScreen, isFalse);
      // 关页时媒体层整个收掉（屏幕流也在里面），不然那块屏会一直被投着
      expect(a.media.closed, isTrue);
      expect(a.media.screenSharing, isFalse);
    });
  });
}

/// 等一轮微任务（控制器里有很多 `unawaited` 的异步链路）
Future<void> pump() => Future<void>.delayed(Duration.zero);

/// 锁屏来电界面（S8.1n，2026-09-20 真机故障的收尾）。
///
/// 离线叫醒的来电靠全屏通知拉起 Activity，而**能不能盖住锁屏是 Activity 自己的事**
/// —— 不声明的话系统会退回成一条横幅，用户看到的还是锁屏。
/// 这里只钉两件事：什么时候开、什么时候关（以及幂等）。
void _callWindowGroup() {
  group('锁屏来电界面（S8.1n）', () {
    test('通话一开始就开、结束时关；中途的状态变化不重复打通道', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      FakeServer(<Peer>[a, b]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await pump();

      expect(a.window.enabled, isTrue, reason: '通话中要能盖在锁屏之上');
      expect(b.window.enabled, isTrue, reason: '被叫（来电路上）同样要');

      // 通话里状态变很多次（界面状态、大小窗…），不能每次都去动窗口
      final opened = a.window.setCalls;
      a.controller.toggleLayout();
      await pump();
      expect(a.window.setCalls, opened, reason: '幂等：状态没变就不打通道');
      expect(a.window.enabled, isTrue);

      await a.controller.hangup();
      await pump();
      expect(a.window.enabled, isFalse, reason: '挂了就该把锁屏还给系统');
      expect(b.window.enabled, isFalse);
    });

    test('控制器被放掉（登出/换账号）也要关掉，否则下一通通知也会盖住锁屏', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      FakeServer(<Peer>[a, b]);

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await pump();
      expect(a.window.enabled, isTrue);

      await a.controller.dispose();
      await pump();
      expect(a.window.enabled, isFalse);
    });

    test('通道抛异常也不能影响通话（锁屏显示只是体验）', () async {
      final a = Peer(userId: 'u1', name: '我');
      final b = Peer(userId: 'u2', name: '老B');
      final server = FakeServer(<Peer>[a, b]);
      a.window.throwOnSet = StateError('系统不给开');

      await a.controller.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      await pump();

      expect(a.view.session.phase, CallPhase.outgoing, reason: '通话照常拨出去');
      expect(server.wire.single['event'], CallEvent.calling);
    });
  });
}

/// 一个「设备」：控制器 + 假媒体层 + 手推计时器。
///
/// 三个对端（`FakeServer` 里那条总线）在构造完之后才接上 `send`，
/// 所以这里留一个可变的 [send] 口子，避免「设备要服务端、服务端要设备」的循环。
class Peer {
  Peer({required this.userId, required this.name, bool pipSupported = true})
    : pip = FakeCallPip(supported: pipSupported) {
    controller = CallController(
      machine: CallMachine(myUserId: userId),
      media: media,
      tones: tones,
      send: (request) {
        sent.add(request);
        final bus = send;
        if (bus == null) {
          throw StateError('这个设备还没接上假服务端');
        }
        return bus(request);
      },
      notify: tips.add,
      notifyPermission: permissionTips.add,
      keepAlive: keepAlive,
      pip: pip,
      callWindow: window,
      ticker: ticker,
    );
  }

  final String userId;
  final String name;
  final FakeCallMediaEngine media = FakeCallMediaEngine();
  final SilentCallTones tones = SilentCallTones();
  final ManualTicker ticker = ManualTicker();

  /// 锁屏来电界面那个窗口开关（S8.1n）
  final FakeCallWindow window = FakeCallWindow();

  /// 前台服务（S6.5）：每条结束路径都要停干净，这里是断言的地方
  final FakeCallKeepAlive keepAlive = FakeCallKeepAlive();

  /// 小窗（画中画，S6.6）：参数有没有交、结束有没有把小窗收掉，在这里断言
  final FakeCallPip pip;

  /// 本设备发出去的全部报文（顺序）
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  /// 收到的提示（i18n key）
  final List<String> tips = <String>[];

  /// 「带按钮」的那条提示（权限被拒时走它，按钮是「去授权」）
  final List<String> permissionTips = <String>[];

  /// 假服务端的出口，由 [FakeServer] 装上
  Future<Map<String, dynamic>> Function(Map<String, dynamic> request)? send;

  late final CallController controller;

  CallViewState get view => controller.view.value;
}

/// 手动推进的计时器（测试里不跑真 `Timer`）
class ManualTicker implements CallTicker {
  void Function()? _onTick;
  bool running = false;

  @override
  void start(void Function() onTick) {
    _onTick = onTick;
    running = true;
  }

  @override
  void stop() {
    _onTick = null;
    running = false;
  }

  /// 走一秒
  void tick() => _onTick?.call();
}

/// 一条内存里的「服务端」。
///
/// 与真实服务端的两个形态一致（S6.1 里逐行核实过）：
/// * 请求体那些字段（event/code/status/type/sdp/iceCandidate…）被塞进 `extends` 推给对端；
/// * 外层 `id` 原样带回、`msg_id` 由服务端生成、发送方是谁由 `fromUser` 表示。
class FakeServer {
  FakeServer(List<Peer> peers, {this.echoToSender = false}) {
    for (final peer in peers) {
      _peers[peer.userId] = peer;
      peer.send = (request) => _deliver(peer.userId, request);
    }
  }

  /// 服务端会不会把发送方自己那条也推回去（老端靠 `isMobile` 区分，S6.0 待确认）
  final bool echoToSender;

  final Map<String, Peer> _peers = <String, Peer>{};

  /// 走过的报文（按顺序）
  final List<Map<String, dynamic>> wire = <Map<String, dynamic>>[];

  /// 模拟「对方不在线」：服务端在回执里用 `extends.code = 907` 告诉我们
  bool offline = false;

  int _seq = 0;

  Future<Map<String, dynamic>> _deliver(
    String fromId,
    Map<String, dynamic> request,
  ) async {
    wire.add(request);
    final serverId = 'srv-${++_seq}';
    final sender = _peers[fromId]!;
    // 真服务端只推给 `toContactId` 那个人（外加发送方自己的其它设备）。
    // 这一条不能省：不加就会把「忙线」那条又推回给发送方的对端，
    // 两端你回我我回你，无限循环（第一版假服务端就这么挂上了）。
    final target = asText(request['toContactId']);

    for (final peer in _peers.values) {
      final isSender = peer.userId == fromId;
      final isTarget = peer.userId == target;
      if (!isTarget && !(isSender && echoToSender)) continue;
      await peer.controller.remote(
        signal(
          event: asText(request['event']),
          from: fromId,
          fromName: sender.name,
          messageId: asText(request['id']),
          serverId: serverId,
          code: asInt(request['code'], 0),
          status: asInt(request['status'], 0),
          type: asInt(request['type'], CallType.voice),
          sdp: asText(request['sdp']),
          iceCandidate: decodeIceCandidate(request['iceCandidate']),
        ),
      );
    }

    return <String, dynamic>{
      'msg_id': serverId,
      'extends': <String, dynamic>{
        ...request,
        if (offline) 'code': CallCode.busy,
      },
    };
  }

  /// 造一条远程信令（测试里直接调 `controller.remote` 时用）
  CallSignal signal({
    required String event,
    required String from,
    String fromName = '某人',
    String messageId = 'call-1',
    String serverId = 'srv-x',
    int code = 0,
    int status = 0,
    int type = CallType.voice,
    String sdp = '',
    Map<String, dynamic> iceCandidate = const <String, dynamic>{},
  }) => CallSignal(
    event: event,
    code: code,
    status: status,
    type: type,
    sdp: sdp,
    iceCandidate: iceCandidate,
    messageId: messageId,
    serverId: serverId,
    fromUserId: from,
    fromUserName: fromName,
  );
}
