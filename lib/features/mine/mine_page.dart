import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/router/app_router.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import 'widgets/mine_list.dart';

/// 「我」tab，对应老端 `pages/mine/index.vue`（S5.5）。
///
/// 长相按微信来：**这一页没有标题栏**（见 `HomeShell._buildNavBar`），
/// 顶上就是一张白底资料卡，直接顶到状态栏；下面靠灰缝分成几块，
/// 每块都是通栏白底 + 一条细线，没有圆角卡片。
///
/// 老端是一条品牌蓝顶栏 + 「我的」标题 + 一堆白色圆角卡片，两回事。
///
/// 微信那几块里我们**有的才画**：
/// * 资料卡右上角 → 我的二维码（微信也是这个位置）；
/// * 「表情」→ 自定义表情管理（微信 `我 › 表情` 也是这一页）；
/// * 「设置」→ 全部设置项都挪进去了（老端是平铺在这一页上）。
///
/// 没画的：服务、收藏、朋友圈、作品、小店与卡包、状态、切换账号 —— 都没有对应功能。
/// 「扫一扫」也从这一页拿掉了：微信里它在右上角那颗「＋」里，我们那颗 ＋ 里已经有。
class MinePage extends ConsumerWidget {
  const MinePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);

    return ListView(
      padding: EdgeInsets.zero,
      children: <Widget>[
        _profileCard(context, ref, i18n),
        MineList(
          dividerIndentRpx: AppDimens.listIconDividerRpx,
          children: <Widget>[
            MineListItem(
              icon: Icons.sentiment_satisfied_alt,
              iconColor: AppColors.iconAmber,
              label: i18n.t('common.emoji'),
              onTap: () => context.push(AppRoutes.emoji),
            ),
          ],
        ),
        MineList(
          dividerIndentRpx: AppDimens.listIconDividerRpx,
          children: <Widget>[
            MineListItem(
              icon: Icons.settings,
              iconColor: AppColors.iconBlue,
              label: i18n.t('user.setting'),
              onTap: () => context.push(AppRoutes.mineSetting),
            ),
          ],
        ),
        SizedBox(height: context.rpx(40)),
      ],
    );
  }

  /// 白底资料卡：头像 + 昵称 + 恩信号，右下角一个 `>`，右上角二维码。
  ///
  /// 微信的摆法是**头像左、两行文字右、二维码在右上角贴顶**，那个 `>` 不居中而是
  /// 落在第二行（恩信号那行）后面 —— 所以这里是「外层贴顶 + 第二行自己带箭头」，
  /// 不是把箭头垂直居中。
  ///
  /// 上下留白与行间距全部照微信实测值（1080px 宽截图 → rpx 就是 px÷1.44）：
  ///
  /// | 位置 | 微信 | 这里 |
  /// |---|---|---|
  /// | 状态栏 → 头像顶 | 184px | `rpx(128)` |
  /// | 头像 | 172px | `rpx(125)` |
  /// | 名字顶 / 恩信号顶 | 276 / 360 | 278 / 372 |
  /// | 那一排小药丸 | 475~539（高 65px） | 473~539（高 `rpx(46)`） |
  /// | 药丸底 → 卡片底 | 65px | `rpx(46)` |
  /// | 卡片总高 | 604px | ~605px |
  Widget _profileCard(BuildContext context, WidgetRef ref, AppI18n i18n) {
    final user = ref.watch(sessionStoreProvider.select((state) => state.user));
    final circleAvatar = ref.watch(
      sessionStoreProvider.select((state) => state.setting.circleAvatar),
    );
    final account = user?.account ?? '';

    return Container(
      // 给测试一个把手：几张尺寸是照微信实测值钉的（见上面那张表）
      key: const ValueKey<String>('mineProfileCard'),
      color: AppColors.white,
      padding: EdgeInsets.fromLTRB(
        context.rpx(AppDimens.listPadRpx),
        // 微信资料卡上面那片留白很大（实测 184px ≫ 状态栏那点高度），
        // 原来只留了 rpx(24)，卡片就贴到状态栏上了。
        context.statusBarHeight + context.rpx(128),
        context.rpx(AppDimens.listPadRpx),
        context.rpx(46),
      ),
      child: InkWell(
        onTap: () => context.push(AppRoutes.mineProfile),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ClipRRect(
              borderRadius: circleAvatar
                  ? BorderRadius.circular(context.rpx(62))
                  : BorderRadius.circular(context.rpx(16)),
              child: SizedBox(
                width: context.rpx(125),
                height: context.rpx(125),
                child: (user?.avatar ?? '').isEmpty
                    ? _avatarPlaceholder(context)
                    : Image.network(
                        user!.avatar,
                        fit: BoxFit.cover,
                        errorBuilder: (error, stack, _) =>
                            _avatarPlaceholder(context),
                      ),
              ),
            ),
            SizedBox(width: context.rpx(28)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(height: context.rpx(8)),
                  Text(
                    user?.name ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: context.rpx(38),
                      fontWeight: FontWeight.w600,
                      color: AppColors.text000,
                    ),
                  ),
                  SizedBox(height: context.rpx(18)),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          account.isEmpty
                              ? ''
                              : '${i18n.t('user.wechatId')}：$account',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: context.rpx(28),
                            color: AppColors.text666,
                          ),
                        ),
                      ),
                      // 微信那个 `>` 落在这一行（不是整张卡垂直居中）
                      Icon(
                        Icons.chevron_right,
                        size: context.rpx(36),
                        color: AppColors.chevron,
                      ),
                    ],
                  ),
                  SizedBox(height: context.rpx(44)),
                  // 认证状态。微信在这个位置是一排小药丸（`+ 状态`、`朋友 👥`），
                  // 我们没有那两项，但「已认证 / 未认证」是我们**本来就有**的信息
                  // —— 去掉就再也看不见了，于是照微信那排药丸的样式摆在同一个位置。
                  _authPill(context, i18n, user?.isAuth ?? 0),
                ],
              ),
            ),
            // 个人二维码（微信也在资料卡右上角）
            IconButton(
              tooltip: i18n.t('user.myQrcode'),
              icon: Icon(
                Icons.qr_code,
                size: context.rpx(44),
                color: AppColors.text000,
              ),
              onPressed: () => context.push(AppRoutes.qrcode),
            ),
          ],
        ),
      ),
    );
  }

  /// 「已认证 / 未认证」小药丸。
  ///
  /// 尺寸与配色照微信那一排药丸实测：高 65px（`rpx(46)`）、圆角全圆、
  /// 一条 `#B2B2B2` 细边、里面 24rpx 的近黑字 + 前面一个小图标。
  Widget _authPill(BuildContext context, AppI18n i18n, int isAuth) {
    final verified = isAuth == 1;
    return Container(
      key: const ValueKey<String>('mineAuthPill'),
      height: context.rpx(46),
      padding: EdgeInsets.symmetric(horizontal: context.rpx(20)),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.pillBorder, width: 0.5),
        borderRadius: BorderRadius.circular(context.rpx(23)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            verified ? Icons.verified_user : Icons.report_gmailerrorred,
            size: context.rpx(26),
            color: verified ? AppColors.iconGreen : AppColors.text999,
          ),
          SizedBox(width: context.rpx(8)),
          Text(
            i18n.t(verified ? 'user.isAuth' : 'user.notAuth'),
            style: TextStyle(
              fontSize: context.rpx(24),
              color: AppColors.text333,
            ),
          ),
        ],
      ),
    );
  }

  Widget _avatarPlaceholder(BuildContext context) => ColoredBox(
    color: AppColors.gray,
    child: Icon(Icons.person, size: context.rpx(70), color: AppColors.text999),
  );
}
