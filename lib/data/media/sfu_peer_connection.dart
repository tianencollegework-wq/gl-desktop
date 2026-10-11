import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../core/store/session_store.dart';
import '../../domain/call/call_media_config.dart';
import '../../domain/call/turn_credentials.dart';
import '../../domain/group_call/sfu_ice_gathering.dart';
import '../../domain/group_call/sfu_transport.dart';
import 'sfu_local_media.dart';

/// 一条到 Cloudflare SFU 的连接：把 CF 的 connection patterns 逐条翻成插件调用。
///
/// 这里**只做翻译**，不含任何时序/状态判断（谁先谁后、失败该重试还是该重建，
/// 全在 `SfuRoom` 与 `SfuSessionQueue` 里，那些是用假实现测到底的）。
///
/// 与 1:1 那套（[WebrtcCallMediaEngine]）的关键差别，全部来自 CF 的硬要求：
///
/// * **候选非 trickle**：每次 `setLocalDescription` 之后要等 gathering 结束
///   （[IceGatherBarrier]，带超时），再把 SDP 交给服务端；没有单独的候选通道；
/// * **发布与订阅不对称**：发布是我们出 offer、CF 回 answer；订阅是**CF 出 offer**、
///   我们作答（[answerSfuOffer]）后走 `/renegotiate` 交回去；
/// * **一条连接可以反复改**（加共享屏、关订阅），每次都要重新出 offer、
///   重新等候选 —— 所以这里没有「一次协商到底」的状态，插件随时能重来。
class WebrtcSfuPeerConnection implements SfuPeerConnection {
  WebrtcSfuPeerConnection({
    required this.iceServers,
    this.trackOf,
    this.gatherTimeout = const Duration(seconds: 5),
  });

  /// 要的时候再算 ICE 列表（站内那份 + 服务端签发的 CF TURN 凭据）
  final Future<List<Map<String, dynamic>>> Function() iceServers;

  /// 按 track 名找本机轨道（`mic` / `screen`）：媒体只有一份，两条会话共用
  final MediaStreamTrack? Function(String trackName)? trackOf;

  /// 一次交换最多等候选多久（等不到照样放行，见 [IceGatherBarrier]）
  final Duration gatherTimeout;

  /// 拿**此刻真实的** gathering 状态当快速判断：不然一次先于
  /// [IceGatherBarrier.wait] 到达的 `complete` 回调就白丢了，这一次交换要空等到
  /// 超时（真机上就是进房间莫名其妙慢十几秒）。
  late final IceGatherBarrier _gathering = IceGatherBarrier(
    timeout: gatherTimeout,
    alreadyComplete: () => _gatheringComplete,
  );

  /// 上一次 `onIceGatheringState` 回调里读到的状态（每次开始新交换前重置）
  bool _gatheringComplete = false;

  final StreamController<SfuIncomingTrack> _incoming =
      StreamController<SfuIncomingTrack>.broadcast();
  final StreamController<RTCPeerConnectionState> _states =
      StreamController<RTCPeerConnectionState>.broadcast();

  RTCPeerConnection? _pc;
  RTCPeerConnectionState? _lastState;
  bool _closed = false;

  /// 这条会话上**已经发布出去**的 track 名 → mid（[replaceTrackByName] 靠它找回
  /// 「同一条轨原来在哪个 transceiver 上」）。
  ///
  /// 不能按 `sender.track` 去认：采集重建之后本机那条轨已经**换了对象**
  /// （新 `getDisplayMedia` 给的是新的 track），旧 track 的 id 再也对不上。
  final Map<String, String> _publishedMids = <String, String>{};

  @override
  Stream<SfuIncomingTrack> get incomingTracks => _incoming.stream;

  /// 各条**远端音频**的瞬时能量（`mid → 0~1`），读的是 WebRTC 统计里的
  /// `audioLevel`（它是 libwebrtc 自己算的，单位就是 0~1，不是 dB）。
  ///
  /// 三处防御都是必须的（不然一个平台差异就能把"说话人"变成乱跳的人名）：
  /// * 统计里**没有** `type == inbound-rtp` 的条目 → 空表（老版本/某些平台不给）；
  /// * 没有 `mid` → 丢掉（归不了位就不知道是谁）；
  /// * 拿不到 `audioLevel`（字段名也可能是 `audio_level`） → 空表。
  @override
  Future<Map<String, double>> audioLevels() async {
    final pc = _pc;
    if (pc == null || _closed) return const <String, double>{};
    try {
      final report = await pc.getStats();
      final levels = <String, double>{};
      for (final entry in report) {
        if (entry.type != 'inbound-rtp') continue;
        final values = entry.values;
        final kind = '${values['kind'] ?? values['mediaType'] ?? ''}';
        if (kind != 'audio') continue;
        final mid = '${values['mid'] ?? ''}';
        if (mid.isEmpty) continue;
        final level = _parseLevel(
          values['audioLevel'] ?? values['audio_level'],
        );
        if (level == null) continue;
        levels[mid] = level;
      }
      return levels;
    } catch (error) {
      debugPrint('[群通话] 读音频能量失败：$error');
      return const <String, double>{};
    }
  }

  /// **接收侧**每条视频流的「还在不在收」的计数（`mid → 计数`）。
  ///
  /// 与 [audioLevels] 同一条 `getStats`，只是取的是另一档：视频的
  /// `framesDecoded`（退而求其次 `framesReceived` / `bytesReceived` /
  /// `packetsReceived`）—— 平台/版本给的字段名不一样，我们只靠
  /// 「**涨了 = 还在收**」这一个语义（判定在 `SfuStreamWatch` 里）。
  @override
  Future<Map<String, int>> inboundVideoCounters() async {
    final pc = _pc;
    if (pc == null || _closed) return const <String, int>{};
    try {
      final report = await pc.getStats();
      final counters = <String, int>{};
      for (final entry in report) {
        if (entry.type != 'inbound-rtp') continue;
        final values = entry.values;
        final kind = '${values['kind'] ?? values['mediaType'] ?? ''}';
        if (kind != 'video') continue;
        final mid = '${values['mid'] ?? ''}';
        if (mid.isEmpty) continue;
        final counter =
            _parseCounter(values['framesDecoded']) ??
            _parseCounter(values['framesReceived']) ??
            _parseCounter(values['bytesReceived']) ??
            _parseCounter(values['packetsReceived']);
        if (counter == null) continue;
        counters[mid] = counter;
      }
      return counters;
    } catch (error) {
      debugPrint('[群通话] 读视频收流计数失败：$error');
      return const <String, int>{};
    }
  }

  /// 计数那几档可能是整数、也可能是浮点（原生按类型序列化）
  static int? _parseCounter(Object? raw) {
    final value = double.tryParse('${raw ?? ''}');
    if (value == null || !value.isFinite) return null;
    return value.round();
  }

  /// 统计里的值都是字符串；`"0.0312"` 这种直接解析，越界（有的是 dB）丢弃。
  static double? _parseLevel(Object? raw) {
    final level = double.tryParse('${raw ?? ''}');
    if (level == null || !level.isFinite) return null;
    if (level < 0 || level > 1) return null;
    return level;
  }

  /// 建连接（**懒建**：工厂是同步的，而建连接要等 ICE 列表算出来）。
  ///
  /// 建完先摸一下确认它不是空壳 —— 与 1:1 那套同一个坑（ICE 地址不合法时原生
  /// 直接返回空对象，插件不检查，后面 `addTransceiver` 会撞出不可捕获的 Java NPE）。
  Future<RTCPeerConnection> _connection() async {
    final existing = _pc;
    if (existing != null) return existing;
    if (_closed) throw StateError('这条会话已经关掉了');
    final servers = await iceServers();
    final pc = await createPeerConnection(<String, dynamic>{
      'iceServers': servers,
      'sdpSemantics': 'unified-plan',
    });
    try {
      await pc.getTransceivers();
    } catch (error) {
      throw StateError('建连接失败（ICE 服务器地址可能不合法）：$error');
    }
    pc.onIceGatheringState = _handleGatheringState;
    pc.onConnectionState = _handleConnectionState;
    pc.onTrack = _handleTrack;
    if (_closed) {
      // 建的过程中房间关了
      await _safeClose(pc);
      throw StateError('这条会话已经关掉了');
    }
    _pc = pc;
    return pc;
  }

  @override
  Future<bool> waitConnected(Duration timeout) async {
    final pc = await _connection();
    // 先问一次当前状态：回调可能在我们开始等之前就已经到过了
    if (_isConnected(await pc.getConnectionState())) return true;
    try {
      await _states.stream
          .firstWhere(_isSettled)
          .timeout(
            timeout,
            onTimeout: () =>
                RTCPeerConnectionState.RTCPeerConnectionStateFailed,
          );
    } catch (error) {
      debugPrint('[群通话] 等 ICE 连通时出错：$error');
      return false;
    }
    return _isConnected(_lastState);
  }

  @override
  Future<SfuPreparedSdp> preparePublish(List<SfuLocalTrack> tracks) async {
    final pc = await _connection();
    final mids = <String, String>{};
    for (final track in tracks) {
      if (mids.containsKey(track.name)) continue; // 同一条轨道别挂两次
      final local = trackOf?.call(track.name);
      if (local == null) {
        debugPrint('[群通话] 本机没有 ${track.name} 这条轨道，跳过');
        continue;
      }
      final transceiver = await pc.addTransceiver(
        track: local,
        init: RTCRtpTransceiverInit(
          direction: TransceiverDirection.SendOnly,
          streams: <MediaStream>[],
        ),
      );
      mids[track.name] = transceiver.mid;
    }
    // 发布这条会话是 sendonly 的：出 offer 时**不要**请求接收音视频
    // （`OfferToReceiveAudio: true` 会在 offer 里多塞一条谁都认领不了的 recvonly 音轨，
    // 见 [CallMediaConfig.publishSdpConstraints]）。
    final prepared = await _swapOffer(pc, mids, sendOnly: true);
    // 记下来：以后换轨（采集重建）要按名字找同一个 transceiver
    _publishedMids.addAll(prepared.mids);
    return prepared;
  }

  /// 把已经发布出去的那条轨换成「此刻本机的那一条」，**挂在同一个 transceiver 上**。
  ///
  /// 用在桌面共享窗口被最小化又还原之后：本机重建了采集（新的 track），而 SFU 那边
  /// 这条发布的身份（mid / 注册表里那一行）都不该变 —— 不重新协商、不碰服务端，
  /// 对面看到的只是同一个 mid 上重新有了画面。
  ///
  /// 找不到（本机没这条轨 / 没在这条会话上发布过）就返回 false，不当错误：
  /// 比如共享已经停了、或者发布那边刚重建过（重建本身就是按当前轨整体重发的）。
  @override
  Future<bool> replaceTrackByName(String trackName) async {
    final pc = await _connection();
    final want = trackOf?.call(trackName);
    if (want == null) {
      debugPrint('[群通话] 本机没有 $trackName 这条轨（换轨跳过）');
      return false;
    }
    final mid = _publishedMids[trackName];
    if (mid == null || mid.isEmpty) return false;
    for (final transceiver in await pc.getTransceivers()) {
      if (transceiver.mid != mid) continue;
      final sender = transceiver.sender;
      if (sender.track?.id == want.id) return true; // 已经是这一条了
      await sender.replaceTrack(want);
      debugPrint('[群通话] $trackName 已换到重建后的新轨（mid=$mid，连接没重谈）');
      return true;
    }
    return false;
  }

  @override
  Future<void> applyAnswer(String answerSdp) async {
    final pc = await _connection();
    await pc.setRemoteDescription(RTCSessionDescription(answerSdp, 'answer'));
  }

  @override
  Future<String> answerSfuOffer(String offerSdp) async {
    final pc = await _connection();
    await pc.setRemoteDescription(RTCSessionDescription(offerSdp, 'offer'));
    final answer = await pc.createAnswer(
      CallMediaConfig.sdpConstraints(video: false),
    );
    _gatheringComplete = false;
    await pc.setLocalDescription(answer);
    await _gathering.wait();
    final text = answer.sdp;
    if (text == null || text.isEmpty) {
      throw StateError('本机 answer 是空的');
    }
    return text;
  }

  @override
  Future<SfuPreparedSdp?> prepareClose(List<String> mids) async {
    final pc = await _connection();
    final transceivers = await pc.getTransceivers();
    var stopped = 0;
    for (final transceiver in transceivers) {
      if (!mids.contains(transceiver.mid)) continue;
      await transceiver.stop();
      stopped += 1;
    }
    if (stopped == 0) {
      // 这些 mid 的 transceiver 早就没了（例如上一轮已经关过）：调用方改用
      // `force: true` 直接关，不再做一次没有意义的 SDP 交换。
      return null;
    }
    // 关掉的这几条不再是「已发布」了：换轨不能再去动它们
    _publishedMids.removeWhere((_, mid) => mids.contains(mid));
    return _swapOffer(pc, const <String, String>{});
  }

  @override
  Future<void> applyCloseAnswer(String answerSdp) async {
    final pc = await _connection();
    await pc.setRemoteDescription(RTCSessionDescription(answerSdp, 'answer'));
  }

  @override
  Future<void> close() async {
    _closed = true;
    final pc = _pc;
    _pc = null;
    _lastState = null;
    await _safeClose(pc);
    await _incoming.close();
    await _states.close();
  }

  // ------------------------------------------------------------------ 内部

  /// 重新出一份 offer（带上下面的 track）、等候选收齐，返回可以直接发的那份 SDP
  Future<SfuPreparedSdp> _swapOffer(
    RTCPeerConnection pc,
    Map<String, String> mids, {
    bool sendOnly = false,
  }) async {
    final offer = await pc.createOffer(
      sendOnly
          ? CallMediaConfig.publishSdpConstraints()
          : CallMediaConfig.sdpConstraints(video: false),
    );
    _gatheringComplete = false;
    await pc.setLocalDescription(offer);
    await _gathering.wait();
    // **必须读之后的那份 localDescription**：`createOffer()` 返回的 SDP 里
    // 还没有候选（候选是 setLocalDescription 之后才收的），而 CF 要的是
    // "候选已经在里面" 的那一份。
    final local = await pc.getLocalDescription();
    final text = local?.sdp ?? offer.sdp;
    if (text == null || text.isEmpty) {
      throw StateError('本机 offer 是空的');
    }
    final resolved = <String, String>{};
    for (final entry in mids.entries) {
      resolved[entry.key] = entry.value.isEmpty
          ? await _midOfTrack(pc, entry.key)
          : entry.value;
    }
    return SfuPreparedSdp(sdp: text, mids: resolved);
  }

  /// 这个 track 名对应的 transceiver 的 mid（`addTransceiver` 当场读常常是空的）
  Future<String> _midOfTrack(RTCPeerConnection pc, String trackName) async {
    final want = trackOf?.call(trackName);
    if (want == null) return '';
    for (final transceiver in await pc.getTransceivers()) {
      if (transceiver.sender.track?.id == want.id) return transceiver.mid;
    }
    return '';
  }

  void _handleGatheringState(RTCIceGatheringState state) {
    final complete = state == RTCIceGatheringState.RTCIceGatheringStateComplete;
    _gatheringComplete = complete;
    if (complete) _gathering.complete();
  }

  void _handleConnectionState(RTCPeerConnectionState state) {
    _lastState = state;
    if (!_states.isClosed) _states.add(state);
  }

  /// 收一路远端 track。
  ///
  /// ⚠️ **`event.streams` 可能是空的** —— SFU 的 offer 常常不带 `msid`（那是点对点
  /// 那套的东西），这时插件给的只有 track、没有 stream。而界面那层要的是
  /// `MediaStream`（`RTCVideoRenderer.srcObject` 只认它），把 track 当流交上去，
  /// 共享屏就永远画不出来：**别人明明在共享，这边却一直是一片头像**。
  ///
  /// 1:1 那条路径早就踩过这个坑（`WebrtcCallMediaEngine._handleTrack` 自己包了一层
  /// 流），群通话这边漏了。这里补上同一层。
  Future<void> _handleTrack(RTCTrackEvent event) async {
    if (_incoming.isClosed) return;
    final MediaStream stream;
    if (event.streams.isNotEmpty) {
      stream = event.streams.first;
    } else {
      try {
        final wrapped = await createLocalMediaStream('sfu-${event.track.id}');
        await wrapped.addTrack(event.track);
        stream = wrapped;
      } catch (error) {
        debugPrint('[群通话] 收远端轨道失败（包流不成）：$error');
        return;
      }
      // 包流是异步的，这期间房间可能已经关掉了：包出来的流要放掉
      if (_incoming.isClosed) {
        try {
          await stream.dispose();
        } catch (_) {
          // 放不掉就算了：连接关掉时原生会一起收
        }
        return;
      }
    }
    _incoming.add(
      SfuIncomingTrack(
        mid: event.transceiver?.mid ?? '',
        kind: event.track.kind ?? 'audio',
        stream: stream,
      ),
    );
  }

  bool _isConnected(RTCPeerConnectionState? state) =>
      state == RTCPeerConnectionState.RTCPeerConnectionStateConnected;

  /// 已经可以下结论的两种状态（连上了 / 没救了）；其它状态（connecting 等）继续等
  bool _isSettled(RTCPeerConnectionState state) =>
      _isConnected(state) ||
      state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
      state == RTCPeerConnectionState.RTCPeerConnectionStateClosed;

  Future<void> _safeClose(RTCPeerConnection? pc) async {
    if (pc == null) return;
    try {
      await pc.close();
      await pc.dispose();
    } catch (error) {
      debugPrint('[群通话] 关闭连接失败：$error');
    }
  }
}

/// 造一条到 SFU 的连接（每个会话一条：会话被判死时要换全新的重建）。
///
/// ICE 列表与 1:1 那套完全一致：站内配置 + 服务端签发的短时 TURN 凭据
/// （2026-09-26 真机验过 relay 能分配成功）。TURN 对 SFU 同样是兜底：
/// 能直连就直连，打不通才中继。
class WebrtcSfuConnectionFactory {
  WebrtcSfuConnectionFactory({
    required this.iceServers,
    required this.trackOf,
    this.gatherTimeout = const Duration(seconds: 5),
  });

  final Future<List<Map<String, dynamic>>> Function() iceServers;
  final MediaStreamTrack? Function(String trackName) trackOf;
  final Duration gatherTimeout;

  SfuPeerConnection call() => WebrtcSfuPeerConnection(
    iceServers: iceServers,
    trackOf: trackOf,
    gatherTimeout: gatherTimeout,
  );
}

/// 造连接到 SFU。ICE 列表**建连接时才读**（与 1:1 那套同一个理由：
/// 站点配置热更新对下一通生效，且不 watch 会话状态以免重建正在进行的通话）。
final sfuConnectionFactoryProvider = Provider<SfuConnectionFactory>((ref) {
  final media = ref.read(sfuLocalMediaProvider);
  final factory = WebrtcSfuConnectionFactory(
    iceServers: () async {
      final base = CallMediaConfig.iceServers(
        ref.read(sessionStoreProvider).config.chatInfo,
      );
      try {
        final turn = await ref.read(turnCredentialServiceProvider).iceServers();
        return <Map<String, dynamic>>[...base, ...turn];
      } catch (error) {
        debugPrint('[群通话] 取 TURN 凭据失败（只用 STUN）：$error');
        return base;
      }
    }, // 真机那版才认识 track 名（测试里 override 成假媒体时这里自然是空）
    trackOf: (name) =>
        media is WebrtcSfuLocalMedia ? media.trackOf(name) : null,
  );
  // 明确 tear-off：这条 provider 给出去的就是"能造连接的那个函数"
  return factory.call;
});
