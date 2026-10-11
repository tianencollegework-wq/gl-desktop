/// 通讯录的分组与索引（S5.1），全是纯函数。
///
/// 口径照抄老端 `pages/contacts/index.vue`：
/// * 分组依据是每项的 `index`（服务端给的拼音首字母）；
/// * 排序时 `#` 永远排最后，其余按字母升序（老端用 `localeCompare(zh)`，
///   对单个大写字母来说与普通比较一致）；
/// * 同一组内保持接口返回的顺序（老端那个比较器对同 index 的项返回 0，
///   JS 的 `sort` 是稳定的）。
library;

import 'package:flutter/foundation.dart' show immutable;

import '../../data/model/contact.dart';

/// `#` 组：名字首字母识别不出来的都归到这里
const String otherIndex = '#';

/// 一个字母（或 `#`）下面的一组联系人
@immutable
class ContactGroup {
  const ContactGroup({required this.name, required this.children});

  /// 字母或 `#`
  final String name;

  final List<Contact> children;

  int get count => children.length;

  @override
  String toString() => 'ContactGroup($name, ${children.length})';
}

/// 取一项的分组字母。
///
/// 三级兜底（服务端字段优先，与老端一致，只是它没写兜底）：
/// 1. `index` —— 服务端给的拼音首字母（它给 `#` 时就是 `#`，不再往下猜）；
/// 2. `name_py` 的首字母 —— 服务端一般会给（群聊列表的搜索也在用它）；
/// 3. 名字本身以英文字母开头就用那个字母（英文名、别名）。
///
/// 都拿不到就归到 `#`。**中文名在没有 `name_py` 的情况下会落到 `#`**：
/// 本地算拼音要引一个词库依赖，先按服务端的来（真机上确认那两列有没有值，
/// 没有的话再补，见规划书 S5.1 的待确认项）。
///
/// 注意名字兜底只认 `displayName` / `realName`，**不认 id**：
/// 拿 id（`u1` 这种）去猜会得到一堆假的 `U` 分组——写这条兜底时踩过。
String contactIndexLetter(Contact contact) {
  final rawIndex = contact.indexLetter.trim();
  if (rawIndex == otherIndex) return otherIndex;
  final serverIndex = _normalizeLetter(rawIndex);
  if (serverIndex != null) return serverIndex;

  final pinyin = contact.namePy.trim();
  if (pinyin.isNotEmpty) {
    final first = _normalizeLetter(pinyin[0]);
    if (first != null) return first;
  }

  for (final name in <String>[contact.displayName, contact.realName]) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) continue;
    final first = _normalizeLetter(trimmed[0]);
    if (first != null) return first;
  }
  return otherIndex;
}

/// 把一个字符归一到 `A`–`Z`；不是字母就是 null（中文、数字、符号都算认不出来）
String? _normalizeLetter(String value) {
  if (value.isEmpty) return null;
  final char = value.trim().toUpperCase();
  if (char.isEmpty) return null;
  final code = char.codeUnitAt(0);
  if (code < 0x41 || code > 0x5A) return null;
  return char[0];
}

/// 按首字母分组（顺序：`A`–`Z` 升序，`#` 最后）
List<ContactGroup> groupByIndex(List<Contact> contacts) {
  final buckets = <String, List<Contact>>{};
  for (final contact in contacts) {
    buckets
        .putIfAbsent(contactIndexLetter(contact), () => <Contact>[])
        .add(contact);
  }
  final letters = buckets.keys.toList()..sort(compareIndexLetters);
  return <ContactGroup>[
    for (final letter in letters)
      ContactGroup(name: letter, children: buckets[letter]!),
  ];
}

/// 字母排序：`#` 永远最后，其余按字母序
int compareIndexLetters(String a, String b) {
  if (a == b) return 0;
  if (a == otherIndex) return 1;
  if (b == otherIndex) return -1;
  return a.compareTo(b);
}

/// 侧边索引条上的字母（就是每组的名字）
List<String> indexBarLetters(List<ContactGroup> groups) =>
    groups.map((group) => group.name).toList();

/// 通讯录底部那行「N 位朋友」用的计数（老端 `total` 只数好友）
int friendCount(List<Contact> contacts) =>
    contacts.where((contact) => contact.isFriend).length;

/// 按 id 找到某项在第几组第几个（索引条跳转后要能定位到具体行）
({int group, int child})? locateContact(List<ContactGroup> groups, String id) {
  for (var i = 0; i < groups.length; i++) {
    final children = groups[i].children;
    for (var j = 0; j < children.length; j++) {
      if (children[j].id == id) return (group: i, child: j);
    }
  }
  return null;
}

/// 通讯录里的搜索（名字 / 拼音 / 账号，与群聊列表页同一套口径）
List<Contact> searchContacts(List<Contact> contacts, String keyword) {
  final key = keyword.trim().toLowerCase();
  if (key.isEmpty) return contacts;
  return contacts
      .where(
        (contact) =>
            contact.displayName.toLowerCase().contains(key) ||
            contact.realName.toLowerCase().contains(key) ||
            contact.namePy.toLowerCase().contains(key) ||
            contact.account.toLowerCase().contains(key),
      )
      .toList();
}
