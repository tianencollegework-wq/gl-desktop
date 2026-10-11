import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/platform/desktop_shell.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../data/repo/conversation_repository.dart';
import '../mine/app_update_flow.dart';
import '../notify/first_launch_permissions.dart';
import 'desktop_frame.dart';
import 'shell_menu.dart';
import 'shell_tabs.dart';

/// 主外壳，对应老端 `pages/index/index.vue`。
///
/// 两个刻意的还原点：
///
/// 1. 老端把 4 个 tab 页面用 `v-show` 叠在同一个页面里（不是 4 个独立路由），
///    这里用 IndexedStack 保持一致：切 tab 不重建、不丢滚动位置。
/// 2. tab 数量是动态的：消息、通讯录、我的 是固定的，「发现」只在服务端
///    `globalConfig.compass.status == 1` 时才出现。
///
/// ⚠️ 2026-09-27 起「发现」这一格**不再看服务端开关**：那一页是纯客户端写死的
/// （只有「灵听」一条），服务端把 `compass` 关掉也不该把这一格一起藏起来。
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  @override
  void initState() {
    super.initState();
    // 启动时查一次新版本（老端在 `App.vue` 里调 `appUpdate()`，S7.2）。
    // 放主界面而不是登录页：这条接口要拿全局配置里的服务端地址与登录后的网络栈，
    // 而且没登录时弹「有新版本」也没地方可装。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) runStartupUpdateCheck(context, ref);
    });
    // 第一次打开 App：把通知那一项要一遍（用户 2026-09-27 的要求：
    // 「软件下载完第一次打开会自动申请系统的这几个基本权限」）。
    // 与检查更新一样放主界面（没登录时也不会有消息要提醒，而且全局配置是登录后才齐的），
    // 而且**推后一帧**：系统权限框会把 App 顶上后台，不能在首帧还没画出来时就弹。
    //
    // 以前这里是「每个进程问一次」（一个顶级 bool）—— 冷启动一次就问一次，
    // 现在由它自己存一个「问过了」的标记（见 `first_launch_permissions.dart`）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(runFirstLaunchPermissionPrompt(ref));
    });
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    // 「发现」tab 现在**不看服务端配置了**（2026-09-27 用户要求：那一页是纯客户端
    // 写死的，里面只有「灵听」一条）—— 老端那个 `compass.status == 1` 的开关
    // 不再决定这一格在不在。
    final tabs = buildShellTabs(i18n);
    // 选中的分区放 provider 里（不只这个 State）：桌面那条左图标条也要能切分区
    final index = ref.watch(homeTabIndexProvider).clamp(0, tabs.length - 1);
    final current = tabs[index];
    // 消息 tab 的未读角标（老端是消息页内部自己画的，新端放在 tab 上，
    // 这样停在通讯录页也能看到有新消息）
    // 用「可见」口径：被「不显示该聊天」藏起来的会话不该让底部冒红点
    final unread = ref.watch(
      visibleTotalsProvider.select((value) => value.value?.unread ?? 0),
    );

    // 桌面横屏（窗口 ≥ [kDesktopFrameMinWidth]）：交给桌面框架
    // （左图标条 + 栏，见 `desktop_frame.dart`）。四个分区按各自的形状摆：
    // 消息 = 会话列 + 聊天区，通讯录 = 好友列 + 资料，发现 / 我 = 一栏面板。
    // 框架自己读 `homeTabIndexProvider`，所以图标条切分区也走它。
    if (desktopWideLayout(context, ref)) {
      return const DesktopFrame();
    }

    return Scaffold(
      backgroundColor: AppColors.page,
      body: Column(
        children: [
          _buildNavBar(context, current),
          Expanded(
            // 顶部状态栏、底部手势条这两个内边距，**外壳已经各吃了一次**：
            // 上面那条导航栏按 `context.statusBarHeight` 撑高，下面那条 tab 栏
            // 包着 `SafeArea`。所以这里要把它们从 MediaQuery 里去掉 ——
            // Flutter 的 ScrollView 在 `padding == null` 时会自动把
            // `MediaQuery.padding` 当成自己的 padding，页面里的列表于是**又吃一遍**，
            // 症状就是列表第一行上方凭空多出一段状态栏高度的空白
            // （用户 2026-09-26 反馈的就是这个）。
            // 例外：「我」页没有导航栏，它的资料卡自己用 `context.statusBarHeight`
            // 留状态栏那一段，所以那一页不能去。
            child: MediaQuery.removePadding(
              context: context,
              removeTop: current.name != 'mine',
              removeBottom: true,
              child: IndexedStack(
                index: index,
                children: [for (final tab in tabs) shellTabBody(tab)],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: _buildTabBar(
        context,
        tabs,
        index: index,
        unread: unread,
      ),
    );
  }

  /// 顶部自定义导航栏。老端：`PageCur == 'mine' ? 'bg-mine' : 'bg-white'`
  ///
  /// 按微信的摆法：**左边空着，搜索与「＋」都在右边**，标题在屏幕正中
  /// （老端是「搜索在左、＋在右」）。消息页与通讯录页共用这一套。
  Widget _buildNavBar(BuildContext context, ShellTabSpec tab) {
    // 微信的「我」页**没有标题栏** —— 白底资料卡直接顶到状态栏，
    // 所以这一页整条导航栏都不画（老端是一条品牌色顶栏 + 「我的」）。
    if (tab.name == 'mine') return const SizedBox.shrink();

    final isMessage = tab.name == 'message';
    const foreground = AppColors.text333;
    // 老端 `search()`：消息页用 `type=1`、通讯录页用 `type=2`，都进全局搜索
    final searchType = isMessage ? 1 : 2;
    final searchOnRight = tab.showSearch;
    // 微信的消息页与通讯录页顶部栏都是**浅灰**（连状态栏那片也是这个灰），
    // 下面还有一条分割线；发现页是白底
    final greyBar = isMessage || tab.name == 'contacts';

    return Container(
      decoration: BoxDecoration(
        color: greyBar ? AppColors.navBar : AppColors.white,
        border: greyBar
            ? const Border(
                bottom: BorderSide(color: AppColors.navDivider, width: 0.5),
              )
            : null,
      ),
      height: context.statusBarHeight + context.customBarHeight,
      padding: EdgeInsets.only(top: context.statusBarHeight),
      child: Stack(
        children: [
          // 标题永远在屏幕正中：右边挂两个图标也不会把它挤偏
          Align(
            alignment: Alignment.center,
            child: Text(
              tab.label,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: foreground,
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (searchOnRight)
                  _searchButton(context, searchType, foreground),
                if (tab.showAdd)
                  ShellAddMenu(
                    actions: actionsForTab(tab.name),
                    iconColor: foreground,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 导航栏上的搜索图标
  Widget _searchButton(BuildContext context, int searchType, Color foreground) {
    // TODO(M4): 换成老端的 cuIcon-search（等 cuIcon 字体抽出来）
    return IconButton(
      icon: Icon(Icons.search, size: 22, color: foreground),
      onPressed: () =>
          context.push('${AppRoutes.indexSearch}?type=$searchType'),
    );
  }

  Widget _buildTabBar(
    BuildContext context,
    List<ShellTabSpec> tabs, {
    required int index,
    required int unread,
  }) {
    return Container(
      // 微信底部栏：比顶部栏**浅一档**的灰（实测 #F7F7F7 vs #EDEDED）+ 一条上分割线，没有投影
      decoration: const BoxDecoration(
        color: AppColors.tabBar,
        border: Border(
          top: BorderSide(color: AppColors.navDivider, width: 0.5),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: context.rpx(AppDimens.tabBarRpx),
          child: Row(
            children: [
              for (var i = 0; i < tabs.length; i++)
                Expanded(
                  child: _TabButton(
                    tab: tabs[i],
                    active: i == index,
                    // 只给消息 tab 挂角标
                    badge: tabs[i].name == 'message' ? unread : 0,
                    onTap: () =>
                        ref.read(homeTabIndexProvider.notifier).select(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.tab,
    required this.active,
    required this.onTap,
    this.badge = 0,
  });

  final ShellTabSpec tab;
  final bool active;
  final VoidCallback onTap;

  /// 未读数，0 不显示
  final int badge;

  @override
  Widget build(BuildContext context) {
    // 微信：选中是品牌绿 #07C160，未选中是同一档灰（图标和文字一个颜色）
    final color = active ? AppColors.wechatGreen : AppColors.tabInactive;
    final iconSize = context.rpx(52);

    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              SvgPicture.asset(
                active ? tab.activeIconAsset : tab.iconAsset,
                width: iconSize,
                height: iconSize,
                // 图标自己带死颜色（老端那套蓝/灰），这里统一染成 tab 的颜色
                colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
              ),
              if (badge > 0)
                Positioned(
                  top: -5,
                  right: -10,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 18),
                    height: 18,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    decoration: BoxDecoration(
                      color: AppColors.unreadRed,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      badge > 99 ? '99+' : '$badge',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.white,
                        height: 1.1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          // 文字**只给一行**：`Flexible` 把剩下的高度让给它，`softWrap: false`
          // 再加 `ellipsis` 保证再长的名字也不会把这一格撑破 ——
          // 以前是裸 `Text`，英文界面下 `Gracelink` 这种名字会折成两行，
          // 而 tab 栏高度是死的（`rpx(100)`），于是底部冒黄黑条（溢出 9px）。
          // 中文两个字的标签同理受益（换成更长的语言包也不会崩版）。
          Flexible(
            child: Text(
              tab.bottomLabel,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: color),
            ),
          ),
        ],
      ),
    );
  }
}
