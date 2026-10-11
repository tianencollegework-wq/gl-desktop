import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/platform/desktop_shell.dart';
import '../../core/router/app_router.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/hover_highlight.dart';
import '../../data/model/contact.dart';
import '../../data/repo/conversation_repository.dart';
import '../chat/chat_page.dart';
import '../contacts/contacts_page.dart';
import '../conversations/conversation_list_page.dart';
import '../contacts/user_detail_page.dart';
import '../contacts/widgets/contact_avatar.dart';
import 'shell_menu.dart';
import 'shell_tabs.dart';

/// 桌面**横屏**外壳：左图标条 + 右边那些栏。
///
/// 2026-10-03 用户给的形态（对着微信 PC 端截图）：「电脑是横屏手机是竖屏」——
/// 手机那套「顶部标题栏 + 底部 tab 栏 + 一屏一页」在 1200 宽的窗口里既浪费宽度、
/// 也不像电脑软件。这一层只做**框架**（谁在哪儿、各占多宽），栏里的内容全部
/// 复用手机那套页面。四个分区**按各自的形状**摆（不是一律「页面整块塞进去」）：
///
/// ```text
/// 消息    ┌──┬──────────┬──────────────────────┐
///         │图│ 搜索   ＋ │ 标题栏             ⋯ │
///         │标│──────────│                      │
///         │条│ 会话行   │      聊天区           │
///         ├──┼──────────┼──────────────────────┤
/// 通讯录  │图│ 搜索   ＋ │ 好友资料              │
///         │标│──────────│（点左边一行就换到右边）│
///         │条│ 好友行   │                      │
///         ├──┼──────────┴──────────────────────┤
/// 发现/我 │图│ 那一页（定宽 500）        │ 灰底 │
///         └──┴───────────────────────────┴──────┘
/// ```
///
/// * 「发现」「我」是一栏就够的形状（只有两行入口 / 一张资料卡 + 几行设置），
///   硬拆成「列表 + 详情」是摆样子：桌面上把它们摆成**一栏定宽面板**，
///   与二级页（设置、资料…见 [DesktopPageFrame]）同一个形状。
///
/// 三个刻意的选择：
///
/// 1. **宽度靠列数解决，不靠放大**：栏里仍按手机那份尺寸来（头像 40dp、
///    字号 16/14），不会因为窗口 1200 宽就把字放大到 24。做法是把子树看到的
///    `MediaQuery` 宽度**钉在** [contentBaseWidth]（`rpx` 就是按它算的），
///    实际占地由 Row 里的固定宽度给。
/// 2. **点会话 / 点好友 = 选中到右栏，不 push 新页面**（[ConversationListPage.onOpenChat]、
///    [ContactsPage.onOpenContact]）；从搜索、通知那条路进聊天页的仍然是普通路由，
///    那种情况下 [ChatScreen] 会把同一个框架套起来，所以看上去还是三栏。
/// 3. 图标条底部那颗「≡」是**设置**入口（微信 PC 那儿的「设置 / 退出」），
///    不新造页面。
///
/// **二级页（[DesktopPageFrame]）是这同一个框架 + [pane]** —— 2026-10-04 用户
/// 指出的问题：「为什么有些页面都一直在左半部分显示，右边一直空着？比如通讯录
/// 主页面在左半部分，点击新的朋友之后是不是可以把新的朋友页面显示在右半部分呢？」
/// 所以二级页不再摆成「图标条 + 一栏面板 + 右边留灰」，而是**把中栏那些入口留着、
/// 内容摆进右栏**（消息区也是：二级页把聊天区整块换掉，见 [_messageBody]）——
/// 桌面上「左边是列表、右边是详情」这条规矩贯通所有页面。
class DesktopFrame extends ConsumerStatefulWidget {
  const DesktopFrame({
    super.key,
    this.selectedConversationId,
    this.pane,
    this.section,
    this.paneId,
    this.railGoesHome = false,
  });

  /// 从路由（`/message/chat?id=`）进来时先选中的会话
  final String? selectedConversationId;

  /// 右栏要显示的**二级页**（null = 这个分区的默认内容：聊天区 / 好友资料 /
  /// 空态 / 留灰）。二级页恒为「白底 + 一条左细线」，里面按 [panelWidth] 那一档
  /// 的基准排版（见 [_Pane]）。
  final Widget? pane;

  /// 强制用哪个分区的形状（二级页用：设置页走「我」那一栏、新的朋友走通讯录
  /// 那一栏）。null = 按当前选中的 tab（主界面就是这种）。
  final String? section;

  /// 中栏里该点亮哪一行：会话 id / 好友 id / 入口名（`newFriends`、`groups`）。
  /// 只影响底色，不影响任何行为。
  final String? paneId;

  /// 点图标条时回不回主界面。主界面自己那份是 false（只切分区）；
  /// 二级页与聊天页（[ChatScreen]）是 true —— 它们不在主界面上，不回去就会
  /// 「切了个看不见的分区」。
  final bool railGoesHome;

  /// 图标条宽（微信 PC 约 60）
  static const double railWidth = 60;

  /// 中栏宽（会话列 / 好友列；微信 PC 约 300）
  static const double listWidth = 300;

  /// 三栏内部按**手机屏宽**排版用的基准宽度：`rpx` 是 `屏宽 / 750`，
  /// 钉在 420 之后，栏里的字号、头像、行高仍是手机上那一档 —— 电脑上得到的是
  /// 「更多内容」，不是「更大的字」。
  static const double contentBaseWidth = 420;

  /// 单栏面板的宽度（「发现」「我」这两个分区）。
  /// 与 [DesktopShell.maxWidth] 同值：那一档本来就是按手机屏宽排的。
  static const double panelWidth = DesktopShell.maxWidth;

  @override
  ConsumerState<DesktopFrame> createState() => _DesktopFrameState();
}

class _DesktopFrameState extends ConsumerState<DesktopFrame> {
  /// 右栏正在看的会话 / 好友。
  ///
  /// 两个分区各自记一份（切去通讯录再切回来，刚才那个会话还在右边）——
  /// 与手机上「切 tab 不重建」那条一致（`IndexedStack`）。
  String? _selectedConversation;
  String? _selectedContact;

  @override
  void initState() {
    super.initState();
    _selectedConversation = widget.selectedConversationId;
  }

  @override
  void didUpdateWidget(covariant DesktopFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    final id = widget.selectedConversationId;
    if (id != null && id != oldWidget.selectedConversationId) {
      _selectedConversation = id;
    }
  }

  void _selectConversation(String id) {
    if (_selectedConversation == id) return;
    setState(() => _selectedConversation = id);
  }

  void _selectContact(Contact contact) {
    if (_selectedContact == contact.id) return;
    setState(() => _selectedContact = contact.id);
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final tabs = buildShellTabs(i18n);
    final forced = widget.section == null
        ? -1
        : tabs.indexWhere((tab) => tab.name == widget.section);
    final index = forced >= 0
        ? forced
        : ref.watch(homeTabIndexProvider).clamp(0, tabs.length - 1);
    final current = tabs[index];

    // 图标条与各栏都要 `rpx`，所以整块先按手机基准钉一次宽度
    // （面板那一栏会再钉一次，见 [DesktopPanel]）。高度保持真实值。
    return DesktopFrameScope(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          size: Size(
            DesktopFrame.contentBaseWidth,
            MediaQuery.sizeOf(context).height,
          ),
        ),
        // `Material` 不能省：栏里的图标、搜索框、会话行全是 `InkWell` /
        // `IconButton`，它们都要一个 Material 祖先才肯画（手机那套是在 Scaffold
        // 里的，框架没有 Scaffold，少了这一层会在构建期直接抛
        // 「No Material widget found」——表现是整个中栏消失，而不是报在脸上）。
        child: Material(
          color: AppColors.white,
          child: Row(
            children: <Widget>[
              _Rail(
                tabs: tabs,
                current: index,
                onSelect: (next) {
                  ref.read(homeTabIndexProvider.notifier).select(next);
                  // 从聊天路由（`/message/chat`）与二级页进来的那两份框架不在主界面上：
                  // 图标条一按就应该回到主界面，否则会切了个看不见的分区。
                  if (widget.railGoesHome ||
                      widget.selectedConversationId != null) {
                    context.go(AppRoutes.home);
                  }
                },
              ),
              const VerticalDivider(
                width: 0.5,
                thickness: 0.5,
                color: AppColors.navDivider,
              ),
              Expanded(child: _body(context, i18n, current)),
            ],
          ),
        ),
      ),
    );
  }

  /// 分区正文：每个分区按自己的形状摆（见 [DesktopFrame] 顶部那张图）
  Widget _body(BuildContext context, AppI18n i18n, ShellTabSpec current) {
    switch (current.name) {
      case 'message':
        return _messageBody(context, i18n);
      case 'contacts':
        return _contactsBody();
      default:
        // 发现 / 我：一栏定宽面板（+ 二级页在右栏）
        return _panelBody(current);
    }
  }

  /// 消息：会话列 + 聊天区（二级页时右栏就是那一页，见方法末尾的注释）
  Widget _messageBody(BuildContext context, AppI18n i18n) {
    final pane = widget.pane;
    final selected = widget.pane != null
        ? widget.paneId
        : _selectedConversation;

    return Row(
      children: <Widget>[
        SizedBox(
          width: DesktopFrame.listWidth,
          child: _ConversationColumn(
            selectedId: selected,
            // 二级页里点会话 = 照手机推一页（那一页自己会带三栏 + 这个会话）；
            // 主界面里点会话 = 选中到右栏
            onSelect: pane == null ? _selectConversation : null,
          ),
        ),
        const VerticalDivider(
          width: 0.5,
          thickness: 0.5,
          color: AppColors.navDivider,
        ),
        // 二级页一律**铺满右栏**。
        //
        // 2026-10-04 之前，属于某个会话的二级页（会话信息 / 聊天记录 / 群公告…）
        // 是在聊天区右边**再接一栏**（420 宽）。1200 的窗口下那是四层：
        // 会话列 300 + 聊天 + 面板 300 + 详情 420 —— 聊天区只剩 120 宽，
        // 用户截图报「一层套一层干什么啊」。现在二级页把聊天区整块换掉，
        // 形状与其它分区的二级页一致：图标条 + 中栏 + 这一页。
        if (pane == null)
          Expanded(child: _chatPane(i18n))
        else
          Expanded(child: _Pane(child: pane)),
      ],
    );
  }

  /// 通讯录：好友列 + 好友资料（微信 PC 点左边一行，右边就是那个人的资料）
  ///
  /// 二级页（新的朋友 / 群聊列表 / 用户详情…）走同一个右栏：中栏还是那份通讯录，
  /// 右边换成那一页 —— 用户 2026-10-04 要的就是这个。
  Widget _contactsBody() {
    final pane = widget.pane;
    return Row(
      children: <Widget>[
        SizedBox(
          width: DesktopFrame.listWidth,
          child: _ContactsColumn(
            selectedId: pane == null ? _selectedContact : null,
            onSelect: pane == null ? _selectContact : null,
            selectedEntry: pane == null ? null : widget.paneId,
          ),
        ),
        const VerticalDivider(
          width: 0.5,
          thickness: 0.5,
          color: AppColors.navDivider,
        ),
        Expanded(
          child: pane == null
              ? _ContactsPane(
                  userId: _selectedContact,
                  onDeleted: () => setState(() => _selectedContact = null),
                )
              : _Pane(child: pane),
        ),
      ],
    );
  }

  /// 发现 / 我：那一页整块摆进一栏定宽面板（不是「列表 + 详情」的形状，
  /// 拆栏是摆样子）；二级页（设置、账号与安全、灵听…）进右栏，不再留灰
  Widget _panelBody(ShellTabSpec current) {
    final pane = widget.pane;
    return Row(
      children: <Widget>[
        DesktopPanel(child: shellTabBody(current)),
        Expanded(
          child: pane == null
              // 注意用 `Container` 而不是 `ColoredBox`：**没有 child 的 ColoredBox
              // 只占 `constraints.smallest`**，而 Row 里交叉轴是松约束（高度 0..∞）——
              // 于是它是 0 高、什么都不画，右边就是一片白（2026-10-03 实机上就是这么
              // 翻车的，widget 用例只看 left/right 也照样绿）。`Container` 无 child 时
              // 会自己撑满有界的那一维。
              ? Container(color: AppColors.page)
              : _Pane(child: pane),
        ),
      ],
    );
  }

  Widget _chatPane(AppI18n i18n) {
    final id = _selectedConversation;
    if (id == null) {
      return _EmptyPane(
        icon: Icons.chat_bubble_outline,
        text: i18n.t('desktop.pickChat'),
      );
    }
    // 会话被删掉（或换了账号）之后，选中的 id 可能已经不存在：
    // 聊天页自己会画「找不到这个联系人」，这里不做额外判断。
    return ChatPage(conversationId: id, embedded: true);
  }
}

/// 桌面上的**一栏定宽面板**：宽 [DesktopFrame.panelWidth]，里面按手机基准
/// （500 宽）排版 —— 「发现」「我」两个分区、以及所有二级页（[DesktopPageFrame]）
/// 共用这个形状。
///
/// 右边那条细线是给「面板 + 灰底」这道分界用的：没有它就只剩底色差，
/// 宽窗口里看着像内容没对齐。
class DesktopPanel extends StatelessWidget {
  const DesktopPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: DesktopFrame.panelWidth,
    child: MediaQuery(
      data: MediaQuery.of(context).copyWith(
        size: Size(DesktopFrame.panelWidth, MediaQuery.sizeOf(context).height),
      ),
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(
            right: BorderSide(color: AppColors.navDivider, width: 0.5),
          ),
        ),
        child: child,
      ),
    ),
  );
}

/// 二级页（设置 / 资料 / 聊天记录 / 新的朋友…）在宽屏桌面上的外壳：
/// **还是 [DesktopFrame] 那个框架，只是内容摆进右栏**。
///
/// 为什么这么改（2026-10-04 用户）：「为什么有些页面都一直在左半部分显示，右边一直
/// 空着？比如通讯录主页面在左半部分，点击新的朋友之后是不是可以把新的朋友页面显示
/// 在右半部分呢？」—— 旧实现是「图标条 + 一栏面板 + 右侧留灰」，右边那块灰确实白瞎了
/// 半个窗口；现在中栏（会话列 / 好友列 / 发现·我那一栏）照旧在，二级页铺在右栏，
/// 消息分区里还会把聊天留在中间、这一页当右侧栏（见 [_messageBody]）。
///
/// 窄窗 / 手机直接返回 [child]，这条路径一个字节都不改。
class DesktopPageFrame extends ConsumerWidget {
  const DesktopPageFrame({
    super.key,
    required this.child,
    this.section,
    this.paneId,
    this.conversationId,
  });

  final Widget child;

  /// 这一页是从哪个分区点进来的（图标条点亮哪一格、中栏摆成那一栏）。
  ///
  /// 给的是分区的 name（`message` / `contacts` / `compass` / `mine`）或 null
  /// （不属于任何分区，比如设置里的子页）。
  final String? section;

  /// 中栏里该点亮哪一行：会话 id / 好友 id / 入口名（`newFriends`、`groups`）。
  final String? paneId;

  /// 这一页属于哪个会话（消息分区那几个二级页用）：给了它，聊天区会留在中栏、
  /// 这一页在右边当侧栏；不给就整块铺满右栏。
  final String? conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!desktopWideLayout(context, ref)) return child;

    return DesktopFrame(
      section: section,
      pane: child,
      paneId: paneId,
      selectedConversationId: conversationId,
      railGoesHome: true,
    );
  }
}

/// 右栏里的一块二级页：白底 + 左边一条细线 + 按面板那一档（500）的基准排版。
///
/// 钉 MediaQuery 是整套桌面版式的同一招：页面全是按手机屏宽写的（`rpx` = 屏宽/750），
/// 把它钉在 500 之后，字号/行高仍是手机那一档 —— 电脑上多出来的是**宽度**，
/// 不是更大的字（见 [DesktopFrame] 的注释 1）。
class _Pane extends StatelessWidget {
  const _Pane({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      size: Size(DesktopFrame.panelWidth, MediaQuery.sizeOf(context).height),
    ),
    child: DecoratedBox(
      // 用例靠这个 key 量右栏那块矩形（见 `test/features/desktop_windows_test.dart`）
      key: const ValueKey<String>('desktopPane'),
      decoration: const BoxDecoration(
        color: AppColors.white,
        border: Border(
          left: BorderSide(color: AppColors.navDivider, width: 0.5),
        ),
      ),
      child: child,
    ),
  );
}

/// 左图标条（微信 PC 最左边那一条）。
///
/// 从上到下：头像 → 四个分区 → 「≡」设置。
/// 选中那颗染品牌绿（与手机底部 tab 同一套判据），未选中的是同一档灰。
class _Rail extends ConsumerWidget {
  const _Rail({
    required this.tabs,
    required this.current,
    required this.onSelect,
  });

  final List<ShellTabSpec> tabs;
  final int current;
  final void Function(int index) onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(sessionStoreProvider.select((state) => state.user));
    final circleAvatar = ref.watch(
      sessionStoreProvider.select((state) => state.setting.circleAvatar),
    );
    final unread = ref.watch(
      visibleTotalsProvider.select((value) => value.value?.unread ?? 0),
    );

    return Container(
      width: DesktopFrame.railWidth,
      color: AppColors.navBar,
      child: Column(
        children: <Widget>[
          const SizedBox(height: 14),
          // 头像：点进「我的」资料页（微信 PC 点左上角头像就是这个）
          HoverHighlight(
            borderRadius: BorderRadius.circular(context.rpx(12)),
            child: InkWell(
              onTap: () => context.push(AppRoutes.mineProfile),
              customBorder: const CircleBorder(),
              child: ContactAvatar(
                url: user?.avatar ?? '',
                circle: circleAvatar,
                sizeRpx: 64,
              ),
            ),
          ),
          const SizedBox(height: 18),
          for (var i = 0; i < tabs.length; i++)
            _RailItem(
              tab: tabs[i],
              active: i == current,
              badge: tabs[i].name == 'message' ? unread : 0,
              onTap: () => onSelect(i),
            ),
          const Spacer(),
          // 「≡」：微信 PC 那里是「设置 / 退出」这类入口。我们只留设置，
          // 退出登录本来就在「我的 → 设置」里，不在这儿重复一遍
          _RailIcon(
            icon: Icons.menu,
            label: ref.watch(appI18nProvider).t('user.setting'),
            onTap: () => context.push(AppRoutes.mineSetting),
          ),
          const SizedBox(height: 14),
        ],
      ),
    );
  }
}

/// 图标条上的一格
class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.tab,
    required this.active,
    required this.onTap,
    this.badge = 0,
  });

  final ShellTabSpec tab;
  final bool active;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.wechatGreen : AppColors.tabInactive;
    final size = context.rpx(52);

    return HoverHighlight(
      borderRadius: BorderRadius.circular(context.rpx(14)),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.rpx(14),
            vertical: context.rpx(18),
          ),
          child: Tooltip(
            message: tab.bottomLabel,
            waitDuration: const Duration(milliseconds: 500),
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                SvgPicture.asset(
                  active ? tab.activeIconAsset : tab.iconAsset,
                  width: size,
                  height: size,
                  // 图标自己带死颜色（老端那套蓝/灰），这里统一染成这一格的颜色
                  colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
                ),
                if (badge > 0)
                  Positioned(
                    top: -6,
                    right: -8,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 16),
                      height: 16,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        color: AppColors.unreadRed,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        badge > 99 ? '99+' : '$badge',
                        style: const TextStyle(
                          fontSize: 10,
                          color: AppColors.white,
                          height: 1.1,
                        ),
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
}

/// 图标条底部那颗没有角标的图标（「≡」）
class _RailIcon extends StatelessWidget {
  const _RailIcon({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => HoverHighlight(
    borderRadius: BorderRadius.circular(context.rpx(14)),
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.all(context.rpx(18)),
        child: Tooltip(
          message: label,
          waitDuration: const Duration(milliseconds: 500),
          child: Icon(
            icon,
            size: context.rpx(44),
            color: AppColors.tabInactive,
          ),
        ),
      ),
    ),
  );
}

/// 中栏顶上那一行：**搜索框 + 「＋」**（微信 PC 就是这两样）。
///
/// 消息页与通讯录页共用，只是搜索的类型不同（老端 `type=1` / `type=2`）
/// 与「＋」里那几项不同（见 [actionsForTab]）。
class _ListColumnHeader extends ConsumerWidget {
  const _ListColumnHeader({required this.searchType, required this.actions});

  final int searchType;
  final List<ShellAddAction> actions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);

    return Container(
      height: context.rpx(96),
      padding: EdgeInsets.symmetric(horizontal: context.rpx(20)),
      color: AppColors.navBar,
      child: Row(
        children: <Widget>[
          Expanded(
            child: HoverHighlight(
              borderRadius: BorderRadius.circular(context.rpx(10)),
              child: InkWell(
                // 走的是手机那颗放大镜同一条路（`/index/search?type=`）
                onTap: () =>
                    context.push('${AppRoutes.indexSearch}?type=$searchType'),
                child: Container(
                  height: context.rpx(60),
                  padding: EdgeInsets.symmetric(horizontal: context.rpx(16)),
                  decoration: BoxDecoration(
                    color: AppColors.white,
                    borderRadius: BorderRadius.circular(context.rpx(10)),
                    border: Border.all(color: AppColors.fieldBorder),
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        Icons.search,
                        size: context.rpx(32),
                        color: AppColors.text999,
                      ),
                      SizedBox(width: context.rpx(10)),
                      Text(
                        i18n.t('common.search'),
                        style: TextStyle(
                          fontSize: context.rpx(26),
                          color: AppColors.text999,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SizedBox(width: context.rpx(12)),
          ShellAddMenu(
            actions: actions,
            iconColor: AppColors.text333,
            iconSize: context.rpx(46),
          ),
        ],
      ),
    );
  }
}

/// 中栏：搜索框 + ＋ + 会话列表。
///
/// 下面直接就是手机那套会话列表（[ConversationListPage]），因此置顶、未读、
/// 长按菜单、群语音标记全都照旧。
class _ConversationColumn extends StatelessWidget {
  const _ConversationColumn({required this.selectedId, required this.onSelect});

  final String? selectedId;

  /// 点一行时干什么。**不传 = 手机那套**：push 聊天页（二级页里就是这条）。
  final void Function(String id)? onSelect;

  @override
  Widget build(BuildContext context) {
    final onSelect = this.onSelect;
    return Column(
      children: <Widget>[
        const _ListColumnHeader(searchType: 1, actions: messageAddActions),
        Expanded(
          child: ConversationListPage(
            onOpenChat: onSelect == null
                ? null
                : (conversation) => onSelect(conversation.id),
            selectedId: selectedId,
          ),
        ),
      ],
    );
  }
}

/// 通讯录中栏：搜索框 + ＋ + 好友列表（手机那一页，点行改成「选中到右栏」）
class _ContactsColumn extends StatelessWidget {
  const _ContactsColumn({
    required this.selectedId,
    required this.onSelect,
    this.selectedEntry,
  });

  final String? selectedId;

  /// 点一行时干什么。**不传 = 手机那套**：push 用户详情（二级页里就是这条）。
  final void Function(Contact contact)? onSelect;

  /// 二级页（新的朋友 / 群聊）点亮哪一行入口
  final String? selectedEntry;

  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      const _ListColumnHeader(searchType: 2, actions: contactsAddActions),
      Expanded(
        child: ContactsPage(
          onOpenContact: onSelect,
          selectedId: selectedId,
          selectedEntry: selectedEntry,
        ),
      ),
    ],
  );
}

/// 通讯录右栏：选中好友的资料。
///
/// 复用整页那一份 [UserDetailPage]，只是不带自己的顶栏（`embedded: true`）——
/// 资料卡、群内管理、底部那几栏动作与手机上完全同一套，不另写一份。
class _ContactsPane extends ConsumerWidget {
  const _ContactsPane({required this.userId, required this.onDeleted});

  final String? userId;

  /// 在右栏里把好友删掉之后干什么：把选中清掉（没有页面可 pop）
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = userId;
    if (id == null || id.isEmpty) {
      return _EmptyPane(
        icon: Icons.person_outline,
        text: ref.watch(appI18nProvider).t('desktop.pickContact'),
      );
    }
    return UserDetailPage(userId: id, embedded: true, onDeleted: onDeleted);
  }
}

/// 右栏还没选东西时的样子（微信 PC 那边就是一片空的白 / 灰）
class _EmptyPane extends StatelessWidget {
  const _EmptyPane({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: AppColors.page,
    child: Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: context.rpx(90), color: AppColors.text999),
          SizedBox(height: context.rpx(20)),
          Text(
            text,
            style: TextStyle(
              fontSize: context.rpx(28),
              color: AppColors.text999,
            ),
          ),
        ],
      ),
    ),
  );
}

/// 聊天页的**路由入口**：宽屏桌面把它套进三栏框架（右栏就是这个会话），
/// 其余形态（手机 / 窄窗）就是聊天页本身。
///
/// 这一层真身是个无状态包装：真正的聊天页状态只在框架右栏里创建一次，
/// 不会出现「外面那份也在跑 initState」的双份副作用。
///
/// ⚠️ **分区必须钉成 `message`**（2026-10-08 用户报「在好友资料里点『发消息』
/// 返回上一层」）：不钉的话框架会按**当前选中的 tab** 摆 —— 从通讯录点进来的
/// 时候那个 tab 还是通讯录，于是框架照旧画「好友列 + 资料」，聊天根本没出现，
/// 看着就像退了一页（资料没了、聊天也没来）。二级页（[DesktopPageFrame]）
/// 一直是这样钉的，聊天页从前漏了。
class ChatScreen extends ConsumerWidget {
  const ChatScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (desktopWideLayout(context, ref)) {
      return DesktopFrame(
        section: 'message',
        selectedConversationId: conversationId,
        railGoesHome: true,
      );
    }
    return ChatPage(conversationId: conversationId);
  }
}
