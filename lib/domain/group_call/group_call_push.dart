import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;

import '../../core/util/json_value.dart';
import '../chat/message_notification.dart' show MessageNotification;

/// 群通话的**离线推送**（S6.14）。
///
/// 解决的是这件事：**群里有人开语音时，没打开 App 的人什么都不知道**。
/// 长连接那条路对他们是断的（`sfuRoom` 那条 WS 提示只发给在线的人），
/// 所以只能由服务端推一条通知把他们叫醒 —— 这就是这一块。
///
/// 与 1:1 来电那套（`incoming_call_push.dart`）**刻意分开**，因为形状不一样：
///
/// | | 1:1 来电 | 群通话 |
/// |---|---|---|
/// | 谁在响 | 一个指名道姓的人 | 一个群，谁都可以进来 |
/// | 服务端什么时候推 | 叫号那一下（`Im::sendToMsg`） | 这个房间**第一次有人进来**（`Sfu::session`） |
/// | 什么时候收 | 主叫取消 / 超时（`pushCallCanceled`） | **房间空了**（`Sfu::leave` / TTL 清场） |
/// | 点开去哪 | 来电页（要接听） | 群通话页（进去就是加入） |
///
/// 服务端那两个帧（`Sfu.php::pushGroupCall`）长这样（改那边要同步改这里）：
///
/// ```json
/// {
///   "id": "<call_id>",
///   "type": "group_call",
///   "toContactId": "group-5",          // = 群会话 id
///   "fromUser": {"id": "7", "displayName": "张三"},
///   "sendTime": 1699999999000,
///   "extends": {
///     "event": "groupCalling",         // 响铃；结束帧是 groupCallEnded
///     "call_id": "<call_id>",
///     "group_id": "5",
///     "name": "项目群"
///   }
/// }
/// ```
///
/// 而 FCM 那条数据消息把它们摊平成 `PushMessage::dataPayload()` 那几个字段
/// （`type` / `event` / `contact_id` / `call_id` / `payload`），客户端按那份契约读。

/// 群通话推送的 `type`（服务端 `Sfu.php` 里写死的那一个）
const String groupCallPushType = 'group_call';

/// 帧上的事件名
abstract final class GroupCallPushEvent {
  /// 群里有人开语音了：弹一条**能响铃**的通知
  static const String ringing = 'groupCalling';

  /// 这通群语音结束了：把那条通知**静默收掉**（不弹任何东西）
  static const String ended = 'groupCallEnded';
}

/// 这一通群语音的 id 放在哪个字段（与 1:1 那份同名，服务端也是同一个出处）
const String groupCallPushIdKey = 'call_id';

/// 这条推送是不是「群里有人开语音」（该响铃）
bool isGroupCallRingPush(Map<String, String> data) {
  if (data['type'] != groupCallPushType) return false;
  return data['event'] == GroupCallPushEvent.ringing;
}

/// 这条推送是不是「这通群语音结束了」（该把通知收掉）。
///
/// 为什么非得有这么一条：收到邀请的人**恰恰是长连接不在线的那一端**，
/// 「房间里没人了」这件事他一个字都收不到 —— 没有这一条，那条通知（和它的铃声）
/// 只能干等系统超时。1:1 那边是同一个道理（见 `isCallCancelPush`）。
bool isGroupCallEndPush(Map<String, String> data) {
  if (data['type'] != groupCallPushType) return false;
  return data['event'] == GroupCallPushEvent.ended;
}

/// 推送里那通群语音的 id（服务端没给就是空串）。
///
/// 用来挡一件真事：**新的一通群语音刚开始响、上一通那条结束帧才姗姗来迟** ——
/// 不带 id 地无条件收通知，会把正在响的那通一起收掉。
String groupCallPushIdOf(Map<String, String> data) =>
    (data[groupCallPushIdKey] ?? '').trim();

/// 一条**被离线推送送来的群通话邀请**。
@immutable
class GroupCallPush {
  const GroupCallPush({
    required this.conversationId,
    required this.groupName,
    required this.starterName,
    required this.callId,
    required this.payload,
    required this.frame,
    required this.sentAt,
  });

  /// 群会话 id（`group-5`）：点通知要进的那个群，也是群通话页的 `id` 参数
  final String conversationId;

  /// 群名（通知标题；取不到是空串，会退回「群语音通话」这个通用文案）
  final String groupName;

  /// 发起人的昵称（通知正文里那句「张三 邀请你加入群语音」）
  final String starterName;

  /// 这一通群语音的 id（服务端在响铃帧与结束帧里给的是同一个）
  final String callId;

  /// **服务端原样的那份**报文 JSON（点通知 / 冷启动用它重建邀请，
  /// 与 1:1 来电那条同一个理由：主 isolate 要拿它当报文用）
  final String payload;

  /// 解开的报文（服务端的 `payload` 被超长丢掉时是空 map）
  final Map<String, dynamic> frame;

  /// 服务端发出这条推送的时刻（`sendTime`，毫秒）。取不到是 null。
  final DateTime? sentAt;

  /// 能不能靠它点进群通话页
  bool get canOpen => conversationId.isNotEmpty;

  /// 这条邀请是不是还值得响铃。
  ///
  /// 服务端那条推送的存活时间是 60 秒（`isCall`：来电与邀请共用那一套下发参数），
  /// 所以迟到一分钟以上的邀请不该再响 —— 群里那通可能早就结束了，
  /// 半夜响一下再被自己的结束帧收掉，比不响更烦人。
  bool isFresh(DateTime now, {Duration window = const Duration(minutes: 2)}) {
    final sent = sentAt;
    if (sent == null) return true; // 没有时间就当它是新的（宁可多响一次）
    // 只卡上界（理由与 1:1 那份一样：两端时钟差几秒不该让来电被漏掉）
    return now.difference(sent) <= window;
  }

  /// 画到通知栏上的样子：标题 = **群名**，正文 = 「张三 邀请你加入群语音」。
  ///
  /// [translate] 收 (key, fallback)：后台 isolate 里语言包可能没加载成功，
  /// 那时用 fallback（与 `PushNotificationHandler` 里其它文案同一个套路）。
  MessageNotification toNotification(
    String Function(String key, String fallback) translate,
  ) {
    final invite = translate('group.pushRing', '邀请你加入群语音');
    return MessageNotification(
      conversationId: conversationId,
      title: groupName.isEmpty
          ? translate('group.pushTitle', '群语音通话')
          : groupName,
      body: starterName.isEmpty ? invite : '$starterName $invite',
    );
  }
}

/// 把一条推送数据解析成群通话邀请。**不是邀请就返回 null**。
GroupCallPush? groupCallFromPush({required Map<String, String> data}) {
  if (!isGroupCallRingPush(data)) return null;
  return _fromFrame(
    _decodeFrame(data['payload'] ?? ''),
    payload: data['payload'] ?? '',
    fallbackConversationId: (data['contact_id'] ?? '').trim(),
    fallbackGroupName: (data['title'] ?? '').trim(),
    fallbackCallId: groupCallPushIdOf(data),
  );
}

/// 直接从**一整条报文**还原邀请（不带推送那层包装）。
///
/// 这条入口是给「点通知 / 冷启动」用的（见 `GroupCallPushHost`）：通知的 payload
/// 里放的就是这条报文，不再是推送数据那张表。会再验一次「它确实是一条群通话邀请」——
/// 那份 payload 是我们自己写的，但它是从**外部**（系统通知）绕回来的。
GroupCallPush? groupCallFromSignal(Map<String, dynamic>? signal) {
  final frame = signal ?? const <String, dynamic>{};
  if (asText(frame['type']) != groupCallPushType) return null;
  final ext = asMap(frame['extends']);
  if (asText(ext['event']) != GroupCallPushEvent.ringing) return null;
  return _fromFrame(
    frame,
    payload: jsonEncode(frame),
    fallbackConversationId: asText(frame['toContactId']).trim(),
    fallbackGroupName: '',
    fallbackCallId: '',
  );
}

GroupCallPush _fromFrame(
  Map<String, dynamic>? frame, {
  required String payload,
  required String fallbackConversationId,
  required String fallbackGroupName,
  required String fallbackCallId,
}) {
  final ext = asMap(frame?['extends']);
  final from = asMap(frame?['fromUser']);

  final conversationId = asText(frame?['toContactId']).trim();
  final callId = asText(ext[groupCallPushIdKey]).trim();
  final groupName = asText(ext['name']).trim();

  return GroupCallPush(
    conversationId: conversationId.isNotEmpty
        ? conversationId
        : fallbackConversationId,
    groupName: groupName.isNotEmpty ? groupName : fallbackGroupName,
    starterName: asText(from['displayName'] ?? from['realname']).trim(),
    callId: callId.isNotEmpty
        ? callId
        : (asText(frame?['id']).trim().isNotEmpty
              ? asText(frame?['id']).trim()
              : fallbackCallId),
    payload: payload,
    frame: frame ?? const <String, dynamic>{},
    sentAt: _sentAtOf(frame),
  );
}

Map<String, dynamic>? _decodeFrame(String raw) {
  if (raw.isEmpty) return null;
  try {
    final decoded = json.decode(raw);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// `sendTime` 是毫秒（服务端 `time() * 1000`）
DateTime? _sentAtOf(Map<String, dynamic>? frame) {
  if (frame == null) return null;
  final raw = asInt(frame['sendTime'], 0);
  if (raw <= 0) return null;
  return DateTime.fromMillisecondsSinceEpoch(raw);
}
