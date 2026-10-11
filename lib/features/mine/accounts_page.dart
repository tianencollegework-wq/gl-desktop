import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/config/app_info.dart';
import '../../core/i18n/app_i18n.dart';
import '../../core/platform/desktop_shell.dart';
import '../../core/router/app_router.dart';
import '../../core/store/saved_accounts.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/ui/wechat_dialog.dart';
import '../../domain/session/session_service.dart';
import '../contacts/widgets/contact_avatar.dart';
import '../login/widgets/auth_widgets.dart';
import '../../core/ui/desktop_overlay.dart';

/// 切换账号，对应设置里那一行「切换账号」（S10.1）。
///
/// 观感照用户 2026-09-29 给的那张图（Mosavi 的账号页），只是把 logo 换成我们自己
/// 随包的那张：顶部 logo + 站点名 → 「轻触头像以切换账号」→ 账号卡（头像、昵称、
/// 恩信号）→ 「添加账号」。右上角是「管理」，进管理模式后每张卡上出现删除。
///
/// 几条定死的规则（都是用户定的）：
/// * **最多三个账号**：存满之后「添加账号」那一行**不再显示**，要加先点「管理」删一个；
/// * 卡片上「当前使用」的是正在用的那个；
/// * 在设置里**退出登录过的账号仍留在列表里**（但令牌已作废，卡上标「已退出」），
///   点它会进登录表单、账号已预填，输个密码就能回来；
/// * 「管理」里**当前账号也能删**，删它等同退出登录（会先弹一次确认）。
///
/// 切换本身不调服务端登出（见 `session_service.switchAccount`）：把令牌存回列表，
/// 换上新账号的那一份，断线重连。所以只有当前账号在线 —— 一条 WebSocket 只能绑
/// 一个 uid，后台那几个账号收不到消息与来电（不改造服务端解决不了）。
class AccountsPage extends ConsumerStatefulWidget {
  const AccountsPage({super.key});

  @override
  ConsumerState<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends ConsumerState<AccountsPage> {
  /// 管理模式（右上角「管理 / 完成」）
  bool _managing = false;

  /// 切换进行中：挡住连点，顺便盖一层半透明遮罩（要清本机数据再重连，有一下等待）
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final store = ref.watch(savedAccountsProvider);
    final siteName = AppInfo.siteName(
      ref.watch(
        sessionStoreProvider.select((state) => state.config.sysInfo.name),
      ),
    );
    final currentUserId = ref.watch(
      sessionStoreProvider.select((state) => state.userId),
    );
    final circle = ref.watch(
      sessionStoreProvider.select((state) => state.setting.circleAvatar),
    );

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(
        title: Text(i18n.t('user.switchAccount')),
        actions: <Widget>[
          // 一个账号都没有时没什么可管理的，那颗字就不画
          if (store.accounts.isNotEmpty)
            TextButton(
              onPressed: () => setState(() => _managing = !_managing),
              child: Text(
                _managing ? i18n.t('common.done') : i18n.t('user.manage'),
              ),
            ),
        ],
      ),
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: ValueListenableBuilder<int>(
              valueListenable: store.revision,
              builder: (context, _, _) {
                final accounts = store.accounts;
                return ListView(
                  padding: EdgeInsets.only(bottom: context.rpx(60)),
                  children: <Widget>[
                    SizedBox(height: context.rpx(50)),
                    Center(child: AuthBrand(siteName: siteName)),
                    SizedBox(height: context.rpx(44)),
                    Center(
                      child: Text(
                        i18n.t('user.switchAccountHint'),
                        style: TextStyle(
                          fontSize: context.rpx(40),
                          fontWeight: FontWeight.w600,
                          color: AppColors.text000,
                        ),
                      ),
                    ),
                    SizedBox(height: context.rpx(40)),
                    for (final account in accounts)
                      _accountCard(
                        i18n,
                        account,
                        current: account.userId == currentUserId,
                        circle: circle,
                      ),
                    // 满了就不画这一行：要加先「管理」里删一个（用户定的）
                    if (!store.isFull) _addRow(i18n),
                  ],
                );
              },
            ),
          ),
          if (_busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x33000000),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }

  /// 一张账号卡：头像 + 昵称 + 恩信号，右边是状态或删除
  Widget _accountCard(
    AppI18n i18n,
    SavedAccount account, {
    required bool current,
    required bool circle,
  }) {
    final radius = BorderRadius.circular(context.rpx(24));
    return Padding(
      padding: EdgeInsets.only(
        left: context.rpx(30),
        right: context.rpx(30),
        bottom: context.rpx(24),
      ),
      child: Material(
        color: AppColors.white,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: () => _onAccountTap(account, current: current),
          child: Padding(
            padding: EdgeInsets.all(context.rpx(24)),
            child: Row(
              children: <Widget>[
                ContactAvatar(
                  url: account.avatar,
                  circle: circle,
                  sizeRpx: 108,
                  radiusRpx: 24,
                ),
                SizedBox(width: context.rpx(20)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        account.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: context.rpx(34),
                          fontWeight: FontWeight.w600,
                          color: AppColors.text000,
                        ),
                      ),
                      SizedBox(height: context.rpx(8)),
                      Text(
                        // 「恩信号」= 登录账号（服务端没有单独的号码字段，
                        // 见 `SavedAccount.gracelinkId`；key 与「我」页那张资料卡同一个）
                        '${i18n.t('user.wechatId')}：${account.gracelinkId}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: context.rpx(26),
                          color: AppColors.text999,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: context.rpx(16)),
                _cardTrailing(i18n, account, current: current),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _cardTrailing(
    AppI18n i18n,
    SavedAccount account, {
    required bool current,
  }) {
    if (_managing) {
      // 删除那颗：管理模式里每张卡都有（当前账号也在内，删它等同退出登录）
      return GestureDetector(
        onTap: () => _delete(account, current: current),
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: context.rpx(20),
            vertical: context.rpx(12),
          ),
          decoration: BoxDecoration(
            color: AppColors.red.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(context.rpx(18)),
          ),
          child: Text(
            i18n.t('user.deleteAccount'),
            style: TextStyle(
              fontSize: context.rpx(26),
              fontWeight: FontWeight.w600,
              color: AppColors.red,
            ),
          ),
        ),
      );
    }
    if (current) {
      return Text(
        i18n.t('user.currentUsing'),
        style: TextStyle(
          fontSize: context.rpx(28),
          fontWeight: FontWeight.w500,
          color: AppColors.wechatGreen,
        ),
      );
    }
    // 在设置里退出登录过的那一份：令牌已作废，点它得重新输密码
    if (!account.canSwitchOnline) {
      return Text(
        i18n.t('user.signedOut'),
        style: TextStyle(fontSize: context.rpx(26), color: AppColors.text999),
      );
    }
    return const SizedBox.shrink();
  }

  /// 「添加账号」那一行：绿框加号 + 文字
  Widget _addRow(AppI18n i18n) {
    final radius = BorderRadius.circular(context.rpx(24));
    return Padding(
      padding: EdgeInsets.only(
        left: context.rpx(30),
        right: context.rpx(30),
        bottom: context.rpx(24),
      ),
      child: Material(
        color: AppColors.white,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: () => _showAddSheet(i18n),
          child: Padding(
            padding: EdgeInsets.all(context.rpx(24)),
            child: Row(
              children: <Widget>[
                Container(
                  width: context.rpx(108),
                  height: context.rpx(108),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: AppColors.wechatGreen,
                      width: context.rpx(3),
                    ),
                    borderRadius: BorderRadius.circular(context.rpx(24)),
                  ),
                  child: Icon(
                    Icons.add_rounded,
                    size: context.rpx(56),
                    color: AppColors.wechatGreen,
                  ),
                ),
                SizedBox(width: context.rpx(20)),
                Expanded(
                  child: Text(
                    i18n.t('user.addAccount'),
                    style: TextStyle(
                      fontSize: context.rpx(34),
                      fontWeight: FontWeight.w600,
                      color: AppColors.text000,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 点一个账号：切过去；令牌作废的（退出登录过）就送去登录表单
  Future<void> _onAccountTap(
    SavedAccount account, {
    required bool current,
  }) async {
    if (_busy || _managing || current) return;
    final i18n = ref.read(appI18nProvider);
    if (!account.canSwitchOnline) {
      await _openLoginForm(account);
      return;
    }
    setState(() => _busy = true);
    final result = await ref
        .read(sessionServiceProvider)
        .switchAccount(account.userId);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (result) {
      case AccountSwitchResult.switched:
        // 换人了：整棵界面按新账号重建（会话、通讯录都会重新拉）
        context.go(AppRoutes.home);
      case AccountSwitchResult.needsLogin:
        await _openLoginForm(account);
      case AccountSwitchResult.alreadyActive:
        break;
      case AccountSwitchResult.unknown:
        // 列表里刚被删掉的那种（正常点不到），提示一句别让人干等
        noticeBus.toast(i18n.t('user.deleteAccountTip'));
    }
  }

  /// 去登录表单（账号预填）：给「已退出」的那一份用
  Future<void> _openLoginForm(SavedAccount account) async {
    if (!mounted) return;
    context.push(
      '${AppRoutes.accountsAdd}'
      '?account=${Uri.encodeComponent(account.gracelinkId)}',
    );
  }

  /// 「添加账号」底部抽屉：注册新账号 / 登录其他账号
  Future<void> _showAddSheet(AppI18n i18n) async {
    final action = await showAppSheet<String>(
      context: context,
      backgroundColor: AppColors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(context.rpx(36)),
        ),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(height: sheetContext.rpx(16)),
            // 电脑端不许注册账号（用户 2026-10-08）：这一行整个不出现
            if (!ref.read(desktopFeaturesProvider))
              ListTile(
                leading: Icon(
                  Icons.person_add_alt_1_rounded,
                  color: AppColors.wechatGreen,
                  size: sheetContext.rpx(40),
                ),
                title: Text(
                  i18n.t('user.registerNewAccount'),
                  style: TextStyle(
                    fontSize: sheetContext.rpx(32),
                    color: AppColors.text000,
                  ),
                ),
                onTap: () => Navigator.of(sheetContext).pop('register'),
              ),
            ListTile(
              leading: Icon(
                Icons.login_rounded,
                color: AppColors.blue,
                size: sheetContext.rpx(40),
              ),
              title: Text(
                i18n.t('user.loginOtherAccount'),
                style: TextStyle(
                  fontSize: sheetContext.rpx(32),
                  color: AppColors.text000,
                ),
              ),
              onTap: () => Navigator.of(sheetContext).pop('login'),
            ),
            Divider(height: sheetContext.rpx(2), color: AppColors.line),
            ListTile(
              title: Center(
                child: Text(
                  i18n.t('common.cancel'),
                  style: TextStyle(
                    fontSize: sheetContext.rpx(30),
                    color: AppColors.text666,
                  ),
                ),
              ),
              onTap: () => Navigator.of(sheetContext).pop(),
            ),
            SizedBox(height: sheetContext.rpx(16)),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    // 两条都做成**普通路由**（不是 /login 那两条）：已经登录的人去 /login 会被
    // 守卫弹回主界面，而「添加账号」恰恰是已登录状态下再登一个（见 AppRoutes 注释）
    if (action == 'register') {
      context.push(AppRoutes.accountsAddRegister);
    } else {
      context.push(AppRoutes.accountsAdd);
    }
  }

  /// 管理模式里删一个账号。删当前账号 = 退出登录（会真的调服务端登出）。
  Future<void> _delete(SavedAccount account, {required bool current}) async {
    final i18n = ref.read(appI18nProvider);
    final confirmed = await showWeChatConfirm(
      context,
      message: current
          ? i18n.t('user.exitLoginTip')
          : i18n.t('user.deleteAccountTip'),
      confirmLabel: current ? i18n.t('user.exit') : i18n.t('common.ok'),
    );
    if (!confirmed || !mounted) return;

    if (current) {
      await ref.read(sessionServiceProvider).logout();
      // 退出登录：这一份仍然留在列表里（令牌作废），人回登录页
      if (mounted) context.go(AppRoutes.home);
      return;
    }

    await SavedAccountsStore.instance.remove(account.userId);
    if (!mounted) return;
    // 删空了就没有可管理的东西了，顺手退出管理模式
    setState(() {
      if (ref.read(savedAccountsProvider).isEmpty) _managing = false;
    });
  }
}
