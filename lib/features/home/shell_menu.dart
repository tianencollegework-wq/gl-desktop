import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/platform/desktop_shell.dart';
import '../../core/router/app_router.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../data/model/global_config.dart';
import '../../data/repo/conversation_repository.dart';

/// 主界面右上角那个「＋」菜单里的四项（老端 `pages/index/index.vue` 的 `add-modal`）。
///
/// 2026-10-03 从 `home_shell.dart` 里挪出来：桌面横屏的会话列顶上也要摆同一颗「＋」
/// （微信 PC 就是「搜索框 + ＋」），两处各写一份菜单迟早会漂。
enum ShellAddAction {
  refresh(icon: Icons.refresh, labelKey: 'user.updateMsg'),
  addFriend(icon: Icons.person_add_alt, labelKey: 'user.addFriend'),
  createGroup(icon: Icons.group_add_outlined, labelKey: 'user.createGroup'),
  scan(icon: Icons.qr_code_scanner, labelKey: 'user.scan');

  const ShellAddAction({required this.icon, required this.labelKey});

  final IconData icon;
  final String labelKey;

  /// 老端那两处 `v-if`：`sysInfo.runMode == 2` 才有「添加朋友」、
  /// `chatInfo.groupChat == 1` 才有「创建群聊」
  bool isVisible(GlobalConfig config) => switch (this) {
    ShellAddAction.addFriend => config.sysInfo.runMode == 2,
    ShellAddAction.createGroup => config.chatInfo.groupChat == 1,
    _ => true,
  };
}

/// 消息页「＋」菜单里的四项
const List<ShellAddAction> messageAddActions = <ShellAddAction>[
  ShellAddAction.refresh,
  ShellAddAction.addFriend,
  ShellAddAction.createGroup,
  ShellAddAction.scan,
];

/// 通讯录页「＋」菜单。微信通讯录那颗「＋」里是「发起群聊 / 添加朋友 /
/// 扫一扫 / 收付款」——收付款我们没有，剩下的三项照微信的顺序摆。
const List<ShellAddAction> contactsAddActions = <ShellAddAction>[
  ShellAddAction.createGroup,
  ShellAddAction.addFriend,
  ShellAddAction.scan,
];

/// 每个分区那颗「＋」里摆哪几项。
///
/// 手机上按分区（消息 / 通讯录各一套），桌面会话列顶上那颗用的是消息那套。
List<ShellAddAction> actionsForTab(String tabName) =>
    tabName == 'contacts' ? contactsAddActions : messageAddActions;

/// 导航栏上那颗「＋」。
///
/// 长相按微信来：**深色半透明小卡片**（长按会话那个菜单才是白底，两者不一样）。
/// 颜色和形状都在这里写死，不靠主题 —— 主题里的 `popupMenuTheme` 是给白底菜单用的。
class ShellAddMenu extends ConsumerWidget {
  const ShellAddMenu({
    super.key,
    required this.actions,
    this.iconColor = AppColors.text333,
    this.iconSize = 24,
    this.tooltip = '',
  });

  final List<ShellAddAction> actions;
  final Color iconColor;
  final double iconSize;
  final String tooltip;

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    ShellAddAction action,
  ) async {
    switch (action) {
      case ShellAddAction.refresh:
        // 老端 `initContacts()`：重新拉一次会话列表
        await ref.read(conversationRepositoryProvider).syncFromServer();
      case ShellAddAction.addFriend:
        if (context.mounted) context.push(AppRoutes.contactSearch);
      case ShellAddAction.createGroup:
        // 用户选择器是 M7 的（S5.4 只把入口接上）
        if (context.mounted) {
          context.push('${AppRoutes.userSelection}?type=1');
        }
      case ShellAddAction.scan:
        // 电脑端没有这一项（菜单里也不摆，见 build 里那句过滤）。这里再挡一道：
        // 万一哪天又从别处调进来，也不会落到一个「只能用鼠标去翻相册」的页面上。
        if (ref.read(desktopFeaturesProvider)) return;
        if (context.mounted) context.push(AppRoutes.scan);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);
    final config = ref.watch(
      sessionStoreProvider.select((state) => state.config),
    );
    // 电脑端不摆「扫一扫」（用户 2026-10-08：「扫一扫在电脑端没用，直接删了」）。
    // 桌面上没有相机可取景，只剩「选一张图找二维码」那条路 —— 多此一举，
    // 而手机端一切照旧。
    final desktop = ref.watch(desktopFeaturesProvider);

    // TODO(M4): 换成老端的 cuIcon-add
    return PopupMenuButton<ShellAddAction>(
      tooltip: tooltip,
      icon: Icon(Icons.add_circle_outline, size: iconSize, color: iconColor),
      color: AppColors.menuDark,
      elevation: 8,
      position: PopupMenuPosition.under,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(context.rpx(12)),
      ),
      onSelected: (action) => unawaited(_run(context, ref, action)),
      itemBuilder: (menuContext) => <PopupMenuEntry<ShellAddAction>>[
        for (final action in actions)
          if (action.isVisible(config) &&
              !(desktop && action == ShellAddAction.scan))
            PopupMenuItem<ShellAddAction>(
              value: action,
              // 微信那个卡片比 Material 默认窄、行也没那么高
              height: context.rpx(96),
              child: SizedBox(
                width: context.rpx(330),
                child: Row(
                  children: <Widget>[
                    Icon(action.icon, size: 20, color: AppColors.white),
                    const SizedBox(width: 14),
                    Text(
                      i18n.t(action.labelKey),
                      style: const TextStyle(
                        fontSize: 15,
                        color: AppColors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}
