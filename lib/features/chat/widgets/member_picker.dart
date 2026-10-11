import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/i18n/app_i18n.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../data/repo/group_member_repository.dart';
import '../../../domain/chat/group_members.dart';
import '../../../core/ui/desktop_overlay.dart';

/// 打开群成员选择器（老端 `im-input.vue` 的 `usermodel` 弹层 + `user-select`）。
///
/// 返回选中的成员；用户直接关掉则返回 null。
Future<List<GroupMember>?> showMemberPicker(
  BuildContext context, {
  required String groupId,
  List<GroupMember> preselected = const <GroupMember>[],
}) => showAppSheet<List<GroupMember>>(
  context: context,
  backgroundColor: AppColors.white,
  isScrollControlled: true,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
  ),
  builder: (context) =>
      _MemberPickerSheet(groupId: groupId, preselected: preselected),
);

class _MemberPickerSheet extends ConsumerStatefulWidget {
  const _MemberPickerSheet({required this.groupId, required this.preselected});

  final String groupId;
  final List<GroupMember> preselected;

  @override
  ConsumerState<_MemberPickerSheet> createState() => _MemberPickerSheetState();
}

class _MemberPickerSheetState extends ConsumerState<_MemberPickerSheet> {
  final TextEditingController _search = TextEditingController();
  late final Map<String, GroupMember> _picked = <String, GroupMember>{
    for (final member in widget.preselected) member.userId: member,
  };

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _toggle(GroupMember member) {
    setState(() {
      if (_picked.containsKey(member.userId)) {
        _picked.remove(member.userId);
      } else {
        _picked[member.userId] = member;
      }
    });
  }

  /// 「所有人」在老端是一个单独的 user_id == 0 的假成员
  GroupMember _allMember(AppI18n i18n) =>
      GroupMember(userId: atAllUserId, name: i18n.t('chat.allUser'), role: 1);

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final members = ref.watch(groupMembersProvider(widget.groupId));
    final height = MediaQuery.sizeOf(context).height * 0.7;

    return SizedBox(
      height: height,
      child: Column(
        children: <Widget>[
          _header(context, i18n),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: context.rpx(30)),
            child: Container(
              height: context.rpx(64),
              padding: EdgeInsets.symmetric(horizontal: context.rpx(20)),
              decoration: BoxDecoration(
                color: AppColors.page,
                borderRadius: BorderRadius.circular(context.rpx(32)),
              ),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.search,
                    size: context.rpx(32),
                    color: AppColors.text999,
                  ),
                  SizedBox(width: context.rpx(10)),
                  Expanded(
                    child: TextField(
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      style: TextStyle(
                        fontSize: context.rpx(26),
                        color: AppColors.text333,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: i18n.t('common.keywords'),
                        hintStyle: TextStyle(
                          fontSize: context.rpx(26),
                          color: AppColors.text999,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: context.rpx(10)),
          Expanded(
            child: members.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(
                child: Text(
                  i18n.t('common.noData'),
                  style: TextStyle(
                    fontSize: context.rpx(26),
                    color: AppColors.text666,
                  ),
                ),
              ),
              data: (list) => _list(context, i18n, list),
            ),
          ),
          _footer(context, i18n),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, AppI18n i18n) => Container(
    height: context.rpx(90),
    padding: EdgeInsets.symmetric(horizontal: context.rpx(30)),
    alignment: Alignment.center,
    child: Row(
      children: <Widget>[
        GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Text(
            i18n.t('common.cancel'),
            style: TextStyle(
              fontSize: context.rpx(28),
              color: AppColors.text666,
            ),
          ),
        ),
        Expanded(
          child: Text(
            i18n.t('message.remindTo'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: context.rpx(30),
              color: AppColors.text333,
            ),
          ),
        ),
        GestureDetector(
          onTap: () => Navigator.of(context).pop(_picked.values.toList()),
          child: Text(
            i18n.t('common.complete'),
            style: TextStyle(fontSize: context.rpx(28), color: AppColors.brand),
          ),
        ),
      ],
    ),
  );

  Widget _list(BuildContext context, AppI18n i18n, List<GroupMember> members) {
    final keyword = _search.text.trim();
    final filtered = searchMembers(members, keyword);
    final all = _allMember(i18n);
    // @ 所有人的入口只有群主/管理员有，且只在没搜索时显示（老端 `v-if="!keywords"`）
    final showAll = keyword.isEmpty && members.any((member) => member.canAtAll);

    return ListView(
      children: <Widget>[
        if (showAll) _tile(context, all, Icons.groups_outlined),
        for (final member in filtered)
          _tile(
            context,
            member,
            member.isOwner
                ? Icons.workspace_premium_outlined
                : member.isManager
                ? Icons.shield_outlined
                : Icons.person_outline,
          ),
      ],
    );
  }

  Widget _tile(BuildContext context, GroupMember member, IconData icon) {
    final checked = _picked.containsKey(member.userId);
    return InkWell(
      onTap: () => _toggle(member),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.rpx(30),
          vertical: context.rpx(18),
        ),
        child: Row(
          children: <Widget>[
            CircleAvatar(
              radius: context.rpx(30),
              backgroundColor: AppColors.page,
              foregroundImage: member.avatar.isEmpty
                  ? null
                  : NetworkImage(member.avatar),
              child: Icon(
                icon,
                size: context.rpx(32),
                color: AppColors.text666,
              ),
            ),
            SizedBox(width: context.rpx(20)),
            Expanded(
              child: Text(
                member.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.rpx(28),
                  color: AppColors.text333,
                ),
              ),
            ),
            Icon(
              checked ? Icons.check_circle : Icons.circle_outlined,
              size: context.rpx(40),
              color: checked ? AppColors.brand : AppColors.text999,
            ),
          ],
        ),
      ),
    );
  }

  Widget _footer(BuildContext context, AppI18n i18n) => Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.rpx(30),
          vertical: context.rpx(16),
        ),
        child: Row(
          children: <Widget>[
            Text(
              '${i18n.t('common.checked')} ${_picked.length} ${i18n.t('group.per')}',
              style: TextStyle(
                fontSize: context.rpx(26),
                color: AppColors.text666,
              ),
            ),
          ],
        ),
      ),
      SizedBox(height: context.bottomSafeHeight),
    ],
  );
}
