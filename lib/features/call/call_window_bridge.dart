/// 通话独立窗口（2026-10-04）两侧共用的一点点约定。
///
/// 用户原话：「请将通话做到新开一个独立窗口」。桌面这颗窗口与文章/网页那几颗
/// 有个本质区别：**通话不只是界面**。`MediaStream`（以及它背后那份原生
/// `RTCPeerConnection`）过不了引擎边界，所以媒体引擎必须搬到拿画面的那颗引擎里
/// —— 也就是通话窗。
///
/// 于是这条链切成了两半：
///
/// * **主窗口**：状态机、信令（WS）、通话记录依旧在这儿（它们只有这一份），
///   界面上的动作（接听/挂断/静音/开关摄像头/大小窗互换）也从这儿下发；
/// * **通话窗**：真媒体引擎（建连接、取麦克风/摄像头、渲染画面）+ 一块微信 PC
///   版式的界面（`call_desktop_page.dart`）。
///
/// 两条线：
///
/// ```
/// 主窗口 --状态 / 媒体指令--> gracelink/window/call   （通话窗注册）
/// 通话窗 --媒体事件 / 动作--> gracelink/call/events   （主窗口注册）
/// ```
///
/// 为什么是「媒体指令」而不是把媒体引擎整个搬过来：见
/// `call_window_media_engine.dart` 里那份代理。
library;

import '../../domain/call/call_controller.dart';
import '../../domain/call/call_diagnostics.dart';
import '../../domain/call/call_machine.dart';
import '../../domain/call/call_signal.dart';

/// 主窗口 → 通话窗（与其它窗口同一套命名：`gracelink/window/<kind>`）
const String callWindowChannelName = 'gracelink/window/call';

/// 通话窗 → 主窗口
const String callWindowEventChannelName = 'gracelink/call/events';

// ------------------------------------------------------- 主窗口叫通话窗做的事

/// 打个招呼（判断那颗窗还活着没用 —— ✕ 是真销毁，幽灵窗口见
/// `desktop_window_service.dart::_findAlive`）
const String callWindowPing = 'ping';

/// 界面状态换了（`CallViewState` 的可序列化形态，见 [callStatePayload]）
const String callWindowState = 'state';

/// 媒体指令：`{'method': <CallMediaEngine 上的方法名>, 'args': {...}}`
const String callWindowMedia = 'media';

/// 这通电话完了 —— 通话窗自己把窗关掉（关窗只有窗口自己做得干净）
const String callWindowBye = 'bye';

// ------------------------------------------------------- 通话窗告诉主窗口的事

/// 媒体事件（[callEventLocalStream] 那几样）
const String callWindowEvent = 'media_event';

/// 界面上点了一下（接听 / 挂断 / 静音 / 摄像头 / 大小窗互换）
const String callWindowAction = 'action';

/// 本机流取到了（画面已经在通话窗里渲染）
const String callEventLocalStream = 'local_stream';

/// 对方的流收到了
const String callEventRemoteStream = 'remote_stream';

/// 收到一条本机 ICE 候选（老端 `onicecandidate`）
const String callEventIceCandidate = 'ice_candidate';

/// ICE 连通
const String callEventConnected = 'connected';

/// 连接失败
const String callEventFailed = 'connection_failed';

/// 通话窗刚起来时自报家底：屏幕共享支不支持、有没有摄像头、实际用的 ICE 列表
const String callEventCapabilities = 'capabilities';

/// 通话窗那条线挂上了，问主窗口要一次当前状态。
///
/// 为什么不能只靠主窗口主动推：**被叫**那一屏中间没有计时器，状态可能就变那么
/// 一次，而那次推送十有八九发生在窗口还没起来的空档里（新引擎冷启动要几百毫秒）。
/// 所以窗口一挂上线就自己伸手要一次。
const String callEventReady = 'ready';

/// 界面状态编成一份能过通道的东西（主窗口 → 通话窗）。
///
/// 逐个字段写死而不是 `jsonEncode(view)`：一来 `CallViewState` 里有枚举与
/// `CallSession`（不是 JSON 原生），二来**这份字段表就是两侧的契约**，
/// 多一个少一个都在这里看得见。
Map<String, dynamic> callStatePayload(CallViewState view) => <String, dynamic>{
  'phase': view.session.phase.name,
  'peerId': view.session.peerId,
  'peerName': view.session.peerName,
  'peerAvatar': view.session.peerAvatar,
  'video': view.session.isVideo,
  'isCaller': view.session.isCaller,
  'callTime': view.session.callTime,
  'microphoneEnabled': view.microphoneEnabled,
  'cameraEnabled': view.cameraEnabled,
  'hasLocalStream': view.hasLocalStream,
  'hasRemoteStream': view.hasRemoteStream,
  'remoteBig': view.remoteBig,
  'canShareScreen': view.canShareScreen,
  'screenSharing': view.screenSharing,
};

/// 通话窗把那份状态还原成界面认识的东西。
///
/// 认不出来的阶段按 `idle` 处理（那颗窗随后就关掉了）——**界面不能因为一条
/// 报文没看懂就崩**。
CallViewState callViewStateFrom(Map<String, dynamic> payload) => CallViewState(
  session: CallSession(
    phase: _phaseOf(payload['phase']),
    peerId: (payload['peerId'] as String?) ?? '',
    peerName: (payload['peerName'] as String?) ?? '',
    peerAvatar: (payload['peerAvatar'] as String?) ?? '',
    type: payload['video'] == true ? CallType.video : CallType.voice,
    isCaller: payload['isCaller'] == true,
    callTime: (payload['callTime'] as num?)?.toInt() ?? 0,
  ),
  microphoneEnabled: payload['microphoneEnabled'] != false,
  cameraEnabled: payload['cameraEnabled'] != false,
  hasLocalStream: payload['hasLocalStream'] == true,
  hasRemoteStream: payload['hasRemoteStream'] == true,
  remoteBig: payload['remoteBig'] == true,
  canShareScreen: payload['canShareScreen'] == true,
  screenSharing: payload['screenSharing'] == true,
);

/// 一次媒体统计编成一份能过通道的东西（诊断面板用；字段与
/// `CallMediaSample` 一一对应）。
Map<String, dynamic> callSamplePayload(CallMediaSample sample) =>
    <String, dynamic>{
      'roundTripMs': sample.roundTripMs,
      'localCandidateType': sample.localCandidateType,
      'remoteCandidateType': sample.remoteCandidateType,
      'protocol': sample.protocol,
      'bytesSent': sample.bytesSent,
      'bytesReceived': sample.bytesReceived,
      'packetsLost': sample.packetsLost,
      'jitterMs': sample.jitterMs,
      'framesPerSecond': sample.framesPerSecond,
    };

/// 反过来：认不出来的字段按空处理（统计是排查用的，宁可少一项也不能抛）。
CallMediaSample callSampleFrom(Map<String, dynamic> payload) => CallMediaSample(
  roundTripMs: (payload['roundTripMs'] as num?)?.toInt(),
  localCandidateType: (payload['localCandidateType'] as String?) ?? '',
  remoteCandidateType: (payload['remoteCandidateType'] as String?) ?? '',
  protocol: (payload['protocol'] as String?) ?? '',
  bytesSent: (payload['bytesSent'] as num?)?.toInt() ?? 0,
  bytesReceived: (payload['bytesReceived'] as num?)?.toInt() ?? 0,
  packetsLost: (payload['packetsLost'] as num?)?.toInt() ?? 0,
  jitterMs: (payload['jitterMs'] as num?)?.toInt() ?? 0,
  framesPerSecond: (payload['framesPerSecond'] as num?)?.toInt() ?? 0,
);

CallPhase _phaseOf(Object? raw) {
  for (final phase in CallPhase.values) {
    if (phase.name == raw) return phase;
  }
  return CallPhase.idle;
}
