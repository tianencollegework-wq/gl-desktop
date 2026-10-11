import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/net/api_exception.dart';
import '../../core/router/app_router.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/ui/wechat_dialog.dart';
import '../../data/model/contact.dart';
import '../../data/repo/contact_repository.dart';
import '../../data/repo/conversation_repository.dart';
import '../../data/repo/friend_apply_repository.dart';
import '../../domain/contacts/friend_apply.dart';
import 'widgets/contact_avatar.dart';
import 'widgets/contacts_empty.dart';

/// 「新朋友」，对应老端 `pages/contacts/friend.vue`。
///
/// 结构照老端：两个分段（我收到的 / 我发起的）+ 搜索入口（加好友，路由到 S5.4 的
/// 搜索页）+ 分页列表；每行右边按 `status` 显示不同的东西：
/// * 0 已拒绝（红字）
/// * 1 已同意 → 「发消息」（蓝字，点了进聊天）
/// * 2 待处理：收到的给一个绿色「操作」按钮（弹窗里选接受 / 拒绝）；我发起的显示「待同意」
///
/// 与老端不同（刻意的）：
/// * 空态/失败都用同一套空视图（老端失败时列表无声无息地空着）；
/// * 同意之后会**刷新通讯录红点**（老端手工 `sysUnread--`，其实那个角标挂的是
///   系统消息未读数，见 `contact_repository` 的注释）。
class NewFriendsPage extends ConsumerStatefulWidget {
  const NewFriendsPage({super.key});

  @override
  ConsumerState<NewFriendsPage> createState() => _NewFriendsPageState();
}

class _NewFriendsPageState extends ConsumerState<NewFriendsPage> {
  ApplyTab _tab = ApplyTab.received;
  int _page = 1;
  int _total = 0;
  List<FriendApply> _items = const <FriendApply>[];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({int? page}) async {
    final target = page ?? _page;
    setState(() => _loading = true);
    try {
      final result = await ref
          .read(friendApplyRepositoryProvider)
          .page(tab: _tab, page: target);
      if (!mounted) return;
      setState(() {
        _items = result.items;
        _total = result.total;
        _page = result.page;
        _loading = false;
      });
    } on Object catch (error) {
      debugPrint('[新朋友] 列表加载失败：$error');
      if (!mounted) return;
      setState(() {
        _items = const <FriendApply>[];
        _total = 0;
        _page = 1;
        _loading = false;
      });
    }
  }

  void _switchTab(ApplyTab tab) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
    // 老端换分段时 `params.page = 1`
    _load(page: 1);
  }

  /// 同意 / 拒绝（老端那个 `uni.showModal`：左键是「拒绝」，右键是「接受」）
  ///
  /// 这里不能直接用 `showWeChatConfirm`：那个只分「确定/其他」两态，
  /// 而这两个键各自都是一个动作（拒绝要真的发拒绝请求），所以取三态。
  Future<void> _respond(FriendApply apply, AppI18n i18n) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => WeChatDialogBox(
        body: WeChatDialogText(i18n.t('friend.comfirmAgree')),
        actions: <WeChatDialogAction>[
          WeChatDialogAction(label: i18n.t('friend.refuse'), value: 'refuse'),
          WeChatDialogAction(
            label: i18n.t('friend.agree'),
            value: 'agree',
            tone: WeChatDialogTone.primary,
          ),
        ],
      ),
    );
    // 点外面关掉弹窗 = 什么都不做（老端的 `success` 回调也只在两个按钮上触发）
    if (choice == null) return;
    final agreed = choice == 'agree';

    try {
      final message = await ref
          .read(friendApplyRepositoryProvider)
          .respond(friendId: apply.friendId, agree: agreed);
      // 老端弹的是服务端回执的 msg
      if (message.isNotEmpty) noticeBus.toast(message);
      // 处理掉一条，通讯录上那个红点跟着变
      ref.invalidate(pendingApplyCountProvider);
    } on ApiException catch (error) {
      debugPrint('[新朋友] 处理申请失败：${error.message}');
      noticeBus.toast(error.message);
    }
    if (!mounted) return;
    await _load();
  }

  /// 进聊天：老端 `sendMsg()`——陌生会话先要一次用户信息补进会话列表
  Future<void> _openChat(FriendApply apply) async {
    if (apply.userId.isEmpty) return;
    final info = Contact(
      id: apply.userId,
      displayName: apply.title,
      avatar: apply.avatar,
    );
    await ref.read(conversationRepositoryProvider).ensureFromContact(info);
    if (!mounted) return;
    context.push('${AppRoutes.chat}?id=${Uri.encodeComponent(apply.userId)}');
  }

  void _openDetail(FriendApply apply) {
    if (apply.userId.isEmpty) return;
    context.push(
      '${AppRoutes.contactsDetail}?id=${Uri.encodeComponent(apply.userId)}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final setting = ref.watch(
      sessionStoreProvider.select((state) => state.setting),
    );

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(
        title: Text(i18n.t('friend.newApply')),
        actions: <Widget>[
          IconButton(
            tooltip: i18n.t('friend.seachFriend'),
            onPressed: () => context.push(AppRoutes.contactSearch),
            icon: const Icon(Icons.person_add_alt),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _tabs(context, i18n),
          const Divider(height: 1, color: AppColors.line),
          Expanded(
            child: RefreshIndicator(
              color: AppColors.brand,
              onRefresh: () => _load(),
              child: _body(context, i18n, circle: setting.circleAvatar),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabs(BuildContext context, AppI18n i18n) => Container(
    color: AppColors.white,
    height: context.rpx(80),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        for (final tab in ApplyTab.values)
          GestureDetector(
            onTap: () => _switchTab(tab),
            child: Container(
              alignment: Alignment.center,
              padding: EdgeInsets.symmetric(horizontal: context.rpx(40)),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    width: context.rpx(4),
                    color: _tab == tab ? AppColors.brand : Colors.transparent,
                  ),
                ),
              ),
              child: Text(
                i18n.t(tab.labelKey),
                style: TextStyle(
                  fontSize: context.rpx(30),
                  color: _tab == tab ? AppColors.brand : AppColors.text666,
                ),
              ),
            ),
          ),
      ],
    ),
  );

  Widget _body(BuildContext context, AppI18n i18n, {required bool circle}) {
    if (_loading && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      // 空态也要能下拉刷新
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: <Widget>[
          SizedBox(height: context.rpx(80)),
          Center(child: ContactsEmpty(text: i18n.t('common.none'))),
        ],
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      // 列表 + 底部翻页条
      itemCount: _items.length + 1,
      itemBuilder: (context, index) {
        if (index == _items.length) return _pager(context);
        return _applyRow(
          context,
          apply: _items[index],
          i18n: i18n,
          circle: circle,
        );
      },
    );
  }

  Widget _applyRow(
    BuildContext context, {
    required FriendApply apply,
    required AppI18n i18n,
    required bool circle,
  }) => Container(
    color: AppColors.white,
    padding: EdgeInsets.symmetric(
      horizontal: context.rpx(30),
      vertical: context.rpx(20),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ContactAvatar(url: apply.avatar, circle: circle, sizeRpx: 80),
        SizedBox(width: context.rpx(20)),
        Expanded(
          child: GestureDetector(
            onTap: () => _openDetail(apply),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(height: context.rpx(6)),
                _mainLine(context, apply: apply, i18n: i18n),
                if (apply.remark.isNotEmpty) ...<Widget>[
                  SizedBox(height: context.rpx(10)),
                  Text(
                    apply.remark,
                    style: TextStyle(
                      fontSize: context.rpx(24),
                      color: AppColors.text666,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        SizedBox(width: context.rpx(20)),
        _action(context, apply: apply, i18n: i18n),
      ],
    ),
  );

  /// 主文案：收到的「XX 申请添加您为好友」/ 我发起的「添加 XX 为好友」
  Widget _mainLine(
    BuildContext context, {
    required FriendApply apply,
    required AppI18n i18n,
  }) {
    final name = TextSpan(
      text: apply.title,
      style: const TextStyle(color: AppColors.brand),
    );
    final children = _tab == ApplyTab.received
        ? <InlineSpan>[name, TextSpan(text: ' ${i18n.t('friend.applyFriend')}')]
        : <InlineSpan>[
            TextSpan(text: '${i18n.t('friend.apply')} '),
            name,
            TextSpan(text: ' ${i18n.t('friend.forFriend')}'),
          ];
    return Text.rich(
      TextSpan(children: children),
      style: TextStyle(fontSize: context.rpx(28), color: AppColors.text666),
    );
  }

  Widget _action(
    BuildContext context, {
    required FriendApply apply,
    required AppI18n i18n,
  }) {
    if (apply.isRefused) {
      return Text(
        i18n.t('friend.refused'),
        style: TextStyle(fontSize: context.rpx(28), color: AppColors.red),
      );
    }
    if (apply.isAccepted) {
      return GestureDetector(
        onTap: () => _openChat(apply),
        child: Text(
          i18n.t('message.send'),
          style: TextStyle(fontSize: context.rpx(28), color: AppColors.brand),
        ),
      );
    }
    if (!apply.isPending) {
      // 状态认不出来（老端此时也不显示任何操作）
      return const SizedBox.shrink();
    }
    if (_tab == ApplyTab.sent) {
      return Text(
        i18n.t('friend.waitAgree'),
        style: TextStyle(fontSize: context.rpx(28), color: AppColors.orange),
      );
    }
    // 收到的待处理：老端那个绿色圆角按钮
    return GestureDetector(
      onTap: () => _respond(apply, i18n),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.rpx(24),
          vertical: context.rpx(10),
        ),
        decoration: BoxDecoration(
          color: AppColors.green,
          borderRadius: BorderRadius.circular(context.rpx(30)),
        ),
        child: Text(
          i18n.t('common.option'),
          style: TextStyle(fontSize: context.rpx(26), color: AppColors.white),
        ),
      ),
    );
  }

  /// 底部翻页条（老端 `uni-pagination`；只有超过一页才出现）
  Widget _pager(BuildContext context) {
    final pages = pageCountFor(
      total: _total,
      pageSize: FriendApplyRepository.pageSize,
    );
    if (pages <= 1) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.rpx(20)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          IconButton(
            onPressed: hasPrevPage(_page) ? () => _load(page: _page - 1) : null,
            icon: const Icon(Icons.chevron_left),
          ),
          Text(
            '$_page / $pages',
            style: TextStyle(
              fontSize: context.rpx(26),
              color: AppColors.text666,
            ),
          ),
          IconButton(
            onPressed:
                hasNextPage(
                  page: _page,
                  total: _total,
                  pageSize: FriendApplyRepository.pageSize,
                )
                ? () => _load(page: _page + 1)
                : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}
