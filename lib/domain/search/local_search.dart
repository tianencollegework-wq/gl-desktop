/// 本地搜索（S5.4）：老端 `pages/index/search.vue`。
///
/// 这一页**不查会话**（老端虽然从消息页的搜索图标进 `type=1`，但它的数据源
/// 一直是 `getFriendList` + `getGroupList` 两份列表），三个 type 的区别只有
/// 标题、以及「好友」那段要不要显示：
///
/// | type | 标题 | 好友段 | 群聊段 |
/// | --- | --- | --- | --- |
/// | 1（消息页进） | `common.search` | 显示 | 显示 |
/// | 2（通讯录进） | `common.searchContacts` | 显示 | 显示 |
/// | 3（群聊列表进） | `common.searchGroup` | **不显示** | 显示 |
///
/// 匹配口径与通讯录/群聊列表同一套（名字 / 真名 / 拼音 / 账号，忽略大小写）。
library;

import 'package:flutter/foundation.dart' show immutable;

import '../../data/model/contact.dart';
import '../contacts/contact_index.dart';

/// 搜索页的三种入口
enum LocalSearchType {
  /// `type=1`：消息页的搜索图标
  all(1, 'common.search', showFriends: true),

  /// `type=2`：通讯录的搜索图标
  contacts(2, 'common.searchContacts', showFriends: true),

  /// `type=3`：群聊列表的搜索图标（只搜群）
  groups(3, 'common.searchGroup', showFriends: false);

  const LocalSearchType(this.value, this.titleKey, {required this.showFriends});

  /// 老端 `onLoad(options)` 里的 `options.type`
  final int value;

  /// 导航栏标题的文案 key
  final String titleKey;

  /// 要不要显示「好友」那一段（老端 `v-if="type<3"`）
  final bool showFriends;

  static LocalSearchType fromValue(Object? raw) {
    final value = int.tryParse('$raw');
    for (final type in LocalSearchType.values) {
      if (type.value == value) return type;
    }
    // 老端没传 type 时 `options.type` 是 undefined，走到 else 分支 → 全局搜索
    return LocalSearchType.all;
  }
}

/// 搜索结果的两个分段
@immutable
class LocalSearchResults {
  const LocalSearchResults({required this.friends, required this.groups});

  const LocalSearchResults.empty()
    : friends = const <Contact>[],
      groups = const <Contact>[];

  final List<Contact> friends;
  final List<Contact> groups;

  bool get isEmpty => friends.isEmpty && groups.isEmpty;

  int get total => friends.length + groups.length;

  @override
  String toString() =>
      'LocalSearchResults(friends=${friends.length}, groups=${groups.length})';
}

/// 在本地通讯录里搜（老端 `$util.searchObject(list, ['displayName','name_py',
/// 'account'], keywords)`）。
///
/// * 关键词为空（或只有空格）→ 两个分段都空：老端就是「清空两个列表」；
/// * `type=3` 时好友段恒空（不显示，而不是「搜到了但不画」）。
LocalSearchResults localSearch(
  List<Contact> contacts,
  String keyword, {
  required LocalSearchType type,
}) {
  if (keyword.trim().isEmpty) return const LocalSearchResults.empty();
  final matched = searchContacts(contacts, keyword);
  return LocalSearchResults(
    friends: type.showFriends
        ? matched.where((contact) => contact.isFriend).toList()
        : const <Contact>[],
    groups: matched.where((contact) => contact.isChatGroup).toList(),
  );
}
