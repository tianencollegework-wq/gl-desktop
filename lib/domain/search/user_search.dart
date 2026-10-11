/// 搜人（S5.4）：老端 `pages/contacts/search.vue` 用的 `searchUser({keywords})`。
///
/// 老端模板里读的字段就是这四个（`items.user_id` / `items.realname` /
/// `items.avatar` / `items.friend`），右侧动作按 `friend` 分两种：
/// 是好友给「发消息」，否则给「查看」——两者都进用户详情页，区别只是
/// 「发消息」点了直接建会话进聊天。
library;

import 'package:flutter/foundation.dart' show immutable;

import '../../core/util/json_value.dart';

/// 一条搜索结果
@immutable
class UserSearchResult {
  const UserSearchResult({
    required this.userId,
    required this.realName,
    this.account = '',
    this.avatar = '',
    this.isFriend = false,
  });

  /// 服务端的 `user_id`（老端点进详情页用的就是它，不是 id）
  final String userId;

  final String realName;
  final String account;
  final String avatar;

  /// 已经是好友（`friend` 字段，老端那个 `v-if="items.friend"` 的宽松判断）
  final bool isFriend;

  /// 右侧动作的文案 key：老端 `items.friend ? 发消息 : 查看`
  String get actionKey => isFriend ? 'message.send' : 'common.view';

  /// 本地会话的 id 就是对方的 `user_id`
  String get conversationId => userId;

  factory UserSearchResult.fromServerJson(Map<String, dynamic> json) =>
      UserSearchResult(
        userId: asText(json['user_id']),
        realName: asText(json['realname']),
        account: asText(json['account']),
        avatar: asText(json['avatar']),
        isFriend: asBool(json['friend']),
      );

  @override
  bool operator ==(Object other) =>
      other is UserSearchResult &&
      other.userId == userId &&
      other.realName == realName &&
      other.account == account &&
      other.avatar == avatar &&
      other.isFriend == isFriend;

  @override
  int get hashCode => Object.hash(userId, realName, account, avatar, isFriend);

  @override
  String toString() => 'UserSearchResult($userId, $realName, friend=$isFriend)';
}

/// 解析 `searchUser` 的返回。
///
/// `data` 是**数组**（老端 `this.contacts = res.data` 直接赋值），所以走
/// `postListMaps`——用 `postMap` 读它会静默得到空 map（群成员列表那个坑的
/// 第三例）。没有 `user_id` 的项直接跳过：点下去也无处可去。
List<UserSearchResult> parseUserSearch(
  List<Map<String, dynamic>> rows,
) => <UserSearchResult>[
  for (final row in rows)
    if (asText(row['user_id']).isNotEmpty) UserSearchResult.fromServerJson(row),
];

/// 搜索的关键词是不是「空的」。
///
/// 老端 `search()` 里判的是 `this.keywords==''`（只挡空串，一个空格也能搜出去）
/// ——新端按 trim 后判空，顺手把「只打了空格」也挡掉。
bool isBlankKeyword(String keyword) => keyword.trim().isEmpty;
