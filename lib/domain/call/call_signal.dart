/// 通话信令的**报文层**（S6.1）。
///
/// 对照老端三处：`pages/message/call.vue`（页面与 WebView 之间的转发 + 那次
/// `sendToMsg`）、`App.vue` 的 `webrtc` 分支（来电分流与多端判定）、
/// `hybrid/html/index.html`（事件与 90x 码的产地）。
///
/// 三条必须记住的事实（详见 `docs/protocol/call-signaling.md`）：
/// 1. **没有独立的信令通道**：每条信令都是一条 `type = webrtc` 的业务消息，
///    客户端 `POST /enterprise/im/sendToMsg`，服务端落库后推给对端；
/// 2. **两边的字段名不一样**：我们**发**的是平的（`event`/`code`/`status`/`sdp`/
///    `iceCandidate` 都在顶层），**收**到的却在 `extends` 里
///    （`data.extends.event`）——服务端在落库时把它们塞进了 `extends`；
/// 3. **`iceCandidate` 是 JSON 字符串**（老端把对象 `JSON.stringify` 再发，
///    收到时两边都兼容字符串与对象）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/util/json_value.dart';

/// 事件名（老端 `index.html::callMessagecallback` 的 switch 分支 +
/// `App.vue` 的 `webrtc` 分支合起来就是这些）
abstract final class CallEvent {
  /// 主叫：本机媒体就绪后发出（`code: 901`）。被叫靠它弹来电页。
  static const String calling = 'calling';

  /// 被叫：点接听且本机媒体就绪后发出（`code: 904`）
  static const String acceptRtc = 'acceptRtc';

  /// 主叫：收到 `acceptRtc` 之后发出的 SDP
  static const String offer = 'offer';

  /// 被叫：收到 `offer` 之后回的 SDP
  static const String answer = 'answer';

  /// 双向：ICE 候选，一条一个
  static const String iceCandidate = 'iceCandidate';

  /// 双向：挂断（带 `code` / `callTime` / `isbtn`）
  static const String hangup = 'hangup';

  /// 任一方 → 对方：忙线（`code: 907`）
  static const String busy = 'busy';

  /// 多端：同一账号的其它端已经处理了这次通话，本端静默关页
  static const String otherOpt = 'otherOpt';

  /// **推送专用**（S8.1n）：这通电话已经结束了，把那条来电通知收掉。
  ///
  /// 它不走长连接，也不该被当成一通来电：被叫收到来电推送时恰恰是长连接不在线的
  /// 那一端，主叫取消的那句 `hangup` 根本到不了他手上 —— 服务端于是补一条静默
  /// 数据推送（不弹通知），后台 isolate 拿到就把通知收掉。见 [callCancelId].
  static const String callCanceled = 'callCanceled';

  /// 收尾推送里那通电话的 id 放在这个字段（与 `calling` 报文的 `call_id` 同名）
  static const String callCancelId = 'call_id';

  /// **本端内部**事件（老端从不发出去）：`getUserMedia` 失败，提示+关页
  static const String mediaDevices = 'mediaDevices';

  /// 老端 switch 里有分支、但**没有任何地方发送**（语义待确认）
  static const String turndown = 'turndown';

  /// 客户端真的会发出去的事件
  static const List<String> sent = <String>[
    calling,
    acceptRtc,
    offer,
    answer,
    iceCandidate,
    hangup,
    busy,
  ];
}

/// 90x 码（老端 `index.html::hangup` 与 `App.vue` 里的解锁列表）
abstract final class CallCode {
  /// 主叫：本机媒体就绪，发起呼叫（`calling` 帧携带）
  static const int dialing = 901;

  /// 主叫取消：拨号中挂断，或 40 秒无人接听自动挂断
  static const int cancel = 902;

  /// 被叫拒接：来电中挂断
  static const int reject = 903;

  /// 被叫已接听（`acceptRtc` 帧携带）
  static const int accept = 904;

  /// **老端从未发出过**，只在「收到这些码就解锁」的列表里出现过 → 待报文确认
  static const int unknown = 905;

  /// 通话中挂断
  static const int hangupInCall = 906;

  /// 忙线（对方正在通话中 / 同一账号的其它端正在处理 / 本端忙）
  static const int busy = 907;

  /// 收到这些码说明这次通话结束了，要解锁多端锁
  /// （老端 `App.vue`：`[902,903,905,906,907].includes(code)`）
  static const List<int> unlockCodes = <int>[902, 903, 905, 906, 907];
}

/// 业务状态（老端 `extends.status`）
abstract final class CallStatus {
  static const int none = 0;

  /// 拨号中（主叫）
  static const int dialing = 1;

  /// 通话中（两边都算「接通之后」）
  static const int talking = 2;

  /// 来电中（被叫）
  static const int ringing = 3;

  /// 忙线
  static const int busy = 4;
}

/// 通话类型（老端 `extends.type`）
abstract final class CallType {
  static const int voice = 0;
  static const int video = 1;
}

/// 收到的一条通话信令。
///
/// 字段分两组：`extends` 里的（事件/码/状态/SDP/候选）与外层的
/// （`id` / `msg_id` / `fromUser`），老端也是这么分工的
/// （外层用来判「是不是我这条通话」「是不是我自己发的」）。
@immutable
class CallSignal {
  const CallSignal({
    required this.event,
    this.code = 0,
    this.status = CallStatus.none,
    this.type = CallType.voice,
    this.sdp = '',
    this.iceCandidate = const <String, dynamic>{},
    this.callTime = 0,
    this.byButton = false,
    this.isMobile = false,
    this.messageId = '',
    this.serverId = '',
    this.fromUserId = '',
    this.fromUserName = '',
    this.fromUserAvatar = '',
    this.toContactId = '',
  });

  /// 从 WS `webrtc` 消息的 `extends` 解析（外层那几个 id 由调用方传进来）。
  ///
  /// 一律走宽松取值：老端是 JS，`code` 可能是 `'907'`、`status` 可能是 `''`
  /// （它发出去时缺字段就写空串，服务端原样存），`isMobile` 可能是 `1`。
  factory CallSignal.fromExtends(
    Object? extendsMap, {
    String messageId = '',
    String serverId = '',
    String fromUserId = '',
    String fromUserName = '',
    String fromUserAvatar = '',
    String toContactId = '',
  }) {
    final ext = asMap(extendsMap);
    return CallSignal(
      event: asText(ext['event']),
      code: asInt(ext['code'], 0),
      status: asInt(ext['status'], CallStatus.none),
      type: asInt(ext['type'], CallType.voice),
      sdp: asText(ext['sdp']),
      iceCandidate: decodeIceCandidate(ext['iceCandidate']),
      callTime: asInt(ext['callTime'], 0),
      byButton: asBool(ext['isbtn']),
      isMobile: asBool(ext['isMobile']),
      messageId: messageId,
      serverId: serverId,
      fromUserId: fromUserId,
      fromUserName: fromUserName,
      fromUserAvatar: fromUserAvatar,
      toContactId: toContactId,
    );
  }

  /// `extends.event`
  final String event;

  /// `extends.code`（90x）
  final int code;

  /// `extends.status`
  final int status;

  /// `extends.type`：0 语音 / 1 视频
  final int type;

  /// `extends.sdp`（offer / answer）
  final String sdp;

  /// 已解开的 ICE 候选（老端收到的是字符串）
  final Map<String, dynamic> iceCandidate;

  /// `extends.callTime`：秒
  final int callTime;

  /// `extends.isbtn`：这条挂断是不是「用户按了按钮」（false = 对端被动关页，不用再回一条）
  final bool byButton;

  /// `extends.isMobile`：**服务端加的标记**（同一台手机的其它端？），
  /// 老端拿它和 `event == 'calling'` 一起过滤「自己发的消息」。语义待 S6.0 报文确认。
  final bool isMobile;

  /// 外层 `id`：主叫侧是自己生成的 uuid，被叫侧就是那条消息的 id
  final String messageId;

  /// 外层 `msg_id`：服务端业务 id（每收到一条就记下来，发出去时带上）
  final String serverId;

  final String fromUserId;
  final String fromUserName;
  final String fromUserAvatar;
  final String toContactId;

  bool get isVideo => type == CallType.video;

  /// 这条信令算不算「自己发的那条被服务端推回来了」
  bool isEchoOf(String? myUserId) =>
      myUserId != null && myUserId.isNotEmpty && fromUserId == myUserId;

  @override
  String toString() =>
      'CallSignal($event, code=$code, status=$status, id=$messageId, msg=$serverId)';
}

/// 只留老端那三个键（`candidate` / `sdpMLineIndex` / `sdpMid`）。
///
/// 老端在 `call.vue::msgCallback` 里就是这么筛的——浏览器给的
/// `RTCIceCandidate` 还带 `toJSON`/`address` 等字段，全发过去是浪费带宽。
Map<String, dynamic> normalizeIceCandidate(Map<String, dynamic> raw) =>
    <String, dynamic>{
      'candidate': raw['candidate'],
      'sdpMLineIndex': raw['sdpMLineIndex'],
      'sdpMid': raw['sdpMid'],
    };

/// 发出去时的形态：**JSON 字符串**（老端 `JSON.stringify(niceCandidate)`）
String encodeIceCandidate(Map<String, dynamic> raw) =>
    jsonEncode(normalizeIceCandidate(raw));

/// 收到时的形态：字符串或对象都认（老端 WebView 里两种都处理了）
Map<String, dynamic> decodeIceCandidate(Object? value) {
  if (value == null) return const <String, dynamic>{};
  if (value is Map) return value.cast<String, dynamic>();
  if (value is String && value.trim().isNotEmpty) {
    try {
      final decoded = json.decode(value);
      return asMap(decoded);
    } on FormatException {
      return const <String, dynamic>{};
    }
  }
  return const <String, dynamic>{};
}

/// 拼一条 `sendToMsg` 的请求体（老端 `call.vue::msgCallback` 里那段）。
///
/// 逐字对齐老端的十个字段，包括两个怪癖：
/// * 缺的数字字段发**空串**（老端 `e.data['code'] ?? ''`）；
/// * `iceCandidate` 除了 `iceCandidate` 事件以外都发空串。
///
/// [id] 是主叫侧自己生成的 uuid（被叫侧是从对方那里收到的 `id`）；
/// [serverId] 是服务端业务 id，只在「收到过一条」之后才有值。
Map<String, dynamic> buildSignalRequest({
  required String toContactId,
  required int type,
  required String event,
  required String id,
  String serverId = '',
  int? status,
  int? code,
  int? callTime,
  String sdp = '',
  Map<String, dynamic>? iceCandidate,
}) => <String, dynamic>{
  'id': id,
  'msg_id': serverId,
  'toContactId': toContactId,
  'type': type,
  'event': event,
  'status': status ?? '',
  'code': code ?? '',
  'callTime': callTime ?? '',
  'sdp': sdp,
  'iceCandidate': iceCandidate == null || iceCandidate.isEmpty
      ? ''
      : encodeIceCandidate(iceCandidate),
};
