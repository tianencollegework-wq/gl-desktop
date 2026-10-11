/// 群聊列表页（S5.1，对应老端 `pages/contacts/group.vue`）的纯逻辑：
/// 分段筛选、搜索、排序。全是纯函数，便于单测。
library;

import '../../data/model/contact.dart';
import 'contact_index.dart';

/// 顶上那四个分段（老端 `tabBars`：`all` / 1 / 2 / 3）
enum GroupTab {
  /// 全部
  all('all', 'common.all'),

  /// 我创建的（`owner_id` 是我）
  created('1', 'group.iCreated'),

  /// 我管理的（`role == 2`）
  managed('2', 'group.iManaged'),

  /// 我加入的（`role == 3`）
  joined('3', 'group.iJoined');

  const GroupTab(this.id, this.labelKey);

  /// 老端那个 tab 的 id（留着是为了跟老端代码对照）
  final String id;

  final String labelKey;
}

/// 群主（老端 `role == 1`，但列表页那个小人图标只看 `owner_id`）
const int groupRoleOwner = 1;

/// 管理员（老端 `role == 2`）
const int groupRoleManager = 2;

/// 普通成员（老端 `role == 3`）
const int groupRoleMember = 3;

/// 按分段筛选。
///
/// 三段过滤的口径逐条照抄老端 `filterGroup()`：
/// * 我创建的看 `owner_id`；我管理的看 `role == 2`；我加入的看 `role == 3`。
///
/// 注意老端**没有**「我加入的 = 非群主非管理」这层意思，它就是认 `role == 3`，
/// 跟服务端给的 role 对齐；照抄。
List<Contact> filterGroups(
  List<Contact> groups,
  GroupTab tab, {
  required String myUserId,
}) {
  switch (tab) {
    case GroupTab.all:
      return groups;
    case GroupTab.created:
      return groups
          .where((group) => group.isOwner(myUserId))
          .toList(growable: false);
    case GroupTab.managed:
      return groups
          .where((group) => group.role == groupRoleManager)
          .toList(growable: false);
    case GroupTab.joined:
      return groups
          .where((group) => group.role == groupRoleMember)
          .toList(growable: false);
  }
}

/// 排序：按拼音首字母升序，`#` 最后，同字母保持接口给的顺序。
///
/// Dart 的 `List.sort` 不保证稳定，而老端那个比较器（同 index 返回 0）依赖
/// JS 的稳定排序，所以这里用原始下标兜底，保证同字母内顺序不变。
List<Contact> sortGroups(List<Contact> groups) {
  final indexed = <({int order, Contact group})>[
    for (var i = 0; i < groups.length; i++) (order: i, group: groups[i]),
  ];
  indexed.sort((a, b) {
    final byLetter = compareIndexLetters(
      contactIndexLetter(a.group),
      contactIndexLetter(b.group),
    );
    return byLetter != 0 ? byLetter : a.order.compareTo(b.order);
  });
  return <Contact>[for (final item in indexed) item.group];
}

/// 界面上真正要画的那一份：搜索优先（搜索时不看分段，老端也是把 `type` 归零），
/// 否则按分段筛选，最后统一排序。
List<Contact> visibleGroups(
  List<Contact> groups, {
  required GroupTab tab,
  required String myUserId,
  String keyword = '',
}) {
  final key = keyword.trim();
  // 群聊列表页的搜索口径与通讯录一致（老端用同一个 `$util.searchObject`）
  final base = key.isEmpty ? groups : searchContacts(groups, key);
  final filtered = key.isEmpty
      ? filterGroups(base, tab, myUserId: myUserId)
      : base;
  return sortGroups(filtered);
}
