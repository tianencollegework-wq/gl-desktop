import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import '../../core/util/json_value.dart';
import '../db/app_database.dart';
import 'time_units.dart';

/// 会话（老端 `allContacts` 里的一项，也是 `mainContacts[id]` 的 value）。
///
/// 老端的字段全部来自服务端，命名是 `is_group` / `is_at` / `is_notice` 那一套；
/// 落库时只把界面确实用到的拆成列，其余塞进 [extra]，服务端加字段不会丢。
class Conversation {
  const Conversation({
    required this.id,
    this.displayName = '',
    this.avatar = '',
    this.lastContent = '',
    this.lastSendTime = 0,
    this.lastType = 'text',
    this.isGroup = 0,
    this.unread = 0,
    this.isAt = 0,
    this.isTop = 0,
    this.isNotice = 1,
    this.role = 0,
    this.depId = 0,
    this.isOnline = 0,
    this.draft = '',
    this.extra = const <String, dynamic>{},
  });

  /// 单聊是对方 `user_id`，群聊是 `group_id`，系统消息是 `system`
  final String id;

  final String displayName;
  final String avatar;

  /// 最后一条消息的原文（展示时非文本类型会换成「[图片]」这类占位）
  final String lastContent;

  /// 毫秒
  final int lastSendTime;

  final String lastType;

  /// 1 群聊；2 群聊且推送时额外累加未读
  final int isGroup;

  final int unread;
  final int isAt;
  final int isTop;

  /// 0 免打扰、1 提醒
  final int isNotice;

  /// 群内角色，`< 3` 表示有撤回权限
  final int role;

  final int depId;
  final int isOnline;
  final String draft;
  final Map<String, dynamic> extra;

  factory Conversation.fromServerJson(Map<String, dynamic> json) {
    final id = asText(json['id']);
    return Conversation(
      id: id,
      displayName: asText(json['displayName'] ?? json['name']),
      avatar: asText(json['avatar']),
      lastContent: asText(json['lastContent']),
      lastSendTime: toMillis(json['lastSendTime']),
      lastType: asText(json['type'], 'text'),
      isGroup: asInt(json['is_group'], 0),
      unread: asInt(json['unread'], 0),
      isAt: asInt(json['is_at'], 0),
      isTop: asInt(json['is_top'], 0),
      isNotice: asInt(json['is_notice'], 1),
      role: asInt(json['role'], 0),
      depId: asInt(json['dep_id'], 0),
      isOnline: asInt(json['is_online'], 0),
      draft: asText(json['draft']),
      extra: Map<String, dynamic>.from(json)
        ..remove('id')
        ..remove('displayName')
        ..remove('name')
        ..remove('avatar')
        ..remove('lastContent')
        ..remove('lastSendTime')
        ..remove('type')
        ..remove('is_group')
        ..remove('unread')
        ..remove('is_at')
        ..remove('is_top')
        ..remove('is_notice')
        ..remove('role')
        ..remove('dep_id')
        ..remove('is_online')
        ..remove('draft'),
    );
  }

  /// 推送里带的 `contactInfo`（陌生会话）→ 会话
  static Conversation fromContactInfo(Map<String, dynamic> json) =>
      Conversation.fromServerJson(json);

  static Conversation fromRow(DbConversation row) => Conversation(
    id: row.id,
    displayName: row.displayName,
    avatar: row.avatar,
    lastContent: row.lastContent,
    lastSendTime: row.lastSendTime,
    lastType: row.lastType,
    isGroup: row.isGroup,
    unread: row.unread,
    isAt: row.isAt,
    isTop: row.isTop,
    isNotice: row.isNotice,
    role: row.role,
    depId: row.depId,
    isOnline: row.isOnline,
    draft: row.draft,
    extra: _decodeMap(row.extra),
  );

  DbConversationsCompanion toCompanion() => DbConversationsCompanion(
    id: Value(id),
    displayName: Value(displayName),
    avatar: Value(avatar),
    lastContent: Value(lastContent),
    lastSendTime: Value(lastSendTime),
    lastType: Value(lastType),
    isGroup: Value(isGroup),
    unread: Value(unread),
    isAt: Value(isAt),
    isTop: Value(isTop),
    isNotice: Value(isNotice),
    role: Value(role),
    depId: Value(depId),
    isOnline: Value(isOnline),
    draft: Value(draft),
    extra: Value(jsonEncode(extra)),
    updatedAt: Value(nowMillis()),
  );

  /// 只更新"服务端同步过来"的那部分字段（不覆盖本地未读数与草稿）
  DbConversationsCompanion toSyncCompanion() => DbConversationsCompanion(
    id: Value(id),
    displayName: Value(displayName),
    avatar: Value(avatar),
    lastContent: Value(lastContent),
    lastSendTime: Value(lastSendTime),
    lastType: Value(lastType),
    isGroup: Value(isGroup),
    unread: Value(unread),
    isAt: Value(isAt),
    isTop: Value(isTop),
    isNotice: Value(isNotice),
    role: Value(role),
    depId: Value(depId),
    isOnline: Value(isOnline),
    extra: Value(jsonEncode(extra)),
    updatedAt: Value(nowMillis()),
  );

  Conversation copyWith({
    String? displayName,
    String? avatar,
    String? lastContent,
    int? lastSendTime,
    String? lastType,
    int? isGroup,
    int? unread,
    int? isAt,
    int? isTop,
    int? isNotice,
    int? role,
    int? depId,
    int? isOnline,
    String? draft,
    Map<String, dynamic>? extra,
  }) => Conversation(
    id: id,
    displayName: displayName ?? this.displayName,
    avatar: avatar ?? this.avatar,
    lastContent: lastContent ?? this.lastContent,
    lastSendTime: lastSendTime ?? this.lastSendTime,
    lastType: lastType ?? this.lastType,
    isGroup: isGroup ?? this.isGroup,
    unread: unread ?? this.unread,
    isAt: isAt ?? this.isAt,
    isTop: isTop ?? this.isTop,
    isNotice: isNotice ?? this.isNotice,
    role: role ?? this.role,
    depId: depId ?? this.depId,
    isOnline: isOnline ?? this.isOnline,
    draft: draft ?? this.draft,
    extra: extra ?? this.extra,
  );

  /// 系统消息会话（老端单独累加 `sysUnread`，不建会话行）
  bool get isSystem => id == 'system';

  /// 群聊。
  ///
  /// **只有 `is_group == 1` 是群**：2 是系统通知、3 是「我的收藏」
  /// （服务端把 `to_user = -1` 那条会话存成 3）。写成 `!= 0` 会把那两种也当群，
  /// 聊天信息页就会为它们画群成员/群名/群公告那一套（用户 2026-09-21 报的
  /// 「我的收藏」里冒出「群成员 0 人」就是这个原因）。
  bool get isGroupChat => isGroup == 1;

  /// 免打扰（老端 `is_notice == 0` 不响铃、不计入总未读）
  bool get muted => isNotice == 0;

  /// 群里的管理员/群主（老端 `role < 3` 可以撤回别人的消息）
  bool get canModerate => role < 3;

  /// 有未读（含 @ 提醒）
  bool get hasUnread => unread > 0 || isAt > 0;

  @override
  String toString() => 'Conversation($id "$displayName" unread=$unread)';
}

Map<String, dynamic> _decodeMap(String raw) {
  if (raw.isEmpty) return const <String, dynamic>{};
  try {
    final decoded = json.decode(raw);
    if (decoded is Map) return decoded.cast<String, dynamic>();
  } on FormatException {
    // 脏数据当空处理
  }
  return const <String, dynamic>{};
}
