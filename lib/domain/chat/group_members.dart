/// 群成员与 @ 提及（S4.4c）。
///
/// 对照老端 `components/message/user-select.vue` 的 `type == 4` 分支与
/// `im-input.vue` 的 `at()` / `setAtList()` / `sendTextMsg()`：
/// * 成员列表来自 `groupUserList({group_id})`，每项是 `{role, userInfo:{...}}`；
/// * 列表里**不含自己**（老端 filter 掉了）；
/// * 只有群主（role 1）/管理员（role 2）能 @ 所有人（老端 `isAuth`）；
/// * 搜索按 `displayName` 与 `name_py`（拼音）匹配；
/// * 发出去的 `at` 是 user_id 数组（老端还要 `parseInt`，新端保持字符串）。
class GroupMember {
  const GroupMember({
    required this.userId,
    required this.name,
    this.avatar = '',
    this.namePy = '',
    this.role = 0,
    this.noSpeakTime = 0,
    this.noSpeakDays = 0,
  });

  final String userId;
  final String name;
  final String avatar;

  /// 拼音（老端 `userInfo.name_py`，搜索用）
  final String namePy;

  /// 1 群主、2 管理员、3 普通成员（老端 `role`）
  final int role;

  /// 禁言到期时间（服务端 `no_speak_time`，秒；0 表示没被禁言）
  final int noSpeakTime;

  /// 这次禁言的天数（服务端 `no_speak_day`，老端的自定义天数框用）
  final int noSpeakDays;

  bool get isOwner => role == 1;

  bool get isManager => role == 2;

  /// @ 所有人这个入口只有群主/管理员有
  bool get canAtAll => role == 1 || role == 2;

  @override
  bool operator ==(Object other) =>
      other is GroupMember &&
      other.userId == userId &&
      other.name == name &&
      other.avatar == avatar &&
      other.namePy == namePy &&
      other.role == role &&
      other.noSpeakTime == noSpeakTime &&
      other.noSpeakDays == noSpeakDays;

  @override
  int get hashCode =>
      Object.hash(userId, name, avatar, namePy, role, noSpeakTime, noSpeakDays);

  @override
  String toString() => 'GroupMember($userId, $name, role=$role)';
}

/// @ 所有人的那个 user_id（老端 `atAll()` 里写死 0）
const String atAllUserId = '0';

/// 解析 `groupUserList` 的返回。
///
/// 每项形如 `{role: 3, userInfo: {id, displayName, avatar, name_py}}`；
/// 老端在这里做了三次赋值（`item.realname/displayName/avatar/name_py` 都从
/// `userInfo` 抄一遍），新端只留一份。`userInfo` 缺失或没有 id 的项直接跳过
/// ——老端会因为 `item.userInfo.displayName` 抛异常，整张列表都出不来。
List<GroupMember> parseGroupMembers(
  List<Map<String, dynamic>> raw, {
  String? excludeUserId,
}) {
  final members = <GroupMember>[];
  for (final item in raw) {
    final info = item['userInfo'];
    if (info is! Map) continue;
    final userId = info['id']?.toString() ?? '';
    if (userId.isEmpty) continue;
    if (excludeUserId != null && userId == excludeUserId) continue;
    members.add(
      GroupMember(
        userId: userId,
        name: info['displayName']?.toString() ?? '',
        avatar: info['avatar']?.toString() ?? '',
        namePy: info['name_py']?.toString() ?? '',
        role: int.tryParse(item['role']?.toString() ?? '') ?? 0,
        noSpeakTime: int.tryParse(item['no_speak_time']?.toString() ?? '') ?? 0,
        noSpeakDays: int.tryParse(item['no_speak_day']?.toString() ?? '') ?? 0,
      ),
    );
  }
  return members;
}

/// 搜索（老端 `user-select.vue::search`：按 `displayName` / `name_py` 匹配）
List<GroupMember> searchMembers(List<GroupMember> members, String keyword) {
  final key = keyword.trim().toLowerCase();
  if (key.isEmpty) return members;
  return members
      .where(
        (member) =>
            member.name.toLowerCase().contains(key) ||
            member.namePy.toLowerCase().contains(key),
      )
      .toList();
}

/// 把选中的成员拼成 `at` 数组（发送时用）。
///
/// 老端是从富文本的 link 节点里抓 user_id（`edit.getLink()`）——也就是说
/// **文本里删掉的 @ 就不会带上**。新端输入框是纯文本，所以这里用同一个语义：
/// 只有文本里还留着 `@名字` 的成员才算数。
List<String> resolveAt(String text, List<GroupMember> picked) {
  if (picked.isEmpty) return const <String>[];
  final ids = <String>[];
  for (final member in picked) {
    if (text.contains('@${member.name}') && !ids.contains(member.userId)) {
      ids.add(member.userId);
    }
  }
  return ids;
}
