/// 通话诊断（安卓端「打不通 / 黑屏 / 没声音」的第一排查工具）。
///
/// 为什么要有它：连不上的原因只有三类，界面上长得一模一样（都在「正在接通…」）：
/// * **没有候选**：ICE 配置不合法（站点那栏没带 `stun:` 前缀就是这个）或权限没给；
/// * **只有 host 候选**：STUN 没起作用，两边一出门就找不到对方；
/// * **有 srflx（公网）候选还是连不上**：典型的对称 NAT，**这条路必须走 TURN**，
///   没部署 TURN 就永远打不通（见规划书风险 #1）。
///
/// 有了这份记录，上面三条一眼就能分开；没有它只能靠猜。
///
/// 分层：本文件是**纯逻辑**（不碰平台通道、不碰文件），所以能整体跑单测：
/// * [iceCandidateKind] / [parseCallMediaSample]：把原始数据变成可读的东西；
/// * [CallDiagnosticsRecorder]：把一通电话里发生的事按时间线记下来；
/// * [CallDiagnostics.summary]：导出成一段可以贴给别人的纯文本。
///
/// 面板与文件落盘分别在 `features/call/call_diagnostics_sheet.dart` 与
/// `core/util/diagnostics_file.dart`。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show StatsReport;

import 'call_duration.dart';

/// ICE 候选类型（`candidate` 字符串里那个 `typ xxx`）
enum IceCandidateKind {
  /// 本机地址（同一个局域网里能直接用）
  host,

  /// 服务器反射地址（STUN 问出来的公网地址）—— 能拿到它说明 STUN 是通的
  srflx,

  /// 对端反射地址（少见，由对端发现）
  prflx,

  /// TURN 中转地址 —— 能拿到它说明 TURN 是通的（连通性最稳但费服务器带宽）
  relay,

  /// 认不出来（格式变了 / 服务端改过报文）
  unknown;

  /// 候选字符串里的写法（`host` / `srflx` / `relay` / `prflx`）
  String get label => name;
}

/// 从候选字符串里读出类型。
///
/// 形如（老端/浏览器原样发过来的）：
/// `candidate:842163049 1 udp 1677729535 203.0.113.7 54321 typ srflx raddr 0.0.0.0 rport 0`
IceCandidateKind iceCandidateKind(String raw) {
  final match = RegExp(r'\btyp\s+(\w+)').firstMatch(raw);
  switch (match?.group(1)?.toLowerCase()) {
    case 'host':
      return IceCandidateKind.host;
    case 'srflx':
      return IceCandidateKind.srflx;
    case 'prflx':
      return IceCandidateKind.prflx;
    case 'relay':
      return IceCandidateKind.relay;
    default:
      return IceCandidateKind.unknown;
  }
}

/// 一次 `getStats` 采样里我们关心的那些值（拿不到的就是 null / 0）。
///
/// 为什么要「关心的一部分」而不是全量：全量有上百个键，面板上没人看，
/// 导出报告也会变成噪音。真要更细的，`getStats` 原始 JSON 在
/// `flutter_webrtc` 侧随时能打。
@immutable
class CallMediaSample {
  const CallMediaSample({
    this.roundTripMs,
    this.localCandidateType = '',
    this.remoteCandidateType = '',
    this.protocol = '',
    this.bytesSent = 0,
    this.bytesReceived = 0,
    this.packetsLost = 0,
    this.jitterMs = 0,
    this.framesPerSecond = 0,
    this.videoFramesSent = 0,
    this.videoFramesReceived = 0,
    this.videoFramesDecoded = 0,
    this.videoBytesSent = 0,
    this.videoBytesReceived = 0,
  });

  /// 选中的候选对的往返延迟（毫秒）
  final int? roundTripMs;

  /// 选中候选对的本地/对端候选类型（`host` / `srflx` / `relay`）
  final String localCandidateType;
  final String remoteCandidateType;

  /// `udp` / `tcp`
  final String protocol;

  final int bytesSent;
  final int bytesReceived;

  /// 收到的包里丢了多少（对端的重传/丢包统计，方向是从对方到本机）
  final int packetsLost;

  /// 抖动（毫秒）
  final int jitterMs;

  /// 视频帧率（语音通话是 0）
  final int framesPerSecond;

  /// 视频那一路**自己发出去**了多少帧 / 收进来多少帧、解出来多少帧（S12.34）。
  ///
  /// 为什么要单列：真机上「对方看不到画面」时，光看 fps 分不清是**没发出去**、
  /// **没收到**、还是**收到了解不出来**。三个数一摆，方向立刻清楚：
  /// * 本机 `videoFramesSent` 不动 → 发送侧的问题（轨道没挂上 / 没协商进 m-line）；
  /// * 对端 `videoFramesReceived` 不动 → 根本没到（网络 / 协商）；
  /// * 收到了但 `videoFramesDecoded` 不涨 → 解码器那一档的问题。
  ///
  /// 语音通话里这几个都是 0。
  final int videoFramesSent;
  final int videoFramesReceived;
  final int videoFramesDecoded;
  final int videoBytesSent;
  final int videoBytesReceived;

  /// 视频收发那一行（日志与诊断面板共用一句，省得两处对不上）
  String get videoFlowSummary =>
      'video sent=$videoFramesSent 帧/${_kb(videoBytesSent)}·'
      'recv=$videoFramesReceived 帧/decoded=$videoFramesDecoded 帧/'
      '${_kb(videoBytesReceived)}';

  static String _kb(int bytes) => '${(bytes / 1024).round()}KB';

  /// 这份采样里有没有有用的东西（全空说明 `getStats` 什么都没给）
  bool get isEmpty =>
      roundTripMs == null &&
      bytesSent == 0 &&
      bytesReceived == 0 &&
      localCandidateType.isEmpty &&
      remoteCandidateType.isEmpty;

  /// 走没走 TURN 中转
  bool get relayed =>
      localCandidateType == 'relay' || remoteCandidateType == 'relay';

  @override
  String toString() =>
      'CallMediaSample(rtt=${roundTripMs}ms, pair=$localCandidateType→'
      '$remoteCandidateType/$protocol, sent=$bytesSent, recv=$bytesReceived, '
      'lost=$packetsLost, jitter=${jitterMs}ms, fps=$framesPerSecond, '
      '$videoFlowSummary)';
}

/// 把 `getStats()` 的报告解析成 [CallMediaSample]。
///
/// 保守解析：**认不出来就返回空值，绝不抛**（统计报表的字段名各平台版本有差异，
/// 一个诊断工具把通话搞崩就本末倒置了）。
CallMediaSample parseCallMediaSample(List<StatsReport> reports) {
  final byId = <String, StatsReport>{
    for (final report in reports)
      if (report.id.isNotEmpty) report.id: report,
  };

  // ---- 选中/成功的候选对（优先 `selected`，没有就看最后一条 `succeeded`）----
  Map<dynamic, dynamic>? pair;
  for (final report in reports) {
    if (report.type != 'candidate-pair') continue;
    final values = report.values;
    if (_asBool(values['selected'])) {
      pair = values;
      break;
    }
    if (_asText(values['state']) == 'succeeded') pair = values;
  }

  String candidateType(Object? id) =>
      _asText(byId[_asText(id)]?.values['candidateType']);

  final localType = candidateType(pair?['localCandidateId']);
  final remoteType = candidateType(pair?['remoteCandidateId']);

  // ---- 收发字节 / 丢包 / 抖动 / 帧率 ----
  var bytesSent = 0;
  var bytesReceived = 0;
  var packetsLost = 0;
  var jitterMs = 0;
  var fps = 0;
  var videoFramesSent = 0;
  var videoFramesReceived = 0;
  var videoFramesDecoded = 0;
  var videoBytesSent = 0;
  var videoBytesReceived = 0;
  for (final report in reports) {
    final values = report.values;
    switch (report.type) {
      case 'outbound-rtp':
        bytesSent += _asInt(values['bytesSent']);
        if (_isVideo(values)) {
          if (_asInt(values['framesPerSecond']) > fps) {
            fps = _asInt(values['framesPerSecond']);
          }
          videoFramesSent += _asInt(values['framesSent']);
          videoBytesSent += _asInt(values['bytesSent']);
        }
      case 'inbound-rtp':
        bytesReceived += _asInt(values['bytesReceived']);
        packetsLost += _asInt(values['packetsLost']);
        jitterMs += _msFromSeconds(values['jitter']);
        if (_isVideo(values)) {
          if (_asInt(values['framesPerSecond']) > fps) {
            fps = _asInt(values['framesPerSecond']);
          }
          videoFramesReceived += _asInt(values['framesReceived']);
          videoFramesDecoded += _asInt(values['framesDecoded']);
          videoBytesReceived += _asInt(values['bytesReceived']);
        }
      case 'remote-inbound-rtp':
        // 对端回报「我这边丢了你的包」——上行丢包只有这里看得到
        packetsLost += _asInt(values['packetsLost']);
      default:
        break;
    }
  }

  return CallMediaSample(
    roundTripMs: pair == null
        ? null
        : _msFromSeconds(pair['currentRoundTripTime']),
    localCandidateType: localType,
    remoteCandidateType: remoteType,
    protocol: _asText(pair?['protocol']),
    bytesSent: bytesSent,
    bytesReceived: bytesReceived,
    packetsLost: packetsLost,
    jitterMs: jitterMs,
    framesPerSecond: fps,
    videoFramesSent: videoFramesSent,
    videoFramesReceived: videoFramesReceived,
    videoFramesDecoded: videoFramesDecoded,
    videoBytesSent: videoBytesSent,
    videoBytesReceived: videoBytesReceived,
  );
}

/// 时间：libwebrtc 的统计里 RTT / jitter 都是**秒**（浮点），这里换成毫秒。
///
/// 但有些平台版本（或插件的 Dart 侧）已经换算过一遍，所以带一个启发式：
/// **小于 100 以为是秒**（100 秒的 RTT 没有意义），大于等于 100 就当成毫秒。
int _msFromSeconds(Object? value) {
  if (value is num) {
    final raw = value.toDouble();
    final ms = raw < 100 ? (raw * 1000).round() : raw.round();
    return ms.isNegative ? 0 : ms;
  }
  if (value is String) {
    final parsed = double.tryParse(value);
    return parsed == null ? 0 : _msFromSeconds(parsed);
  }
  return 0;
}

bool _isVideo(Map<dynamic, dynamic> values) {
  final kind = _asText(values['kind']);
  if (kind.isNotEmpty) return kind == 'video';
  return _asText(values['mediaType']) == 'video';
}

bool _asBool(Object? value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) return value.toLowerCase() == 'true' || value == '1';
  return false;
}

int _asInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}

String _asText(Object? value) => value?.toString() ?? '';

/// 时间线上的一条记录
@immutable
class CallDiagnosticsEvent {
  const CallDiagnosticsEvent({required this.label, required this.at});

  /// 人话（「取本机媒体」「收到对方候选」…）
  final String label;
  final DateTime at;

  @override
  String toString() => label;
}

/// 一通电话的全部诊断信息（不可变快照，界面直接渲染它）
@immutable
class CallDiagnostics {
  const CallDiagnostics({
    this.startedAt,
    this.video = false,
    this.caller = true,
    this.peer = '',
    this.events = const <CallDiagnosticsEvent>[],
    this.localCandidates = const <IceCandidateKind, int>{},
    this.remoteCandidates = const <IceCandidateKind, int>{},
    this.signals = const <String, int>{},
    this.failedSignals = const <String, int>{},
    this.latestSample,
    this.upstreamKbps,
    this.downstreamKbps,
    this.rttMinMs,
    this.rttMaxMs,
    this.sampleCount = 0,
    this.iceServers = const <String>[],
    this.hint = '',
    this.connected = false,
  });

  /// 还没开始任何通话
  const CallDiagnostics.empty() : this();

  /// 这通电话是什么时候开始的（null = 还没开始）
  final DateTime? startedAt;

  final bool video;

  /// 主叫还是被叫
  final bool caller;

  /// 对端（诊断记录里带上，导出后不用猜是谁）
  final String peer;

  final List<CallDiagnosticsEvent> events;

  /// 本机/对方候选各类型收到的条数（**只数不存**：一通电话几十条，存下来没意义）
  final Map<IceCandidateKind, int> localCandidates;
  final Map<IceCandidateKind, int> remoteCandidates;

  /// 发出去的信令条数（按事件名）与发送失败的条数
  final Map<String, int> signals;
  final Map<String, int> failedSignals;

  /// 最近一次 `getStats` 采样
  final CallMediaSample? latestSample;

  /// 上下行码率（kbps，由两次采样的字节差算出来）
  final double? upstreamKbps;
  final double? downstreamKbps;

  final int? rttMinMs;
  final int? rttMaxMs;

  /// 采样次数
  final int sampleCount;

  /// 这次通话实际用的 ICE 服务器（诊断配置问题用，账号密码只显示有没有）
  final List<String> iceServers;

  /// 一句人话结论（见 `_diagnoseHint`），面板上最上面那行
  final String hint;

  /// ICE 是否已连通。
  ///
  /// 面板那行结论的**配色看它**，不要去匹配 [hint] 的文案：
  /// 以前是 `hint.contains('已连通')`，哪天改个措辞（或者以后要翻译）
  /// 「绿=连上、橙=没连上」这套颜色就会静默失效，而且不会有任何报错。
  final bool connected;

  bool get isEmpty => startedAt == null;

  int get localCandidateCount =>
      localCandidates.values.fold(0, (sum, count) => sum + count);

  int get remoteCandidateCount =>
      remoteCandidates.values.fold(0, (sum, count) => sum + count);

  bool get hasRelay =>
      (localCandidates[IceCandidateKind.relay] ?? 0) > 0 ||
      (remoteCandidates[IceCandidateKind.relay] ?? 0) > 0;

  /// 导出文本（面板的「复制」与「导出日志」都是它）
  String get summary => buildCallSummary(this);

  @override
  String toString() =>
      'CallDiagnostics(${caller ? '主叫' : '被叫'}, events=${events.length}, '
      'local=$localCandidateCount, remote=$remoteCandidateCount)';
}

/// 采集器：按顺序把通话里发生的事记下来，随时可以 [snapshot]。
///
/// 不做任何判断（连通与否是状态机的事），只负责「记」与「算结论」。
class CallDiagnosticsRecorder {
  CallDiagnosticsRecorder({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;

  DateTime? _startedAt;
  bool _video = false;
  bool _caller = true;
  String _peer = '';
  final List<CallDiagnosticsEvent> _events = <CallDiagnosticsEvent>[];
  final Map<IceCandidateKind, int> _local = <IceCandidateKind, int>{};
  final Map<IceCandidateKind, int> _remote = <IceCandidateKind, int>{};
  final Map<String, int> _signals = <String, int>{};
  final Map<String, int> _failedSignals = <String, int>{};
  CallMediaSample? _latestSample;
  DateTime? _lastSampleAt;
  int _lastBytesSent = 0;
  int _lastBytesReceived = 0;
  double? _upstreamKbps;
  double? _downstreamKbps;
  int? _rttMin;
  int? _rttMax;
  int _sampleCount = 0;
  bool _connected = false;
  final List<String> _iceServers = <String>[];

  /// 时间线最多留这么多条（长通话里事件可能很多，导出的东西要保持可读）
  static const int maxEvents = 200;

  bool _finished = false;

  /// 这通电话还在记（[begin] 之后、[finish] 之前）。
  ///
  /// 控制器用它决定「会话一起来就 `begin`」（避免同一通电话记两遍）：
  /// 结束了就不再是记录中，但**快照留着**，打完还能在「设置 → 通话诊断」里回看。
  bool get isRecording => _startedAt != null && !_finished;

  /// 开始记录一通电话（`CallController.start` / 收到来电时调）。
  void begin({
    required bool video,
    required bool caller,
    required String peer,
    List<String> iceServers = const <String>[],
  }) {
    _startedAt = _clock();
    _video = video;
    _caller = caller;
    _peer = peer;
    _events.clear();
    _local.clear();
    _remote.clear();
    _signals.clear();
    _failedSignals.clear();
    _latestSample = null;
    _lastSampleAt = null;
    _lastBytesSent = 0;
    _lastBytesReceived = 0;
    _upstreamKbps = null;
    _downstreamKbps = null;
    _rttMin = null;
    _rttMax = null;
    _sampleCount = 0;
    _connected = false;
    _finished = false;
    _iceServers
      ..clear()
      ..addAll(iceServers);
    event(caller ? '开始拨号' : '收到来电');
  }

  /// 补记一份 ICE 列表。
  ///
  /// 为什么需要：`begin` 在**会话一起来**就调了，而「这条连接实际用了哪些
  /// 服务器」要等建连接那一刻才知道 —— 服务端签发的 TURN 凭据（S6.9）
  /// 就是在那一步才并进来的。空列表=没变化，直接忽略（免得把已有记录擦掉）。
  void updateIceServers(List<String> servers) {
    if (servers.isEmpty) return;
    _iceServers
      ..clear()
      ..addAll(servers);
  }

  /// 记一条时间线事件。还没 `begin` 就忽略（避免别的调用把时间线搅乱）。
  void event(String label) {
    final startedAt = _startedAt;
    if (startedAt == null) return;
    _events.add(CallDiagnosticsEvent(label: label, at: _clock()));
    if (_events.length > maxEvents) _events.removeAt(0);
  }

  /// 发出了一条信令（成功与否都先计一次）
  void signalSent(String event) {
    _signals[event] = (_signals[event] ?? 0) + 1;
  }

  /// 信令发失败了（弱网下「关键信令丢一条」就是靠这个看出来）
  void signalFailed(String name, Object error) {
    _failedSignals[name] = (_failedSignals[name] ?? 0) + 1;
    event('$name 发送失败：$error');
  }

  /// 一条信令正在**重试**（只进时间线，不动计数）。
  ///
  /// 计数口径保持「一条信令 = 一次」：[signalSent] 数的是想要发出去多少条，
  /// [signalFailed] 数的是最后没发出去的多少条。重试只是过程，
  /// 如果算进计数，面板上那句「信令：iceCandidate 15」就会变得不可解释。
  void signalRetried(String name, int attempt, Object error) {
    event('$name 第 $attempt 次未发出，重试：$error');
  }

  /// 本机收到（收集到）一条候选
  void localCandidate(String candidate) {
    final kind = iceCandidateKind(candidate);
    _local[kind] = (_local[kind] ?? 0) + 1;
  }

  /// 对方的候选
  void remoteCandidate(String candidate) {
    final kind = iceCandidateKind(candidate);
    _remote[kind] = (_remote[kind] ?? 0) + 1;
  }

  /// ICE 连通 / 断掉 / 失败（控制器从媒体层回调里转进来）
  void setConnected(bool connected) {
    if (_connected == connected) return;
    _connected = connected;
    event(connected ? 'ICE 已连通' : 'ICE 连接中断');
  }

  /// 一次 `getStats` 采样：更新码率（用两次采样的字节差）与 RTT 区间
  void sample(CallMediaSample sample) {
    final now = _clock();
    if (sample.bytesSent > 0 || sample.bytesReceived > 0) {
      final last = _lastSampleAt;
      if (last != null) {
        final seconds = now.difference(last).inMilliseconds / 1000;
        if (seconds > 0) {
          _upstreamKbps =
              (sample.bytesSent - _lastBytesSent) * 8 / 1000 / seconds;
          _downstreamKbps =
              (sample.bytesReceived - _lastBytesReceived) * 8 / 1000 / seconds;
        }
      }
      _lastSampleAt = now;
      _lastBytesSent = sample.bytesSent;
      _lastBytesReceived = sample.bytesReceived;
    }
    final rtt = sample.roundTripMs;
    if (rtt != null && rtt > 0) {
      _rttMin = _rttMin == null ? rtt : (rtt < _rttMin! ? rtt : _rttMin);
      _rttMax = _rttMax == null ? rtt : (rtt > _rttMax! ? rtt : _rttMax);
    }
    _latestSample = sample;
    _sampleCount += 1;
  }

  /// 当前快照（界面 watch 它）
  CallDiagnostics snapshot() {
    final sample = _latestSample;
    return CallDiagnostics(
      startedAt: _startedAt,
      video: _video,
      caller: _caller,
      peer: _peer,
      events: List<CallDiagnosticsEvent>.unmodifiable(_events),
      localCandidates: Map<IceCandidateKind, int>.unmodifiable(_local),
      remoteCandidates: Map<IceCandidateKind, int>.unmodifiable(_remote),
      signals: Map<String, int>.unmodifiable(_signals),
      failedSignals: Map<String, int>.unmodifiable(_failedSignals),
      latestSample: sample,
      upstreamKbps: _upstreamKbps,
      downstreamKbps: _downstreamKbps,
      rttMinMs: _rttMin,
      rttMaxMs: _rttMax,
      sampleCount: _sampleCount,
      iceServers: List<String>.unmodifiable(_iceServers),
      connected: _connected,
      hint: _diagnoseHint(
        startedAt: _startedAt,
        connected: _connected,
        local: _local,
        sample: sample,
      ),
    );
  }

  /// 结束这通电话时记一条（导出时一眼看出时长）
  void finish({int callTimeSeconds = 0}) {
    if (_startedAt == null || _finished) return;
    _finished = true;
    event(
      callTimeSeconds > 0
          ? '通话结束（时长 ${formatCallDuration(callTimeSeconds)}）'
          : '通话结束',
    );
  }
}

/// 一句人话结论 —— 这个面板最值钱的一行。
///
/// 四种「连不上」的原因在界面上长得一样，这里把它们分开：
/// 没候选 / 只有本机地址 / 有公网地址（缺 TURN） / 连上了但走中转。
String _diagnoseHint({
  required DateTime? startedAt,
  required bool connected,
  required Map<IceCandidateKind, int> local,
  required CallMediaSample? sample,
}) {
  if (startedAt == null) return '还没有通话记录';
  final host = local[IceCandidateKind.host] ?? 0;
  final srflx = local[IceCandidateKind.srflx] ?? 0;
  final relay = local[IceCandidateKind.relay] ?? 0;
  final total = host + srflx + relay + (local[IceCandidateKind.unknown] ?? 0);

  if (connected) {
    if (sample?.relayed ?? false) {
      return '已连通，但走的是 TURN 中转（直连没打成功，中转费服务器带宽）';
    }
    // 统计还没采到时只能看候选：本机只有 relay 说明必然走中转
    if (srflx == 0 && host == 0 && relay > 0) {
      return '已连通：本机只有 relay 候选，只能走 TURN 中转';
    }
    if (srflx > 0) return '已连通：点对点直连（P2P）';
    if (host > 0) return '已连通：局域网内直连（没拿到公网地址）';
    if (relay > 0) {
      return '已连通：收到了 relay 候选（到底走没走中转要看上面的选中候选对）';
    }
    return '已连通（没记录到本机候选，可能是统计被系统裁剪）';
  }

  if (total == 0) {
    return '一条本机候选都没有：ICE 服务器配置不合法（地址缺 stun:/turn: 前缀）'
        '或麦克风权限没给';
  }
  if (srflx == 0 && relay == 0) {
    return '只拿到本机地址（host）：STUN 没起作用 —— 检查站点那栏 ICE 地址、'
        '或当前网络把 STUN 挡了';
  }
  if (relay == 0) {
    return '有公网地址（srflx）还是连不上：典型的对称 NAT / 移动网络，'
        '这种必须部署 TURN 中转';
  }
  return '连 TURN 地址都没连上：检查 TURN 的地址、账号密码与证书';
}

/// 导出成一段纯文本（面板的「复制」/「导出日志」用的就是它）。
///
/// 刻意用中文 + 技术名词原样（ICE/TURN/RTT）：它是给排查问题的人看的，
/// 不进多语言包。
String buildCallSummary(CallDiagnostics diagnostics) {
  final startedAt = diagnostics.startedAt;
  final buffer = StringBuffer();
  if (startedAt == null) {
    buffer.writeln('通话诊断：还没有通话记录');
    return buffer.toString();
  }

  final kind = diagnostics.video ? '视频' : '语音';
  final role = diagnostics.caller ? '主叫' : '被叫';
  buffer.writeln(
    '通话诊断 · ${_stamp(startedAt)} · $kind / $role'
    '${diagnostics.peer.isEmpty ? '' : ' · 对端=${diagnostics.peer}'}',
  );

  buffer.writeln('时间线（相对开始）：');
  for (final event in diagnostics.events) {
    final offset = event.at.difference(startedAt).inMilliseconds / 1000;
    buffer.writeln('  +${offset.toStringAsFixed(2)}s  ${event.label}');
  }

  buffer.writeln('候选：');
  buffer.writeln(
    '  本机 ${diagnostics.localCandidateCount} 条：${_kindCounts(diagnostics.localCandidates)}',
  );
  buffer.writeln(
    '  对方 ${diagnostics.remoteCandidateCount} 条：${_kindCounts(diagnostics.remoteCandidates)}',
  );

  final sample = diagnostics.latestSample;
  buffer.writeln('连接：');
  if (sample == null) {
    buffer.writeln('  还没有统计采样（没连通时也可能一直没有）');
  } else {
    if (sample.localCandidateType.isNotEmpty ||
        sample.remoteCandidateType.isNotEmpty) {
      buffer.writeln(
        '  选中候选对：${sample.localCandidateType.isEmpty ? '?' : sample.localCandidateType}'
        ' → ${sample.remoteCandidateType.isEmpty ? '?' : sample.remoteCandidateType}'
        '${sample.protocol.isEmpty ? '' : '（${sample.protocol}）'}',
      );
    }
    if (sample.roundTripMs != null) {
      buffer.writeln(
        '  RTT ${sample.roundTripMs}ms'
        '${diagnostics.rttMinMs == null ? '' : '（最低 ${diagnostics.rttMinMs} / 最高 ${diagnostics.rttMaxMs}）'}',
      );
    }
    buffer.writeln(
      '  上行 ${_kbps(diagnostics.upstreamKbps)} / 下行 ${_kbps(diagnostics.downstreamKbps)}'
      '（采样 ${diagnostics.sampleCount} 次）',
    );
    buffer.writeln(
      '  丢包 ${sample.packetsLost} / 抖动 ${sample.jitterMs}ms'
      '${sample.framesPerSecond > 0 ? ' / ${sample.framesPerSecond}fps' : ''}',
    );
  }
  buffer.writeln('  结论：${diagnostics.hint}');

  if (diagnostics.iceServers.isNotEmpty) {
    buffer.writeln('ICE 服务器：');
    for (final server in diagnostics.iceServers) {
      buffer.writeln('  $server');
    }
  }

  final failed = diagnostics.failedSignals.isEmpty
      ? ''
      : '；失败 ${_counts(diagnostics.failedSignals)}';
  buffer.writeln('信令：${_counts(diagnostics.signals)}$failed');

  return buffer.toString();
}

String _kindCounts(Map<IceCandidateKind, int> counts) {
  if (counts.isEmpty) return '（无）';
  return <IceCandidateKind>[
        IceCandidateKind.host,
        IceCandidateKind.srflx,
        IceCandidateKind.relay,
        IceCandidateKind.prflx,
        IceCandidateKind.unknown,
      ]
      .where((kind) => (counts[kind] ?? 0) > 0)
      .map((kind) {
        return '${kind.label} ${counts[kind]}';
      })
      .join(' / ');
}

String _counts(Map<String, int> counts) => counts.isEmpty
    ? '（无）'
    : counts.entries.map((entry) => '${entry.key} ${entry.value}').join(' / ');

String _kbps(double? value) => value == null ? '—' : '${value.round()}kbps';

/// 时间戳：`2026-09-19 21:03:12`
String _stamp(DateTime at) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)} '
      '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
}

/// 这次通话用到的 ICE 服务器（地址 + 有没有账号），给诊断面板显示。
///
/// 站点那栏填错是**最容易发生也最难看出来**的一个问题（`stun:xxx` 少个前缀
/// 就是整条连接建不起来），所以把它一字不差地显示出来。
List<String> describeIceServers(List<Map<String, dynamic>> servers) {
  final lines = <String>[];
  for (final server in servers) {
    final urls = server['urls'];
    final text = urls is List ? urls.join(', ') : '$urls';
    final hasCredentials =
        '${server['username'] ?? ''}'.isNotEmpty ||
        '${server['credential'] ?? ''}'.isNotEmpty;
    lines.add('$text${hasCredentials ? '（带账号）' : '（无账号）'}');
  }
  return lines;
}
