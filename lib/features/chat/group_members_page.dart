import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/net/api_exception.dart';
import '../../core/router/app_router.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/util/json_value.dart';
import '../../data/repo/contact_repository.dart';
import '../../data/repo/conversation_repository.dart';
import '../../data/repo/group_admin_repository.dart';
import '../../domain/chat/group_admin.dart';
import '../../domain/chat/group_members.dart';
import '../contacts/widgets/contact_avatar.dart';
import '../contacts/widgets/contacts_empty.dart';
import 'widgets/group_member_sheets.dart';
import '../../core/ui/desktop_overlay.dart';

/// 群成员管理，对应老端 `pages/message/group/groupUser.vue`。
///
/// 结构照老端：搜索 + 成员列表（头像、名字、角色标签、「我的」标签、禁言至），
/// 有权限的人点右边「⋯」弹操作菜单（转让群主 / 设置管理员 / 设置禁言 / 移出群聊）。
///
/// 与老端不同（刻意的）：
/// * **自己那一行不出操作菜单**（老端的管理员能看到自己的菜单，点下去只有「移出群聊」，
///   等于自己把自己踢了——退出群聊在聊天信息页是正经入口）；
/// * 「自定义禁言天数」真的能改（老端那个数字框只写了单向 `:value`，永远是 1 天）；
/// * 点对方头像进详情页前会判权限（老端 `role < 3 || setting.profile == '1' || 是好友`，
///   照抄；不满足时提示「已开启用户隐私」）。
class GroupMembersPage extends ConsumerStatefulWidget {
  const GroupMembersPage({super.key, required this.groupId});

  final String groupId;

  @override
  ConsumerState<GroupMembersPage> createState() => _GroupMembersPageState();
}

class _GroupMembersPageState extends ConsumerState<GroupMembersPage> {
  List<GroupMember> _members = const <GroupMember>[];
  GroupPermissions _permissions = const GroupPermissions();
  String _keyword = '';
  bool _loading = true;
  bool _failed = false;

  /// 群设置里的 `profile`（允许互相看资料）——决定点成员能不能进详情页。
  ///
  /// 老端判的是 `setting.profile == '1'`（字段缺失时一律不给看）；新端反过来：
  /// **只有明确是 `'0'` 才算「已开启用户隐私」**，字段没同步下来时不误报。
  bool _profilePublic = true;

  int get _myRole {
    if (_permissions.isOwner) return groupRoleOwner;
    if (_permissions.isManager) return groupRoleManager;
    return groupRoleMember;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final list = await ref
          .read(groupAdminRepositoryProvider)
          .members(widget.groupId);
      final conversation = await ref
          .read(conversationRepositoryProvider)
          .find(widget.groupId);
      final setting = asMap(conversation?.extra['setting']);
      final myId = ref.read(sessionStoreProvider).userId;
      if (!mounted) return;
      setState(() {
        _members = list.members;
        _permissions = groupPermissionsOf(list.members, myId);
        _profilePublic = asText(setting['profile']) != '0';
        _loading = false;
      });
    } on Object catch (error) {
      debugPrint('[群成员] 加载失败：$error');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _openMember(GroupMember member) {
    final myId = ref.read(sessionStoreProvider).userId;
    if (member.userId == myId) return;
    // 老端：群主/管理员能看，或者群设置允许互相看资料，或者已经是好友
    final isFriend =
        ref
            .read(friendListProvider)
            .value
            ?.any((contact) => contact.id == member.userId) ??
        false;
    final allowed = _myRole < groupRoleMember || _profilePublic || isFriend;
    if (!allowed) {
      noticeBus.toast(ref.read(appI18nProvider).t('group.userAuth'));
      return;
    }
    context.push(
      '${AppRoutes.contactsDetail}?id=${Uri.encodeComponent(member.userId)}'
      '&group_id=${Uri.encodeComponent(widget.groupId)}',
    );
  }

  /// 成员操作菜单（老端那个底部弹层）
  Future<void> _openActions(GroupMember member) async {
    final i18n = ref.read(appI18nProvider);
    final myId = ref.read(sessionStoreProvider).userId;
    final actions = memberActionsOf(
      member: member,
      myUserId: myId,
      permissions: _permissions,
    );
    if (!actions.remove) return;

    final picked = await showAppSheet<String>(
      context: context,
      backgroundColor: AppColors.white,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _sheetHeader(sheetContext, member: member, i18n: i18n),
            if (actions.changeOwner)
              groupSheetItem(
                sheetContext,
                label: i18n.t('group.moveManage'),
                color: AppColors.orange,
                onTap: () => Navigator.of(sheetContext).pop('owner'),
              ),
            if (actions.toggleManager)
              groupSheetItem(
                sheetContext,
                label: member.isManager
                    ? i18n.t('group.cancelManage')
                    : i18n.t('group.setManage'),
                onTap: () => Navigator.of(sheetContext).pop('manager'),
              ),
            if (actions.noSpeak)
              groupSheetItem(
                sheetContext,
                label: i18n.t('group.setNoSpeak'),
                onTap: () => Navigator.of(sheetContext).pop('nospeak'),
              ),
            groupSheetItem(
              sheetContext,
              label: i18n.t('group.moveUser'),
              onTap: () => Navigator.of(sheetContext).pop('remove'),
            ),
            const Divider(height: 1, color: AppColors.line),
            groupSheetItem(
              sheetContext,
              label: i18n.t('common.cancel'),
              color: AppColors.red,
              onTap: () => Navigator.of(sheetContext).pop(),
            ),
          ],
        ),
      ),
    );
    if (!mounted || picked == null) return;

    switch (picked) {
      case 'owner':
        await _changeOwner(member);
      case 'manager':
        await _toggleManager(member);
      case 'nospeak':
        await _openNoSpeak(member);
      case 'remove':
        await _confirmRemove(member);
    }
  }

  Future<void> _changeOwner(GroupMember member) async {
    final i18n = ref.read(appI18nProvider);
    final confirmed = await showGroupConfirm(
      context,
      i18n,
      i18n.t('common.comfirmManageMove'),
    );
    if (confirmed != true) return;
    try {
      await ref
          .read(groupAdminRepositoryProvider)
          .changeOwner(groupId: widget.groupId, userId: member.userId);
      if (!mounted) return;
      // 老端转让成功后 reLaunch 回首页：权限整个换了，留在群里当普通成员没意义
      context.go(AppRoutes.home);
    } on ApiException catch (error) {
      debugPrint('[群成员] 转让群主失败：${error.message}');
      noticeBus.toast(error.message);
    }
  }

  Future<void> _toggleManager(GroupMember member) async {
    final i18n = ref.read(appI18nProvider);
    final nextRole = member.isManager ? groupRoleMember : groupRoleManager;
    final confirmed = await showGroupConfirm(
      context,
      i18n,
      member.isManager
          ? i18n.t('group.cancelManageTips')
          : i18n.t('group.setManageTips'),
    );
    if (confirmed != true || !mounted) return;
    await _applyManager(member.userId, role: nextRole);
  }

  /// 真的去设/撤管理员（用户详情页的「群内管理」块也走这里）
  Future<void> _applyManager(String userId, {required int role}) async {
    try {
      await ref
          .read(groupAdminRepositoryProvider)
          .setManager(groupId: widget.groupId, userId: userId, role: role);
      await _load();
    } on ApiException catch (error) {
      debugPrint('[群成员] 设置管理员失败：${error.message}');
      noticeBus.toast(error.message);
    }
  }

  /// 禁言弹层（共用实现，见 widgets/group_member_sheets.dart）
  Future<void> _openNoSpeak(GroupMember member) async {
    final i18n = ref.read(appI18nProvider);
    final result = await showNoSpeakSheet(
      context,
      i18n,
      days: member.noSpeakDays,
      muted: noSpeakExpiryLabel(member.noSpeakTime).isNotEmpty,
    );
    if (result == null || !mounted) return;
    await _applyNoSpeak(member.userId, choice: result.choice);
  }

  /// 真的去禁言 / 取消禁言
  Future<void> _applyNoSpeak(String userId, {NoSpeakChoice? choice}) async {
    try {
      await ref
          .read(groupAdminRepositoryProvider)
          .muteMember(groupId: widget.groupId, userId: userId, choice: choice);
      await _load();
    } on ApiException catch (error) {
      debugPrint('[群成员] 禁言失败：${error.message}');
      noticeBus.toast(error.message);
    }
  }

  /// 移出群聊（带「加入黑名单」开关的确认弹层，共用实现）。
  ///
  /// 移出后留在管理页（老端 `groupUser.vue` 也是只重拉列表）——用户详情页那条路
  /// 才需要返回上一页。
  Future<void> _confirmRemove(GroupMember member) async {
    final i18n = ref.read(appI18nProvider);
    final isBlack = await showRemoveMemberSheet(context, i18n);
    if (isBlack == null || !mounted) return;
    await _removeMember(member.userId, isBlack: isBlack);
  }

  /// 真的去移出成员。移出成功返回 true
  Future<bool> _removeMember(String userId, {required bool isBlack}) async {
    try {
      await ref
          .read(groupAdminRepositoryProvider)
          .removeMember(
            groupId: widget.groupId,
            userId: userId,
            isBlack: isBlack,
          );
      await _load();
      return true;
    } on ApiException catch (error) {
      debugPrint('[群成员] 移出失败：${error.message}');
      noticeBus.toast(error.message);
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final myId = ref.watch(
      sessionStoreProvider.select((state) => state.userId),
    );
    final visible = searchMembers(_members, _keyword);

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(title: Text(i18n.t('group.user'))),
      body: Column(
        children: <Widget>[
          Container(
            color: AppColors.white,
            padding: EdgeInsets.symmetric(horizontal: context.rpx(30)),
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
                    style: TextStyle(fontSize: context.rpx(28)),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: i18n.t('common.keywords'),
                      hintStyle: TextStyle(
                        fontSize: context.rpx(28),
                        color: AppColors.text999,
                      ),
                    ),
                    onChanged: (value) => setState(() => _keyword = value),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.line),
          Expanded(
            child: _body(context, i18n, myId: myId, visible: visible),
          ),
        ],
      ),
    );
  }

  Widget _body(
    BuildContext context,
    AppI18n i18n, {
    required String myId,
    required List<GroupMember> visible,
  }) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_failed || visible.isEmpty) {
      return Center(child: ContactsEmpty(text: i18n.t('common.none')));
    }
    return RefreshIndicator(
      color: AppColors.brand,
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: visible.length,
        itemBuilder: (context, index) =>
            _row(context, member: visible[index], i18n: i18n, myId: myId),
      ),
    );
  }

  Widget _row(
    BuildContext context, {
    required GroupMember member,
    required AppI18n i18n,
    required String myId,
  }) {
    final expiry = noSpeakExpiryLabel(member.noSpeakTime);
    final canOperate = canOpenMemberOptions(
      member: member,
      myUserId: myId,
      permissions: _permissions,
    );
    return Container(
      color: AppColors.white,
      padding: EdgeInsets.symmetric(
        horizontal: context.rpx(30),
        vertical: context.rpx(16),
      ),
      child: Row(
        children: <Widget>[
          GestureDetector(
            onTap: () => _openMember(member),
            child: ContactAvatar(url: member.avatar, circle: true, sizeRpx: 90),
          ),
          SizedBox(width: context.rpx(20)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        member.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: context.rpx(30),
                          color: AppColors.text333,
                        ),
                      ),
                    ),
                    if (member.role < groupRoleMember) ...<Widget>[
                      SizedBox(width: context.rpx(10)),
                      _tag(
                        context,
                        label: i18n.t(roleLabelKey(member.role)),
                        color: member.isOwner
                            ? AppColors.red
                            : AppColors.orange,
                      ),
                    ],
                    if (member.userId == myId) ...<Widget>[
                      SizedBox(width: context.rpx(10)),
                      _tag(
                        context,
                        label: i18n.t('user.mine'),
                        color: AppColors.text999,
                      ),
                    ],
                  ],
                ),
                if (expiry.isNotEmpty)
                  Text(
                    '${i18n.t('group.noSpeakTo')}：$expiry',
                    style: TextStyle(
                      fontSize: context.rpx(22),
                      color: AppColors.red,
                    ),
                  ),
              ],
            ),
          ),
          if (canOperate)
            GestureDetector(
              onTap: () => _openActions(member),
              child: Padding(
                padding: EdgeInsets.all(context.rpx(10)),
                child: Icon(
                  Icons.more_horiz,
                  size: context.rpx(40),
                  color: AppColors.text999,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tag(
    BuildContext context, {
    required String label,
    required Color color,
  }) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: context.rpx(12),
      vertical: context.rpx(4),
    ),
    decoration: BoxDecoration(
      border: Border.all(color: color, width: 0.8),
      borderRadius: BorderRadius.circular(context.rpx(20)),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: context.rpx(20), color: color),
    ),
  );

  Widget _sheetHeader(
    BuildContext context, {
    required GroupMember member,
    required AppI18n i18n,
  }) => Padding(
    padding: EdgeInsets.all(context.rpx(24)),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        ContactAvatar(url: member.avatar, circle: true, sizeRpx: 60),
        SizedBox(width: context.rpx(16)),
        Flexible(
          child: Text(
            member.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: context.rpx(30),
              color: AppColors.text333,
            ),
          ),
        ),
        if (member.isManager) ...<Widget>[
          SizedBox(width: context.rpx(10)),
          _tag(context, label: i18n.t('group.manage'), color: AppColors.orange),
        ],
      ],
    ),
  );
}
