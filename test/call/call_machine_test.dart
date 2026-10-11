import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/domain/call/call_machine.dart';
import 'package:gracelinkim/domain/call/call_signal.dart';

/// 通话状态机（S6.1）。
///
/// 每一条断言都对着老端三处代码抄：`App.vue` 的 `webrtc` 分支、
/// `pages/message/call.vue::msgCallback`、`hybrid/html/index.html`。
/// 用固定种子的 [Random] 让 uuid 可预测，好断言请求体。
void main() {
  CallMachine machine({String myUserId = 'u1', int seed = 7}) {
    final m = CallMachine(myUserId: myUserId, random: Random(seed));
    _active = m;
    return m;
  }

  /// 发出去的信令里的某个 `event`（找不到就 null）
  Map<String, dynamic>? signalOf(CallOutcome outcome, String event) {
    for (final request in outcome.signals) {
      if (request['event'] == event) return request;
    }
    return null;
  }

  bool hasEffect<T extends CallEffect>(CallOutcome outcome) =>
      outcome.effects.any((effect) => effect is T);

  /// 一个已经「拨号中」的主叫
  CallMachine dialing({int type = CallType.voice}) {
    final m = machine();
    m.start(
      peerId: 'u2',
      peerName: '老B',
      peerAvatar: 'https://a.test/b.png',
      type: type,
      webrtcEnabled: true,
      simpleChatEnabled: true,
    );
    m.mediaReady();
    return m;
  }

  /// 一条来自 [from] 的远程信令。
  ///
  /// `id` 默认就是**当前那通电话的 id**：这是协议里的一条事实 —— 对端发回来的每一条
  /// 信令都带主叫当初造的那个 id（老端 `call.vue` 发出去写的是 `id: this.main_id`，
  /// 而 `main_id` 就是主叫那条消息的 `id`），而 `id` 不一样在老端等价于「在忙线中」。
  CallSignal remoteSignal({
    required String event,
    String from = 'u2',
    String? messageId,
    String serverId = 'srv-remote',
    int code = 0,
    int status = 0,
    int type = CallType.voice,
    String sdp = '',
    Map<String, dynamic> iceCandidate = const <String, dynamic>{},
    bool isMobile = false,
  }) => CallSignal(
    event: event,
    code: code,
    status: status,
    type: type,
    sdp: sdp,
    iceCandidate: iceCandidate,
    byButton: false,
    isMobile: isMobile,
    messageId: messageId ?? _active?.session.messageId ?? 'uuid-remote',
    serverId: serverId,
    fromUserId: from,
    fromUserName: '老B',
    fromUserAvatar: 'https://a.test/b.png',
  );

  /// 一个已经收到 calling、正在振铃的被叫（`uuid-caller` 是主叫自己那个 id，
  /// 被叫之后每一条信令都要把它原样带回去）
  CallMachine ringing() {
    final m = machine();
    m.remote(
      remoteSignal(
        event: CallEvent.calling,
        status: CallStatus.ringing,
        messageId: 'uuid-caller',
      ),
    );
    return m;
  }

  group('发起通话（主叫）', () {
    test('三道检查的顺序与文案照老端 im-input.vue::calling', () {
      final m = machine();

      final noWebrtc = m.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: false,
        simpleChatEnabled: true,
      );
      expect(noWebrtc.toasts, <String>['chat.closeWebrtc']);
      expect(noWebrtc.session.isActive, isFalse);

      final noChat = m.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: false,
      );
      expect(noChat.toasts, <String>['chat.notTalk']);
      expect(noChat.session.isActive, isFalse);
    });

    test('服务端没开音视频时连私聊那关都不判（顺序不能反）', () {
      final m = machine();
      final outcome = m.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: false,
        simpleChatEnabled: false,
      );

      expect(outcome.toasts, <String>['chat.closeWebrtc']);
    });

    test('建成会话：拨号中、主叫、自己生成的 uuid、去取本机媒体', () {
      final m = machine();
      final outcome = m.start(
        peerId: 'u2',
        peerName: '老B',
        peerAvatar: 'https://a.test/b.png',
        type: CallType.video,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      expect(outcome.session.phase, CallPhase.outgoing);
      expect(outcome.session.isCaller, isTrue);
      expect(outcome.session.peerId, 'u2');
      expect(outcome.session.peerName, '老B');
      expect(outcome.session.peerAvatar, 'https://a.test/b.png');
      expect(outcome.session.type, CallType.video);
      expect(outcome.session.isVideo, isTrue);
      expect(outcome.session.wireStatus, CallStatus.dialing);
      expect(outcome.session.isRinging, isTrue);
      // 老端：msg_id = $util.getUuid()，主叫侧自己造
      expect(
        outcome.session.messageId,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(outcome.effects, hasLength(1));
      expect(hasEffect<RequestLocalMedia>(outcome), isTrue);
      expect(
        (outcome.effects.single as RequestLocalMedia).type,
        CallType.video,
      );
    });

    test('已经在通话里 → otherCalling，且不动当前那通', () {
      final m = dialing();
      final before = m.session.messageId;

      final outcome = m.start(
        peerId: 'u3',
        peerName: '老C',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      expect(outcome.toasts, <String>['message.otherCalling']);
      expect(outcome.signals, isEmpty);
      expect(m.session.messageId, before);
      expect(m.session.peerId, 'u2');
    });

    test('老端那把多端锁锁着时也不让打', () {
      final m = machine();
      m.remote(remoteSignal(event: CallEvent.calling));

      final outcome = m.start(
        peerId: 'u3',
        peerName: '老C',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      expect(outcome.toasts, <String>['message.otherCalling']);
    });

    test('媒体就绪 → 发 calling（status 3 / code 901）+ 放铃', () {
      final m = machine();
      m.start(
        peerId: 'u2',
        peerName: '老B',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      final messageId = m.session.messageId;

      final outcome = m.mediaReady();
      final calling = signalOf(outcome, CallEvent.calling)!;

      expect(calling['toContactId'], 'u2');
      expect(calling['id'], messageId);
      expect(calling['msg_id'], '');
      expect(calling['type'], CallType.voice);
      expect(calling['status'], CallStatus.ringing);
      expect(calling['code'], CallCode.dialing);
      expect(hasEffect<PlayRingtone>(outcome), isTrue);
    });

    test('媒体就绪之后再调一次不会重复发 calling（老端 WebView 可能回调两次）', () {
      final m = dialing();
      expect(m.mediaReady().signals, isEmpty);
    });
  });

  group('主叫接通链路', () {
    test('收到 acceptRtc → 接通中 + 停铃 + 起表 + 造 offer', () {
      final m = dialing();
      final messageId = m.session.messageId;

      final outcome = m.remote(
        remoteSignal(event: CallEvent.acceptRtc, code: CallCode.accept),
      );

      expect(outcome.session.phase, CallPhase.connecting);
      expect(outcome.session.wireStatus, CallStatus.talking);
      expect(outcome.session.isRinging, isFalse);
      expect(outcome.session.serverId, 'srv-remote');
      expect(outcome.signals, isEmpty, reason: 'offer 要等媒体层造好才发');
      expect(hasEffect<StopRingtone>(outcome), isTrue);
      expect(hasEffect<StartCallTimer>(outcome), isTrue);
      expect(hasEffect<CreateOffer>(outcome), isTrue);
      // 这通电话的 id 还是自己那个 uuid（服务端推回来的 extends.id 不该改它）
      expect(outcome.session.messageId, messageId);
    });

    test('造好 offer → 发出去（带 sdp、不带 code）', () {
      final m = dialing();
      m.remote(remoteSignal(event: CallEvent.acceptRtc, code: CallCode.accept));

      final offer = signalOf(m.localOffer('v=0\r\nsdp'), CallEvent.offer)!;

      expect(offer['sdp'], 'v=0\r\nsdp');
      expect(offer['code'], '');
      expect(offer['status'], '');
      expect(offer['event'], 'offer');
      expect(offer['toContactId'], 'u2');
    });

    test('拨号中造不出 offer（offer 必须等到对方接听）', () {
      final m = dialing();

      expect(m.localOffer('sdp').signals, isEmpty);
    });

    test('收到 answer → 设远端描述', () {
      final m = dialing();
      m.remote(remoteSignal(event: CallEvent.acceptRtc, code: CallCode.accept));

      final outcome = m.remote(
        remoteSignal(event: CallEvent.answer, sdp: 'remote-answer'),
      );

      expect(outcome.effects, hasLength(1));
      expect(
        (outcome.effects.single as ApplyRemoteAnswer).sdp,
        'remote-answer',
      );
    });

    test('媒体层报告连上 → 通话中（对外 status 还是 2）', () {
      final m = dialing();
      m.remote(remoteSignal(event: CallEvent.acceptRtc, code: CallCode.accept));

      final outcome = m.mediaConnected();

      expect(outcome.session.phase, CallPhase.connected);
      expect(outcome.session.wireStatus, CallStatus.talking);
      expect(outcome.effects, isEmpty);
      expect(outcome.session.isActive, isTrue);
      expect(outcome.session.isRinging, isFalse);
    });

    test('媒体层连上之前就调 mediaConnected 不算（阶段不对就忽略）', () {
      final m = dialing();
      expect(m.mediaConnected().session.phase, CallPhase.outgoing);
    });
  });

  group('被叫接通链路', () {
    test('收到 calling → 来电中 + 响铃 + 锁上这个联系人', () {
      final m = machine();

      final outcome = m.remote(
        remoteSignal(
          event: CallEvent.calling,
          messageId: 'uuid-caller',
          status: CallStatus.ringing,
        ),
      );

      expect(outcome.session.phase, CallPhase.incoming);
      expect(outcome.session.isCaller, isFalse);
      expect(outcome.session.peerId, 'u2');
      expect(outcome.session.peerName, '老B');
      expect(outcome.session.peerAvatar, 'https://a.test/b.png');
      expect(outcome.session.wireStatus, CallStatus.ringing);
      expect(outcome.session.isRinging, isTrue);
      // 老端：主叫的 id 就是被叫这边的 main_id
      expect(outcome.session.messageId, 'uuid-caller');
      expect(outcome.session.serverId, 'srv-remote');
      expect(outcome.signals, isEmpty);
      expect(hasEffect<PlayRingtone>(outcome), isTrue);
      expect(m.lock.isLocked, isTrue);
      expect(m.lock.peerId, 'u2');
    });

    test('点接听 → 接通中 + 停铃 + 起表 + 取本机媒体（还不发信令）', () {
      final m = ringing();

      final outcome = m.accept();

      expect(outcome.session.phase, CallPhase.connecting);
      expect(outcome.signals, isEmpty);
      expect(hasEffect<StopRingtone>(outcome), isTrue);
      expect(hasEffect<StartCallTimer>(outcome), isTrue);
      expect(hasEffect<RequestLocalMedia>(outcome), isTrue);
    });

    test('没来电的时候点接听是空操作', () {
      final m = machine();
      expect(m.accept().effects, isEmpty);
      expect(m.accept().session.phase, CallPhase.idle);
    });

    test('媒体就绪 → 发 acceptRtc（code 904）+ 停铃', () {
      final m = ringing();
      m.accept();

      final outcome = m.mediaReady();
      expect(m.mediaReady().signals, isEmpty, reason: '重复回调不能重复发');
      final accept = signalOf(outcome, CallEvent.acceptRtc)!;

      expect(accept['code'], CallCode.accept);
      expect(accept['toContactId'], 'u2');
      expect(accept['id'], 'uuid-caller');
      expect(accept['msg_id'], 'srv-remote');
      expect(accept['status'], '');
      expect(hasEffect<StopRingtone>(outcome), isTrue);
    });

    test('自己那条 offer 被服务端推回来时不会当成远端的 offer', () {
      final m = dialing();
      m.remote(remoteSignal(event: CallEvent.acceptRtc, code: CallCode.accept));

      final outcome = m.remote(
        remoteSignal(event: CallEvent.offer, from: 'u1', sdp: 'my-own-offer'),
      );

      expect(outcome.effects, isEmpty);
      expect(m.session.phase, CallPhase.connecting);
    });

    test('收到 offer → 设远端 + 造 answer', () {
      final m = ringing();
      m.accept();
      m.mediaReady();

      final outcome = m.remote(
        remoteSignal(event: CallEvent.offer, sdp: 'caller-offer'),
      );

      expect((outcome.effects.single as AcceptRemoteOffer).sdp, 'caller-offer');
      expect(outcome.session.serverId, 'srv-remote');
    });

    test('造好 answer → 发出去', () {
      final m = ringing();
      m.accept();
      m.mediaReady();
      m.remote(remoteSignal(event: CallEvent.offer, sdp: 'caller-offer'));

      final answer = signalOf(m.localAnswer('my-answer'), CallEvent.answer)!;

      expect(answer['sdp'], 'my-answer');
      expect(answer['event'], 'answer');
    });

    test('接听前收到 offer 先挂起，接听并取到媒体后再响应（老端的 SDP 早到）', () {
      final m = ringing();

      // 媒体还没建（连接听都还没点）：当场响应只会在媒体层撞上「连接还没建」
      final early = m.remote(
        remoteSignal(event: CallEvent.offer, sdp: 'caller-offer'),
      );
      expect(early.effects, isEmpty);

      // 接听只去取流：acceptRtc 要等媒体就绪才发（老端也是 `getUserMedia` 成功回调里发）
      final accepted = m.accept();
      expect(signalOf(accepted, CallEvent.acceptRtc), isNull);
      expect(hasEffect<AcceptRemoteOffer>(accepted), isFalse);

      // 本机媒体就绪：先发 acceptRtc，再把那条早到的 offer 应答掉
      final ready = m.mediaReady();
      expect(signalOf(ready, CallEvent.acceptRtc), isNotNull);
      final offers = ready.effects.whereType<AcceptRemoteOffer>().toList();
      expect(offers.single.sdp, 'caller-offer');
    });

    test('取媒体途中收到 offer → 挂起，媒体就绪后自动应答（视频通话的常态）', () {
      final m = ringing();
      m.accept(); // 已经进入「接通中」，但流还没取到

      final outcome = m.remote(
        remoteSignal(event: CallEvent.offer, sdp: 'early-offer'),
      );
      expect(outcome.effects, isEmpty, reason: '媒体没就绪，不能当场响应');

      final ready = m.mediaReady();
      expect(
        ready.effects.whereType<AcceptRemoteOffer>().single.sdp,
        'early-offer',
      );
    });

    test('挂起的 offer 只响应一次（媒体就绪后再来一条新的才顶掉）', () {
      final m = ringing();
      m.accept();

      // 对端连发两条（服务端重推是真实存在的形态）：后到的那条生效
      m.remote(remoteSignal(event: CallEvent.offer, sdp: 'first'));
      m.remote(remoteSignal(event: CallEvent.offer, sdp: 'second'));

      final ready = m.mediaReady();
      final offers = ready.effects.whereType<AcceptRemoteOffer>().toList();
      expect(offers, hasLength(1));
      expect(offers.single.sdp, 'second');
    });

    test('本端没有通话时收到 offer → 忽略（过期信令，不能弹「请检查音视频」）', () {
      final m = machine();

      final outcome = m.remote(
        remoteSignal(event: CallEvent.offer, sdp: 'stale-offer'),
      );

      expect(outcome.effects, isEmpty);
      expect(outcome.signals, isEmpty);
      expect(m.session.phase, CallPhase.idle);
    });

    test('挂断之后又收到 offer → 忽略（真机日志里那两条「响应 offer失败」）', () {
      final m = ringing();
      m.accept();
      m.mediaReady();
      m.hangup();

      final outcome = m.remote(
        remoteSignal(event: CallEvent.offer, sdp: 'late-offer'),
      );

      expect(outcome.effects, isEmpty);
      expect(m.session.phase, CallPhase.ended);
    });

    test('挂起中的 offer 在挂断后丢弃，不会落到下一通电话上', () {
      final m = ringing();
      m.remote(remoteSignal(event: CallEvent.offer, sdp: 'stale-offer'));
      m.hangup(); // 拒接

      // 又来一通：接听并取到媒体，不该拿着上一通那条 SDP 去协商
      m.remote(
        remoteSignal(event: CallEvent.calling, from: 'u3', messageId: 'uuid-c'),
      );
      m.accept();
      final ready = m.mediaReady();

      expect(ready.effects.whereType<AcceptRemoteOffer>(), isEmpty);
      expect(signalOf(ready, CallEvent.acceptRtc), isNotNull);
    });

    test('被叫收到 acceptRtc 一律忽略（自己的那条被推回来时不能回一个多余 offer）', () {
      final m = ringing();
      m.accept();
      m.mediaReady();

      final outcome = m.remote(
        remoteSignal(event: CallEvent.acceptRtc, code: CallCode.accept),
      );

      expect(outcome.effects, isEmpty);
      expect(outcome.signals, isEmpty);
    });

    test('主叫收到 offer 也忽略（同一个收紧的另一面）', () {
      final m = dialing();

      expect(m.remote(remoteSignal(event: CallEvent.offer)).effects, isEmpty);
    });
  });

  group('忙线', () {
    test('通话页开着时又来一条 calling → 回忙线 907，当前那通不受影响', () {
      final m = ringing();

      final outcome = m.remote(
        remoteSignal(event: CallEvent.calling, from: 'u3', messageId: 'uuid-c'),
        pageActive: true,
      );

      final busy = signalOf(outcome, CallEvent.busy)!;
      expect(busy['code'], CallCode.busy);
      expect(busy['toContactId'], 'u3');
      expect(busy['id'], 'uuid-c');
      expect(busy['type'], CallType.voice);
      expect(outcome.session.peerId, 'u2');
      expect(outcome.session.phase, CallPhase.incoming);
      expect(hasEffect<PlayRingtone>(outcome), isFalse);
    });

    test('本端机器在通话中（页面状态未知）也回忙线', () {
      final m = ringing();

      final outcome = m.remote(
        remoteSignal(event: CallEvent.calling, from: 'u3', messageId: 'uuid-c'),
      );

      expect(signalOf(outcome, CallEvent.busy)!['code'], CallCode.busy);
    });

    test('同一通话跑到一半又收到「另一次通话」的 offer（id 不同）→ 回忙线', () {
      final m = dialing();
      m.remote(remoteSignal(event: CallEvent.acceptRtc, code: CallCode.accept));

      final outcome = m.remote(
        remoteSignal(
          event: CallEvent.hangup,
          from: 'u3',
          messageId: 'uuid-other',
          code: CallCode.hangupInCall,
        ),
      );

      expect(signalOf(outcome, CallEvent.busy)!['toContactId'], 'u3');
      // 本通没被挂断
      expect(m.session.phase, CallPhase.connecting);
      expect(hasEffect<EndCall>(outcome), isFalse);
    });

    test('同一个人又来一通（id 不同）也回忙线', () {
      final m = dialing();

      final outcome = m.remote(
        remoteSignal(event: CallEvent.calling, messageId: 'uuid-again'),
      );

      expect(signalOf(outcome, CallEvent.busy)!['code'], CallCode.busy);
      expect(m.session.phase, CallPhase.outgoing);
    });

    test('对方回忙线 → 关页 + 「对方忙~~」', () {
      final m = dialing();

      final outcome = m.remote(
        remoteSignal(event: CallEvent.busy, code: CallCode.busy),
      );

      expect(outcome.session.phase, CallPhase.ended);
      expect(outcome.session.code, CallCode.busy);
      expect(outcome.session.wireStatus, CallStatus.none);
      expect(outcome.signals, isEmpty, reason: '被动结束不用再发一枪');
      expect(outcome.toasts, <String>['message.toBusy']);
      expect(hasEffect<EndCall>(outcome), isTrue);
      expect(hasEffect<StopRingtone>(outcome), isTrue);
      expect(hasEffect<StopCallTimer>(outcome), isTrue);
    });

    test('收到带 907 的挂断 → 关页 + 「对方忙~~」', () {
      final m = ringing();

      final outcome = m.remote(
        remoteSignal(event: CallEvent.hangup, code: CallCode.busy),
      );

      expect(outcome.session.phase, CallPhase.ended);
      expect(outcome.toasts, <String>['message.toBusy']);
    });

    test('服务端在回执里用 code 907 说「对方不在线」→ 提示 + 关页', () {
      final m = dialing();

      final outcome = m.signalAccepted(<String, dynamic>{
        'msg_id': 'srv-1',
        'extends': <String, dynamic>{'code': 907},
      });

      expect(outcome.session.phase, CallPhase.ended);
      expect(outcome.session.code, CallCode.busy);
      expect(outcome.toasts, <String>['message.notOnline']);
      expect(hasEffect<EndCall>(outcome), isTrue);
    });
  });

  group('挂断', () {
    test('拨号中挂断 → 902（取消）', () {
      final m = dialing();

      final outcome = m.hangup();
      final hangup = signalOf(outcome, CallEvent.hangup)!;

      expect(hangup['code'], CallCode.cancel);
      expect(outcome.session.code, CallCode.cancel);
      expect(outcome.session.phase, CallPhase.ended);
      expect(hasEffect<EndCall>(outcome), isTrue);
    });

    test('来电中拒接 → 903（拒接）', () {
      final m = ringing();
      final hangup = signalOf(m.hangup(), CallEvent.hangup)!;

      expect(hangup['code'], CallCode.reject);
    });

    test('通话中挂断 → 906，并且带上通话时长', () {
      final m = dialing();
      m.remote(remoteSignal(event: CallEvent.acceptRtc, code: CallCode.accept));
      for (var i = 0; i < 42; i++) {
        m.tick();
      }

      final hangup = signalOf(m.hangup(), CallEvent.hangup)!;

      expect(hangup['code'], CallCode.hangupInCall);
      expect(hangup['callTime'], 42);
      expect(m.session.callTime, 42);
    });

    test('没通话时挂断是空操作（老端按钮没防抖，这里挡住）', () {
      final m = machine();
      expect(m.hangup().effects, isEmpty);
    });

    test('挂断之后再挂一次不发第二枪（这是老端的一个真毛病）', () {
      final m = dialing();
      m.hangup();

      expect(m.hangup().effects, isEmpty);
      expect(m.hangup().signals, isEmpty);
    });

    test('收到对方挂断 → 关页、停铃停表，不发信令', () {
      final m = dialing();
      m.remote(remoteSignal(event: CallEvent.acceptRtc, code: CallCode.accept));

      final outcome = m.remote(
        remoteSignal(event: CallEvent.hangup, code: CallCode.hangupInCall),
      );

      expect(outcome.session.phase, CallPhase.ended);
      expect(outcome.session.code, CallCode.hangupInCall);
      expect(outcome.signals, isEmpty);
      expect(hasEffect<EndCall>(outcome), isTrue);
    });

    test('已经结束了再收到一条挂断是空操作（两台设备同时挂）', () {
      final m = dialing();
      m.hangup();

      expect(
        m
            .remote(
              remoteSignal(
                event: CallEvent.hangup,
                code: CallCode.hangupInCall,
              ),
            )
            .effects,
        isEmpty,
      );
    });

    test('拨号 60 秒超时 → 902（老端是 40 秒，为离线推送放宽，见 S8.1h）', () {
      final m = dialing();

      final hangup = signalOf(m.timeout(), CallEvent.hangup)!;

      expect(CallMachine.dialTimeoutSeconds, 60);
      expect(hangup['code'], CallCode.cancel);
      expect(m.session.phase, CallPhase.ended);
    });

    test('来电中 / 通话中调 timeout 是空操作', () {
      final incoming = ringing();
      expect(incoming.timeout().effects, isEmpty);
      expect(incoming.session.phase, CallPhase.incoming);

      final talking = dialing();
      talking.remote(
        remoteSignal(event: CallEvent.acceptRtc, code: CallCode.accept),
      );
      expect(talking.timeout().effects, isEmpty);
      expect(talking.session.phase, CallPhase.connecting);
    });
  });

  group('计时', () {
    test('只在接通之后累加', () {
      final m = dialing();
      expect(m.session.callTime, 0);
      m.tick();
      expect(m.session.callTime, 0, reason: '拨号中不计时');

      m.remote(remoteSignal(event: CallEvent.acceptRtc, code: CallCode.accept));
      m.tick();
      m.tick();
      expect(m.session.callTime, 2);

      m.mediaConnected();
      m.tick();
      expect(m.session.callTime, 3);
    });

    test('来电振铃时不计时', () {
      final m = ringing();
      m.tick();
      expect(m.session.callTime, 0);
    });
  });

  group('ICE 候选', () {
    test('通话中收一条就加一条（只认三个键）', () {
      final m = dialing();
      m.remote(remoteSignal(event: CallEvent.acceptRtc, code: CallCode.accept));

      final outcome = m.remote(
        remoteSignal(
          event: CallEvent.iceCandidate,
          iceCandidate: <String, dynamic>{
            'candidate': 'cand-1',
            'sdpMLineIndex': 0,
            'sdpMid': 'audio',
          },
        ),
      );

      final added = outcome.effects.single as AddIceCandidate;
      expect(added.candidate['candidate'], 'cand-1');
      expect(added.candidate['sdpMid'], 'audio');
    });

    test('本端的候选发出去时是一串 JSON、且带 msg_id', () {
      final m = dialing();
      m.remote(remoteSignal(event: CallEvent.acceptRtc, code: CallCode.accept));

      final request = signalOf(
        m.localIceCandidate(<String, dynamic>{
          'candidate': 'cand-9',
          'sdpMLineIndex': 1,
          'sdpMid': 'video',
        }),
        CallEvent.iceCandidate,
      )!;

      expect(request['msg_id'], 'srv-remote');
      expect(request['iceCandidate'], isA<String>());
      expect(request['iceCandidate'], contains('cand-9'));
    });

    test('空候选 / 还没接通时不发不处理', () {
      final m = dialing();
      expect(m.localIceCandidate(const <String, dynamic>{}).signals, isEmpty);
      expect(
        m
            .remote(
              remoteSignal(
                event: CallEvent.iceCandidate,
                iceCandidate: const <String, dynamic>{},
              ),
            )
            .effects,
        isEmpty,
      );
    });

    test('没通话时收到候选直接忽略（不该炸）', () {
      final m = machine();

      expect(
        m
            .remote(
              remoteSignal(
                event: CallEvent.iceCandidate,
                iceCandidate: <String, dynamic>{
                  'candidate': 'x',
                  'sdpMid': 'audio',
                },
              ),
            )
            .effects,
        isEmpty,
      );
    });
  });

  group('自己那条信令被服务端推回来', () {
    test('自己发的 calling 不当成来电（只进聊天列表，消息层管）', () {
      final m = dialing();

      final outcome = m.remote(
        remoteSignal(
          event: CallEvent.calling,
          from: 'u1',
          messageId: m.session.messageId,
          isMobile: true,
        ),
      );

      expect(outcome.signals, isEmpty);
      expect(outcome.toasts, isEmpty);
      expect(outcome.session.phase, CallPhase.outgoing);
      expect(hasEffect<PlayRingtone>(outcome), isFalse);
    });

    test('自己那条 902 回来 → 解开多端锁（老端就是这么解的）', () {
      final m = machine();
      m.remote(remoteSignal(event: CallEvent.calling));
      expect(m.lock.isLocked, isTrue);

      m.remote(
        remoteSignal(
          event: CallEvent.hangup,
          from: 'u1',
          messageId: 'uuid-self',
          code: CallCode.cancel,
          isMobile: true,
        ),
      );

      expect(m.lock.isLocked, isFalse);
    });

    test('本地挂断当场就解锁，不等服务端那条回执', () {
      final m = ringing();
      expect(m.lock.isLocked, isTrue);

      m.hangup();

      expect(m.lock.isLocked, isFalse);
    });

    test('媒体失败也解锁', () {
      final m = ringing();

      m.mediaFailed();

      expect(m.lock.isLocked, isFalse);
    });
  });

  group('多端（otherOpt）', () {
    test('同一账号的其它端处理了 → 本端静默关页，不发信令', () {
      final m = ringing();

      final outcome = m.remote(
        remoteSignal(event: CallEvent.otherOpt, code: CallCode.hangupInCall),
      );

      expect(outcome.session.phase, CallPhase.ended);
      expect(outcome.signals, isEmpty);
      expect(outcome.toasts, isEmpty);
      expect(hasEffect<EndCall>(outcome), isTrue);
      expect(hasEffect<PlayRingtone>(outcome), isFalse);
    });

    test('★ 自己那句 acceptRtc 的回声，不许把自己的通话关掉', () {
      // 真机 2026-09-20「一接通一秒就闪退」的根因：服务端 `Im.php::sendToMsg()`
      // 末尾会把 `acceptRtc` / `hangup` **回声**成 `otherOpt` 发给发送者账号的
      // **所有**连接 —— 包括刚发出这句话的我们自己。
      final m = ringing();
      m.accept();
      m.mediaReady(); // acceptRtc 发出去了 → 几百毫秒后它自己会变成一条 otherOpt 回来

      final outcome = m.remote(
        remoteSignal(event: CallEvent.otherOpt, code: CallCode.accept),
      );

      expect(
        outcome.session.phase,
        CallPhase.connecting,
        reason: '这条是自己那句的回声，不是「别的端处理了」',
      );
      expect(outcome.effects, isEmpty);
      expect(hasEffect<EndCall>(outcome), isFalse);
    });

    test('但还在响铃时收到同账号的接听回声 → 照样结束（那才是真的别的端接了）', () {
      final m = ringing();

      final outcome = m.remote(
        remoteSignal(event: CallEvent.otherOpt, code: CallCode.accept),
      );

      expect(outcome.session.phase, CallPhase.ended);
      expect(hasEffect<EndCall>(outcome), isTrue);
    });
  });

  group('媒体失败', () {
    test('拿不到媒体 → 提示 + 关页，**不发信令**（老端也不发）', () {
      final m = dialing();

      final outcome = m.mediaFailed();

      expect(outcome.session.phase, CallPhase.ended);
      expect(outcome.signals, isEmpty);
      expect(outcome.toasts, <String>['message.checkWebtc']);
      expect(hasEffect<EndCall>(outcome), isTrue);
      expect(hasEffect<StopRingtone>(outcome), isTrue);
      expect(hasEffect<StopCallTimer>(outcome), isTrue);
    });

    test('没通话时媒体失败什么也不做', () {
      final m = machine();
      expect(m.mediaFailed().effects, isEmpty);
    });
  });

  group('收尾与其它', () {
    test('对方下线 → 解锁（老端 App.vue 的 isOnline 分支）', () {
      final m = ringing();

      m.peerOffline('u3');
      expect(m.lock.isLocked, isTrue);

      m.peerOffline('u2');
      expect(m.lock.isLocked, isFalse);
    });

    test('回执里记下服务端业务 id（之后发出去都带上）', () {
      final m = dialing();

      m.signalAccepted(<String, dynamic>{'msg_id': 'srv-1'});

      expect(m.session.serverId, 'srv-1');
      expect(signalOf(m.hangup(), CallEvent.hangup)!['msg_id'], 'srv-1');
    });

    test('回执照旧端优先读 msg_id，没有才读 id', () {
      final m = dialing();
      expect(
        m.signalAccepted(<String, dynamic>{'id': 'srv-2'}).session.serverId,
        'srv-2',
      );
    });

    test('回执是脏数据（null / 字符串 / 没有 id）不炸也不改状态', () {
      final m = dialing();
      m.signalAccepted(null);
      m.signalAccepted('炸了');
      m.signalAccepted(<String, dynamic>{'msg_id': ''});

      expect(m.session.serverId, '');
      expect(m.session.phase, CallPhase.outgoing);
    });

    test('reset 清回空闲（通话页关掉之后调）', () {
      final m = dialing();

      final outcome = m.reset();

      expect(outcome.session.phase, CallPhase.idle);
      expect(outcome.session.isActive, isFalse);
      expect(outcome.session.peerId, '');
      expect(m.session.messageId, '');
    });

    test('reset 之后还能再打一通（上一通真的结束了）', () {
      final m = dialing();
      m.hangup();
      m.reset();

      final outcome = m.start(
        peerId: 'u3',
        peerName: '老C',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      expect(outcome.session.phase, CallPhase.outgoing);
      expect(outcome.session.peerId, 'u3');
      expect(outcome.toasts, isEmpty);
    });

    test('收到结束信令后没 reset 也能再接一通新来电（老端的路由切回来了）', () {
      final m = dialing();
      m.remote(
        remoteSignal(event: CallEvent.hangup, code: CallCode.hangupInCall),
      );

      final outcome = m.remote(
        remoteSignal(event: CallEvent.calling, from: 'u3', messageId: 'uuid-3'),
      );

      expect(outcome.session.phase, CallPhase.incoming);
      expect(outcome.session.peerId, 'u3');
    });

    test('turndown / mediaDevices 这类没用的信令一律忽略', () {
      final m = machine();

      for (final event in <String>[
        CallEvent.turndown,
        CallEvent.mediaDevices,
        '',
      ]) {
        final outcome = m.remote(remoteSignal(event: event));
        expect(outcome.effects, isEmpty, reason: 'event=$event');
        expect(m.session.phase, CallPhase.idle);
      }
    });
  });

  /// 对方被**离线推送**叫醒这条路上的两件事（S8.1h）：
  /// 主叫补发 offer、被叫自己收场。
  /// 对方**中途上线**这条路（S8.1o）。
  ///
  /// 背景：打过去的时候他不在线，服务端不会给他补投 `calling`（那一帧当场就丢
  /// 了）。他过一会儿自己打开 App —— 如果主叫不重喊，这通电话就永远送不到
  /// （用户原话：「呼叫一分钟，对方 30 秒后上线了呢？」）。
  group('对方中途上线（S8.1o）：主叫重喊这通电话', () {
    test('还在响 → 用同一个 id 重喊整帧 calling（字段与首发一模一样）', () {
      final m = dialing();
      final callId = m.session.messageId;

      final resent = signalOf(m.peerOnline('u2'), CallEvent.calling)!;

      expect(
        resent['id'],
        callId,
        reason:
            '必须是同一个 id：服务端靠它判「这是重喊，别落库」，'
            '被叫靠它判「这是我正在响的那一通」',
      );
      expect(resent['toContactId'], 'u2');
      expect(resent['status'], CallStatus.ringing);
      expect(resent['code'], CallCode.dialing);
      // 本端不算「又来了一通」：还是那通电话、还在响
      expect(m.session.phase, CallPhase.outgoing);
      expect(m.session.messageId, callId);
    });

    test('重喊有上限（默认 3 次）：对方反复上下线不会变成洪水', () {
      final m = dialing();

      for (var i = 0; i < CallMachine.callResendLimit; i++) {
        expect(signalOf(m.peerOnline('u2'), CallEvent.calling), isNotNull);
      }

      expect(m.peerOnline('u2').signals, isEmpty);
    });

    test('已经接听了就不再重喊，改用补发 offer', () {
      final m = dialing();
      m.remote(remoteSignal(event: CallEvent.acceptRtc, code: CallCode.accept));
      m.localOffer('sdp-offer');

      final outcome = m.peerOnline('u2');

      expect(
        signalOf(outcome, CallEvent.calling),
        isNull,
        reason: '他已经在接了，别再把「有人打给你」发一遍',
      );
      expect(signalOf(outcome, CallEvent.offer), isNotNull);
    });

    test('换一通新电话时重喊次数归零', () {
      final first = dialing();
      for (var i = 0; i < CallMachine.callResendLimit; i++) {
        first.peerOnline('u2');
      }
      expect(first.peerOnline('u2').signals, isEmpty, reason: '这一通已经用满了');
      first.reset();
      first.start(
        peerId: 'u2',
        peerName: '老B',
        peerAvatar: 'https://a.test/b.png',
        type: CallType.voice,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );
      first.mediaReady();

      expect(
        signalOf(first.peerOnline('u2'), CallEvent.calling),
        isNotNull,
        reason: '新的一通要能重新重喊',
      );
    });

    test('被叫收到同一通的重复 calling：静默忽略，绝不回忙线', () {
      final m = ringing(); // 正响着 uuid-caller 那一通
      _active = m;

      final outcome = m.remote(
        remoteSignal(
          event: CallEvent.calling,
          status: CallStatus.ringing,
          messageId: 'uuid-caller',
        ),
      );

      expect(outcome.signals, isEmpty, reason: '回了忙线，主叫那通电话就被我们自己挂掉了');
      expect(outcome.effects, isEmpty, reason: '也不该再响一次铃：本来就在响');
      expect(m.session.phase, CallPhase.incoming);
    });

    test('换一通（不同 id）打进来仍然是忙线', () {
      final m = ringing();
      _active = m;

      final outcome = m.remote(
        remoteSignal(
          event: CallEvent.calling,
          status: CallStatus.ringing,
          messageId: 'uuid-other',
        ),
      );

      expect(signalOf(outcome, CallEvent.busy), isNotNull);
    });
  });

  group('离线推送叫醒（S8.1h）', () {
    /// 一个「已接听、offer 已发出去、还在等 answer」的主叫
    CallMachine calling() {
      final m = dialing();
      m.remote(remoteSignal(event: CallEvent.acceptRtc, code: CallCode.accept));
      m.localOffer('sdp-offer');
      return m;
    }

    test('对方上线 → 原样补发同一份 offer（服务端不给离线的人补投信令）', () {
      final m = calling();

      final offer = signalOf(m.peerOnline('u2'), CallEvent.offer)!;

      expect(offer['sdp'], 'sdp-offer');
      expect(m.session.phase, CallPhase.connecting);
    });

    test('补发有上限（默认 2 次）：对方反复上下线不会变成洪水', () {
      final m = calling();

      for (var i = 0; i < CallMachine.offerResendLimit; i++) {
        expect(signalOf(m.peerOnline('u2'), CallEvent.offer), isNotNull);
      }

      expect(m.peerOnline('u2').signals, isEmpty);
    });

    test('answer 到了就不再补发（该做的已经做完了）', () {
      final m = calling();
      m.remote(remoteSignal(event: CallEvent.answer, sdp: 'sdp-answer'));

      expect(m.peerOnline('u2').signals, isEmpty);
    });

    test('只有主叫、只有还没结束才发东西', () {
      // 被叫（正在振铃）什么都不发：offer 是主叫那边的事
      expect(ringing().peerOnline('u1').signals, isEmpty);
      // 还没接听（dialing）→ 不是「补发 offer」，是「重喊整帧 calling」
      // （见下面那组 S8.1o）
      expect(
        signalOf(dialing().peerOnline('u2'), CallEvent.calling),
        isNotNull,
      );
      // 已经结束
      final ended = calling();
      ended.remote(
        remoteSignal(event: CallEvent.hangup, code: CallCode.hangupInCall),
      );
      expect(ended.peerOnline('u2').signals, isEmpty);
    });

    test('别的人上线不搅这通电话', () {
      final m = calling();

      expect(m.peerOnline('u9').signals, isEmpty);
      expect(m.peerOnline('').signals.length, 1, reason: '空 id（拿不到对端）就当是他');
    });

    test('被叫响铃上限到了：自收场，而且一枪信令都不发', () {
      final m = ringing();

      final outcome = m.ringTimeout();

      expect(CallMachine.incomingRingTimeoutSeconds, 45);
      expect(outcome.session.phase, CallPhase.ended);
      expect(outcome.session.code, CallCode.cancel);
      expect(hasEffect<StopRingtone>(outcome), isTrue);
      expect(hasEffect<EndCall>(outcome), isTrue);
      // 我们并不知道主叫还在不在等 —— 乱发一条会搅乱多端
      expect(outcome.signals, isEmpty);
      expect(m.lock.isLocked, isFalse, reason: '锁必须解开，否则之后的去电全被挡住');
    });

    test('不是来电时调 ringTimeout 是空操作', () {
      expect(dialing().ringTimeout().effects, isEmpty);
      expect(calling().ringTimeout().effects, isEmpty);
    });
  });
}

/// 最近一个被测的通话机器（只为让 [remoteSignal] 能默认拿到「当前通话的 id」）
CallMachine? _active;
