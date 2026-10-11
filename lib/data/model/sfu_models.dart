/// 群通话（Cloudflare Realtime SFU）的返回模型。
///
/// 字段口径见 `docs/protocol/sfu-group-call.md` 第三节：我们的服务端把 CF 的
/// `sessionDescription` / 逐条 track 结果原样翻成这里这几个名字。
library;

import 'package:flutter/foundation.dart';

import '../../core/util/json_value.dart';

/// 一次 SDP 交换的结果（发布 / 订阅都用它）。
///
/// CF 的两种形态都收得下：
/// * 端点发 offer → CF 回 answer：落在 [sdpAnswer]；
/// * CF 回 offer（`requires_renegotiation`）→ 端点要 createAnswer 再 renegotiate 回去：
///   落在 [sdpOffer]。
@immutable
class SfuExchangeResult {
  const SfuExchangeResult({
    required this.tracks,
    this.sdpAnswer,
    this.sdpOffer,
    this.requiresRenegotiation = false,
  });

  /// SDP 类型是 answer（端点发起的交换，正常路径）
  final String? sdpAnswer;

  /// SDP 类型是 offer：CF 要求端点作答，**必须**通过 `renegotiate` 交回去
  final String? sdpOffer;

  final bool requiresRenegotiation;

  /// 逐条 track 的结果（成功/失败都在这里，**不要**只看 HTTP 200）
  final List<SfuTrackResult> tracks;

  /// 有没有哪条 track 没成
  List<SfuTrackResult> get failedTracks =>
      tracks.where((track) => !track.succeeded).toList(growable: false);

  bool get allTracksOk => failedTracks.isEmpty;

  static SfuExchangeResult fromJson(Map<String, dynamic> json) {
    final sdp = asMap(json['sdp']);
    return SfuExchangeResult(
      sdpAnswer: _nonEmpty(sdp['answer']) ?? _nonEmpty(json['sdp_answer']),
      sdpOffer: _nonEmpty(sdp['offer']) ?? _nonEmpty(json['sdp_offer']),
      requiresRenegotiation: asBool(json['requires_renegotiation']),
      tracks: asList(json['tracks'])
          .map((item) => SfuTrackResult.fromJson(asMap(item)))
          .toList(growable: false),
    );
  }
}

/// 一次请求里某条 track 的结果。
///
/// CF 的整包 HTTP 200 **不代表每条 track 都成功**（官方原话：不一定每条资源都成功），
/// 所以这一层必须逐条看。
@immutable
class SfuTrackResult {
  const SfuTrackResult({
    required this.trackName,
    this.mid,
    this.status = '',
    this.errorCode = '',
    this.errorDescription = '',
  });

  final String trackName;

  /// 这条 track 在本条连接里的 mid（发布后要用它做 track 与 transceiver 的对应）
  final String? mid;

  /// `active` / `inactive` / 空（没给）
  final String status;

  final String errorCode;
  final String errorDescription;

  bool get succeeded => errorCode.isEmpty && errorDescription.isEmpty;

  static SfuTrackResult fromJson(Map<String, dynamic> json) => SfuTrackResult(
    trackName: asText(json['track_name'] ?? json['trackName']),
    mid: _nonEmpty(json['mid']),
    status: asText(json['status']),
    errorCode: asText(json['error_code'] ?? json['errorCode']),
    errorDescription: asText(
      json['error_description'] ?? json['errorDescription'],
    ),
  );
}

/// 心跳的回包。
///
/// 心跳有两个用处：注册表靠它知道"我还在"（超时没动静的行会被清掉，别人就会退订
/// 我的声音）；回包里的 [epoch] 还顺手当一次自检 —— 手里那份快照的版本号和它对不上，
/// 就说明"有变化而那条 WS 推送没收到"，马上重新对一次账。
@immutable
class SfuHeartbeat {
  const SfuHeartbeat({required this.epoch, required this.memberCount});

  final int epoch;
  final int memberCount;

  static SfuHeartbeat fromJson(Map<String, dynamic> json) => SfuHeartbeat(
    epoch: asInt(json['epoch'], 0),
    memberCount: asInt(json['member_count'] ?? json['memberCount'], 0),
  );
}

/// `leave` 的回包：**这一通是不是就此结束**。
///
/// 为什么退出房间还要关心"结束没结束"：群里那条通话记录（微信里那条
/// 「通话时长 12:30」）由**最后一个走的人**发，服务端只让一个人拿到
/// [announce]（两个人同时挂断时不能各写一条，仲裁见 `Sfu.php::claimClosed`）。
@immutable
class SfuLeaveResult {
  const SfuLeaveResult({
    this.closed = false,
    this.announce = false,
    this.durationSeconds = 0,
    this.participants = 0,
  });

  /// 我这一走之后房间里没人了
  final bool closed;

  /// 这一通的"结束"由我来广播（服务端只发给一个人）→ 我负责往群里落记录
  final bool announce;

  /// 这通电话持续了多少秒（从房间里第一个人进来那一刻算起）
  final int durationSeconds;

  /// 期间到过几个人（含自己）：只有 1 个人时不留记录（点进去又出来不算一通电话）
  final int participants;

  static SfuLeaveResult fromJson(Map<String, dynamic> json) => SfuLeaveResult(
    closed: asBool(json['closed']),
    announce: asBool(json['announce']),
    durationSeconds: asInt(json['duration'], 0),
    participants: asInt(json['participants'], 0),
  );
}

/// 房间快照：**谁发布了什么**。
///
/// CF 不提供房间发现（"The SFU does not supply a room-presence protocol"），
/// 这份映射由我们的服务端维护，客户端按 [epoch] 收敛订阅。
@immutable
class SfuRoomState {
  const SfuRoomState({required this.members, required this.epoch});

  final List<SfuRoomMember> members;

  /// 注册表版本号：变了就说明有人发布/离开/换了会话 → 必须重新对账订阅
  final int epoch;

  /// 有音频/视频发布的人
  List<SfuRoomMember> get publishers =>
      members.where((member) => member.sessionId.isNotEmpty).toList();

  static SfuRoomState fromJson(Map<String, dynamic> json) => SfuRoomState(
    members: asList(json['members'])
        .map((item) => SfuRoomMember.fromJson(asMap(item)))
        .toList(growable: false),
    epoch: asInt(json['epoch'], 0),
  );

  static const SfuRoomState empty = SfuRoomState(
    members: <SfuRoomMember>[],
    epoch: 0,
  );
}

/// 房间里的一个人：他的**发布会话** id 与发布了哪些 track，以及**麦克风是不是静音中**。
///
/// ⚠️ [muted] 与 [tracks] 里的 `mic` **不是一回事**，两者都要看：
/// * `tracks` 说的是"他**发布**了一条麦克风"—— 这是订阅关系，拆了对方就听不到；
/// * [muted] 说的是"他**按了静音**"—— 本端不再发包，但那条 publication 还在。
///
/// 所以"他有没有声音"= `tracks.contains('mic') && !muted`。少看任何一半都会错：
/// 只看 `tracks` 就会把静音的人画成"麦克风已开"（2026-10-07 真机就是这个 bug），
/// 只看 [muted] 则会把没进房间的人也算进来。
@immutable
class SfuRoomMember {
  const SfuRoomMember({
    required this.userId,
    required this.sessionId,
    required this.tracks,
    this.muted = false,
  });

  final String userId;

  /// 发布会话 id（订阅别人时要用它 + trackName 一起定位）
  final String sessionId;

  /// 发布的 track 名，例如 `mic` / `screen`
  final List<String> tracks;

  /// 他的麦克风**静音中**（本端不发包，但 `mic` 那条 track 还在）。
  ///
  /// 默认 `false`：**老服务端没有这个字段时行为与从前逐字一致**（只按 `tracks`
  /// 判），升级是平滑的 —— 服务端补上字段之前，客户端不会崩也不会误报。
  final bool muted;

  static SfuRoomMember fromJson(Map<String, dynamic> json) => SfuRoomMember(
    userId: asText(json['user_id'] ?? json['userId']),
    sessionId: asText(json['session_id'] ?? json['sessionId']),
    tracks: asList(
      json['tracks'],
    ).map(asText).where((name) => name.isNotEmpty).toList(growable: false),
    muted: asBool(json['muted']),
  );
}

/// 宽松取「可空字符串」：缺失或空串都算没有（`asText` 会落成 `''`）
String? _nonEmpty(Object? value) {
  final text = asText(value);
  return text.isEmpty ? null : text;
}
