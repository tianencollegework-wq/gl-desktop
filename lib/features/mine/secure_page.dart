import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/router/app_router.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../domain/mine/profile_form.dart';
import 'widgets/mine_list.dart';

/// 账号与安全，对应老端 `pages/mine/secure.vue`（S5.5）。
///
/// 三件事：
/// * **我的账号**（换账号）：没认证（`is_auth`）时点不进去，只提示「请先认证账户！」
///   （老端 `editAcc`）；
/// * **修改密码**：独立的三步向导页 `PasswordChangePage`；
/// * **认证账户**：只有未认证时才出现。它点了也进**换账号那一页**
///   —— 认证这件事本身就是「把账号换成真实的邮箱，验证成功后服务端把 `is_auth`
///   置 1」，所以这一行**不能**被上面那道认证校验挡住（老端这一行也是直接进表单，
///   不查 `is_auth`）。
///
/// 换账号原来跟改密码一样是**一个底部弹层塞三栏**，现在两边都拆成了一屏一项的
/// 向导页（`AccountChangePage` / `PasswordChangePage`）。
///
/// 验证码两个入口的 `type` 不一样（老端：改密码 3、改账号 4），
/// 参数与校验全在 `domain/mine/profile_form.dart` 里（有单测）。
///
/// 观感按微信 `设置 → 账号与安全`：通栏白底 + 行高 50dp + 细线（同一套 `AppDimens`），
/// **没有行首图标**（微信那页也是纯文字），也没有底部那个红色按钮 ——
/// 微信的退出入口只在「设置」最底下那一块，我们跟它一样（避免两个地方都能退出）。
class SecurePage extends ConsumerWidget {
  const SecurePage({super.key});

  /// 进换账号那一页。
  ///
  /// [checkAuth] 只有「我的账号」那一行会传 true：那个入口要求先认证；
  /// 「认证账户」那一行进来时是 false —— 它就是来认证的。
  void _openAccountChange(
    BuildContext context,
    WidgetRef ref, {
    required bool checkAuth,
  }) {
    if (checkAuth) {
      final isAuth = (ref.read(sessionStoreProvider).user?.isAuth ?? 0) != 0;
      final blocked = accountEditErrorKey(isAuth: isAuth);
      if (blocked != null) {
        noticeBus.toast(ref.read(appI18nProvider).t(blocked));
        return;
      }
    }
    context.push(AppRoutes.mineAccount);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);
    final user = ref.watch(sessionStoreProvider.select((state) => state.user));
    final isAuth = (user?.isAuth ?? 0) != 0;

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(title: Text(i18n.t('user.secure'))),
      body: ListView(
        padding: EdgeInsets.only(bottom: context.rpx(40)),
        children: <Widget>[
          MineList(
            gapBefore: false,
            children: <Widget>[
              MineListItem(
                label: i18n.t('user.myAcount'),
                trailing: user?.account ?? '',
                // 没认证点不进换账号（老端那句「请先认证账户！」）
                onTap: () => _openAccountChange(context, ref, checkAuth: true),
              ),
              MineListItem(
                label: i18n.t('user.editPass'),
                onTap: () => context.push(AppRoutes.minePassword),
              ),
              if (!isAuth)
                MineListItem(
                  label: i18n.t('user.doAuth'),
                  // 这一行就是来认证的，所以**不查** `is_auth`（老端也一样）
                  onTap: () =>
                      _openAccountChange(context, ref, checkAuth: false),
                ),
            ],
          ),
          SizedBox(height: context.rpx(20)),
          // 注销账号（不可逆）：单独一块、红字居中，和「退出登录」同一套观感
          InkWell(
            onTap: () => context.push(AppRoutes.mineCancelAccount),
            child: Container(
              height: context.rpx(AppDimens.listRowRpx),
              color: AppColors.white,
              alignment: Alignment.center,
              child: Text(
                i18n.t('user.cancelAccount'),
                style: TextStyle(
                  fontSize: context.rpx(32),
                  color: AppColors.red,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
