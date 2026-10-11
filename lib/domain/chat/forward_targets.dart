import 'package:flutter/foundation.dart';

/// 转发时能选的人/群（S4.5）。
///
/// 老端 `pages/index/userSelection.vue` 的 `type == 3` 分支：
/// 好友列表 + 群聊列表拼起来，过滤掉**当前会话**与 `is_group` 不在 `[0,1,3]`
/// 的项（那两个值是系统会话/应用号），群聊名字后面加「（群聊）」；
/// 选完调 `forwardMessage({user_ids, msg_id})`，最多 5 个。
const int forwardLimit = 5;

/// 能选的目标：好友（`isGroup == 0`）或群聊（`isGroup == 1`）
@immutable
class ForwardTarget {
  const ForwardTarget({
    required this.id,
    required this.name,
    this.avatar = '',
    this.isGroup = 0,
    this.namePy = '',
  });

  final String id;
  final String name;
  final String avatar;

  /// 0 好友、1 群聊（老端里还有 2/3 表示系统会话与应用，选项里不出现）
  final int isGroup;

  final String namePy;

  /// 老端列表里群聊要加个后缀区分
  bool get isGroupChat => isGroup == 1;

  @override
  bool operator ==(Object other) =>
      other is ForwardTarget &&
      other.id == id &&
      other.name == name &&
      other.avatar == avatar &&
      other.isGroup == isGroup;

  @override
  int get hashCode => Object.hash(id, name, avatar, isGroup);

  @override
  String toString() => 'ForwardTarget($id, $name, isGroup=$isGroup)';
}

/// 拼转发候选列表（老端那两个 `filter` + `forEach`）
List<ForwardTarget> parseForwardTargets({
  required List<Map<String, dynamic>> friends,
  required List<Map<String, dynamic>> groups,
  String? excludeId,
}) {
  final targets = <ForwardTarget>[];
  for (final raw in <Map<String, dynamic>>[...friends, ...groups]) {
    final id = raw['id']?.toString() ?? '';
    if (id.isEmpty) continue;
    if (excludeId != null && id == excludeId) continue;
    final isGroup = int.tryParse(raw['is_group']?.toString() ?? '') ?? 0;
    // 老端只留 [0,1,3]；新端再收紧一步：只留好友与群聊（系统会话转发不了）
    if (isGroup != 0 && isGroup != 1) continue;
    targets.add(
      ForwardTarget(
        id: id,
        name: raw['displayName']?.toString() ?? '',
        avatar: raw['avatar']?.toString() ?? '',
        isGroup: isGroup,
        namePy: raw['name_py']?.toString() ?? '',
      ),
    );
  }
  return targets;
}

/// 列表里那一行文字：群聊带「（群聊）」后缀（老端 `name += "（群聊）"`）
String forwardTargetLabel(ForwardTarget target, String groupSuffix) =>
    target.isGroupChat ? '${target.name}$groupSuffix' : target.name;

/// 搜索（与成员选择器同一套：名字 + 拼音）
List<ForwardTarget> searchForwardTargets(
  List<ForwardTarget> targets,
  String keyword,
) {
  final key = keyword.trim().toLowerCase();
  if (key.isEmpty) return targets;
  return targets
      .where(
        (target) =>
            target.name.toLowerCase().contains(key) ||
            target.namePy.toLowerCase().contains(key),
      )
      .toList();
}
