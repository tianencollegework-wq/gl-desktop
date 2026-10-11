/// 用户详情页的「群内管理」块（S5.2b）。
///
/// 对照老端 `pages/contacts/detail.vue` 第 55～94 行：
///
/// ```html
/// <view v-if="detail.groupInfo && detail.groupInfo.manageRole<3
///              && detail.groupInfo.owner_id!=detail.user_id">
/// ```
///
/// 也就是**同时**满足三条才显示：
/// 1. 服务端给了 `groupInfo`（只有从群成员那一侧点进来才有）；
/// 2. `manageRole < 3`——`manageRole` 是**我**在这个群里的角色（1 群主 / 2 管理员 / 3 普通成员），
///    由服务端算好给下来，客户端不推导；
/// 3. 对方不是群主（群主不能被动）。
///
/// 块里那三行：成员角色（对方）、设置禁言（对方）、设为/取消管理员（只有我是群主才给），
/// 外加一颗「移出群聊」。
///
/// 与老端不同（刻意的）：
/// * `manageRole` 缺失 / 认不出来时**不显示**这块（老端 `undefined < 3` 是假，行为一致，
///   这里显式写出来，免得哪天当成 0 处理就把权限放开了）；
/// * 对方的角色认不出来（不是 1/2/3）时角色那一行留空（老端三个 `v-if` 都不命中，也是空）。
library;

import 'package:flutter/foundation.dart' show immutable;

import '../../core/util/json_value.dart';
import 'group_admin.dart';

/// 「群内管理」块要展示的内容
@immutable
class UserGroupManageBlock {
  const UserGroupManageBlock({
    required this.groupName,
    required this.targetRole,
    required this.mutedUntil,
    required this.targetIsManager,
    required this.canToggleManager,
  });

  /// 群名（老端当小标题用：`detail.groupInfo.name`）
  final String groupName;

  /// **对方**在这个群里的角色（1 群主 / 2 管理员 / 3 普通成员 / 0 认不出来）
  final int targetRole;

  /// 「禁言至 m-d H:i」，没被禁言时是空串
  final String mutedUntil;

  /// 对方是管理员（那颗按钮显示「取消管理员」）
  final bool targetIsManager;

  /// 我是群主（老端 `groupInfo.owner_id == 我的 user_id`）——决定「设为管理员」那行在不在
  final bool canToggleManager;

  /// 角色那一行的文案 key；认不出来的角色返回空串（老端就是什么都不显示）
  String get roleLabelKeyOrEmpty =>
      targetRole == groupRoleOwner ||
          targetRole == groupRoleManager ||
          targetRole == groupRoleMember
      ? roleLabelKey(targetRole)
      : '';

  @override
  String toString() =>
      'UserGroupManageBlock($groupName role=$targetRole '
      'owner=$canToggleManager muted="$mutedUntil")';
}

/// 从 `getUserInfo` 返回的 `groupInfo` 算出这块要不要显示、显示什么。
///
/// [targetUserId] 是页面看的那个人，[myUserId] 是我自己。
/// 返回 `null` 表示不显示这一块。
UserGroupManageBlock? userGroupManageBlockOf({
  required Map<String, dynamic> groupInfo,
  required String targetUserId,
  required String myUserId,
  DateTime? now,
}) {
  if (groupInfo.isEmpty) return null;

  // 我的角色：老端是 `manageRole < 3`（缺失时是 undefined，判假）→ 这里缺失就不显示
  final myRole = _asIntOrNull(groupInfo['manageRole']);
  if (myRole == null || myRole >= groupRoleMember) return null;

  final ownerId = asText(groupInfo['owner_id']);
  // 对方就是群主：群主不能被移出 / 被禁言
  if (ownerId.isNotEmpty && ownerId == targetUserId) return null;

  final info = asMap(groupInfo['userInfo']);
  final targetRole = _asIntOrNull(info['role']) ?? 0;
  final noSpeakTime = _asIntOrNull(info['no_speak_time']) ?? 0;

  return UserGroupManageBlock(
    groupName: asText(groupInfo['name']),
    targetRole: targetRole,
    mutedUntil: noSpeakExpiryLabel(noSpeakTime, now: now),
    targetIsManager: targetRole == groupRoleManager,
    canToggleManager: ownerId.isNotEmpty && ownerId == myUserId,
  );
}

/// 服务端这些数字字段有时是字符串（`"2"`），认不出来就返回 null
int? _asIntOrNull(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString().trim() ?? '');
}
