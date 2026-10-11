import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/net/api_exception.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../data/repo/group_admin_repository.dart';
import '../../domain/chat/group_join.dart';
import 'widgets/contact_avatar.dart';

/// 群资料 / 加入群聊，对应老端 `pages/message/group/info.vue`
/// （`/message/group/info?group_id=`）。
///
/// 这一页只有一个来路：**扫到群二维码之后**（`common/scan.js` 那句
/// `case 'groupInfo'`）。界面上就三样：群头像、群名（人数）、一颗按钮——
/// 已经在群里就是「进入群聊」，否则是「加入群聊」。
///
/// 与老端不同（刻意的）：老端加群成功只把 `is_group` 改成 1 就 `appendContacts`；
/// 新端走 [GroupAdminRepository.join]，通讯录与会话都写、并把本端 client 绑上
/// （不赌服务端推送），否则新进的群可能收不到消息。
///
/// **为什么需要 [scanned]（S7.4 修的 bug）**：服务端的「群资料」接口
/// （`/enterprise/group/groupInfo`）是**群成员专属**的 —— 它先 `checkGroupMember`，
/// 不在群里就回一句「您没有操作权限！」。而群二维码本来就是给**还没进群的人**
/// 扫的，于是这条路死锁：扫码 → 拉群资料 → 被拒 → 连「加入群聊」那颗按钮都不显示
/// （用户 2026-09-29 报的「奇葩bug」就是这个）。
/// 好在**扫码那一步**服务端已经把整行群资料给过我们了
/// （`/scan/g/<token>`，谁都能问）—— 扫码页把它当 `extra` 带过来，这一页拿它兜底：
/// 先用它把页面画出来，`groupInfo` 能拉到（我是群成员）就换成更全的那份
/// （多了群人数与「进入群聊」）。
class GroupJoinPage extends ConsumerStatefulWidget {
  const GroupJoinPage({super.key, required this.groupId, this.scanned});

  final String groupId;

  /// 扫码那一步服务端给的群资料（未入群也能拿到）。
  ///
  /// 空 = 没有（直接 push 这个路由进来的，比如深链 / 用例），那就只能靠 `groupInfo`。
  final GroupJoinInfo? scanned;

  @override
  ConsumerState<GroupJoinPage> createState() => _GroupJoinPageState();
}

class _GroupJoinPageState extends ConsumerState<GroupJoinPage> {
  GroupJoinInfo? _info;
  String _error = '';

  /// 只在**真的还没东西可显示**时才转圈（有扫码带过来的那份就直接画）
  bool _loading = true;
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    final scanned = widget.scanned;
    if (scanned != null) {
      _info = scanned;
      _loading = false;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// 拉群资料。
  ///
  /// 未入群时服务端**就是会拒**（「您没有操作权限！」），所以这里分两层：
  /// 有扫码带过来的那份就照常显示（只是补不上人数/`isJoin`），没有才是错误页。
  /// 拉不到也**不提示**（`notify: false`）：那句「没有操作权限」是预期之内的，
  /// 糊到用户脸上只会让人以为加不了群。
  Future<void> _load() async {
    final scanned = widget.scanned;
    setState(() {
      _loading = _info == null;
      _error = '';
    });
    try {
      final info = await ref
          .read(groupAdminRepositoryProvider)
          .joinInfo(widget.groupId, notify: scanned == null);
      if (!mounted) return;
      setState(() {
        _info = info;
        _loading = false;
      });
    } on ApiException catch (error) {
      debugPrint('[群资料] 拉取失败：${error.message}');
      if (!mounted) return;
      // 有扫码那份就继续用它 —— 这一页的全部意义就是「让人加群」，
      // 服务端的这句拒绝不能把加群这颗按钮也一起挡掉。
      if (scanned != null) {
        setState(() => _loading = false);
        return;
      }
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  Future<void> _join(AppI18n i18n) async {
    final info = _info;
    if (info == null || _joining) return;
    if (!info.inviteOpen) {
      noticeBus.toast(i18n.t('group.closeJoin'));
      return;
    }

    setState(() => _joining = true);
    try {
      await ref
          .read(groupAdminRepositoryProvider)
          .join(
            widget.groupId,
            inviteUid: info.inviteUid,
            // 加入成功后本地要有一条像样的会话（名字 / 头像都从这一页带过去）
            group: <String, dynamic>{
              'id': info.id,
              'displayName': info.name,
              'avatar': info.avatar,
            },
          );
      if (!mounted) return;
      _openChat();
    } on ApiException catch (error) {
      debugPrint('[群资料] 加群失败：${error.message}');
      noticeBus.toast(error.message);
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  void _openChat() => context.push(
    '${AppRoutes.chat}?id=${Uri.encodeComponent(widget.groupId)}',
  );

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final info = _info;

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(title: Text(i18n.t('group.meessage'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : info == null
          ? _errorView(context, i18n)
          : Column(
              children: <Widget>[
                SizedBox(height: context.rpx(100)),
                ContactAvatar(
                  url: info.avatar,
                  circle: false,
                  sizeRpx: 240,
                  radiusRpx: 24,
                ),
                SizedBox(height: context.rpx(20)),
                Text(
                  info.memberCount > 0
                      ? '${info.name} (${info.memberCount})'
                      : info.name,
                  style: TextStyle(
                    fontSize: context.rpx(30),
                    color: AppColors.text333,
                  ),
                ),
                SizedBox(height: context.rpx(60)),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: context.rpx(60)),
                  child: SizedBox(
                    width: double.infinity,
                    height: context.rpx(90),
                    child: FilledButton(
                      onPressed: _joining
                          ? null
                          : info.joined
                          ? _openChat
                          : () => _join(i18n),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.green,
                      ),
                      child: _joining
                          ? SizedBox(
                              width: context.rpx(34),
                              height: context.rpx(34),
                              child: const CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.white,
                              ),
                            )
                          : Text(
                              i18n.t(info.joined ? 'group.goto' : 'group.join'),
                              style: TextStyle(fontSize: context.rpx(30)),
                            ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _errorView(BuildContext context, AppI18n i18n) => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Text(
          _error.isEmpty ? i18n.t('common.noData') : _error,
          style: TextStyle(fontSize: context.rpx(28), color: AppColors.text666),
        ),
        SizedBox(height: context.rpx(20)),
        OutlinedButton(onPressed: _load, child: Text(i18n.t('common.retry'))),
      ],
    ),
  );
}
