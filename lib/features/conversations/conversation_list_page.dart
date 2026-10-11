import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/router/app_router.dart';
import '../../core/store/hidden_conversations.dart';
import '../../core/store/manual_unread.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/app_context_menu.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/ui/wechat_dialog.dart';
import '../../core/ws/ws_client.dart';
import '../../core/ws/ws_service.dart';
import '../../data/model/conversation.dart';
import '../../data/repo/conversation_repository.dart';
import '../notify/system_health_banner.dart';
import '../group_call/group_call_sync.dart' show groupCallPresenceProvider;
import 'widgets/conversation_tile.dart';

/// 消息 tab：会话列表，对应老端 `pages/message/index.vue`。
///
/// 与老端的差别（都是刻意的）：
/// * 老端每次进页面把 `getContacts` 的结果**整份塞进 storage**，列表本身还是内存数组；
///   新端列表直接订阅数据库的流，进页面立即出内容，接口只在首屏与下拉刷新时对齐一次。
/// * 老端置顶/免打扰是**等接口成功**才改本地（弱网下点了没反应）；
///   新端先改本地再同步，失败只记日志（见 [ConversationRepository]）。
class ConversationListPage extends ConsumerStatefulWidget {
  const ConversationListPage({super.key, this.onOpenChat, this.selectedId});

  /// 点会话时干什么。**不传 = 手机那套**：push 一个聊天页。
  ///
  /// 桌面横屏三栏里传的是「选中到右栏」（见 `features/home/desktop_frame.dart`）——
  /// 那时候左边列表一直在，push 一个整页聊天会把列表盖掉。
  final void Function(Conversation conversation)? onOpenChat;

  /// 当前在右栏打开的那个会话 id（桌面，用来给那一行加底色）。
  /// 手机上永远是 null，版式一点不变。
  final String? selectedId;

  @override
  ConsumerState<ConversationListPage> createState() =>
      _ConversationListPageState();
}

class _ConversationListPageState extends ConsumerState<ConversationListPage> {
  /// 本次运行是否已经对齐过（老端是每次 onShow 都拉，这里只在首次和手动下拉时拉）
  bool _synced = false;

  /// 「折叠置顶聊天」是否展开（微信置顶超过 2 条时默认折起来）
  bool _pinnedExpanded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  Future<void> _sync() async {
    if (_synced) return;
    _synced = true;
    try {
      await ref.read(conversationRepositoryProvider).syncFromServer();
    } catch (error) {
      // 失败不清列表：本地缓存照常展示，接口层的提示由 NoticeBus 统一弹
      debugPrint('[会话] 列表同步失败：$error');
    }
  }

  Future<void> _refresh() async {
    try {
      await ref.read(conversationRepositoryProvider).syncFromServer();
    } catch (error) {
      debugPrint('[会话] 下拉刷新失败：$error');
    }
  }

  void _openChat(Conversation conversation) {
    final onOpenChat = widget.onOpenChat;
    if (onOpenChat != null) {
      onOpenChat(conversation);
      return;
    }
    // 与老端一致：只带 id，聊天页自己按 id 从本地库取会话详情
    context.push(
      '${AppRoutes.chat}?id=${Uri.encodeComponent(conversation.id)}',
    );
  }

  Future<void> _toggleTop(Conversation conversation) async {
    await ref
        .read(conversationRepositoryProvider)
        .setTop(
          conversation.id,
          conversation.isTop == 1 ? 0 : 1,
          isGroup: conversation.isGroup,
        );
  }

  Future<void> _toggleNotice(Conversation conversation) async {
    await ref
        .read(conversationRepositoryProvider)
        .setNotice(
          conversation.id,
          conversation.isNotice == 0 ? 1 : 0,
          isGroup: conversation.isGroup,
        );
  }

  Future<void> _delete(Conversation conversation) async {
    final i18n = ref.read(appI18nProvider);
    // 注意：`common.confirm` 在老端语言包里是「吗？」（拼句子的片段），
    // 按钮上要用 `common.ok`（「确定」）
    final confirmed = await showWeChatConfirm(
      context,
      message: i18n.t('chat.confirmDel'),
      confirmLabel: i18n.t('common.ok'),
      cancelLabel: i18n.t('common.cancel'),
      danger: true,
    );
    if (!confirmed) return;
    await ref
        .read(conversationRepositoryProvider)
        .remove(conversation.id, isGroup: conversation.isGroup);
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
    // 用「可见」口径：被「不显示该聊天」藏起来的会话不参与渲染
    final conversations = ref.watch(visibleConversationsProvider);
    // 「标为未读」标出来的那些：它们只顶小红点、不报数字（微信就是这样的）
    final manualUnread = ref.watch(manualUnreadProvider);
    // 「谁在开群语音」（S6.15）：长连接那条 `sfuRoom` 推来的，与正在进行的那个房间无关
    // —— 会话列表只管把它挂到对应那一行上（那一行不一定是当前打开的会话）
    final groupCallPresence = ref.watch(groupCallPresenceProvider);
    final multiport = ref.watch(
      sessionStoreProvider.select((state) => state.multiport),
    );
    // 连接状态是**三态**，不是一个布尔量：
    //   `null`        = 状态流还没吐出第一帧（冷启动那一瞬）；
    //   `idle`        = WS 服务还没 start（同上，都属于「还没连上」）；
    //   `connecting`  = 正在连；
    //   `connected`   = 连上了。
    // 前三种都属于「还在连」这个正常过程。老实现拿 `value.value == WsStatus.connected`
    // 当唯一判据，于是每次冷启动都会先闪一条红色的「通信断开」、一两秒后自己消失
    // （用户 2026-09-26 反馈的体验问题）。
    //
    // `idle` 也得算「连接中」（2026-09-30）：状态流现在**会补当前这一帧**
    // （见 `WsService.statusChanges`），冷启动第一帧拿到的是 `idle`，
    // 按「断开」画就会先闪一条红提示。
    final wsStatus = ref.watch(wsStatusProvider).value;
    final connecting =
        wsStatus == null ||
        wsStatus == WsStatus.idle ||
        wsStatus == WsStatus.connecting;
    final connected = wsStatus == WsStatus.connected;

    return Container(
      // 微信的消息列表整页是白的（连最后一行下面那片空白也是白的）
      color: AppColors.white,
      child: Column(
        children: <Widget>[
          // 微信在列表最上面挂一条「Windows 微信已登录」。我们这边服务端只会告诉
          // 「别的端也登着」（`multiport`），不会说是哪一端，所以文案不带平台名。
          if (multiport && connected) const _PcOnlineRow(),
          if (connecting)
            _buildConnectRow(context, i18n)
          else if (!connected)
            _buildDisconnectRow(context, i18n),
          // 「通知没开 / 没关省电优化」提示条（老端那两条 uni-notice-bar）：
          // 系统不让我们在后台活着，消息就到不了 —— 摆在列表最上面
          const SystemHealthBanner(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              color: AppColors.brand,
              child: conversations.when(
                loading: () => const Center(
                  child: CircularProgressIndicator(color: AppColors.brand),
                ),
                error: (error, _) => _Hint(text: '$error'),
                data: (list) {
                  if (list.isEmpty) {
                    return ListView(
                      // 空列表也要能下拉刷新
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: <Widget>[
                        SizedBox(height: context.rpx(200)),
                        _Hint(text: i18n.t('common.noData')),
                      ],
                    );
                  }
                  // 微信：置顶超过 2 条就折起来，列表最下面留一行「折叠置顶聊天」
                  final pinnedCount = list
                      .where((item) => item.isTop == 1)
                      .length;
                  final canFold = pinnedCount > 2;
                  final rows = (canFold && !_pinnedExpanded)
                      ? list.where((item) => item.isTop != 1).toList()
                      : list;
                  return ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: rows.length + (canFold ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (canFold && index == rows.length) {
                        return _FoldPinnedRow(
                          expanded: _pinnedExpanded,
                          label: i18n.t('chat.foldPinned'),
                          onTap: () => setState(
                            () => _pinnedExpanded = !_pinnedExpanded,
                          ),
                        );
                      }
                      final conversation = rows[index];
                      // 桌面三栏：正在右欄打开的那一行加底色（微信 PC 就是选中行
                      // 比其它行深一档）。手机上 `selectedId` 永远是 null，不参与。
                      final selected = conversation.id == widget.selectedId;
                      return ColoredBox(
                        color: selected ? AppColors.page : AppColors.white,
                        child: ListenableBuilder(
                          listenable: groupCallPresence,
                          builder: (context, _) => ConversationTile(
                            conversation: conversation,
                            setting: setting,
                            config: config,
                            translate: i18n.t,
                            unreadIsDot: manualUnread.contains(conversation.id),
                            // 有人在开语音的群：预览那一位换成「语音通话中」
                            // （在 builder 里现算：标记变了要跟着变）
                            callLabel:
                                groupCallPresence.liveIn(conversation.id) ==
                                    null
                                ? null
                                : i18n.t('group.callInProgress'),
                            onTap: () => _openChat(conversation),
                            // 微信是长按弹菜单（原来是左滑）
                            onLongPress: (position) => unawaited(
                              _showRowMenu(context, conversation, position),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 还在连（含「状态流还没吐出第一帧」）：一条中性的「连接中…」。
  ///
  /// 和下面那条断开的提示**共用同一行的尺寸**，只换左边那颗图标和图标颜色 ——
  /// 「连接中 → 连上了」时不会有条横线抖一下。
  Widget _buildConnectRow(BuildContext context, AppI18n i18n) =>
      _buildStatusRow(
        context,
        text: i18n.t('chat.wsConnecting'),
        icon: Icons.sync,
        iconColor: AppColors.text666,
      );

  /// 连接断了：一条可点的红字提示（老端是头部那个小胶囊，这里铺成一行）。
  ///
  /// 断线时**不显示**「电脑端已登录」：老端在 `socketStatus` 事件里也把
  /// multiport 置了 false —— 连不上就无从确认别的端还在不在。
  Widget _buildDisconnectRow(BuildContext context, AppI18n i18n) =>
      _buildStatusRow(
        context,
        text: i18n.t('chat.wsDisconnect'),
        icon: Icons.info_outline,
        iconColor: AppColors.red,
      );

  /// 列表最上面那条连接状态行。点整行 = 手动重连（右边那颗 `refresh`），
  /// 两种状态的行高、内边距、字号完全一致，只有图标与文案不同。
  Widget _buildStatusRow(
    BuildContext context, {
    required String text,
    required IconData icon,
    required Color iconColor,
  }) {
    return InkWell(
      onTap: _reconnect,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.rpx(33),
          vertical: context.rpx(22),
        ),
        decoration: const BoxDecoration(
          color: AppColors.white,
          border: Border(bottom: BorderSide(color: AppColors.line, width: 0.5)),
        ),
        child: Row(
          children: <Widget>[
            Icon(icon, size: context.rpx(34), color: iconColor),
            SizedBox(width: context.rpx(14)),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: context.rpx(28),
                  color: AppColors.text666,
                ),
              ),
            ),
            Icon(
              Icons.refresh,
              size: context.rpx(34),
              color: AppColors.text666,
            ),
          ],
        ),
      ),
    );
  }

  /// 老端 `reconnect()`：重连着的时候给个「重连中」提示。
  ///
  /// 新端不需要自己发 ping 帧（连接断了 `WsClient` 会自己退避重连），
  /// 这个按钮只是把重置连接这件事变得看得见。
  void _reconnect() {
    noticeBus.toast(ref.read(appI18nProvider).t('chat.reConnected'));
    ref.read(wsServiceProvider).restart();
  }

  /// 长按一行弹出的菜单（微信就是长按弹菜单，左滑是另一套手势）。
  ///
  /// 菜单项按微信的顺序和用词：**标为未读 / 取消置顶 / 不显示该聊天 / 删除该聊天**；
  /// 「免扰」微信是放在聊天设置页的，我们那边还没做，删了就没地方点，所以留在菜单里
  /// （排在删除之前）。群聊 `is_group == 2` 不给删，与老端一致。
  /// 菜单弹在按下的位置，`showMenu` 会自己躲开屏幕边缘。
  Future<void> _showRowMenu(
    BuildContext context,
    Conversation conversation,
    Offset position,
  ) async {
    final i18n = ref.read(appI18nProvider);
    final action = await showAppContextMenu<_RowAction>(
      context: context,
      globalPosition: position,
      items: <AppMenuItem<_RowAction>>[
        AppMenuItem(
          value: _RowAction.markUnread,
          label: i18n.t('chat.markUnread'),
        ),
        AppMenuItem(
          value: _RowAction.top,
          label: i18n.t(conversation.isTop == 1 ? 'chat.unTop' : 'chat.isTop'),
        ),
        AppMenuItem(value: _RowAction.hide, label: i18n.t('chat.hideChat')),
        AppMenuItem(
          value: _RowAction.notice,
          label: i18n.t(
            conversation.isNotice == 1 ? 'chat.noVoice' : 'chat.cancelNoVoice',
          ),
        ),
        if (conversation.isGroup < 2)
          AppMenuItem(value: _RowAction.delete, label: i18n.t('chat.delChat')),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _RowAction.markUnread:
        await ref
            .read(conversationRepositoryProvider)
            .markUnread(conversation.id);
        await ref.read(manualUnreadProvider.notifier).mark(conversation.id);
      case _RowAction.top:
        await _toggleTop(conversation);
      case _RowAction.hide:
        // 「不显示该聊天」：只在本地藏起来（不删消息、不上报服务端），
        // 等这个会话再来新消息会自动冒出来
        await ref
            .read(hiddenConversationsProvider.notifier)
            .hide(conversation.id);
      case _RowAction.notice:
        await _toggleNotice(conversation);
      case _RowAction.delete:
        await ref.read(manualUnreadProvider.notifier).clear(conversation.id);
        await _delete(conversation);
    }
  }

  /// 菜单项文字（微信那种白底卡片、宽松行高）—— 由
  /// [showAppContextMenu] 统一提供，这里不再自己写一份。
}

/// 长按菜单里的动作（顺序就是微信那个菜单的顺序）
enum _RowAction { markUnread, top, hide, notice, delete }

/// 「折叠置顶聊天」一行。
///
/// 微信在置顶超过 2 条时把置顶区折起来，列表最下面留这一行；
/// 箭头向上表示「上面还有东西，点一下展开」。
class _FoldPinnedRow extends StatelessWidget {
  const _FoldPinnedRow({
    required this.expanded,
    required this.label,
    required this.onTap,
  });

  final bool expanded;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        color: AppColors.white,
        padding: EdgeInsets.symmetric(
          horizontal: context.rpx(30),
          vertical: context.rpx(20),
        ),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: context.rpx(80),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Icon(
                  Icons.subject,
                  size: context.rpx(40),
                  color: AppColors.text999,
                ),
              ),
            ),
            SizedBox(width: context.rpx(26)),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: context.rpx(30),
                  color: AppColors.text333,
                ),
              ),
            ),
            Icon(
              expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
              size: context.rpx(44),
              color: AppColors.text999,
            ),
          ],
        ),
      ),
    );
  }
}

/// 「电脑端已登录」一行 —— 对应微信列表最上面那条「Windows 微信已登录」。
///
/// 数据来源是 WS `pong` 里的多端标记（`sessionStore.multiport`）：服务端只会
/// 告诉「这个账号在别的端也登着」，不会说是哪一端，所以文案不带平台名。
/// 连接断开时不显示（无从确认别的端还在不在）。
class _PcOnlineRow extends ConsumerWidget {
  const _PcOnlineRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final label = ref.watch(appI18nProvider).t('chat.pcOnline');

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.rpx(30),
        vertical: context.rpx(20),
      ),
      // 微信这一行的底色和顶部栏是**同一个灰**（不是白底），下面就一条通宽分割线
      decoration: const BoxDecoration(
        color: AppColors.navBar,
        border: Border(bottom: BorderSide(color: AppColors.line, width: 0.5)),
      ),
      child: Row(
        children: <Widget>[
          // 图标蹲在头像那一列里，文字与下面每行的昵称左对齐
          SizedBox(
            width: context.rpx(100),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Icon(
                Icons.computer,
                size: context.rpx(44),
                color: AppColors.text666,
              ),
            ),
          ),
          SizedBox(width: context.rpx(29)),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.rpx(30),
                color: AppColors.text333,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: EdgeInsets.symmetric(vertical: context.rpx(40)),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: context.rpx(28), color: AppColors.text999),
      ),
    ),
  );
}
