import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:gracelinkim/data/model/sfu_models.dart';
import 'package:gracelinkim/domain/group_call/sfu_failure.dart';
import 'package:gracelinkim/domain/group_call/sfu_transport.dart';

/// 假控制面：记录每一次调用（顺序 + 参数），并能按需注入失败。
class FakeSfuControl implements SfuControlPlane {
  final List<String> log = <String>[];

  /// 每次请求的完整参数，便于断言（例如"订阅一次带了几条"）
  final List<({String method, Map<String, dynamic> args})> calls =
      <({String method, Map<String, dynamic> args})>[];

  /// 房间快照（测试直接改它；名字不能叫 `roomState`——那是接口方法）
  SfuRoomState snapshot = const SfuRoomState(
    members: <SfuRoomMember>[],
    epoch: 1,
  );

  /// 下一次某个方法要抛的失败（用完即清）
  final Map<String, SfuFailure> failOnce = <String, SfuFailure>{};

  /// 某个方法的**第几次**调用（从 1 开始）要抛：`方法 → {序号: 失败}`。
  ///
  /// 用在"第一次发布怎么怎么、重建的那一次又怎么怎么"这类场景上
  /// （[failOnce] 只记一个，没法表达"第二次才失败"）。
  final Map<String, Map<int, SfuFailure>> failOnCall =
      <String, Map<int, SfuFailure>>{};

  /// `publish` 返回的 answer
  String publishAnswer = 'answer-from-sfu';

  /// 让 `publish` **反过来回一个 offer**（CF 的 `requiresImmediateRenegotiation`）。
  ///
  /// 真机上 CF 确实会这么回：这时端点必须作答并交回 `renegotiate`，
  /// 只看 answer 的写法会把这一步静默丢掉（"看着发布成功、其实没落地"）。
  String? publishOffer;

  /// 逐条失败（发布侧）：`trackName` → errorCode。
  ///
  /// 用在「上游一条都没接受」那种情形：HTTP 200 但每条 track 都带错误。
  Map<String, String> failingPublications = <String, String>{};

  /// `subscribe` 返回的 offer（**订阅是 SFU 回 offer**）
  String subscribeOffer = 'offer-from-sfu';

  /// 订阅响应里逐条给的**接收侧 mid**：`发布者sessionId|trackName` → mid
  Map<String, String> receivingMids = <String, String>{};

  /// 逐条失败（模拟 HTTP 200 里的 per-track error）：`trackName` → errorCode
  Map<String, String> failingSubscriptions = <String, String>{};

  /// 让 `createSession` **挂在这里**（模拟「建会话要等好几秒」）。
  ///
  /// 用在「会话还停在『正在加入』」那类画面上（小窗、通话页的加载态）：
  /// 建会话是进房间那串里的第一跳，卡住它就能把那一刻定格住。
  Completer<void>? createSessionBlocker;

  /// 放行上面那个门
  void releaseCreateSession() => createSessionBlocker?.complete();

  /// 把 `publish` 卡住。真机上这一跳要好几秒（候选收集 + 与 Cloudflare 建连），
  /// 卡住它就能验证"进房间那一下**不等**我的发布谈成"（听得见别人不需要它）。
  Completer<void>? publishBlocker;

  /// 放行上面那个门
  void releasePublish() => publishBlocker?.complete();

  int _sessions = 0;

  /// 某方法的调用次数
  int countOf(String method) =>
      calls.where((call) => call.method == method).length;

  void _record(String method, Map<String, dynamic> args) {
    log.add(method);
    calls.add((method: method, args: args));
  }

  void _maybeFail(String method) {
    final failure = failOnce.remove(method);
    if (failure != null) throw failure;
    // `_record` 已经记过这一次了，所以 countOf 就是当前调用的序号
    final scheduled = failOnCall[method]?.remove(countOf(method));
    if (scheduled != null) throw scheduled;
  }

  @override
  Future<String> createSession({
    required String roomId,
    required String purpose,
  }) async {
    _record('createSession:$purpose', <String, dynamic>{
      'room_id': roomId,
      'purpose': purpose,
    });
    final blocker = createSessionBlocker;
    if (blocker != null) await blocker.future;
    _maybeFail('createSession');
    _sessions += 1;
    return 'sess-$purpose-$_sessions';
  }

  @override
  Future<SfuExchangeResult> publish({
    required String sessionId,
    required String sdpOffer,
    required List<Map<String, dynamic>> tracks,
  }) async {
    _record('publish', <String, dynamic>{
      'session_id': sessionId,
      'sdp_offer': sdpOffer,
      'tracks': tracks,
    });
    _maybeFail('publish');
    final publishGate = publishBlocker;
    if (publishGate != null) await publishGate.future;
    final offer = publishOffer;
    return SfuExchangeResult(
      sdpAnswer: offer == null ? publishAnswer : null,
      sdpOffer: offer,
      requiresRenegotiation: offer != null,
      tracks: <SfuTrackResult>[
        for (final track in tracks)
          if (failingPublications.containsKey('${track['track_name']}'))
            SfuTrackResult(
              trackName: '${track['track_name']}',
              errorCode: failingPublications['${track['track_name']}'] ?? '',
              errorDescription: 'fake failure',
            )
          else
            SfuTrackResult(
              trackName: '${track['track_name']}',
              mid: '${track['mid']}',
              status: 'active',
            ),
      ],
    );
  }

  @override
  Future<SfuExchangeResult> subscribe({
    required String sessionId,
    required List<Map<String, dynamic>> tracks,
  }) async {
    _record('subscribe', <String, dynamic>{
      'session_id': sessionId,
      'tracks': tracks,
    });
    _maybeFail('subscribe');
    return SfuExchangeResult(
      sdpOffer: subscribeOffer,
      requiresRenegotiation: true,
      tracks: <SfuTrackResult>[
        for (final track in tracks)
          _trackResult('${track['session_id']}', '${track['track_name']}'),
      ],
    );
  }

  SfuTrackResult _trackResult(String publisherSession, String trackName) {
    final error = failingSubscriptions[trackName];
    if (error != null) {
      return SfuTrackResult(
        trackName: trackName,
        errorCode: error,
        errorDescription: 'fake failure',
      );
    }
    return SfuTrackResult(
      trackName: trackName,
      mid: receivingMids['$publisherSession|$trackName'] ?? 'mid-$trackName',
      status: 'active',
    );
  }

  @override
  Future<void> renegotiate({
    required String sessionId,
    required String sdpAnswer,
  }) async {
    _record('renegotiate', <String, dynamic>{
      'session_id': sessionId,
      'sdp_answer': sdpAnswer,
    });
    _maybeFail('renegotiate');
  }

  @override
  Future<SfuExchangeResult> closeTracks({
    required String sessionId,
    required List<String> mids,
    String? sdpOffer,
    bool force = false,
  }) async {
    _record('closeTracks', <String, dynamic>{
      'session_id': sessionId,
      'mids': mids,
      'sdp_offer': sdpOffer,
      'force': force,
    });
    _maybeFail('closeTracks');
    return const SfuExchangeResult(
      sdpAnswer: 'close-answer',
      tracks: <SfuTrackResult>[],
    );
  }

  /// 房间快照这一跳要花多久（模拟服务端被压住：真机上实测 2.7~30s）。
  ///
  /// 用途只有一个：验客户端的"服务端慢就退避"（回查 / 心跳不叠飞）。
  Duration? roomStateDelay;

  /// 心跳这一跳要花多久（同上）
  Duration? heartbeatDelay;

  @override
  Future<SfuRoomState> roomState({required String roomId}) async {
    _record('roomState', <String, dynamic>{'room_id': roomId});
    _maybeFail('roomState');
    final delay = roomStateDelay;
    if (delay != null) await Future<void>.delayed(delay);
    return snapshot;
  }

  /// 心跳回包：`heartbeatEpoch = 0` 表示"就报当前快照的版本号"
  int heartbeatEpoch = 0;
  int heartbeatMembers = 1;

  @override
  Future<SfuHeartbeat> heartbeat({required String roomId}) async {
    _record('heartbeat', <String, dynamic>{'room_id': roomId});
    _maybeFail('heartbeat');
    final delay = heartbeatDelay;
    if (delay != null) await Future<void>.delayed(delay);
    return SfuHeartbeat(
      epoch: heartbeatEpoch == 0 ? snapshot.epoch : heartbeatEpoch,
      memberCount: heartbeatMembers,
    );
  }

  /// `leave` 回包里「这一通结束了吗」（服务端在房间空了时只让一个人拿到
  /// `announce`，测试直接改这里就能造出"最后一个走的人"）
  SfuLeaveResult leaveResult = const SfuLeaveResult();

  @override
  Future<SfuLeaveResult> leave({
    required String roomId,
    required List<String> sessionIds,
    bool closing = false,
  }) async {
    _record('leave', <String, dynamic>{
      'room_id': roomId,
      'session_ids': sessionIds,
      'closing': closing,
    });
    _maybeFail('leave');
    return leaveResult;
  }

  /// 最近一次上报的静音态（`null` = 从没报过）
  bool? muted;

  @override
  Future<void> setMuted({required String roomId, required bool muted}) async {
    _record('setMuted', <String, dynamic>{'room_id': roomId, 'muted': muted});
    _maybeFail('setMuted');
    this.muted = muted;
  }

  /// 失败：结果未知（超时/5xx）→ 会话必须重建
  static SfuFailure unknownOutcome() =>
      SfuFailure.fromCode(SfuCodes.upstreamUnreachable, '请求超时', label: 'fake');

  /// 失败：明确被拒（会话还能用）
  static SfuFailure rejected() =>
      SfuFailure.fromCode(SfuCodes.sessionConflict, '并发提交被拒', label: 'fake');
}

/// 假 PeerConnection：记录动作顺序，并自称"连着"
class FakeSfuPeerConnection implements SfuPeerConnection {
  FakeSfuPeerConnection(this.id);

  final int id;
  final List<String> log = <String>[];

  /// 发布时给的 mid（默认按 track 名编）
  Map<String, String> midsForPublish = <String, String>{};

  /// 这些 mid 拿不到 close 用的 offer（模拟 transceiver 已经没了）
  Set<String> closeWithoutOffer = <String>{};

  String lastAnswer = '';
  bool closed = false;

  /// 这条连接"连不连得上"（false = ICE 一直没通，等超时）
  bool connects = true;

  /// `waitConnected` 被问过几次（契约：应用完 answer 要等到连通）
  int waitConnectedCalls = 0;

  final StreamController<SfuIncomingTrack> _incoming =
      StreamController<SfuIncomingTrack>.broadcast();

  @override
  Stream<SfuIncomingTrack> get incomingTracks => _incoming.stream;

  /// 这一刻的远端音频能量（`mid → 0~1`）：测试直接改它，房间那边会算出"谁在说话"
  Map<String, double> audioLevelsByMid = <String, double>{};

  @override
  Future<Map<String, double>> audioLevels() async =>
      Map<String, double>.of(audioLevelsByMid);

  /// 这一刻**接收侧视频**的收流计数（`mid → 计数`）：测试自己往前推。
  /// 不动它 = 那一路收不到新帧（房间的健康检查会把它放下来）。
  Map<String, int> videoCountersByMid = <String, int>{};

  /// `inboundVideoCounters()` 被问过几次（能钉住"没人在共享时不问"）
  int videoCounterCalls = 0;

  @override
  Future<Map<String, int>> inboundVideoCounters() async {
    videoCounterCalls += 1;
    return Map<String, int>.of(videoCountersByMid);
  }

  /// 模拟 SFU 推来一路远端 track（`mid` 是接收侧的 mid）
  void emit(String mid, {String kind = 'audio', Object? stream}) =>
      _incoming.add(
        SfuIncomingTrack(mid: mid, kind: kind, stream: stream ?? 'stream-$mid'),
      );

  @override
  Future<bool> waitConnected(Duration timeout) async {
    waitConnectedCalls += 1;
    return connects;
  }

  @override
  Future<SfuPreparedSdp> preparePublish(List<SfuLocalTrack> tracks) async {
    log.add('preparePublish(${tracks.map((t) => t.name).join(',')})');
    return SfuPreparedSdp(
      sdp: 'local-offer-$id',
      mids: <String, String>{
        for (final track in tracks)
          track.name: midsForPublish[track.name] ?? 'mid-${track.name}-$id',
      },
    );
  }

  @override
  Future<void> applyAnswer(String answerSdp) async {
    lastAnswer = answerSdp;
    log.add('applyAnswer');
  }

  @override
  Future<String> answerSfuOffer(String offerSdp) async {
    log.add('answerSfuOffer');
    return 'local-answer-$id';
  }

  @override
  Future<SfuPreparedSdp?> prepareClose(List<String> mids) async {
    log.add('prepareClose(${mids.join(',')})');
    if (mids.any(closeWithoutOffer.contains)) return null;
    return SfuPreparedSdp(sdp: 'close-offer-$id', mids: <String, String>{});
  }

  @override
  Future<void> applyCloseAnswer(String answerSdp) async {
    log.add('applyCloseAnswer');
  }

  /// `replaceTrackByName` 换得成吗（false = "本机没这条轨 / 没发布过"）
  bool replaceTrackSucceeds = true;

  /// 换成功的那几条轨（按名字，按调用顺序）
  final List<String> replacedTracks = <String>[];

  @override
  Future<bool> replaceTrackByName(String trackName) async {
    log.add('replaceTrackByName($trackName)');
    if (!replaceTrackSucceeds) return false;
    replacedTracks.add(trackName);
    return true;
  }

  @override
  Future<void> close() async {
    closed = true;
    log.add('close');
    await _incoming.close();
  }
}

/// 假本机媒体
class FakeSfuLocalMedia implements SfuLocalMedia {
  FakeSfuLocalMedia({this.supportsScreen = true});

  final bool supportsScreen;
  bool micStarted = false;
  bool permissionAsked = false;

  /// 用户有没有同意投屏（false = 拒了那个系统框）
  bool screenPermissionGranted = true;

  /// 取屏幕流的时候抛错（模拟用户同意、但取流还是失败）
  bool screenStartFails = false;

  /// 可选的跨层调用轨迹（与 `FakeCallKeepAlive.trace` 用同一条列表）：
  /// 用来钉住「先授权 → 再升前台服务类型 → 最后取流」这个**硬顺序**（Android 14）
  List<String>? trace;

  @override
  bool get supportsScreenShare => supportsScreen;

  @override
  Future<bool> requestScreenSharePermission() async {
    permissionAsked = true;
    trace?.add('media.permission');
    return supportsScreen && screenPermissionGranted;
  }

  @override
  bool screenSharing = false;
  bool micEnabled = true;
  bool disposed = false;

  @override
  Future<void> startMicrophone() async {
    trace?.add('media.startMicrophone');
    micStarted = true;
  }

  /// 最近一次取屏幕流时用户选的那个源（桌面才有；安卓是 null）
  String? screenSourceId;
  int screenStartCalls = 0;

  @override
  Future<void> startScreen({String? sourceId, bool withAudio = false}) async {
    trace?.add('media.startScreen');
    screenStartCalls += 1;
    screenSourceId = sourceId;
    screenWithAudio = withAudio;
    if (!supportsScreen) {
      throw StateError('这台设备没有屏幕采集');
    }
    if (screenStartFails) {
      throw StateError('取屏幕流失败');
    }
    screenSharing = true;
  }

  @override
  Future<void> stopScreen() async {
    screenSharing = false;
  }

  @override
  Future<void> setMicrophoneEnabled(bool enabled) async {
    micEnabled = enabled;
  }

  /// 音频路由（免提/听筒）：null = 没被调过
  bool? speakerOn;

  /// 每一次切路由都记下来（顺序断言用；不进 [trace] —— 那条列表专门盯
  /// 「先授权 → 再升前台服务类型 → 最后取流」那个硬顺序）
  final List<bool> speakerChanges = <bool>[];

  /// 切路由的时候抛错（真机上偶尔会失败）
  bool speakerFails = false;

  @override
  Future<void> setSpeakerEnabled(bool enabled) async {
    speakerChanges.add(enabled);
    if (speakerFails) throw StateError('切音频路由失败');
    speakerOn = enabled;
  }

  /// 上一次 `startScreen` **请求**里要不要电脑的声音（S12.39）。
  /// 用来钉"用户勾了那座开关，有没有一路传到底层的采集"。
  bool screenWithAudio = false;

  /// 模拟"用户勾了、但选中的源根本没有声音"（例如一个静音的窗口）：
  /// 这时 [screenWithAudio] 照样记成 `true`，但抓到的流里**没有**音频轨。
  bool screenCaptureDropsAudio = false;

  @override
  List<SfuLocalTrack> get publishableTracks => <SfuLocalTrack>[
    const SfuLocalTrack(name: 'mic', kind: 'audio'),
    if (screenSharing) const SfuLocalTrack(name: 'screen', kind: 'video'),
    if (screenSharing && screenWithAudio && !screenCaptureDropsAudio)
      const SfuLocalTrack(name: 'screen-audio', kind: 'audio'),
  ];

  /// 「本机屏幕轨换了」的监听方（房间把新轨挂回同一个 mid）
  final Set<VoidCallback> screenTrackListeners = <VoidCallback>{};

  @override
  void addScreenTrackReplacedListener(VoidCallback listener) =>
      screenTrackListeners.add(listener);

  @override
  void removeScreenTrackReplacedListener(VoidCallback listener) =>
      screenTrackListeners.remove(listener);

  /// 模拟「被共享的窗口最小化又回来 → 本机重建了采集」：
  /// 真的那边会换上新的视频/音频轨再叫一声，这里只叫一声（轨换没换由断言
  /// `replaceTrackByName` 那一边负责）。
  void simulateScreenTrackReplaced() {
    for (final listener in screenTrackListeners.toList(growable: false)) {
      listener();
    }
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    screenSharing = false;
    screenTrackListeners.clear();
  }
}

/// 造连接的工厂：每次调用给一条新的，并记下来（断言"重建时换了新连接"）
class FakeSfuConnections {
  final List<FakeSfuPeerConnection> created = <FakeSfuPeerConnection>[];

  /// 逐条指定"这条连不连得上"（索引从 0 开始）；不够用时看 [connectsByDefault]
  final List<bool> connects = <bool>[];

  bool connectsByDefault = true;

  /// 发布会话用的那条（进房间时建的第一条）
  FakeSfuPeerConnection get publish => created.first;

  /// 接收会话用的那条（拉快照时建的第二条）
  FakeSfuPeerConnection get receive => created.last;

  SfuPeerConnection call() {
    final index = created.length;
    final pc = FakeSfuPeerConnection(
      index + 1,
    )..connects = index < connects.length ? connects[index] : connectsByDefault;
    created.add(pc);
    return pc;
  }
}

/// 拼一个房间快照里的成员
///
/// [muted] = 他的麦克风**静音中**（`mic` 那条发布还在，只是本端不再发包）。
/// 默认 `false` 就是"没静音"，所以老用例一个都不用改。
SfuRoomMember member(
  String userId,
  String sessionId,
  List<String> tracks, {
  bool muted = false,
}) => SfuRoomMember(
  userId: userId,
  sessionId: sessionId,
  tracks: tracks,
  muted: muted,
);
