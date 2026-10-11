import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import '../../core/util/json_value.dart';
import '../db/app_database.dart';
import 'time_units.dart';

/// 消息模型。
///
/// 字段来自三处实际用法：
/// * `App.vue::appendMessage` 与 `store/message.js::getContact`——推送消息怎么落到会话上；
/// * `pages/message/chat.vue`——渲染用到哪些字段（`fromUser.realname`、`extends`、`is_undo`…）；
/// * `docs/protocol/ws-events.md` 的「消息体字段」表。
///
/// 两个刻意的处理：
/// * [sendTime] **一律毫秒**（见 `time_units.dart`，老端秒/毫秒混用）；
/// * `at` 与 `extends` 原样存 JSON 字符串，同时给出解析后的访问器，
///   避免每次读 `extends.code` 都要解析一遍。
/// 发送状态。老端只用三个值（`going` / `failed`，没有状态就是成功）。
///
/// 注意它是"本机行为"，服务端不会下发：收到的消息一律 [sent]。
abstract final class MessageStatus {
  /// 已发送（或收到）
  static const String sent = 'sent';

  /// 正在发（乐观消息，等接口回执）
  static const String going = 'going';

  /// 发送失败，可点重发
  static const String failed = 'failed';
}

class Message {
  const Message({
    this.localId,
    this.serverId,
    this.msgId,
    this.clientId,
    required this.conversationId,
    this.fromUserId = '',
    this.fromUserName = '',
    this.fromUserAvatar = '',
    this.toContactId = '',
    this.toUser = '',
    this.type = 'text',
    this.content = '',
    this.sendTime = 0,
    this.at = const <String>[],
    this.ext = const <String, dynamic>{},
    this.isGroup = 0,
    this.isRead = 0,
    this.isUndo = 0,
    this.isMobile = 0,
    this.status = MessageStatus.sent,
    this.extra = const <String, dynamic>{},
    this.providedKeys,
  });

  final int? localId;

  /// 服务端消息主键（老端到处用的 `item.id`；通话里作为 `main_id`）
  final int? serverId;

  /// 业务消息 id（客户端生成 uuid，老端用它对消息去重）
  final String? msgId;

  /// 本机生成的消息 id（发出去时放在 `id` 字段里，见 `tables.dart` 的说明）
  final String? clientId;

  /// 归属会话 id
  final String conversationId;

  final String fromUserId;
  final String fromUserName;
  final String fromUserAvatar;
  final String toContactId;
  final String toUser;
  final String type;
  final String content;

  /// 毫秒
  final int sendTime;

  final List<String> at;
  final Map<String, dynamic> ext;
  final int isGroup;
  final int isRead;
  final int isUndo;
  final int isMobile;

  /// 发送状态（见 [MessageStatus]）
  final String status;

  /// 服务端给的其它字段
  final Map<String, dynamic> extra;

  /// 这条消息是从服务端 JSON 解出来的时候，**JSON 里真的出现了哪些 key**。
  ///
  /// 只服务于 [overlayWith]：服务端的回执可能只有 `{id: 1, status: "sent"}`，
  /// 光看解出来的对象分不清“服务端说了 text”与“服务端没说 type”
  /// （解出来的默认值都是 text）。手工构造的消息这里是 null，表示“全都算提供了”。
  final Set<String>? providedKeys;

  /// 正在发送中（界面上显示转圈）
  bool get isSending => status == MessageStatus.going;

  /// 发送失败（界面上显示红叹号，点了重发）
  bool get isFailed => status == MessageStatus.failed;

  /// 服务端消息 JSON → 模型。
  ///
  /// [conversationId] 由调用方给：REST 列表接口的场景已经知道是哪个会话；
  /// 推送场景用 [conversationIdFor] 推出来（老端 `appendMessage` 里的
  /// 「如果 toContactId 是我自己，那接收人就是 toUser」）。
  factory Message.fromServerJson(
    Map<String, dynamic> json, {
    required String conversationId,
    int? isMobile,
  }) {
    final fromUser = asMap(json['fromUser']);
    final ext = asMap(json['extends']);
    final rawId = asText(json['id']);
    return Message(
      serverId: asInt(json['id'], 0) == 0 ? null : asInt(json['id'], 0),
      msgId: asText(json['msg_id']).isEmpty ? null : asText(json['msg_id']),
      // `id` 不是数字说明服务端把我们的 uuid 原样回传了（老端自己的行为），
      // 存下来就能把回显认领到本机那条乐观消息上
      clientId: _numeric(rawId) ? null : (rawId.isEmpty ? null : rawId),
      conversationId: conversationId,
      fromUserId: asText(fromUser['id'] ?? fromUser['user_id']),
      fromUserName: asText(fromUser['displayName'] ?? fromUser['realname']),
      fromUserAvatar: asText(fromUser['avatar']),
      toContactId: asText(json['toContactId']),
      toUser: asText(json['toUser']),
      type: asText(json['type'], 'text'),
      content: asText(json['content']),
      sendTime: toMillis(json['sendTime']),
      at: asList(json['at']).map((value) => value.toString()).toList(),
      ext: ext,
      isGroup: asInt(json['is_group'], 0),
      isRead: 0,
      isUndo: asInt(json['is_undo'], 0),
      isMobile: isMobile ?? asInt(ext['isMobile'], 0),
      status: _statusOf(json),
      extra: Map<String, dynamic>.from(json)
        ..remove('fromUser')
        ..remove('extends'),
      providedKeys: json.keys.toSet(),
    );
  }

  static Message fromRow(DbMessage row) => Message(
    localId: row.localId,
    serverId: row.serverId,
    msgId: row.msgId,
    clientId: row.clientId,
    conversationId: row.conversationId,
    fromUserId: row.fromUserId,
    fromUserName: row.fromUserName,
    fromUserAvatar: row.fromUserAvatar,
    toContactId: row.toContactId,
    toUser: row.toUser,
    type: row.type,
    content: row.content,
    sendTime: row.sendTime,
    at: _decodeList(row.atUsers),
    ext: _decodeMap(row.ext),
    isGroup: row.isGroup,
    isRead: row.isRead,
    isUndo: row.isUndo,
    isMobile: row.isMobile,
    status: row.status,
    extra: _decodeMap(row.extra),
  );

  DbMessagesCompanion toCompanion() => DbMessagesCompanion(
    localId: localId == null ? const Value.absent() : Value(localId!),
    serverId: Value(serverId),
    msgId: Value(msgId),
    clientId: Value(clientId),
    conversationId: Value(conversationId),
    fromUserId: Value(fromUserId),
    fromUserName: Value(fromUserName),
    fromUserAvatar: Value(fromUserAvatar),
    toContactId: Value(toContactId),
    toUser: Value(toUser),
    type: Value(type),
    content: Value(content),
    sendTime: Value(sendTime),
    atUsers: Value(jsonEncode(at)),
    ext: Value(jsonEncode(ext)),
    isGroup: Value(isGroup),
    isRead: Value(isRead),
    isUndo: Value(isUndo),
    isMobile: Value(isMobile),
    status: Value(status),
    extra: Value(jsonEncode(extra)),
  );

  Message copyWith({
    int? localId,
    int? isRead,
    int? isUndo,
    String? content,
    String? status,
    int? serverId,
    String? msgId,
    String? clientId,
    Map<String, dynamic>? extra,
    Set<String>? providedKeys,
  }) => Message(
    localId: localId ?? this.localId,
    serverId: serverId ?? this.serverId,
    msgId: msgId ?? this.msgId,
    clientId: clientId ?? this.clientId,
    conversationId: conversationId,
    fromUserId: fromUserId,
    fromUserName: fromUserName,
    fromUserAvatar: fromUserAvatar,
    toContactId: toContactId,
    toUser: toUser,
    type: type,
    content: content ?? this.content,
    sendTime: sendTime,
    at: at,
    ext: ext,
    isGroup: isGroup,
    isRead: isRead ?? this.isRead,
    isUndo: isUndo ?? this.isUndo,
    isMobile: isMobile,
    status: status ?? this.status,
    extra: extra ?? this.extra,
    providedKeys: providedKeys ?? this.providedKeys,
  );

  /// 把「服务端给的一条」**叠加**到本机已有的这条上（老端 `Object.assign(msg, message)`）。
  ///
  /// 只有服务端真的给了值的字段才会覆盖，其余保持本地原样。为什么要这么细：
  /// 服务端的回执可能只带一个 id 与状态（比如 `data` 就是 `{}`），
  /// 无脑整行覆盖会把本地的正文、时间、发送人全清空——这个坑是发消息的
  /// 单测抓出来的（插入的行变成了空消息）。
  Message overlayWith(Message incoming) {
    final keys = incoming.providedKeys;

    /// 服务端真的给了这个字段吗（手工构造的消息没有 [providedKeys]，一律算给了）
    bool has(String key) => keys == null || keys.contains(key);

    return Message(
      localId: localId,
      serverId: incoming.serverId ?? serverId,
      msgId: has('msg_id') && (incoming.msgId ?? '').isNotEmpty
          ? incoming.msgId
          : msgId,
      clientId: (incoming.clientId ?? '').isNotEmpty
          ? incoming.clientId
          : clientId,
      conversationId: incoming.conversationId.isNotEmpty
          ? incoming.conversationId
          : conversationId,
      fromUserId: has('fromUser') && incoming.fromUserId.isNotEmpty
          ? incoming.fromUserId
          : fromUserId,
      fromUserName: has('fromUser') && incoming.fromUserName.isNotEmpty
          ? incoming.fromUserName
          : fromUserName,
      fromUserAvatar: has('fromUser') && incoming.fromUserAvatar.isNotEmpty
          ? incoming.fromUserAvatar
          : fromUserAvatar,
      toContactId: has('toContactId') && incoming.toContactId.isNotEmpty
          ? incoming.toContactId
          : toContactId,
      toUser: has('toUser') && incoming.toUser.isNotEmpty
          ? incoming.toUser
          : toUser,
      type: has('type') && incoming.type.isNotEmpty ? incoming.type : type,
      content: has('content') && incoming.content.isNotEmpty
          ? incoming.content
          : content,
      sendTime: has('sendTime') && incoming.sendTime > 0
          ? incoming.sendTime
          : sendTime,
      at: has('at') && incoming.at.isNotEmpty ? incoming.at : at,
      ext: has('extends') && incoming.ext.isNotEmpty ? incoming.ext : ext,
      isGroup: has('is_group') && incoming.isGroup != 0
          ? incoming.isGroup
          : isGroup,
      // 已读/撤回只能往「已完成」方向走，不能被回执退化
      isRead: incoming.isRead == 1 ? 1 : isRead,
      isUndo: incoming.isUndo == 1 ? 1 : isUndo,
      isMobile: incoming.isMobile == 1 ? 1 : isMobile,
      // 服务端说 `sent` 就采纳（说明它真的收到了）；`going`/`failed` 是本机的，不覆盖
      status: incoming.status == MessageStatus.sent ? incoming.status : status,
      extra: incoming.extra.isEmpty
          ? extra
          : <String, dynamic>{...extra, ...incoming.extra},
    );
  }

  /// 是否是我发的
  bool isMine(String myUserId) => fromUserId == myUserId;

  /// 通话信令相关（M6 用，先把解析做掉）
  String? get webrtcEvent => ext['event']?.toString();

  int? get webrtcCode => int.tryParse(ext['code']?.toString() ?? '');

  /// 图片/语音/文件等类型的具体参数都在 `extends` 里
  Map<String, dynamic> get payload => ext;

  /// 推送消息属于哪个会话（老端 `appendMessage` 的判定逻辑）
  static String conversationIdFor(
    Map<String, dynamic> json, {
    required String myUserId,
  }) {
    final toContactId = asText(json['toContactId']);
    if (toContactId == myUserId) {
      final toUser = asText(json['toUser']);
      return toUser.isEmpty ? toContactId : toUser;
    }
    return toContactId;
  }

  @override
  String toString() =>
      'Message(#$serverId $type "${content.length > 20 ? "${content.substring(0, 20)}…" : content}" '
      'in $conversationId @$sendTime)';
}

/// 服务端回执里带的 `status`（老端只在本地拼，服务端一般不回）
String _statusOf(Map<String, dynamic> json) {
  final status = asText(json['status']);
  if (status == MessageStatus.going || status == MessageStatus.failed) {
    return status;
  }
  return MessageStatus.sent;
}

/// 纯数字（含负数）才算"服务端的数字主键"，其余当字符串 id 处理
bool _numeric(String value) {
  if (value.isEmpty) return false;
  return int.tryParse(value) != null;
}

List<String> _decodeList(String raw) {
  if (raw.isEmpty) return const <String>[];
  try {
    final decoded = json.decode(raw);
    if (decoded is List) {
      return decoded.map((value) => value.toString()).toList();
    }
  } on FormatException {
    // 坏数据当空处理：不能因为一行脏数据让整个聊天页打不开
  }
  return const <String>[];
}

Map<String, dynamic> _decodeMap(String raw) {
  if (raw.isEmpty) return const <String, dynamic>{};
  try {
    final decoded = json.decode(raw);
    if (decoded is Map) return decoded.cast<String, dynamic>();
  } on FormatException {
    // 同上
  }
  return const <String, dynamic>{};
}
