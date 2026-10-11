/// 群管理（S5.3）的纯逻辑：角色、权限、成员操作能不能点、禁言时长与到期文案。
///
/// 对照老端 `pages/message/detail.vue` 与 `pages/message/group/groupUser.vue`：
/// * 角色：1 群主、2 管理员、3 普通成员；
/// * `isAdmin` = 我是群主（能解散、能清空记录、能任命管理员）；
/// * `isAuth`  = 我是群主或管理员（能看到「群管理」与成员操作入口）；
/// * 禁言时长：弹层里 4 个预设（`noSpeakTimer` = 1..4）+ 自定义天数（`noSpeakDay`）。
library;

import 'package:flutter/foundation.dart' show immutable;

import '../../core/util/time_format.dart';
import '../../data/model/time_units.dart';
import 'group_members.dart';

/// 群主（老端 `role == 1`）
const int groupRoleOwner = 1;

/// 管理员（老端 `role == 2`）
const int groupRoleManager = 2;

/// 普通成员（老端 `role == 3`）
const int groupRoleMember = 3;

/// 角色文案的 key（老端 `item.role==1 ? owner : role==2 ? manage : ''`，
/// 那个空串在界面上就是什么都不显示）
String roleLabelKey(int role) {
  if (role == groupRoleOwner) return 'group.owner';
  if (role == groupRoleManager) return 'group.manage';
  return 'group.user';
}

/// 我在这个群里的权限
@immutable
class GroupPermissions {
  const GroupPermissions({this.isOwner = false, this.isManager = false});

  final bool isOwner;
  final bool isManager;

  /// 群主或管理员：老端的 `isAuth`
  bool get isAuth => isOwner || isManager;

  @override
  String toString() => 'GroupPermissions(owner=$isOwner manager=$isManager)';
}

/// 从成员列表里挑出「我」的角色（老端是 `res.data.filter(item => item.role==1
/// && item.userInfo.id == 我的 user_id)`，两遍 filter 分别判群主与管理员）。
GroupPermissions groupPermissionsOf(
  List<GroupMember> members,
  String myUserId,
) {
  if (myUserId.isEmpty) return const GroupPermissions();
  for (final member in members) {
    if (member.userId != myUserId) continue;
    return GroupPermissions(
      isOwner: member.role == groupRoleOwner,
      isManager: member.role == groupRoleManager,
    );
  }
  return const GroupPermissions();
}

/// 这行成员能不能弹出操作菜单。
///
/// 老端的条件是 `item.role > 1 && isAuth`（不能操作群主，且自己有权限）。
/// 新端**多排除了自己**：管理员点自己只会得到「移出群聊」这一个后果，
/// 而退出群聊在聊天信息页有正经入口，留着只会让人误触（这处差异是刻意的）。
bool canOpenMemberOptions({
  required GroupMember member,
  required String myUserId,
  required GroupPermissions permissions,
}) {
  if (!permissions.isAuth) return false;
  // 老端是 `item.role > 1`：群主（1）不能被动，认不出的 0 也不给动
  if (member.role <= groupRoleOwner) return false;
  return member.userId != myUserId;
}

/// 操作菜单里那几项能不能点（老端那几处 `v-if` 的合体）：
/// * 「转让管理权限」`isAdmin`
/// * 「设置/取消管理员」`isAdmin`
/// * 「设置禁言」`isAdmin`
/// * 「移出群聊」只有一层：能打开这个菜单就能移出（老端没给它 `v-if`）
@immutable
class MemberActionFlags {
  const MemberActionFlags({
    required this.changeOwner,
    required this.toggleManager,
    required this.noSpeak,
    required this.remove,
  });

  final bool changeOwner;
  final bool toggleManager;
  final bool noSpeak;
  final bool remove;
}

MemberActionFlags memberActionsOf({
  required GroupMember member,
  required String myUserId,
  required GroupPermissions permissions,
}) {
  final allowed = canOpenMemberOptions(
    member: member,
    myUserId: myUserId,
    permissions: permissions,
  );
  return MemberActionFlags(
    changeOwner: allowed && permissions.isOwner,
    toggleManager: allowed && permissions.isOwner,
    noSpeak: allowed && permissions.isOwner,
    remove: allowed,
  );
}

/// 禁言弹层里的 4 个预设（老端 `noSpeakList`：10 分钟 / 1 小时 / 3 小时 / 1 天）
@immutable
class NoSpeakPreset {
  const NoSpeakPreset(this.id, this.labelKey);

  /// 提交给服务端的 `noSpeakTimer`
  final int id;

  final String labelKey;
}

const List<NoSpeakPreset> noSpeakPresets = <NoSpeakPreset>[
  NoSpeakPreset(1, 'common.tenM'),
  NoSpeakPreset(2, 'common.oneHour'),
  NoSpeakPreset(3, 'common.threeHour'),
  NoSpeakPreset(4, 'common.oneDay'),
];

/// 自定义天数的范围（老端那个 `uni-number-box` 的 min/max）
const int noSpeakMinDays = 1;
const int noSpeakMaxDays = 365;

/// 选中的禁言时长：预设（`noSpeakTimer`）或自定义天数
@immutable
class NoSpeakChoice {
  const NoSpeakChoice.preset(int id) : presetId = id, days = 1;

  const NoSpeakChoice.custom(this.days) : presetId = 0;

  /// 服务端要的 `noSpeakTimer`，0 表示自定义
  final int presetId;

  /// 自定义天数（选预设时恒为 1，老端也是这样：`noSpeakDay` 默认 1）
  final int days;

  bool get isCustom => presetId == 0;

  int get clampedDays => days.clamp(noSpeakMinDays, noSpeakMaxDays);

  @override
  bool operator ==(Object other) =>
      other is NoSpeakChoice &&
      other.presetId == presetId &&
      other.days == days;

  @override
  int get hashCode => Object.hash(presetId, days);

  @override
  String toString() => isCustom
      ? 'NoSpeakChoice.custom($clampedDays 天)'
      : 'NoSpeakChoice.preset($presetId)';
}

/// 提交给服务端的禁言参数。
///
/// 老端 `setNoSpeak(time)`：`time` 真时带 `{noSpeakDay, noSpeakTimer}`，
/// 假时（取消禁言）两个字段都传 0；`id` 是群 id、`user_id` 是被禁言的人。
///
/// **老端那个自定义天数输入框是坏的**：`<uni-number-box :value="noSpeakDay">`
/// 只有单向绑定、没有 `@change`，所以 `noSpeakDay` 永远是 1——「自定义 30 天」
/// 实际只会禁言 1 天。新端做成双向的（这处差异是刻意的）。
Map<String, Object> noSpeakPayload({
  required String groupId,
  required String userId,
  NoSpeakChoice? choice,
}) => <String, Object>{
  'id': groupId,
  'user_id': userId,
  'noSpeakDay': choice == null ? 0 : choice.clampedDays,
  'noSpeakTimer': choice == null ? 0 : choice.presetId,
};

/// 「禁言至 m-d H:i」，没过期或没禁言时返回空串（老端 `noSpeakExp`）
///
/// [noSpeakTime] 是服务端给的 `no_speak_time`（秒）。老端直接 `time * 1000`
/// 跟当前时间比，新端走 [`toMillis`] 归一化——服务端要是哪天改成毫秒，
/// 这里也不会算出 1970 年。
String noSpeakExpiryLabel(int noSpeakTime, {DateTime? now}) {
  final millis = toMillis(noSpeakTime);
  if (millis <= 0) return '';
  final nowValue = (now ?? DateTime.now()).millisecondsSinceEpoch;
  if (millis <= nowValue) return '';
  return dateFormat('m-d H:i', millis);
}
