import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/theme/app_colors.dart';
import '../../data/model/conversation.dart';
import '../compass/compass_page.dart';
import '../contacts/contacts_page.dart';
import '../conversations/conversation_list_page.dart';
import '../mine/mine_page.dart';

/// 当前选中的分区（消息 / 通讯录 / 发现 / 我）。
///
/// 原来这个下标是 `_HomeShellState` 的私有字段。2026-10-03 挪成 provider：
/// 桌面横屏那条左图标条**也要能切分区**（而不是只由底部 tab 栏切），
/// 两处各存一份下标就会各切各的。
class HomeTabIndex extends Notifier<int> {
  @override
  int build() => 0;

  void select(int index) => state = index;
}

final homeTabIndexProvider = NotifierProvider<HomeTabIndex, int>(
  HomeTabIndex.new,
);

/// 单个分区的定义。
///
/// 这个名字（message / contacts / compass / mine）同时决定图标文件名，
/// 与老端 tab 名保持一致。
class ShellTabSpec {
  const ShellTabSpec({
    required this.name,
    required this.label,
    required this.legacyPath,
    this.tabLabel,
    this.showSearch = false,
    this.showAdd = false,
  });

  /// 顶部导航栏的标题
  final String label;

  /// 底部栏 / 桌面图标条的文字（不给就用 [label]）——微信顶部写「我的」、
  /// 底部写「我」这种差异靠它
  final String? tabLabel;

  final String name;
  final String legacyPath;
  final bool showSearch;
  final bool showAdd;

  String get bottomLabel => tabLabel ?? label;

  String get iconAsset => 'assets/icons/navbar/$name.svg';
  String get activeIconAsset => 'assets/icons/navbar/$name-active.svg';
}

/// 主界面的四个分区。顺序 = 老端底部 tab 的顺序。
List<ShellTabSpec> buildShellTabs(AppI18n i18n) {
  return <ShellTabSpec>[
    ShellTabSpec(
      name: 'message',
      // 微信顶部与底部第一个 tab 都是应用名（「微信」/「WeChat」）。
      // 这里取 `user.appName`：中文「恩信」、英文「Gracelink」。
      label: i18n.t('user.appName'),
      legacyPath: 'pages/message/index',
      showSearch: true,
      showAdd: true,
    ),
    ShellTabSpec(
      name: 'contacts',
      label: i18n.t('user.contacts'),
      legacyPath: 'pages/contacts/index',
      // 微信通讯录顶部右边也是「放大镜 + ＋」两颗
      showSearch: true,
      showAdd: true,
    ),
    ShellTabSpec(
      name: 'compass',
      // 微信第三个 tab 叫「发现」（老端叫「探索」，用户要求跟微信一致）
      label: i18n.t('user.compass'),
      legacyPath: 'pages/compass/index',
    ),
    ShellTabSpec(
      name: 'mine',
      // 顶部标题仍是「我的」，但底部 tab 按微信写单个「我」字
      label: i18n.t('user.mine'),
      tabLabel: i18n.t('user.mineTab'),
      legacyPath: 'pages/mine/index',
    ),
  ];
}

/// 分区正文。消息（S4.1）与通讯录（S5.1）已是真页面，发现 / 我的 仍是占位。
///
/// [onOpenChat] 只在桌面横屏那一栏里传：那边点会话是「选中到右栏」，
/// 不是 push 一个新页面（见 `desktop_frame.dart`）。
Widget shellTabBody(
  ShellTabSpec tab, {
  void Function(Conversation)? onOpenChat,
}) {
  if (tab.name == 'message') {
    return ConversationListPage(onOpenChat: onOpenChat);
  }
  if (tab.name == 'contacts') {
    return const ContactsPage();
  }
  if (tab.name == 'mine') {
    return const MinePage();
  }
  if (tab.name == 'compass') {
    return const CompassPage();
  }
  return Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(
          Icons.construction_outlined,
          size: 40,
          color: AppColors.text999,
        ),
        const SizedBox(height: 12),
        Text(
          '${tab.label}（待实现）',
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppColors.text333,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '对应老端：${tab.legacyPath}',
          style: const TextStyle(fontSize: 12, color: AppColors.text666),
        ),
      ],
    ),
  );
}
