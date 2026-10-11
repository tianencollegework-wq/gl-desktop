import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/net/api_client.dart';
import '../../core/net/api_exception.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../data/model/contact.dart';
import '../../data/repo/contact_repository.dart';
import '../../data/repo/group_admin_repository.dart';
import '../../domain/contacts/contact_index.dart';
import '../../domain/contacts/group_list.dart';
import '../contacts/widgets/contact_avatar.dart';
import '../contacts/widgets/contacts_empty.dart';

/// 用户选择页，对应老端 `pages/index/userSelection.vue`。
///
/// 老端这一页用 `type` 分五种用途，新端只在这里实现 **`type == 1`（创建群聊）**——
/// 其余三种都各自有更合适的载体，不再挤进同一页：
/// * `2` 添加群成员 → `GroupMemberPickerPage`（从群信息页进，选完原地刷新）；
/// * `3` 转发 → `showForwardPicker`（底部弹层，实时选）；
/// * `4` 提及某人 → `showMemberPicker`（底部弹层，插进输入框）。
class UserSelectionPage extends ConsumerStatefulWidget {
  const UserSelectionPage({
    super.key,
    this.type = 1,
    this.presetIds = const <String>[],
  });

  /// 老端 `userSelection.vue` 的 `type`（新端只认 1）
  final int type;

  /// 进来就替人选上的人（老端 `contact_id`）：单聊信息页的「发起群聊」传对方 id，
  /// 这样从「和某人聊天」一步就能开一个只有俩人的群。
  final List<String> presetIds;

  @override
  ConsumerState<UserSelectionPage> createState() => _UserSelectionPageState();
}

class _UserSelectionPageState extends ConsumerState<UserSelectionPage> {
  /// 选中的好友 id（按点选顺序，底部头像栏也按这个顺序排）
  late final Set<String> _picked = <String>{...widget.presetIds};
  String _keyword = '';
  bool _submitting = false;

  Future<void> _submit() async {
    if (_picked.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    try {
      final groupId = await ref
          .read(groupAdminRepositoryProvider)
          .createGroup(userIds: _picked.toList(growable: false));
      if (!mounted) return;
      // 建完直接进新群（老端也是 `navigateTo chat?id=`）。用 replace 而不是 push：
      // 从群聊返回时应该回到消息首页，而不是回到这个已经用完的选择页。
      context.pushReplacement(
        '${AppRoutes.chat}?id=${Uri.encodeComponent(groupId)}',
      );
    } on ApiException catch (error) {
      debugPrint('[创建群聊] 失败：${error.message}');
      if (mounted) setState(() => _submitting = false);
      // 提示走接口层那一套（`needsRelogin` 该跳登录就跳登录），只是这次由页面触发
      ref.read(apiClientProvider).notifyError(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final friends = ref.watch(friendListProvider).value ?? const <Contact>[];
    final visible = sortGroups(searchContacts(friends, _keyword));
    final byId = <String, Contact>{
      for (final friend in friends) friend.id: friend,
    };

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(
        title: Text(i18n.t('user.createGroup')),
        actions: <Widget>[
          if (_submitting)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.rpx(30)),
              child: Center(
                child: SizedBox(
                  width: context.rpx(34),
                  height: context.rpx(34),
                  child: const CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            TextButton(
              onPressed: _picked.isEmpty ? null : _submit,
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
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.line),
          Expanded(
            child: visible.isEmpty
                ? Center(
                    child: ContactsEmpty(
                      text: i18n.t(
                        _keyword.isEmpty ? 'common.none' : 'common.searchNone',
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, index) =>
                        _row(context, friend: visible[index]),
                  ),
          ),
          if (_picked.isNotEmpty) _pickedBar(context, i18n, byId),
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

  /// 底部「已选的人」横向头像栏（老端 `user-select.vue` 的 `footer-opt`）：
  /// 点一下头像就把这个人去掉，右端跟一句「已选 N 人」。
  Widget _pickedBar(
    BuildContext context,
    AppI18n i18n,
    Map<String, Contact> byId,
  ) => Container(
    height: context.rpx(130),
    color: AppColors.white,
    child: Column(
      children: <Widget>[
        const Divider(height: 1, color: AppColors.line),
        Expanded(
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(
              horizontal: context.rpx(30),
              vertical: context.rpx(15),
            ),
            children: <Widget>[
              for (final id in _picked)
                if (byId[id] != null)
                  Padding(
                    padding: EdgeInsets.only(right: context.rpx(20)),
                    child: GestureDetector(
                      onTap: () => setState(() => _picked.remove(id)),
                      child: ContactAvatar(
                        url: byId[id]!.avatar,
                        circle: true,
                        sizeRpx: 80,
                      ),
                    ),
                  ),
              Align(
                child: Text(
                  '${i18n.t('common.checked')} ${_picked.length} '
                  '${i18n.t('group.per')}',
                  style: TextStyle(
                    fontSize: context.rpx(26),
                    color: AppColors.text666,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: context.bottomSafeHeight),
      ],
    ),
  );
}
