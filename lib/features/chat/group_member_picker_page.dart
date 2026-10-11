import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/net/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../data/model/contact.dart';
import '../../data/repo/contact_repository.dart';
import '../../data/repo/group_admin_repository.dart';
import '../../domain/contacts/contact_index.dart';
import '../../domain/contacts/group_list.dart';
import '../contacts/widgets/contact_avatar.dart';
import '../contacts/widgets/contacts_empty.dart';

/// 添加群成员，对应老端 `pages/index/userSelection.vue` 的 `type == 2` 分支
/// （源头是 `components/message/user-select.vue`：从**好友列表**里挑，
/// 并且把已经在群里的人排除掉）。
///
/// 与老端不同（刻意的）：
/// * 空选时「完成」是灰的（老端点了会弹一句提示）；
/// * 候选名单来自本地通讯录，没有好友或全都在群里时给空态。
class GroupMemberPickerPage extends ConsumerStatefulWidget {
  const GroupMemberPickerPage({super.key, required this.groupId});

  final String groupId;

  @override
  ConsumerState<GroupMemberPickerPage> createState() =>
      _GroupMemberPickerPageState();
}

class _GroupMemberPickerPageState extends ConsumerState<GroupMemberPickerPage> {
  final Set<String> _picked = <String>{};
  String _keyword = '';
  Set<String> _existing = <String>{};
  bool _loadingMembers = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMembers());
  }

  Future<void> _loadMembers() async {
    try {
      final list = await ref
          .read(groupAdminRepositoryProvider)
          .members(widget.groupId);
      if (!mounted) return;
      setState(() {
        _existing = <String>{for (final member in list.members) member.userId};
        _loadingMembers = false;
      });
    } on Object catch (error) {
      // 成员拉不到就当作「谁都不在群里」，大不了让用户点了之后服务端拦
      debugPrint('[添加成员] 群成员取不到：$error');
      if (mounted) setState(() => _loadingMembers = false);
    }
  }

  Future<void> _submit(AppI18n i18n) async {
    if (_picked.isEmpty) return;
    try {
      await ref
          .read(groupAdminRepositoryProvider)
          .addMembers(
            groupId: widget.groupId,
            userIds: _picked.toList(growable: false),
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (error) {
      debugPrint('[添加成员] 失败：${error.message}');
      noticeBus.toast(error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final friends = ref.watch(friendListProvider).value ?? const <Contact>[];

    // 候选 = 好友 - 已在群里的
    final candidates = <Contact>[
      for (final friend in friends)
        if (!_existing.contains(friend.id)) friend,
    ];
    final visible = sortGroups(searchContacts(candidates, _keyword));

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(
        title: Text(i18n.t('group.addUser')),
        actions: <Widget>[
          TextButton(
            onPressed: _picked.isEmpty ? null : () => _submit(i18n),
            child: Text(
              i18n.t('common.complete'),
              style: TextStyle(
                fontSize: context.rpx(30),
                color: _picked.isEmpty ? AppColors.text999 : AppColors.brand,
              ),
            ),
          ),
        ],
      ),
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
                if (_picked.isNotEmpty)
                  Text(
                    '${i18n.t('common.checked')} ${_picked.length}',
                    style: TextStyle(
                      fontSize: context.rpx(26),
                      color: AppColors.brand,
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.line),
          Expanded(
            child: _loadingMembers
                ? const Center(child: CircularProgressIndicator())
                : visible.isEmpty
                ? Center(child: ContactsEmpty(text: i18n.t('common.none')))
                : ListView.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, index) =>
                        _row(context, friend: visible[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, {required Contact friend}) {
    final selected = _picked.contains(friend.id);
    return InkWell(
      onTap: () => setState(() {
        if (selected) {
          _picked.remove(friend.id);
        } else {
          _picked.add(friend.id);
        }
      }),
      child: Container(
        height: context.rpx(110),
        padding: EdgeInsets.symmetric(horizontal: context.rpx(30)),
        color: AppColors.white,
        child: Row(
          children: <Widget>[
            ContactAvatar(url: friend.avatar, circle: true, sizeRpx: 80),
            SizedBox(width: context.rpx(20)),
            Expanded(
              child: Text(
                friend.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.rpx(30),
                  color: AppColors.text333,
                ),
              ),
            ),
            Icon(
              selected ? Icons.check_box : Icons.check_box_outline_blank,
              size: context.rpx(40),
              color: selected ? AppColors.brand : AppColors.text999,
            ),
          ],
        ),
      ),
    );
  }
}
