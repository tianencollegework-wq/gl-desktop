import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import '../../core/util/json_value.dart';
import '../db/app_database.dart';
import 'time_units.dart';

/// 通讯录里的一项（S5.1）。
///
/// 来源是老端那两份前端缓存：
/// * `getFriendList` → 好友（`is_group == 0`）与系统通知（`is_group == 2`）
/// * `getGroupList` → 群聊（`is_group == 1`）
///
/// 与老端一样直接吃服务端的字段名（`is_group` / `index` / `name_py`），
/// 界面上用到的那几个拆成列，其余塞进 [extra]。
class Contact {
  const Contact({
    required this.id,
    this.displayName = '',
    this.realName = '',
    this.avatar = '',
    this.isGroup = 0,
    this.indexLetter = '',
    this.namePy = '',
    this.account = '',
    this.isOnline = 0,
    this.role = 0,
    this.ownerId = '',
    this.extra = const <String, dynamic>{},
  });

  final String id;

  /// 显示名。好友的备注名由服务端写进 `displayName`（老端 `setNickname` 之后
  /// 也是把返回的备注写回 `displayName`），所以这里直接用它。
  final String displayName;

  /// 真实姓名（`realname`）
  final String realName;

  final String avatar;

  /// 0 好友、1 群聊、2 系统通知（老端 `is_group`；它还会出现 3，那是应用号）
  final int isGroup;

  /// 服务端给的拼音首字母（老端分组直接读 `item.index`）
  final String indexLetter;

  /// 名字全拼
  final String namePy;

  final String account;
  final int isOnline;
  final int role;
  final String ownerId;
  final Map<String, dynamic> extra;

  bool get isFriend => isGroup == 0;
  bool get isChatGroup => isGroup == 1;
  bool get isSystem => isGroup == 2;

  /// 界面上的名字：显示名 → 真名，都没有就用 id（不要出现空白行）
  String get title {
    if (displayName.isNotEmpty) return displayName;
    if (realName.isNotEmpty) return realName;
    return id;
  }

  /// 群主（群聊列表页画那个小人图标）
  bool isOwner(String userId) => ownerId.isNotEmpty && ownerId == userId;

  /// 管理员（老端 `role == 2`）
  bool get isManager => role == 2;

  /// 从接口/推送的原始 JSON 解析。
  ///
  /// 名字字段三处都试（`displayName` → `realname`），与老端不同页面各读一个字段
  /// 的写法等价——它只是恰好每个页面都拿到了自己想要的那个。
  factory Contact.fromServerJson(Map<String, dynamic> json) {
    final id = asText(json['id'] ?? json['user_id'] ?? json['group_id']);
    return Contact(
      id: id,
      displayName: asText(
        json['displayName'] ?? json['realname'] ?? json['name'],
      ),
      realName: asText(json['realname']),
      avatar: asText(json['avatar']),
      isGroup: asInt(json['is_group'], 0),
      indexLetter: asText(json['index']),
      namePy: asText(json['name_py']),
      account: asText(json['account']),
      isOnline: asInt(json['is_online'], 0),
      role: asInt(json['role'], 0),
      ownerId: asText(json['owner_id']),
      extra: Map<String, dynamic>.from(json)
        ..remove('id')
        ..remove('user_id')
        ..remove('group_id')
        ..remove('displayName')
        ..remove('realname')
        ..remove('name')
        ..remove('avatar')
        ..remove('is_group')
        ..remove('index')
        ..remove('name_py')
        ..remove('account')
        ..remove('is_online')
        ..remove('role')
        ..remove('owner_id'),
    );
  }

  static Contact fromRow(DbContact row) => Contact(
    id: row.id,
    displayName: row.displayName,
    realName: row.realName,
    avatar: row.avatar,
    isGroup: row.isGroup,
    indexLetter: row.indexLetter,
    namePy: row.namePy,
    account: row.account,
    isOnline: row.isOnline,
    role: row.role,
    ownerId: row.ownerId,
    extra: _decodeMap(row.extra),
  );

  DbContactsCompanion toCompanion() => DbContactsCompanion(
    id: Value(id),
    displayName: Value(displayName),
    realName: Value(realName),
    avatar: Value(avatar),
    isGroup: Value(isGroup),
    indexLetter: Value(indexLetter),
    namePy: Value(namePy),
    account: Value(account),
    isOnline: Value(isOnline),
    role: Value(role),
    ownerId: Value(ownerId),
    extra: Value(jsonEncode(extra)),
    updatedAt: Value(nowMillis()),
  );

  Contact copyWith({
    String? displayName,
    String? realName,
    String? avatar,
    int? isGroup,
    String? indexLetter,
    String? namePy,
    String? account,
    int? isOnline,
    int? role,
    String? ownerId,
    Map<String, dynamic>? extra,
  }) => Contact(
    id: id,
    displayName: displayName ?? this.displayName,
    realName: realName ?? this.realName,
    avatar: avatar ?? this.avatar,
    isGroup: isGroup ?? this.isGroup,
    indexLetter: indexLetter ?? this.indexLetter,
    namePy: namePy ?? this.namePy,
    account: account ?? this.account,
    isOnline: isOnline ?? this.isOnline,
    role: role ?? this.role,
    ownerId: ownerId ?? this.ownerId,
    extra: extra ?? this.extra,
  );

  @override
  bool operator ==(Object other) =>
      other is Contact &&
      other.id == id &&
      other.displayName == displayName &&
      other.realName == realName &&
      other.avatar == avatar &&
      other.isGroup == isGroup &&
      other.indexLetter == indexLetter &&
      other.namePy == namePy &&
      other.isOnline == isOnline &&
      other.role == role &&
      other.ownerId == ownerId;

  @override
  int get hashCode => Object.hash(
    id,
    displayName,
    realName,
    avatar,
    isGroup,
    indexLetter,
    namePy,
    isOnline,
    role,
    ownerId,
  );

  @override
  String toString() => 'Contact($id "$displayName" isGroup=$isGroup)';
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
