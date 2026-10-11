import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;

import '../../core/util/json_value.dart';
import '../chat/conversation_rules.dart';
import '../chat/message_notification.dart' show MessageNotification;
import 'call_signal.dart' show CallEvent, CallType;

/// 一条**被离线推送送来的来电**（S8.1h）。
///
/// 背景：对方 App 被杀时，长连接那条路是断的，`calling` 帧发不到他手上，
/// 全靠这条推送把人叫醒。所以这里要把「谁在打我、语音还是视频、哪一通」从
/// 推送数据里还原出来 —— 而且**必须能还原出完整会话**，否则冷启动后进来电页
/// 也没法接（接听要发 `acceptRtc`，需要 `id` / `toContactId` 这些字段）。
///
/// 服务端 `PushMessage::dataPayload()` 给的就是那几个字段（改那边要同步改这里）：
///
/// | 字段 | 用途 |
/// |---|---|
/// | `type` / `event` | 判「这是不是一通来电」（`webrtc` + `calling`） |
/// | `title` | 来电人昵称（`payload` 丢了就靠它） |
/// | `payload` | **整条 `calling` 报文**（与 WS 那份同构）→ 冷启动靠它重建会话 |
///
/// 为什么不用 `payload` 里带的 SDP：**这一帧本来就没有 SDP**（这套协议的
/// offer/answer 是「被叫接听之后」才开始的），所以推送只需要把「有一通电话」这一件事
/// 送到；打洞的 SDP 全程在两端都在线时交换。
@immutable
class IncomingCallPush {
  const IncomingCallPush({
    required this.peerId,
    required this.callerName,
    required this.isVideo,
    required this.signal,
    required this.sentAt,
  });

  /// 来电人的 uid（= 会话 id：点通知要进的会话 / 通话页上的对端）
  final String peerId;

  /// 来电人昵称（取不到是空串，通知标题会退回「来电」这个通用文案）
  final String callerName;

  /// 视频还是语音（`extends.type`：0 语音 / 1 视频）
  final bool isVideo;

  /// 整条 `calling` 报文。**服务端因为超长丢掉 `payload` 时是空的** ——
  /// 那种情况只能画一条通知，点进去没法接（所以下面 [canRebuildSession] 要判它）。
  final Map<String, dynamic> signal;

  /// 服务端发出这条推送的时刻（`sendTime`，毫秒）。取不到是 null。
  final DateTime? sentAt;

  /// 能不能靠它重建一通可接的电话
  bool get canRebuildSession => signal.isNotEmpty && peerId.isNotEmpty;

  /// 这条来电是不是还值得响铃。
  ///
  /// 主叫等 60 秒就挂了（客户端窗口），服务端那条推送的 TTL 也是 60 秒 —— 两者之间
  /// 留 10 秒余量的理由：否则会出现「t=59 秒才叫醒你，响一秒对面已挂」这种最烦人的
  /// 情况（半夜那一下尤其如此）。
  bool isFresh(DateTime now, {Duration window = const Duration(seconds: 50)}) {
    final sent = sentAt;
    if (sent == null) return true; // 没有时间就当它是新的（宁可多响一次）
    // 只卡上界："超过窗口才算旧"。**不卡下界** —— 两端时钟差几秒就会让 sendTime
    // 显得在"未来"，那时因为时钟快而漏接一通电话才是最冤的。
    return now.difference(sent) <= window;
  }

  /// 画到通知栏上的样子：标题=来电人，正文=「[语音通话]」/「[视频通话]」。
  ///
  /// 正文走**和会话列表同一套**规则（`ConversationRules.preview`）——
  /// 来电通知、消息通知、聊天列表三处的文案不该各不相同。
  MessageNotification toNotification(String Function(String key) translate) {
    return MessageNotification(
      conversationId: peerId,
      title: callerName.isEmpty
          ? translate('call.incomingUnknown')
          : callerName,
      body: ConversationRules.preview(
        type: 'webrtc',
        translate: translate,
        callVideo: isVideo,
      ),
    );
  }
}

/// 这条推送数据是不是一通**来电**（服务端在 `dataPayload()` 里把这两个字段摊平了）
bool isIncomingCallPush(Map<String, String> data) {
  if (data['type'] != 'webrtc') return false;
  return data['event'] == CallEvent.calling;
}

/// 这条推送数据是不是「**那通电话已经结束了**」的收尾帧（S8.1n）。
///
/// 为什么需要它：被叫收到来电推送时，他**恰恰是长连接不在线的那一端**（在线就不会走
/// 推送），所以主叫取消/拨号超时的那句 `hangup` 走长连接过去、他一个字都收不到 ——
/// 那条来电通知于是没人收，只能干等 45 秒的 TTL（真机 2026-09-20：「a 呼叫了一会儿
/// 自己取消了，b 那边的通知却还一直显示」）。
///
/// 服务端在**主叫取消/超时**（`code 902`）时给离线的被叫补一条**静默**数据推送：
/// `event = callCanceled`、`type = webrtc`、`call_id` = 那一通的消息 id。
/// 它**不弹任何通知**：后台 isolate 拿到就把来电通知收掉，然后结束。
/// 字段契约在服务端 `PushMessage::forCallCancel()`（改那边要同步改这里）。
bool isCallCancelPush(Map<String, String> data) {
  if (data['type'] != 'webrtc') return false;
  return data['event'] == CallEvent.callCanceled;
}

/// 收尾推送里那通电话的 id（服务端没给就是空串）。
///
/// 用来挡一件真事：**新的一通电话刚响起来、上一条收尾帧才姗姗来迟** ——
/// 不带 id 地无条件收通知，会把正在响的那通一起收掉。
String callCancelIdOf(Map<String, String> data) =>
    (data[CallEvent.callCancelId] ?? '').trim();

/// 把一条推送数据解析成来电。**不是来电阻返回 null**（普通消息推送由消息那条路处理）。
///
/// [myUserId] 用来挡「自己发的」（服务端推给接收者时已经排掉发送人，这里是双保险）。
IncomingCallPush? incomingCallFromPush({
  required Map<String, String> data,
  required String myUserId,
}) {
  if (!isIncomingCallPush(data)) return null;

  return incomingCallFromSignal(
    _decodeSignal(data['payload'] ?? ''),
    myUserId: myUserId,
    // `payload` 被服务端丢掉时的退路（只能点开会话，接不了）
    fallbackPeerId: data['contact_id'] ?? '',
    fallbackName: data['title'] ?? '',
  );
}

/// 直接从**一整条 `calling` 报文**还原来电（不带推送那层包装）。
///
/// 这条入口是给「点通知 / 冷启动」用的（见 `CallPushHost`）：通知的 payload 里
/// 放的就是这条报文（`IncomingCallNotification.payload`），不再是推送数据那张表。
///
/// 会再验一次「它确实是一通来电」（`type` = webrtc 且 `extends.event` = calling）——
/// 那条通知的 payload 是我们自己写的，但它是从**外部**（系统通知）绕回来的。
IncomingCallPush? incomingCallFromSignal(
  Map<String, dynamic>? signal, {
  required String myUserId,
  String fallbackPeerId = '',
  String fallbackName = '',
}) {
  final frame = signal ?? const <String, dynamic>{};
  // 报文在就再验一次「它确实是一通来电」；报文**不在**（服务端超长丢掉 payload）
  // 时不拦：那时还能靠 `contact_id` / `title` 弹一条「谁在打你」的通知，只是接不了。
  if (frame.isNotEmpty) {
    if (asText(frame['type']) != 'webrtc') return null;
    final payload = asMap(frame['extends']);
    if (asText(payload['event']) != CallEvent.calling) return null;
  }
  final payload = asMap(frame['extends']);

  final fromUser = asMap(frame['fromUser']);
  final peerId = asText(fromUser['id'] ?? fromUser['user_id']);
  final name = asText(fromUser['displayName'] ?? fromUser['realname']).trim();
  if (myUserId.isNotEmpty && peerId.isNotEmpty && peerId == myUserId) {
    return null;
  }

  return IncomingCallPush(
    peerId: peerId.isNotEmpty ? peerId : fallbackPeerId.trim(),
    callerName: name.isNotEmpty ? name : fallbackName.trim(),
    isVideo: asInt(payload['type'], CallType.voice) == CallType.video,
    signal: frame,
    sentAt: _sentAtOf(frame),
  );
}

/// `payload` 解成那条 `calling` 报文（服务端超长丢掉时是空串）
Map<String, dynamic>? _decodeSignal(String raw) {
  if (raw.isEmpty) return null;
  try {
    final decoded = json.decode(raw);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// `sendTime` 是毫秒（服务端 `time() * 1000`，见 `Im::sendToMsg`）
DateTime? _sentAtOf(Map<String, dynamic>? signal) {
  if (signal == null) return null;
  final raw = asInt(signal['sendTime'], 0);
  if (raw <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(raw);
}
