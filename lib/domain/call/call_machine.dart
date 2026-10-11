/// 通话状态机（S6.1）。
///
/// 老端这套逻辑散在三个地方：`App.vue` 的 `webrtc` 分支（来电分流、忙线、多端锁）、
/// `pages/message/call.vue`（页面 ↔ WebView 转发 + `sendToMsg`）、
/// `hybrid/html/index.html`（90x 码的产地与挂断码判定）。新端收口成**一个纯 Dart
/// 状态机**：输入是「用户动作 / 远程信令 / 媒体层回调」，输出是**要发出去的信令**
/// 与「该做的副作用」（响声、计时、关页、取媒体）。
///
/// 这样 S6.2 的媒体层只需要：接到 `RequestLocalMedia` 去 `getUserMedia`、
/// 接到 `CreateOffer` / `AcceptRemoteOffer` / `ApplyRemoteAnswer` / `AddIceCandidate`
/// 去喂 `flutter_webrtc`，再把结果（`mediaReady` / `mediaFailed` / `localOffer` /
/// `localAnswer` / `localIceCandidate` / `mediaConnected`）回调回来。信令本身与老端
/// 1:1（`domain/call/call_signal.dart` 里那十条字段一个字都不改）。
///
/// 刻意的两处收紧（老端这里是靠 `isMobile` 与服务端行为兜的，语义还没确认，见 S6.0）：
/// * **只有主叫处理 `acceptRtc`**、**只有被叫处理 `offer`**：否则自己那条
///   `acceptRtc` 被服务端推回来时（老端会走 `main_id == e.id` 那条路）被叫会
///   回一个多余的 offer；
/// * **同一时刻只服务一通电话**：新端是单进程单通话页，不像老端那样靠「当前路由」
///   猜——判定条件里同时看「机器在不在通话中」与「通话页开着没」。
library;

import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/util/json_value.dart';
import '../../core/util/uuid.dart';
import 'call_lock.dart';
import 'call_signal.dart';

/// 本地通话阶段。老端只有 `status` 那五个值（0-4），这里把「接通中」与
/// 「通话中」分开：两者对外都是 `status = 2`，但界面要能区分「正在接通」与计时开始。
enum CallPhase {
  /// 没有通话
  idle,

  /// 主叫拨号中（老端 `status = 1`）
  outgoing,

  /// 被叫来电中（老端 `status = 3`）
  incoming,

  /// 已接听、正在协商媒体（老端 `status = 2`）
  connecting,

  /// 媒体已连通（老端 `status = 2`）
  connected,

  /// 已结束（本地态；对端由信令通知）
  ended,
}

/// 一通电话（本端视角）
@immutable
class CallSession {
  const CallSession({
    this.phase = CallPhase.idle,
    this.peerId = '',
    this.peerName = '',
    this.peerAvatar = '',
    this.type = CallType.voice,
    this.isCaller = false,
    this.messageId = '',
    this.serverId = '',
    this.callTime = 0,
    this.code = 0,
  });

  final CallPhase phase;
  final String peerId;
  final String peerName;
  final String peerAvatar;

  /// 0 语音 / 1 视频
  final int type;

  /// 是不是本端发起的（挂断码与 `acceptRtc` 的判定都靠它）
  final bool isCaller;

  /// 老端那个 `main_id`：主叫侧是自己生成的 uuid，被叫侧是对方那条消息的 `id`
  final String messageId;

  /// 服务端业务 id（老端 `wsData.msg_id`）：收到一条信令就记下来，发出去时带上
  final String serverId;

  /// 通话时长（秒，本地计时）
  final int callTime;

  /// 结束时那个 90x 码（进行中为 0）
  final int code;

  /// 这通电话还在进行（**`ended` 不算**）。
  ///
  /// 刻意的收紧：老端没有本地阶段，靠路由猜，所以「挂断后再点一次挂断」会再发一枪
  /// （`index.html` 的按钮没做防抖）。新端把 `ended` 排除在 `isActive` 之外，
  /// 重复挂断 / 挂断后再收到一条结束信令都是空操作。
  bool get isActive => phase != CallPhase.idle && phase != CallPhase.ended;
  bool get isVideo => type == CallType.video;
  bool get isRinging =>
      phase == CallPhase.outgoing || phase == CallPhase.incoming;

  /// 对外的 `status`（老端那五个值；新端的连接中与已接通都是 2）
  int get wireStatus => switch (phase) {
    CallPhase.idle || CallPhase.ended => CallStatus.none,
    CallPhase.outgoing => CallStatus.dialing,
    CallPhase.incoming => CallStatus.ringing,
    CallPhase.connecting || CallPhase.connected => CallStatus.talking,
  };

  CallSession copyWith({
    CallPhase? phase,
    String? peerId,
    String? peerName,
    String? peerAvatar,
    int? type,
    bool? isCaller,
    String? messageId,
    String? serverId,
    int? callTime,
    int? code,
  }) => CallSession(
    phase: phase ?? this.phase,
    peerId: peerId ?? this.peerId,
    peerName: peerName ?? this.peerName,
    peerAvatar: peerAvatar ?? this.peerAvatar,
    type: type ?? this.type,
    isCaller: isCaller ?? this.isCaller,
    messageId: messageId ?? this.messageId,
    serverId: serverId ?? this.serverId,
    callTime: callTime ?? this.callTime,
    code: code ?? this.code,
  );

  @override
  String toString() =>
      'CallSession(${phase.name}, peer=$peerId, caller=$isCaller, '
      'id=$messageId, msg=$serverId, ${callTime}s)';
}

/// 状态机要做的副作用（由 S6.3 的控制器消费）
sealed class CallEffect {
  const CallEffect();
}

/// 发一条信令（等价于老端那次 `sendToMsg`）
class SendSignal extends CallEffect {
  const SendSignal(this.request);

  final Map<String, dynamic> request;

  @override
  String toString() => 'SendSignal(${request['event']})';
}

/// 提示一句（值是 i18n key）
class ShowToast extends CallEffect {
  const ShowToast(this.messageKey);

  final String messageKey;

  @override
  String toString() => 'ShowToast($messageKey)';
}

/// 播/停铃声（老端 WebView 里那个循环播放的 `<audio>`）
class PlayRingtone extends CallEffect {
  const PlayRingtone();

  @override
  String toString() => 'PlayRingtone()';
}

class StopRingtone extends CallEffect {
  const StopRingtone();

  @override
  String toString() => 'StopRingtone()';
}

/// 开始/停止通话计时（老端 `setInterval` 那个 `callTime`）
class StartCallTimer extends CallEffect {
  const StartCallTimer();

  @override
  String toString() => 'StartCallTimer()';
}

class StopCallTimer extends CallEffect {
  const StopCallTimer();

  @override
  String toString() => 'StopCallTimer()';
}

/// 去取本机媒体（S6.2：成功回 `mediaReady()`，失败回 `mediaFailed()`）
class RequestLocalMedia extends CallEffect {
  const RequestLocalMedia(this.type);

  final int type;

  @override
  String toString() => 'RequestLocalMedia(type=$type)';
}

/// 主叫收到 `acceptRtc` 之后要造 offer（S6.2），造好用 `localOffer(sdp)` 回传
class CreateOffer extends CallEffect {
  const CreateOffer();

  @override
  String toString() => 'CreateOffer()';
}

/// 被叫收到 `offer`：设远端 → 造 answer（造好用 `localAnswer(sdp)` 回传）
class AcceptRemoteOffer extends CallEffect {
  const AcceptRemoteOffer(this.sdp);

  final String sdp;

  @override
  String toString() => 'AcceptRemoteOffer(sdp=${sdp.length} 字节)';
}

/// 主叫收到 `answer`：设远端描述
class ApplyRemoteAnswer extends CallEffect {
  const ApplyRemoteAnswer(this.sdp);

  final String sdp;

  @override
  String toString() => 'ApplyRemoteAnswer(sdp=${sdp.length} 字节)';
}

/// 加一条 ICE 候选（老端在 WebView 里延迟 100ms 再加，那属于 S6.2 的节奏）
class AddIceCandidate extends CallEffect {
  const AddIceCandidate(this.candidate);

  final Map<String, dynamic> candidate;

  @override
  String toString() => 'AddIceCandidate(${candidate['sdpMid']})';
}

/// 关掉通话页（老端 `closeCall()`：放挂断音 + 返回上一页）
class EndCall extends CallEffect {
  const EndCall();

  @override
  String toString() => 'EndCall()';
}

/// 一次输入的结果：新状态 + 要做的副作用
@immutable
class CallOutcome {
  const CallOutcome(this.session, [this.effects = const <CallEffect>[]]);

  final CallSession session;
  final List<CallEffect> effects;

  /// 里面要发出去的信令（测试里最常断言的就是它）
  List<Map<String, dynamic>> get signals => <Map<String, dynamic>>[
    for (final effect in effects)
      if (effect is SendSignal) effect.request,
  ];

  /// 里面要弹的提示（i18n key）
  List<String> get toasts => <String>[
    for (final effect in effects)
      if (effect is ShowToast) effect.messageKey,
  ];

  @override
  String toString() => 'CallOutcome($session, $effects)';
}

/// 通话状态机。**没有 IO**：所有副作用都在返回值里。
class CallMachine {
  CallMachine({required this.myUserId, Random? random})
    : _random = random; // ignore: prefer_initializing_formals

  /// 当前登录用户 id（用来判「这条信令是不是我自己发的」）
  final String myUserId;

  /// 只为了让测试能固定 uuid
  final Random? _random;

  /// 拨号超时。老端 `index.html::cutdown = 40`，新端放宽到 60（S8.1h）。
  ///
  /// 为什么改：对方 App 被杀时，要靠**离线推送**把他叫醒，而那条路要花时间
  /// （推送 → 冷启动 → 连长连接 → 响铃）。40 秒经常不够，电话会在他刚响就断。
  /// 60 秒也是**和两份超时对齐**的数字：
  /// * 服务端那条来电推送的 TTL 也是 60 秒（`FcmProvider::$callTtl`），
  ///   比它短就会出现「推送还没送到、主叫先挂了」；
  /// * 微信也是响一分钟上下，用户不会觉得这个时长奇怪。
  static const int dialTimeoutSeconds = 60;

  /// 被叫**响铃**上限（S8.1h）。比主叫的 60 秒短一截。
  ///
  /// 为什么需要它：主叫超时后发的那条 `hangup` 到不了我们（我们是被推送叫醒的、
  /// 当时可能还没连上长连接），没有这条上限，手机会一直响到用户手动按拒接。
  /// 45 秒 = 50 秒的推送时效闸门（见 `IncomingCallPush.isFresh`）再留出几秒余量。
  static const int incomingRingTimeoutSeconds = 45;

  /// 主叫补发 offer 的次数上限（见 [peerOnline]）
  static const int offerResendLimit = 2;

  /// 主叫「重喊」的次数上限（见 [peerOnline]）。
  ///
  /// 重喊的触发条件是「对方又上线了一次」（上下线事件是全网广播的），60 秒的
  /// 窗口里正常也就一两次；给 3 次是留给弱网反复重连的人。
  static const int callResendLimit = 3;

  final CallLock lock = CallLock();

  /// 本机媒体是不是已经就绪（防重复拿流：老端 WebView 的 `getUserMedia` 回调
  /// 只可能回来一次，但新端的媒体层是自己的代码，重复回调很容易发生，
  /// 重复一次就会多发一条 `calling` / `acceptRtc`，对端会当成「又来一通」回忙线）。
  bool _mediaReady = false;

  /// 对方**先到**的 offer（本机媒体还没就绪时先挂起，等 [mediaReady] 再响应）。
  ///
  /// ⚠️ **2026-09-19 真机上踩出来的坑**：原来这里是收到就当场响应 —— 而
  /// 「对方发 offer」的时机是「它收到我们的 `acceptRtc` 之后」，视频通话取摄像头
  /// 要 1~3 秒，这段窗口里本机 `RTCPeerConnection` 可能还没建出来，媒体层只能抛
  /// 「PeerConnection 还没建立」，控制器于是弹「请检查音视频」+ 挂断。
  /// 真机上的表现就是用户说的「视频一接通就闪退」（对端那条 SDP 早到是常态，
  /// 老端 `call.vue` 里也是「SDP 早到、页面还没点接听」那条分支）。
  String? _pendingOffer;

  /// 本端**发出去**的 offer（主叫）。
  ///
  /// 存一份是为了 [peerOnline] 能原样补发：对方如果是被推送叫醒的，他刚连上长连接时
  /// 我们那份 offer 很可能早就发了、而且被服务端丢了（服务端不给离线的人补投信令）。
  String? _localOffer;

  /// 对方那条 answer 到了没（到了就不需要再补发 offer）
  bool _answerApplied = false;

  /// 已经补发过几次 offer
  int _offerResends = 0;

  /// 已经「重喊」过几次（见 [peerOnline] 的第一条分支）
  int _callResends = 0;

  CallSession _session = const CallSession();

  CallSession get session => _session;

  CallOutcome _out([List<CallEffect> effects = const <CallEffect>[]]) =>
      CallOutcome(_session, effects);

  /// 清回 `idle`（通话页关掉之后调；老端是 `wsData = null; main_id = null`）
  CallOutcome reset() {
    _mediaReady = false;
    _dropPendingOffer();
    _dropLocalOffer();
    _session = const CallSession();
    return _out();
  }

  /// 主叫：点了「语音/视频通话」。
  ///
  /// 三道检查的顺序与文案照老端 `im-input.vue::calling`：
  /// 服务端没开音视频 → `chat.closeWebrtc`；关了私聊 → `chat.notTalk`；
  /// 已经在通话 → `message.otherCalling`。三关都过才建会话（并让媒体层去取流）。
  CallOutcome start({
    required String peerId,
    required String peerName,
    String peerAvatar = '',
    required int type,
    required bool webrtcEnabled,
    required bool simpleChatEnabled,
  }) {
    if (!webrtcEnabled) {
      return _out(const <CallEffect>[ShowToast('chat.closeWebrtc')]);
    }
    if (!simpleChatEnabled) {
      return _out(const <CallEffect>[ShowToast('chat.notTalk')]);
    }
    if (lock.isLocked || _session.isActive) {
      return _out(const <CallEffect>[ShowToast('message.otherCalling')]);
    }
    _mediaReady = false;
    _dropPendingOffer();
    _dropLocalOffer();
    _session = CallSession(
      phase: CallPhase.outgoing,
      peerId: peerId,
      peerName: peerName,
      peerAvatar: peerAvatar,
      type: type,
      isCaller: true,
      // 老端 `im-input.vue`：`msg_id = $util.getUuid()`，即主叫侧自己生成的
      messageId: uuidV4(_random),
    );
    return _out(<CallEffect>[RequestLocalMedia(type)]);
  }

  /// 被叫：点了「接听」（老端 `index.html::answer`：status=2、取流、停铃、开始计时）
  CallOutcome accept() {
    if (_session.phase != CallPhase.incoming) return _out();
    _mediaReady = false;
    _session = _session.copyWith(phase: CallPhase.connecting);
    return _out(<CallEffect>[
      const StopRingtone(),
      const StartCallTimer(),
      RequestLocalMedia(_session.type),
    ]);
  }

  /// 本机媒体就绪（老端 `getUserMedia` 成功）
  ///
  /// * 主叫 → 发 `calling`（`status: 3`、`code: 901`）+ 开始响铃；
  /// * 被叫（已接听）→ 发 `acceptRtc`（`code: 904`）+ 停铃，**并且顺手把挂起中的
  ///   对方 offer 响应掉**（那条 offer 早到了：见 [_pendingOffer]）。
  CallOutcome mediaReady() {
    if (_mediaReady) return _out();
    if (_session.phase == CallPhase.outgoing && _session.isCaller) {
      _mediaReady = true;
      return _out(<CallEffect>[
        SendSignal(
          _request(
            event: CallEvent.calling,
            status: CallStatus.ringing,
            code: CallCode.dialing,
          ),
        ),
        const PlayRingtone(),
      ]);
    }
    if (_session.phase == CallPhase.connecting && !_session.isCaller) {
      _mediaReady = true;
      final effects = <CallEffect>[
        SendSignal(_request(event: CallEvent.acceptRtc, code: CallCode.accept)),
        const StopRingtone(),
      ];
      final pending = _pendingOffer;
      if (pending != null) {
        // 本机轨道已经挂上连接了，现在响应它才是安全的（顺序也是对的：
        // 先让对端知道我们接听了，再回它的 SDP）
        _dropPendingOffer();
        effects.add(AcceptRemoteOffer(pending));
      }
      return _out(effects);
    }
    return _out();
  }

  /// 本机媒体拿不到（没权限/没设备）。老端这时**不发信令**，只提示 + 关页。
  ///
  /// 同样顺手解锁：这通电话在本端已经结束了，锁留着只会挡住之后的去电。
  CallOutcome mediaFailed() {
    if (!_session.isActive) return _out();
    lock.unlock();
    _dropPendingOffer();
    _session = _session.copyWith(phase: CallPhase.ended);
    return _out(const <CallEffect>[
      StopRingtone(),
      StopCallTimer(),
      ShowToast('message.checkWebtc'),
      EndCall(),
    ]);
  }

  /// 媒体层造好了 offer（主叫）→ 发出去
  CallOutcome localOffer(String sdp) {
    if (!_inCall) return _out();
    // 存一份：对方要是晚才上线，[peerOnline] 要把它原样补发出去
    _localOffer = sdp;
    return _out(<CallEffect>[
      SendSignal(_request(event: CallEvent.offer, sdp: sdp)),
    ]);
  }

  /// 媒体层造好了 answer（被叫）→ 发出去
  CallOutcome localAnswer(String sdp) {
    if (!_inCall) return _out();
    return _out(<CallEffect>[
      SendSignal(_request(event: CallEvent.answer, sdp: sdp)),
    ]);
  }

  /// 媒体层收集到一条 ICE 候选 → 发出去（老端一条一个消息）
  CallOutcome localIceCandidate(Map<String, dynamic> candidate) {
    if (!_inCall || candidate.isEmpty) return _out();
    return _out(<CallEffect>[
      SendSignal(
        _request(event: CallEvent.iceCandidate, iceCandidate: candidate),
      ),
    ]);
  }

  /// 媒体层报告连上了（S6.2 的 `RTCPeerConnection.connectionState == connected`）
  CallOutcome mediaConnected() {
    if (_session.phase != CallPhase.connecting) return _out();
    _session = _session.copyWith(phase: CallPhase.connected);
    return _out();
  }

  /// 本地用户点挂断/拒接/取消：码由当前阶段决定（老端 `index.html::hangup`）
  CallOutcome hangup() {
    if (!_session.isActive) return _out();
    return _hangupWith(_hangupCode());
  }

  /// 拨号 40 秒无人接听（老端是 WebView 里的倒计时，到点调 `hangup(true)`）
  CallOutcome timeout() {
    if (_session.phase != CallPhase.outgoing) return _out();
    return _hangupWith(CallCode.cancel);
  }

  /// 计时器跳一秒（只在「已接听」之后累加）
  CallOutcome tick() {
    if (_session.phase != CallPhase.connecting &&
        _session.phase != CallPhase.connected) {
      return _out();
    }
    _session = _session.copyWith(callTime: _session.callTime + 1);
    return _out();
  }

  /// 自己发出去的那条信令的接口回执（老端 `msgCallback` 里的 `.then((res) => ...)`）。
  ///
  /// 两件事：记下服务端业务 id（老端 `this.wsData = res.data`），
  /// 以及——**服务端用 `extends.code == 907` 告诉我们对方不在线**，此时提示并关页。
  CallOutcome signalAccepted(Object? data) {
    final map = asMap(data);
    final serverId = asText(map['msg_id'], asText(map['id']));
    if (serverId.isNotEmpty) {
      _session = _session.copyWith(serverId: serverId);
    }
    final code = asInt(asMap(map['extends'])['code'], 0);
    if (code == CallCode.busy) {
      _session = _session.copyWith(phase: CallPhase.ended, code: code);
      return _out(const <CallEffect>[
        StopRingtone(),
        StopCallTimer(),
        ShowToast('message.notOnline'),
        EndCall(),
      ]);
    }
    return _out();
  }

  /// 对端下线（老端 `App.vue` 的 `isOnline` 分支：锁着的那个人下线就解锁）
  CallOutcome peerOffline(String peerId) {
    lock.peerOffline(peerId);
    return _out();
  }

  /// 对端**上线了**（S8.1h / S8.1o）：看我们停在哪一步，做两件不同的事。
  ///
  /// **① 还在响、还没人接 → 把这通电话「重喊」一遍。**
  /// 服务端在对方不在线时不会给他补投 `calling`（那一帧当场就丢了），所以光靠
  /// 第一次呼叫，一个「打的时候没连上、30 秒后自己打开 App」的人**永远接不到**
  /// —— 修法就是主叫听到「他上线了」就用同一个 id 再喊一次。
  /// 配套两处，缺一处就会出怪事：
  ///   * 服务端 `Im.php`：同一个 id 已经落过库就**只转发、不新建记录**（否则
  ///     对方聊天列表里多出一条通话记录）；
  ///   * 被叫那半：同一个 id 的重复来电**静默忽略**（见 `case CallEvent.calling`），
  ///     否则他回的忙线反而把这通电话挂掉。
  ///
  /// **② 已经接听、在等 answer → 补发同一份 offer。** 这个坑是这样长出来的：
  /// 对方被推送叫醒、按了接听，他发来的 `acceptRtc` 我们收得到，我们收到就
  /// `CreateOffer()` 把 offer 发出去 —— 可是**那一瞬间他的长连接可能还没建好**，
  /// 这条 offer 就丢了：两边从此各自卡住（他等 SDP、我们等 answer），而服务端
  /// 不会补投。兜法就是把同一份 offer 再发一遭（幂等：他的媒体层再设一次远端
  /// SDP 不会出问题）。
  CallOutcome peerOnline(String peerId) {
    if (!_session.isActive || !_session.isCaller) return _out();
    if (peerId.isNotEmpty && peerId != _session.peerId) return _out();

    // ① 还在响、还没人接：重喊整帧 `calling`（字段与首发一模一样，只是再来一次）
    if (_session.phase == CallPhase.outgoing) {
      if (_callResends >= callResendLimit) return _out();
      _callResends++;
      return _out(<CallEffect>[
        SendSignal(
          _request(
            event: CallEvent.calling,
            status: CallStatus.ringing,
            code: CallCode.dialing,
          ),
        ),
      ]);
    }

    // ② 已经接听：补发 offer
    if (_session.phase != CallPhase.connecting) return _out();
    final offer = _localOffer;
    if (offer == null || _answerApplied || _offerResends >= offerResendLimit) {
      return _out();
    }
    _offerResends++;
    return _out(<CallEffect>[
      SendSignal(_request(event: CallEvent.offer, sdp: offer)),
    ]);
  }

  /// 被叫的响铃上限到了（见 [incomingRingTimeoutSeconds]）：本端自己收场。
  ///
  /// 刻意**一枪信令都不发**：我们并不知道主叫还在不在等（他可能早就挂了，
  /// 而那条 hangup 到不了我们）——乱发一条反而可能搅乱多端场景。归零就完事，
  /// 主叫自己有 60 秒超时。
  CallOutcome ringTimeout() {
    if (_session.phase != CallPhase.incoming) return _out();
    lock.unlock();
    _session = _session.copyWith(phase: CallPhase.ended, code: CallCode.cancel);
    return _out(<CallEffect>[const StopRingtone(), const EndCall()]);
  }

  /// 丢掉本端那份 offer（重新开始 / 结束时要丢）
  void _dropLocalOffer() {
    _localOffer = null;
    _answerApplied = false;
    _offerResends = 0;
    _callResends = 0;
  }

  /// 收到一条远程信令（WS `webrtc` 事件）。
  ///
  /// [pageActive] 是「通话页正开着」——老端用它判忙线（`当前路由 == pages/message/call`）。
  CallOutcome remote(CallSignal signal, {bool pageActive = false}) {
    final effects = <CallEffect>[];

    // ① 自己发出去的那条被服务端推回来（老端 `App.vue` 的第一段）
    if (signal.isEchoOf(myUserId)) {
      lock.ownSignal(signal.code);
      if (signal.isMobile || signal.event == CallEvent.calling) {
        // 老端：自己那条 `calling` 只往聊天列表里加一条（消息本身由消息层落库），
        // 其余一律不当作来电处理
        return _out(effects);
      }
    }

    final event = signal.event;

    // ② 多端锁（老端：offer / answer 锁上、hangup 解锁）
    if (event == CallEvent.offer || event == CallEvent.answer) {
      lock.lockAnonymous();
    } else if (event == CallEvent.hangup) {
      lock.unlock();
    }

    // ③ 不是我们这通电话的那条（同一个人又来一通）→ 回忙线，本通继续
    if (_session.isActive &&
        signal.messageId.isNotEmpty &&
        _session.messageId.isNotEmpty &&
        signal.messageId != _session.messageId) {
      effects.add(SendSignal(_busyReply(signal)));
      return _out(effects);
    }

    switch (event) {
      case CallEvent.calling:
        // ① 主叫的**重喊**（S8.1o）：打过来的时候我们不在线，他听到我们上线
        //    就把同一帧 `calling` 又发了一遍 —— 同一个 id 就是**同一通电话**，
        //    静默忽略。不忽略的话会掉进下面那条「已经有一通就回忙线」，
        //    我们回的忙线会把主叫那通电话直接挂掉（他本来正响着呢）。
        if (_session.isActive &&
            signal.messageId.isNotEmpty &&
            signal.messageId == _session.messageId) {
          return _out(effects);
        }
        // ② 本端已经有一通（或通话页还开着）→ 只回忙线，不动当前那通
        if (pageActive || _session.isActive) {
          effects.add(SendSignal(_busyReply(signal)));
          return _out(effects);
        }
        _session = CallSession(
          phase: CallPhase.incoming,
          peerId: signal.fromUserId,
          peerName: signal.fromUserName,
          peerAvatar: signal.fromUserAvatar,
          type: signal.type,
          isCaller: false,
          messageId: signal.messageId,
          serverId: signal.serverId,
        );
        _dropPendingOffer();
        lock.lockPeer(signal.fromUserId);
        effects.add(const PlayRingtone());

      case CallEvent.acceptRtc:
        // 只有主叫在拨号中才处理（见文件头的收紧说明）
        if (!_session.isCaller || _session.phase != CallPhase.outgoing) break;
        _session = _session.copyWith(
          phase: CallPhase.connecting,
          serverId: _serverIdFrom(signal),
        );
        effects.addAll(const <CallEffect>[
          StopRingtone(),
          StartCallTimer(),
          CreateOffer(),
        ]);

      case CallEvent.offer:
        // ⚠️ 只服务「本端真的有一通来电」的情况。
        //
        // 2026-09-19 真机上的坑：这里原来只判 `isCaller`，而 `isCaller` 默认是
        // false —— 于是一条**过了期的 offer**（对端在我们挂断之后才发出来，或者
        // 服务端连着旧信令一起重推）照样会进到 `AcceptRemoteOffer`，撞上已经
        // 关掉的媒体层 → 抛「PeerConnection 还没建立」→ 弹「请检查音视频」+ 补
        // 一枪挂断。真机日志里那两条 `响应 offer失败` 就是这么来的。
        if (_session.isCaller || !_session.isActive) break;
        _session = _session.copyWith(serverId: _serverIdFrom(signal));
        if (!_mediaReady) {
          // 本机媒体还没就绪（视频取摄像头要 1~3 秒）：先挂起，等媒体就绪
          // 再响应 —— 当场响应只会在媒体层拿不到连接
          _pendingOffer = signal.sdp;
          break;
        }
        effects.add(AcceptRemoteOffer(signal.sdp));

      case CallEvent.answer:
        if (!_session.isCaller) break;
        // 对方的 answer 到了 → 不需要再补发 offer（见 [peerOnline]）
        _answerApplied = true;
        _session = _session.copyWith(serverId: _serverIdFrom(signal));
        effects.add(ApplyRemoteAnswer(signal.sdp));

      case CallEvent.iceCandidate:
        if (!_inCall || signal.iceCandidate.isEmpty) break;
        effects.add(AddIceCandidate(signal.iceCandidate));

      case CallEvent.hangup:
        final ending = _endEffects(code: signal.code);
        effects.addAll(ending);
        // 老端：收到带 907 的挂断会提示「对方忙~~」。
        // 只在真的结束了这一通时才提示：两端同时回忙线时会有第二条到达，
        // 已经关页了就别再弹一次。
        if (ending.isNotEmpty && signal.code == CallCode.busy) {
          effects.add(const ShowToast('message.toBusy'));
        }

      case CallEvent.busy:
        // 对方回忙线：本端被挂断的那一方会看到「对方忙~~」（老端是 WebView
        // 把 status 改成 4 再关页，那条 hangup 带 907 → 页面弹这句）
        final ended = _endEffects(code: CallCode.busy);
        effects.addAll(ended);
        if (ended.isNotEmpty) {
          effects.add(const ShowToast('message.toBusy'));
        }

      case CallEvent.otherOpt:
        // ⚠️ 服务端会把 `acceptRtc` / `hangup` **回声**成 `otherOpt` 发给
        // 「发送者整个账号的所有连接」（`Im.php::sendToMsg()` 末尾那段），
        // **包括刚发出这条信令的那条连接自己**。
        //
        // 也就是说：我们自己按下的「接听」会在几百毫秒后变成一条
        // `otherOpt code=904` 回来。不区分的话，**每通电话都在接通那一瞬间
        // 被自己关掉**（真机 2026-09-20：「一接通一秒就闪退」，日志里正是
        // `[通话] 收到信令：otherOpt code=904`）。
        //
        // 只挡这一种：本端是**被叫且已经接听**（`_inCall`）时收到「接听」的回声
        // —— 那时这条只可能是自己那句。同账号另一个端真的接了电话，
        // 本端那时还停在响铃（`incoming`，不在 `_inCall`），照样按下面结束。
        if (signal.code == CallCode.accept && !_session.isCaller && _inCall) {
          break;
        }
        // 同一账号的其它端已经处理了这次通话 → 本端静默关页（不发信令）
        effects.addAll(_endEffects(code: signal.code));

      default:
        // `mediaDevices` 是老端 WebView 内部事件（本机媒体失败），新端走
        // `mediaFailed()`；`turndown` 老端自己也没发过。
        break;
    }

    return _out(effects);
  }

  // ------------------------------------------------------------------ 内部

  bool get _inCall =>
      _session.phase == CallPhase.connecting ||
      _session.phase == CallPhase.connected;

  /// 丢掉挂起中的对方 offer（挂断 / 结束 / 重新开始时都要丢，
  /// 否则下一通电话可能拿着上一通那条 SDP 去协商）
  void _dropPendingOffer() {
    _pendingOffer = null;
  }

  /// 挂断码（老端 `index.html::hangup`：按 status 分档）
  int _hangupCode() => switch (_session.phase) {
    CallPhase.connecting || CallPhase.connected => CallCode.hangupInCall,
    CallPhase.incoming => CallCode.reject,
    _ => CallCode.cancel,
  };

  /// 主动挂断：`callTime` 与 `code` 照老端发出去，然后停铃、停表、关页。
  ///
  /// 老端还有个 `isbtn` 字段，但它**只在本端用**（决定要不要发这一枪），
  /// 从来没有出现在 `sendToMsg` 的请求体里（`call.vue::msgCallback` 那十个字段）。
  ///
  /// **顺手解掉多端锁**（老端不解，它等自己那条挂断被服务端推回来才解 —— 靠
  /// `App.vue` 的 `fromUser.id == userInfo.user_id` 那条路）。为什么改：万一服务端
  /// 不把自己的消息推回给发送方，老端那把锁就永远留着，**之后所有去电都会被自己
  /// 拦成「其他终端正在通话中」**。锁本来就是本端自己那通电话锁上的，本地挂断时解掉
  /// 不会丢任何信息（同一账号别的设备的通话，本端本来也看不到）。
  CallOutcome _hangupWith(int code) {
    lock.unlock();
    _dropPendingOffer();
    _dropLocalOffer();
    _session = _session.copyWith(phase: CallPhase.ended, code: code);
    return _out(<CallEffect>[
      SendSignal(
        _request(
          event: CallEvent.hangup,
          code: code,
          callTime: _session.callTime,
        ),
      ),
      const StopRingtone(),
      const StopCallTimer(),
      const EndCall(),
    ]);
  }

  /// 被动结束（收到对端的挂断/忙线/多端处理）：不发信令、提示由调用处补
  List<CallEffect> _endEffects({required int code}) {
    if (!_session.isActive) {
      return const <CallEffect>[];
    }
    _dropPendingOffer();
    _session = _session.copyWith(phase: CallPhase.ended, code: code);
    return const <CallEffect>[StopRingtone(), StopCallTimer(), EndCall()];
  }

  /// 对方正在通话中时回的那条（老端 `App.vue` 与 `call.vue` 两处都这么发）
  Map<String, dynamic> _busyReply(CallSignal signal) => buildSignalRequest(
    toContactId: signal.fromUserId,
    type: signal.type,
    event: CallEvent.busy,
    id: signal.messageId,
    serverId: signal.serverId,
    status: signal.status,
    code: CallCode.busy,
  );

  String _serverIdFrom(CallSignal signal) =>
      signal.serverId.isEmpty ? _session.serverId : signal.serverId;

  /// 拼一条本端要发出去的信令（十个字段见 [buildSignalRequest]）
  Map<String, dynamic> _request({
    required String event,
    int? status,
    int? code,
    int? callTime,
    String sdp = '',
    Map<String, dynamic>? iceCandidate,
  }) => buildSignalRequest(
    toContactId: _session.peerId,
    type: _session.type,
    event: event,
    id: _session.messageId,
    serverId: _session.serverId,
    status: status,
    code: code,
    callTime: callTime,
    sdp: sdp,
    iceCandidate: iceCandidate,
  );
}
