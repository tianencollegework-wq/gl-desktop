import 'dart:convert';

import 'package:flutter/foundation.dart' show immutable;

import '../../core/util/emoji.dart';
import '../../core/util/json_value.dart';
import '../../data/model/conversation.dart';
import '../../data/model/message.dart';
import '../call/call_signal.dart' show CallType;
import 'conversation_rules.dart';

/// 一条要弹到系统通知栏的消息（**纯数据**，好单测）
@immutable
class MessageNotification {
  const MessageNotification({
    required this.conversationId,
    required this.title,
    required this.body,
  });

  /// 点通知要进哪个会话（也用来当通知 id，同一会话的通知会互相覆盖）
  final String conversationId;

  /// 通知标题：会话名（群名 / 对方昵称）
  final String title;

  /// 通知内容：群消息带「发送者: 」，非文本显示「[图片]」这类占位
  final String body;

  @override
  bool operator ==(Object other) =>
      other is MessageNotification &&
      other.conversationId == conversationId &&
      other.title == title &&
      other.body == body;

  @override
  int get hashCode => Object.hash(conversationId, title, body);

  @override
  String toString() => 'MessageNotification($conversationId, $title, $body)';
}

/// 这条消息要不要弹通知、弹出什么内容。对应老端 `App.vue::createPushMsg` 前后那段：
///
/// ```js
/// let appStatus = this.appStatus;
/// // 如果app在后台运行,不是自己发的，并且开启了通知，就创建通知栏
/// if(!appStatus && data.fromUser.id!=userInfo.user_id && contact.is_notice==1){
///   this.createPushMsg(data,contact);
/// }
/// ```
///
/// 三个条件缺一不可：**App 在后台**、**不是自己发的**、**会话没关通知（没免打扰）**。
///
/// 与老端的两处不同（刻意的）：
/// * 老端正文直接用 `data.content` 去掉 HTML 标签，文本之外的类型在服务端
///   `unipush()` 里换成类型文案；新端**客户端自己也算一遍**（因为它才是真正弹通知的
///   那一步），文本走 [previewText]（顺带剥掉表情 token，与列表预览同一套）；
/// * 标题取不到（会话名和发信人昵称都空）时**不弹**——老端会画一条没有标题的通知。
MessageNotification? messageNotificationOf({
  required Message message,
  required Conversation? conversation,
  required String myUserId,
  required bool appInForeground,
  required String Function(String key) translate,
}) {
  // 前台有应用内的提示音，不再弹通知（老端也是这个条件）
  if (appInForeground) return null;
  if (myUserId.isNotEmpty && message.fromUserId == myUserId) return null;
  // 免打扰（老端 `contact.is_notice == 1`；新端 Conversation.muted 就是它）
  if (conversation?.muted ?? false) return null;

  // 会话名走 `ConversationRules.displayNameOf`：通知栏上那个名字也要跟语言走
  // （「我的收藏」「系统通知」两个名字是服务端用中文存的）
  final conversationName = conversation == null
      ? ''
      : ConversationRules.displayNameOf(
          conversation,
          translate: translate,
        ).trim();
  final senderName = message.fromUserName.trim();
  var title = conversationName.isNotEmpty ? conversationName : senderName;
  // 系统消息没有会话对象（`conversation_repository` 对 'system' 返回 null），
  // 发信人昵称也常常是空的 —— 用会话列表里那个同一个名字兜底
  // （老端这类消息压根走不到通知，因为它的条件里要 `contact`）。
  if (title.isEmpty && message.conversationId == 'system') {
    title = translate('user.systemNotice');
  }
  if (title.isEmpty) return null;

  return MessageNotification(
    conversationId: message.conversationId,
    title: title,
    body: notificationBodyOf(message, translate),
  );
}

/// 一条推送（FCM 数据消息）要不要弹通知、弹出什么内容（S8.1）。
///
/// 服务端**只发数据消息**，通知栏还是由客户端画出来（契约见后端
/// `PushMessage::dataPayload()`，改那边就要同步改这里）：
///
/// | 字段 | 用途 |
/// |---|---|
/// | `contact_id` | 点通知要进哪个会话（`payload` 丢了就靠它） |
/// | `title` / `content` | 服务端算好的标题与预览（`payload` 丢了就靠它们） |
/// | `payload` | 整条消息的 JSON（与 WS 那份同构）→ 走**和 WS 完全一样**的正文规则 |
/// | `msg_id` | 备用（去重在服务端做：在线不推，见 `wsSendMsg()`） |
///
/// 这里**不重复判断**「App 在不在前台」「会话有没有免打扰」：
/// 前者由送达时机保证（前台收数据消息走 `onMessage`，我们不看），
/// 后者服务端下发前已经查过。但「自己发的不弹」要挡一道（群聊扇出时是双保险）。
///
/// 有两处是**刻意**与 WS 那条路保持一致的：标题优先用会话名、正文复用同一套规则 ——
/// 用户不该看出这条通知是「长连接来的」还是「推送来的」。
MessageNotification? messageNotificationFromPush({
  required Map<String, String> data,
  required String myUserId,
  required String Function(String key) translate,
}) {
  final payload = _decodePayload(data['payload'] ?? '');
  final message = payload == null
      ? null
      : Message.fromServerJson(
          payload,
          // 与 WS 那条路同一个口径：`toContactId` 是「会话」还是「接收人」，
          // 由「它是不是我自己」决定（老端 `appendMessage` 里的那半句）
          conversationId: Message.conversationIdFor(
            payload,
            myUserId: myUserId,
          ),
        );

  // 自己发的不弹（服务端只在接收者离线时推、且会排掉发送人，这里是双保险）
  if (message != null &&
      myUserId.isNotEmpty &&
      message.fromUserId == myUserId) {
    return null;
  }

  final conversationId = (message?.conversationId.isNotEmpty ?? false)
      ? message!.conversationId
      : (data['contact_id'] ?? '').trim();
  if (conversationId.isEmpty) return null;

  // 标题：会话名（`payload` 里带了 `contactInfo` 时用它 —— 群聊要显示群名，
  // 而不是发消息那个人的名字）；取不到再退到发送人昵称 / 服务端给的标题。
  final contactName = asText(
    asMap(payload?['contactInfo'])['displayName'],
  ).trim();
  final senderName = message?.fromUserName.trim() ?? '';
  var title = contactName;
  if (title.isEmpty) title = senderName;
  if (title.isEmpty) title = (data['title'] ?? '').trim();
  if (title.isEmpty) return null;

  // 正文：能解出整条消息就用与 WS 同一套规则（群消息带发送者、表情 token 剥掉、
  // 非文本用类型文案）；解不出来就用服务端给的那份预览。
  final body = message != null
      ? notificationBodyOf(message, translate)
      : (data['content'] ?? '').trim();

  return MessageNotification(
    conversationId: conversationId,
    title: title,
    body: body,
  );
}

/// `payload` 解成一条消息的 JSON（服务端因为超长丢掉 payload 时是空串）。
/// 解不出来一律当没有：宁可退回服务端给的 title/content，也不能因为解析炸掉通知。
Map<String, dynamic>? _decodePayload(String raw) {
  if (raw.isEmpty) return null;
  try {
    final decoded = json.decode(raw);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// 通知正文：老端 `createPushMsg` 里那段
String notificationBodyOf(
  Message message,
  String Function(String key) translate,
) {
  final content = ConversationRules.rawPreviewTypes.contains(message.type)
      // 文本类（text / event / location / contact）显示原文
      ? previewText(message.content)
      : ConversationRules.preview(
          type: message.type,
          translate: translate,
          callVideo: _callVideoOf(message),
        );

  if (content.isEmpty) {
    // 文本被表情 token 吃干净了（比如整条只有一个表情）→ 退回类型占位
    return ConversationRules.preview(
      type: message.type,
      translate: translate,
      callVideo: _callVideoOf(message),
    );
  }

  // 群消息要带发送者（老端 `if(data.is_group==1) content=displayName+':'+content`）
  if (message.isGroup == 1 && message.fromUserName.trim().isNotEmpty) {
    return '${message.fromUserName.trim()}: $content';
  }
  return content;
}

/// `webrtc` 消息的通话类型来自 `extends.type`（老端 `data.extends.type`）：
/// `0` 语音、`1` 视频（见 [CallType]）。取不到时给 null，显示「[音视频通话]」。
bool? _callVideoOf(Message message) {
  if (message.type != 'webrtc') return null;
  final raw = message.ext['type'];
  if (raw == null) return null;
  return asInt(raw, CallType.voice) == CallType.video;
}
