/// 发出去的消息怎么拼（S4.4）。
///
/// 对照的是老端 `components/message/im-input.vue` 的 `msgItem()` 与
/// `pages/message/chat.vue` 的 `sendMessage()`：
/// 先由输入区拼一个「本地消息」，再由聊天页补上 `fromUser` / `from_user` /
/// `toContactId` / `is_group` 四项，然后交给接口。
///
/// **两个刻意的差别**：
/// 1. `content` 是**纯文本**（含 `[!code]` 表情 token），不是老端那种带 `<p>` 的
///    富文本 HTML。老端渲染时本来就要把 token 换成图片（`im-text.vue::emojiToHtml`），
///    所以对方看到的完全一样；而纯文本在会话列表预览、搜索、通知里都更干净。
/// 2. `at` 保持字符串，不做老端那个 `parseInt`（老端把 user_id 转成数字再发，
///    遇到非数字账号会变成 NaN）。
library;

import '../../core/util/rich_text.dart';
import '../../data/model/conversation.dart';
import '../../data/model/message.dart';
import '../../data/model/user_info.dart';
import 'conversation_rules.dart';

/// 拼一条待发送的消息（服务端 `sendMessage` 的请求体）。
///
/// 字段名逐字对齐老端，包括那个 `fromUser` 里额外的 `id`
/// （老端 `user.id = user.user_id`，然后整份塞进 `fromUser`）。
Map<String, dynamic> buildOutgoingPayload({
  required String clientId,
  required String type,
  required String content,
  required UserInfo me,
  required String toContactId,
  required int isGroup,
  required int sendTimeMs,
  Map<String, dynamic>? ext,
  Map<String, dynamic>? quote,
  String? pid,
  List<String> at = const <String>[],
  String fileName = '',
  int fileSize = 0,
  int fileId = 0,
  int fileCate = 0,
}) {
  final payload = <String, dynamic>{
    'id': clientId,
    'sendTime': sendTimeMs,
    'status': MessageStatus.going,
    'type': type,
    'content': content,
    'is_read': 0,
    'is_group': isGroup,
    'file_id': fileId,
    'file_cate': fileCate,
    'fileName': fileName,
    'fileSize': fileSize,
    'extends': ext,
    'fromUser': <String, dynamic>{...me.toJson(), 'id': me.userId},
    'from_user': me.userId,
    'toContactId': toContactId,
  };
  if (quote != null) payload['extends'] = quote;
  if (pid != null) payload['pid'] = pid;
  if (at.isNotEmpty) payload['at'] = at;
  return payload;
}

/// 引用块（老端 `chat.vue::quoteMsgInfo`）。
///
/// 老端把引用的内容摘成一行：文字去掉 HTML 标签，其它类型换成「[图片]」这类占位，
/// 前面冠上发送人名字；`msg_id` 作为 `pid` 一起发出去。
///
/// 去标签用 [richToSingleLine]（不是正则一把挠）：网页端发来的 `content` 是 HTML，
/// 里面有实体（`&nbsp;`）和 `<br>`，那些都要按老端 `htmlToLines` 的规矩处理。
Map<String, dynamic> buildQuote(
  Message message, {
  required String Function(String key) translate,
}) {
  final stripped = richToSingleLine(message.content);
  final preview = ConversationRules.rawPreviewTypes.contains(message.type)
      ? stripped
      : ConversationRules.preview(type: message.type, translate: translate);
  return <String, dynamic>{
    'msg_id': message.msgId,
    'content': '${message.fromUserName}：$preview',
    'user_id': message.fromUserId,
    'realname': message.fromUserName,
  };
}

/// 能不能在这个会话里发言（老端 `chat.vue::nospeak`，名字起反了，语义是「可以发」）。
///
/// 群聊开了禁言时：`setting.nospeak == 1` 只有群主/管理员能发，
/// `setting.nospeak == 2` 只有群主能发。单聊永远能发。
bool canSpeak(Conversation? conversation) {
  if (conversation == null) return true;
  final setting = conversation.extra['setting'];
  final nospeak = setting is Map ? _toInt(setting['nospeak']) : 0;
  if (conversation.isGroup == 1 && nospeak > 0) {
    if (nospeak == 1 && conversation.role < 3) return true;
    if (nospeak == 2 && conversation.role == 1) return true;
    return false;
  }
  return true;
}

int _toInt(Object? value) => int.tryParse(value?.toString() ?? '') ?? 0;
