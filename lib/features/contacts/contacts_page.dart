import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/router/app_router.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../data/model/contact.dart';
import '../../data/repo/contact_repository.dart';
import '../../domain/contacts/contact_index.dart';
import 'widgets/contact_avatar.dart';
import 'widgets/contact_index_bar.dart';

/// 通讯录 tab，对应老端 `pages/contacts/index.vue`。
///
/// 结构照老端：顶部几块入口（「新的朋友」、群聊、系统通知会话）、
/// 好友按拼音首字母分组、右侧字母索引条、底部「N 位朋友」。
///
/// **长相照微信**（这一版重排过）：入口是彩色圆角方块 + 白字形，行与行之间那条
/// 细线**从文字左边才开始**（不是通栏），分组字母是浅灰整条。下面这些数是从
/// 微信截图（1080×2316，3x）里量出来的，不是「差不多」估的：
///
/// | 元素 | 微信实测 | 这里 |
/// |---|---|---|
/// | 行高 | 150px = 50dp | `AppDimens.listRowRpx` |
/// | 入口方块 | 107px ≈ 36dp | `AppDimens.listIconRpx`（≈38dp） |
/// | 方块圆角 | 约 4/36 | 10rpx ≈ 4.8dp |
/// | 分组字母条 | 86px ≈ 28dp | 58rpx ≈ 28dp |
/// | 行细线 | `#E5E5E5` | `AppColors.rowDivider` |
/// | 字母条下细线 | `#D5D5D5` | `AppColors.sectionDivider` |
/// | 入口方块底 | `#FA9E3B` / `#07C160` / `#2781D7` | `AppColors.entryOrange` 等 |
///
/// 行高与右缩进**不再自己写一套数**：微信的通讯录、「我」页、设置页共用同一组
/// 尺寸，全部放在 [AppDimens] 里（见那一段的注释）。
///
/// 与老端不同（刻意的）：
/// * 数据来自本地库的流（进页面立刻有内容、离线可看），接口只在首次与下拉刷新时对齐；
/// * 老端每加一个好友就 `friendUpdate++` 触发整份重拉，新端由 WS 增量改行；
/// * 「新的朋友」的红点数的是**待处理的好友申请**，老端挂的是系统消息未读数。
/// * 微信那几项我们没有的（仅聊天的朋友、标签、公众号、服务号、星标朋友、
///   企业联系人）一律不画。
/// 通讯录顶部那几个入口在桌面框架里的「点亮」标识。
///
/// 二级页（新的朋友 / 群聊）在右栏打开时，中栏那一行要跟会话列表一样带底色 ——
/// 名字就这三个，中栏与路由两边共用（见 `DesktopFrame.paneId`）。
abstract final class ContactEntries {
  static const String newFriends = 'newFriends';
  static const String groups = 'groups';
  static const String systemNotice = 'systemNotice';
}

class ContactsPage extends ConsumerStatefulWidget {
  const ContactsPage({
    super.key,
    this.onOpenContact,
    this.selectedId,
    this.selectedEntry,
  });

  /// 点好友时干什么。**不传 = 手机那套**：push 一页用户详情。
  ///
  /// 桌面横屏的通讯录栏里传的是「选中到右栏」（见 `features/home/desktop_frame.dart`）——
  /// 那时候左边列表一直在，push 一个整页资料会把列表盖掉。
  final void Function(Contact contact)? onOpenContact;

  /// 当前在右栏打开的那个好友 id（桌面，用来给那一行加底色）。
  /// 手机上永远是 null，版式一点不变。
  final String? selectedId;

  /// 当前在右栏打开的是哪个入口（[ContactEntries] 里那三个），
  /// 给那一行加底色。二级页（新的朋友、群聊）用，手机上永远是 null。
  final String? selectedEntry;

  @override
  ConsumerState<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends ConsumerState<ContactsPage> {
  // 行高 / 内边距 / 图标尺寸 / 细线缩进全部走 [AppDimens] 那一套 ——
  // 微信的通讯录与设置页共用同一组尺寸（行高 50dp、内边距 16dp），
  // 所以这里**不再自己写一套数**。

  /// 好友头像的布置盒比头像本身宽 6rpx（`ContactAvatar` 给右下角那个
  /// 在线小绿点留的位置），细线缩进要跟着它走。
  static const double _friendDividerRpx = AppDimens.listIconDividerRpx + 6;

  /// 分组字母条高度（微信 28dp）
  static const double _sectionRpx = 58;

  /// 本次运行是否已经对齐过（老端 `mounted` 里每次都拉）
  bool _synced = false;

  final ScrollController _scroll = ScrollController();

  /// 每个分组表头的 key，索引条跳转靠它定位
  final Map<String, GlobalKey> _groupKeys = <String, GlobalKey>{};

  /// 拖动索引条时显示的字母
  String? _letterBubble;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _sync() async {
    if (_synced) return;
    _synced = true;
    await _refresh();
  }

  Future<void> _refresh() async {
    try {
      await ref.read(contactRepositoryProvider).syncFromServer();
    } catch (error) {
      // 失败不清列表：本地缓存照常展示（与消息页一致）
      debugPrint('[通讯录] 同步失败：$error');
    }
  }

  void _jumpTo(String letter) {
    final target = _groupKeys[letter]?.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      alignment: 0,
      duration: const Duration(milliseconds: 80),
    );
  }

  /// 索引条最上面那格「↑」：回顶部
  void _toTop() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
  }

  void _openChat(String id) {
    context.push('${AppRoutes.chat}?id=${Uri.encodeComponent(id)}');
  }

  /// 点好友：桌面上是「选中到右栏」（[ContactsPage.onOpenContact]），
  /// 手机上还是 push 用户详情（S5.2 那一页）
  void _openDetail(Contact contact) {
    final onOpen = widget.onOpenContact;
    if (onOpen != null) {
      onOpen(contact);
      return;
    }
    context.push(
      '${AppRoutes.contactsDetail}?id=${Uri.encodeComponent(contact.id)}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final setting = ref.watch(
      sessionStoreProvider.select((state) => state.setting),
    );
    final config = ref.watch(
      sessionStoreProvider.select((state) => state.config),
    );
    final friends = ref.watch(friendListProvider).value ?? const <Contact>[];
    final systems = ref.watch(systemContactProvider).value ?? const <Contact>[];
    final pending = ref.watch(pendingApplyCountProvider).value ?? 0;

    final groups = groupByIndex(friends);
    final letters = indexBarLetters(groups);
    // 分组表头每次重建时补 key（分组字母集合变化时只增不减，不影响滚动）
    for (final group in groups) {
      _groupKeys.putIfAbsent(group.name, () => GlobalKey());
    }
    final showOnlineDot = config.chatInfo.online == 1;

    return Stack(
      children: <Widget>[
        RefreshIndicator(
          onRefresh: _refresh,
          color: AppColors.brand,
          // 刻意用「非懒加载」的 SingleChildScrollView + Column：
          // 索引条跳转靠 `Scrollable.ensureVisible` 拿分组表头的 context，
          // 而 ListView 只挂载可见项——点一个还没滚到的字母，那个 key 的
          // context 是 null，跳转会**静默失败**（写这条时被测试抓到的）。
          // 老端 scroll-view 也是全量渲染，行为一致；通讯录条数不大，够用。
          child: SingleChildScrollView(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(bottom: context.rpx(40)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // 新的朋友（老端 `v-if="globalConfig.sysInfo.runMode==2"`）
                if (config.sysInfo.runMode == 2)
                  _entryRow(
                    context,
                    icon: Icons.person_add_alt_1,
                    tile: AppColors.entryOrange,
                    label: i18n.t('friend.newApply'),
                    badge: pending,
                    selected: widget.selectedEntry == ContactEntries.newFriends,
                    onTap: () => context.push(AppRoutes.newFriends),
                  ),
                _entryRow(
                  context,
                  icon: Icons.groups,
                  tile: AppColors.wechatGreen,
                  label: i18n.t('user.group'),
                  selected: widget.selectedEntry == ContactEntries.groups,
                  onTap: () => context.push(AppRoutes.groupList),
                ),
                for (final system in systems)
                  _entryRow(
                    context,
                    icon: Icons.campaign,
                    tile: AppColors.entryBlue,
                    label: i18n.t('user.systemNotice'),
                    onTap: () => _openChat(system.id),
                  ),
                for (final group in groups) ...<Widget>[
                  _sectionHeader(context, group.name),
                  for (final contact in group.children)
                    _contactRow(
                      context,
                      contact: contact,
                      circle: setting.circleAvatar,
                      showOnline: showOnlineDot && contact.isOnline == 1,
                    ),
                ],
                if (friends.isEmpty)
                  Padding(
                    padding: EdgeInsets.only(top: context.rpx(80)),
                    child: Center(
                      child: Image.asset(
                        'assets/images/empty.png',
                        width: context.rpx(240),
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: context.rpx(24)),
                    child: Center(
                      child: Text(
                        '${friendCount(friends)} ${i18n.t('friend.contactNum')}',
                        style: TextStyle(
                          fontSize: context.rpx(24),
                          color: AppColors.text999,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        // 右侧字母索引条（老端固定右下；微信是浮着的，没有白底）
        if (letters.isNotEmpty)
          Positioned(
            right: context.rpx(6),
            top: context.rpx(140),
            bottom: context.rpx(140),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ContactIndexBar(
                letters: letters,
                onSelect: _jumpTo,
                onTop: _toTop,
                onActiveChanged: (active) => setState(
                  () => _letterBubble = active ? _letterBubble : null,
                ),
              ),
            ),
          ),
        // 中间那个大字母（老端 `indexToast`，微信也是个深色方块）
        if (_letterBubble != null)
          IgnorePointer(
            child: Center(
              child: Container(
                width: context.rpx(130),
                height: context.rpx(130),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: const Color(0x80000000),
                  borderRadius: BorderRadius.circular(context.rpx(16)),
                ),
                child: Text(
                  _letterBubble!,
                  style: TextStyle(
                    fontSize: context.rpx(64),
                    color: AppColors.white,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 行与行之间那条细线。微信的线**不是通栏**，从这行文字左边才开始。
  Widget _rowDivider(BuildContext context, double indentRpx) => Container(
    height: 0.5,
    margin: EdgeInsets.only(left: context.rpx(indentRpx)),
    color: AppColors.rowDivider,
  );

  /// 顶部的一个入口行（新的朋友 / 群聊 / 系统通知）
  ///
  /// 图标是微信那种**彩色圆角方块 + 白字形**，不再用老端那几张 PNG。
  Widget _entryRow(
    BuildContext context, {
    required IconData icon,
    required Color tile,
    required String label,
    required VoidCallback onTap,
    int badge = 0,
    bool selected = false,
  }) => InkWell(
    onTap: onTap,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          height: context.rpx(AppDimens.listRowRpx),
          padding: EdgeInsets.symmetric(
            horizontal: context.rpx(AppDimens.listPadRpx),
          ),
          color: selected ? AppColors.page : AppColors.white,
          child: Row(
            children: <Widget>[
              _tileIcon(context, icon, tile),
              SizedBox(width: context.rpx(AppDimens.listGapRpx)),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.rpx(34),
                    color: AppColors.text000,
                  ),
                ),
              ),
              if (badge > 0)
                Container(
                  constraints: BoxConstraints(minWidth: context.rpx(36)),
                  height: context.rpx(36),
                  alignment: Alignment.center,
                  padding: EdgeInsets.symmetric(horizontal: context.rpx(8)),
                  decoration: BoxDecoration(
                    color: AppColors.unreadRed,
                    borderRadius: BorderRadius.circular(context.rpx(18)),
                  ),
                  child: Text(
                    badge > 99 ? '99+' : '$badge',
                    style: TextStyle(
                      fontSize: context.rpx(22),
                      color: AppColors.white,
                    ),
                  ),
                ),
            ],
          ),
        ),
        _rowDivider(context, AppDimens.listIconDividerRpx),
      ],
    ),
  );

  /// 入口那个彩色方块（微信：实心圆角方块 + 白色字形，字形约占边长 6 成）
  Widget _tileIcon(BuildContext context, IconData icon, Color color) =>
      Container(
        width: context.rpx(AppDimens.listIconRpx),
        height: context.rpx(AppDimens.listIconRpx),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(context.rpx(10)),
        ),
        child: Icon(icon, size: context.rpx(48), color: AppColors.white),
      );

  /// 分组字母条：浅灰整条 + 小灰字母（微信就是这样，不是白底）
  Widget _sectionHeader(BuildContext context, String name) => Container(
    key: _groupKeys[name],
    height: context.rpx(_sectionRpx),
    alignment: Alignment.centerLeft,
    padding: EdgeInsets.symmetric(
      horizontal: context.rpx(AppDimens.listPadRpx),
    ),
    decoration: const BoxDecoration(
      color: AppColors.navBar,
      border: Border(
        bottom: BorderSide(color: AppColors.sectionDivider, width: 0.5),
      ),
    ),
    child: Text(
      name,
      style: TextStyle(fontSize: context.rpx(26), color: AppColors.text666),
    ),
  );

  /// 好友行
  Widget _contactRow(
    BuildContext context, {
    required Contact contact,
    required bool circle,
    required bool showOnline,
  }) {
    // 桌面三栏：正在右栏打开的那一行加底色（与会话列表同一个口径：
    // 微信 PC 选中行比其它行深一档）。手机上 `selectedId` 永远是 null，不参与。
    final selected = contact.id == widget.selectedId;
    return InkWell(
      onTap: () => _openDetail(contact),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            height: context.rpx(AppDimens.listRowRpx),
            padding: EdgeInsets.symmetric(
              horizontal: context.rpx(AppDimens.listPadRpx),
            ),
            color: selected ? AppColors.page : AppColors.white,
            child: Row(
              children: <Widget>[
                ContactAvatar(
                  url: contact.avatar,
                  circle: circle,
                  showOnline: showOnline,
                  sizeRpx: AppDimens.listIconRpx,
                ),
                SizedBox(width: context.rpx(AppDimens.listGapRpx)),
                Expanded(
                  child: Text(
                    contact.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: context.rpx(34),
                      color: AppColors.text000,
                    ),
                  ),
                ),
              ],
            ),
          ),
          _rowDivider(context, _friendDividerRpx),
        ],
      ),
    );
  }
}
