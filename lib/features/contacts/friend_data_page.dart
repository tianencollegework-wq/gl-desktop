import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/net/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/ui/text_prompt_dialog.dart';
import '../../data/model/user_detail.dart';
import '../../data/repo/contact_repository.dart';
import '../../domain/contacts/user_detail_actions.dart';
import '../mine/widgets/mine_list.dart';
import 'widgets/contacts_empty.dart';

/// 朋友资料，对应微信「好友资料 → 朋友资料」那一页。
///
/// 从 `UserDetailPage`（用户详情页）点「朋友资料」那一栏进来，一栏一项：
///
/// * **备注名**：可改（老端 `friendApi.setNickname`，改完本地通讯录的显示名也跟着变）；
/// * **个性签名**：只读，显示对方的 `motto`；
/// * **性别**：只读（原来摆在详情页那一行，现在挪到这儿）。
///
/// 微信那一页还有「标签 / 电话 / 附加图片 / 朋友权限」——我们后端没有这些字段，不做。
///
/// 两条刻意的做法：
/// * 这一页**自己拉一次详情**（`getUserInfo`）而不是把对象从上一页传进来：
///   这样它只认一个 `userId`，从任何入口进来都一样，也不怕上一页的数据过期；
/// * 改完备注 **`pop(true)`**，上一页看到 true 就重新拉详情 —— 备注行、标题里的名字
///   都要跟着变（老端是就地改 `detail`，我们让数据单一来源）。
class FriendDataPage extends ConsumerStatefulWidget {
  const FriendDataPage({super.key, required this.userId});

  final String userId;

  @override
  ConsumerState<FriendDataPage> createState() => _FriendDataPageState();
}

class _FriendDataPageState extends ConsumerState<FriendDataPage> {
  UserDetail? _detail;
  bool _loading = true;
  bool _failed = false;
  String _errorMessage = '';

  /// 这一页有没有改过东西（返回时告诉上一页要不要重拉详情）
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (widget.userId.isEmpty) {
      setState(() {
        _loading = false;
        _failed = true;
        _errorMessage = '';
      });
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
      _errorMessage = '';
    });
    try {
      final detail = await ref
          .read(contactRepositoryProvider)
          .userDetail(widget.userId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } on ApiException catch (error) {
      debugPrint('[朋友资料] 加载失败：$error');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
        _errorMessage = error.message;
      });
    } on Object catch (error) {
      debugPrint('[朋友资料] 加载失败：$error');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
        _errorMessage = '';
      });
    }
  }

  /// 改备注 / **清空备注**。
  ///
  /// 与老端的一处刻意差别：**允许清空**。老端（和我们之前）在输入为空时直接弹
  /// 「请输入备注！」拦下，于是备注一旦设过就再也去不掉。现在空输入 = 把备注清掉，
  /// 显示名回到对方的真实昵称。
  ///
  /// ⚠️ 要服务端配合：老版本 `Friend::setNickname` 里那句 `if(!$param['nickname'])`
  /// 会把空串当「没传」拦下，得先上那个补丁（`Friend.php` 里改成按字段存在判断）。
  Future<void> _setNickname(UserDetail detail) async {
    final i18n = ref.read(appI18nProvider);
    if (!detail.isFriend) {
      noticeBus.toast(i18n.t('friend.dontSet'));
      return;
    }
    final input = await showTextPrompt(
      context,
      title: i18n.t('friend.inputRemark'),
      initial: detail.nickname,
    );
    if (input == null || !mounted) return;
    try {
      final message = await ref
          .read(contactRepositoryProvider)
          .setFriendNickname(
            userId: detail.userId,
            friendId: detail.friendId,
            nickname: input.trim(),
            // 真名兜底（服务端没给真名时 `title` 会退到 user_id，不会留个空名字）
            fallbackName: detail.title,
          );
      if (message.isNotEmpty) noticeBus.toast(message);
      _changed = true;
      // 备注与本地通讯录都变了，重新拉一次本页的数据
      await _load();
    } on ApiException catch (error) {
      debugPrint('[朋友资料] 改备注失败：${error.message}');
      noticeBus.toast(error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // 把「改过没有」带回上一页（它据此决定要不要重拉详情）
        Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        backgroundColor: AppColors.page,
        appBar: AppBar(
          title: Text(i18n.t('user.friendData')),
          leading: BackButton(
            onPressed: () => Navigator.of(context).pop(_changed),
          ),
        ),
        body: _body(context, i18n),
      ),
    );
  }

  Widget _body(BuildContext context, AppI18n i18n) {
    final detail = _detail;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_failed || detail == null || detail.userId.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ContactsEmpty(
              text: _errorMessage.isEmpty
                  ? i18n.t('common.noData')
                  : _errorMessage,
            ),
            SizedBox(height: context.rpx(24)),
            TextButton(
              onPressed: () => unawaited(_load()),
              child: Text(i18n.t('common.retry')),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: EdgeInsets.only(bottom: context.rpx(40)),
      children: <Widget>[
        MineList(
          gapBefore: false,
          children: <Widget>[
            MineListItem(
              label: i18n.t('user.remarkName'),
              trailingWidget: _value(
                context,
                detail.nickname.isEmpty
                    ? i18n.t('common.notSet')
                    : detail.nickname,
              ),
              onTap: () => unawaited(_setNickname(detail)),
            ),
            MineListItem(
              label: i18n.t('user.motto'),
              trailingWidget: _value(
                context,
                detail.motto.isEmpty ? i18n.t('common.notSet') : detail.motto,
              ),
              showChevron: false,
            ),
            MineListItem(
              label: i18n.t('user.gender'),
              trailing: i18n.t(sexLabelKey(detail.sex)),
              showChevron: false,
            ),
          ],
        ),
      ],
    );
  }

  /// 右侧那栏的灰字，**贴着行尾、单行省略号**。
  ///
  /// 两点讲究：
  /// * 宽度钉死在一半屏（`rpx(375)`）—— 签名/备注可能很长，不能让它把行首标签挤没；
  /// * 不能包 `Flexible` 交给 `Row` 去平分宽度：那样短值（「未设置」）会落在
  ///   行的**中间**（用户 2026-09-21 报的就是这个，看着不三不四）。
  Widget _value(BuildContext context, String text) => ConstrainedBox(
    constraints: BoxConstraints(maxWidth: context.rpx(375)),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.right,
      style: TextStyle(fontSize: context.rpx(28), color: AppColors.text666),
    ),
  );
}
