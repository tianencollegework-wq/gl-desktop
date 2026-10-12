import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/net/api_exception.dart';
import '../../core/router/app_router.dart';
import '../../core/store/cleared_chats.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/ui/wechat_dialog.dart';
import '../../core/ui/text_prompt_dialog.dart';
import '../../core/util/json_value.dart';
import '../../data/model/conversation.dart';
import '../../data/model/message.dart';
import '../../data/repo/chat_background_repository.dart';
import '../../data/repo/conversation_repository.dart';
import '../../data/repo/group_admin_repository.dart';
import '../../data/repo/message_repository.dart';
import '../../domain/chat/group_admin.dart';
import '../../domain/chat/group_members.dart';
import '../../domain/report/report_reasons.dart';
import '../common/report_sheet.dart';
import '../contacts/widgets/contact_avatar.dart';
import 'group_member_picker_page.dart';
import '../../core/ui/desktop_overlay.dart';

/// 聊天信息，对应老端 `pages/message/detail.vue`（S5.3）。
///
/// **界面照微信**（用户 2026-09-20 给了三张截图）：顶部是头像那一块
/// （单聊：对方头像 + 一颗虚线的「＋」，点了发起群聊；群聊：成员网格 +
/// 「＋ / －」），下面是白卡片一行一行的设置项，卡片之间留灰缝。
///
/// 一个踩过的坑：这里的「是不是群」一度写成 `is_group != 0`，于是「我的收藏」
/// （`is_group == 3`）被当成群聊，页面上冒出「群成员 0 人」「群名称 我的收藏」
/// 「群公告 暂无公告」（用户 2026-09-21 报的）；现在统一用 [_kindOf] 判种类。
///
/// 与微信刻意不同的两处：
/// * **「提醒」不做**（用户明确说没这个功能）；
/// * 「保存到通讯录 / 我在群里的昵称 / 显示群成员昵称 / 备注」这几行也没有，
///   因为服务端与老端都没有对应功能 —— 用户的要求是「有的做，没有的不要做」。
///
/// 会话种类（老端 `is_group`）决定这一页长什么样：
/// * **单聊（0）**：对方头像（点进详情页）+ 发起群聊、查找聊天记录、免打扰、置顶、
///   聊天背景、清空聊天记录、投诉；
/// * **群聊（1）**：再加成员网格（可加人 / 可移除）、群名称、群二维码、群公告、群管理，
///   底下多一颗红色的「退出群聊」（群主还多一颗「解散群聊」）；
/// * **系统通知（2）**：「更多」按钮在聊天页就不给了，进不来；
/// * **我的收藏（3）**：**两样都没有** —— 没有成员网格也没有对方头像，
///   只有免打扰/置顶/背景/查找记录那几行公共项（老端 `is_group<2` / `==1` 两条门槛
///   正好把它排除在外）。
///
/// 刻意与老端不同：
/// * 改群名 / 退群 / 清空记录**都会同步改本地库**，界面不会出现「详情页变了、
///   列表还是旧的」；
/// * 非管理员点群公告是**只读**的（老端只把输入框 `disabled`，新端连「保存」都不画）；
/// * 聊天背景改完**立刻生效**（老端要重进聊天，它界面上那句提示就是为了这个）；
/// * **「清空聊天记录」单聊也能用**（老端只在群里给管理员，单聊连入口都没有）：
///   单聊清的是**本机**这份记录（服务端没有「只清我这边」的接口，
///   所以本地记一份名单把重新拉回来的旧消息丢掉，见 `ClearedChatsStore`）；
///   群里如果我是群主/管理员，仍然照旧连服务端一起清（所有人的记录都删）。
class ChatInfoPage extends ConsumerStatefulWidget {
  const ChatInfoPage({
    super.key,
    required this.conversationId,
    this.isGroup = 0,
    this.embedded = false,
    this.onClearRecord,
  });

  final String conversationId;

  /// 老端从 `detail?id=&is_group=` 传进来；缺省时按会话行的 `is_group` 判断
  final int isGroup;

  /// 桌面右栏面板里嵌着时（[ChatInfoPanel]）：不画 [Scaffold]、不留手机那条
  /// 顶部导航栏 —— 那一栏自己就是分界，标题由聊天页顶栏承担。
  final bool embedded;

  /// 「清空聊天记录」换成外面那套（桌面面板是**本机口径**：微信 PC 那一栏也
  /// 只清本机，删全体的入口在群资料里）。不给就走本页那份（群里我是群主 /
  /// 管理员时连服务端一起清）。
  final VoidCallback? onClearRecord;

  @override
  ConsumerState<ChatInfoPage> createState() => _ChatInfoPageState();
}

/// 这一个会话（改名、公告、开关都靠它）
final _conversationProvider = StreamProvider.family<Conversation?, String>(
  (ref, id) => ref.watch(conversationRepositoryProvider).watchOne(id),
);

class _ChatInfoPageState extends ConsumerState<ChatInfoPage> {
  List<GroupMember> _members = const <GroupMember>[];
  int _memberCount = 0;
  GroupPermissions _permissions = const GroupPermissions();
  bool _loadingMembers = false;

  /// 卡片里那行的高度（微信约 56dp）
  static const double rowRpx = 112;

  /// 一行里的字（微信 17sp）
  static const double labelRpx = 34;

  /// 右侧那个值/灰字（微信 16sp）
  static const double valueRpx = 32;

  ConversationRepository get _conversations =>
      ref.read(conversationRepositoryProvider);

  GroupAdminRepository get _admin => ref.read(groupAdminRepositoryProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMembers());
  }

  @override
  void didUpdateWidget(covariant ChatInfoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId == widget.conversationId &&
        oldWidget.isGroup == widget.isGroup) {
      return;
    }
    // 面板里嵌着时是**同一个 State** 跟着换会话（整页版每次都是新推的一页）：
    // 成员 / 权限还是上一个会话的，先清掉再重拉。
    _members = const <GroupMember>[];
    _memberCount = 0;
    _permissions = const GroupPermissions();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadMembers());
  }

  /// 会话种类（老端 `is_group`）：**0 好友、1 群聊、2 系统通知、3 我的收藏/应用号**。
  ///
  /// 之前这里写的是「不等于 0 就算群」，于是「我的收藏」（服务端把 `to_user = -1`
  /// 的那条会话存成 `is_group = 3`，见 `User::setContact` 与 `Message::create`）
  /// 被当成群聊，聊天信息页里冒出一整套群的东西：「群成员 0 人」「群名称 我的收藏」
  /// 「群公告 暂无公告」（用户 2026-09-21 报的）。
  ///
  /// 老端那一页的门槛写得很清楚：成员/头像那一块是 `v-if="is_group<2"`，
  /// 群名/公告/群管理/退群那几块是 `v-if="is_group==1"` —— 也就是
  /// **`is_group == 3` 两样都没有**，只剩免打扰/置顶/背景/查找记录那几行公共项。
  /// 会话行还没到手时用路由带进来的 `is_group` 顶上。
  int _kindOf(Conversation? conversation) =>
      conversation?.isGroup ?? widget.isGroup;

  /// 真正的群聊（只有 `1` 是群；系统通知与我的收藏都不是）
  bool _isGroup(Conversation? conversation) => _kindOf(conversation) == 1;

  /// 好友会话（有「对方」那一个人）：才画头像那一块
  bool _isPeerChat(Conversation? conversation) => _kindOf(conversation) == 0;

  /// 只有群聊才拉成员（单聊/收藏去请求群成员接口会拿到一个业务错误，白弹一次提示）
  Future<void> _maybeLoadMembers() async {
    final conversation = await ref
        .read(conversationRepositoryProvider)
        .find(widget.conversationId);
    if (!_isGroup(conversation)) return;
    await _loadMembers();
  }

  Future<void> _loadMembers() async {
    setState(() => _loadingMembers = true);
    try {
      final list = await _admin.members(widget.conversationId);
      final myId = ref.read(sessionStoreProvider).userId;
      if (!mounted) return;
      setState(() {
        _members = list.members;
        _memberCount = list.count;
        _permissions = groupPermissionsOf(list.members, myId);
        _loadingMembers = false;
      });
    } on Object catch (error) {
      // 成员拉不到不影响这一页其它功能（老端失败时整页空白）
      debugPrint('[聊天信息] 群成员取不到：$error');
      if (mounted) setState(() => _loadingMembers = false);
    }
  }

  // ------------------------------------------------------------- 群设置

  Future<void> _renameGroup(Conversation conversation) async {
    final i18n = ref.read(appI18nProvider);
    final name = await showTextPrompt(
      context,
      title: i18n.t('group.editName'),
      initial: conversation.displayName,
    );
    if (name == null || name.isEmpty || !mounted) return;
    try {
      await _admin.rename(widget.conversationId, name);
    } on ApiException catch (error) {
      debugPrint('[聊天信息] 改群名失败：${error.message}');
      noticeBus.toast(error.message);
    }
  }

  /// 群公告 → **整页编辑**（S6.22）。
  ///
  /// 用户 2026-09-27 要求把原来那个底部弹层换成"一个页面输入，右上角保存"：
  /// 所以这里只负责把人送进 [GroupNoticePage]（权限已经算过一遍，顺手带过去），
  /// 保存那段逻辑搬到那一页里（它写完会顺手覆盖本地那一格，返回时这一行的值
  /// 自己就变了）。非管理员带过去的 `auth=0` 让那一页只给看。
  void _editNotice(Conversation conversation) => context.push(
    '${AppRoutes.groupNotice}'
    '?id=${Uri.encodeComponent(conversation.id)}'
    '&auth=${_permissions.isAuth ? 1 : 0}',
  );

  /// 群管理（老端那个「点一下改内存、点保存才提交」的弹层）
  Future<void> _openGroupSettings(Conversation conversation) async {
    final i18n = ref.read(appI18nProvider);
    final setting = Map<String, dynamic>.from(
      asMap(conversation.extra['setting']),
    );
    bool flag(String key) => asText(setting[key]) == '1';
    int speakMode() => asInt(setting['nospeak'], 0);

    final saved = await showAppSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.white,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _sheetBar(
                  sheetContext,
                  title: i18n.t('group.management'),
                  onSave: () => Navigator.of(sheetContext).pop(true),
                ),
                _switchTile(
                  sheetContext,
                  label: i18n.t('group.ownerOrManage'),
                  hint: i18n.t('group.qihoansg'),
                  value: flag('manage'),
                  onChanged: (value) => setSheetState(
                    () => setting['manage'] = value ? '1' : '0',
                  ),
                ),
                _switchTile(
                  sheetContext,
                  label: i18n.t('group.allowUserToInvite'),
                  hint: i18n.t('group.quasdbnan'),
                  value: flag('invite'),
                  onChanged: (value) => setSheetState(
                    () => setting['invite'] = value ? '1' : '0',
                  ),
                ),
                _switchTile(
                  sheetContext,
                  label: i18n.t('group.viewHistoryMsg'),
                  hint: i18n.t('group.qyxiasbn'),
                  value: flag('history'),
                  onChanged: (value) => setSheetState(
                    () => setting['history'] = value ? '1' : '0',
                  ),
                ),
                _switchTile(
                  sheetContext,
                  label: i18n.t('group.allowToGroupUserAdd'),
                  hint: i18n.t('group.qwinqdqdqa'),
                  value: flag('profile'),
                  onChanged: (value) => setSheetState(
                    () => setting['profile'] = value ? '1' : '0',
                  ),
                ),
                const Divider(height: 1, color: AppColors.line),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: context.rpx(30),
                      vertical: context.rpx(10),
                    ),
                    child: Text(
                      i18n.t('group.noSpeak'),
                      style: TextStyle(
                        fontSize: context.rpx(26),
                        color: AppColors.text666,
                      ),
                    ),
                  ),
                ),
                RadioGroup<int>(
                  groupValue: speakMode(),
                  onChanged: (value) =>
                      setSheetState(() => setting['nospeak'] = '${value ?? 0}'),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (final mode in const <({int value, String label})>[
                        (value: 0, label: 'common.close'),
                        (value: 1, label: 'group.manageSpeak'),
                        (value: 2, label: 'group.ownerSpeak'),
                      ])
                        RadioListTile<int>(
                          value: mode.value,
                          activeColor: AppColors.wechatGreen,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: context.rpx(30),
                          ),
                          title: Text(
                            i18n.t(mode.label),
                            style: TextStyle(fontSize: context.rpx(28)),
                          ),
                        ),
                    ],
                  ),
                ),
                SizedBox(height: context.rpx(20)),
              ],
            ),
          ),
        ),
      ),
    );
    if (saved != true || !mounted) return;
    try {
      await _admin.saveSettings(widget.conversationId, setting);
    } on ApiException catch (error) {
      debugPrint('[聊天信息] 保存群管理失败：${error.message}');
      noticeBus.toast(error.message);
    }
  }

  // ------------------------------------------------------------- 动作

  Future<void> _addMembers() async {
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) =>
            GroupMemberPickerPage(groupId: widget.conversationId),
      ),
    );
    if (added == true) await _loadMembers();
  }

  void _openMembers() => context.push(
    '${AppRoutes.groupUser}'
    '?group_id=${Uri.encodeComponent(widget.conversationId)}',
  );

  /// 点成员/对方头像 → 用户详情页。
  ///
  /// `group_id` **只有群聊才带** —— 老端 `pages/message/detail.vue` 是
  /// `"/pages/contacts/detail?id="+item.id+ (this.is_group==1 ? "&group_id="+this.contact_id : '')`。
  ///
  /// 单聊的会话 id 就是**对方的 `user_id`**，把它当 `group_id` 发过去，服务端
  /// `Im::getUserInfo` 里那句 `explode('-', $group_id)[1]` 会踩 undefined offset，
  /// ThinkPHP 把 notice 抛成异常 → HTTP 500 → 客户端只看到「服务器繁忙，请稍后再试」
  /// （2026-09-21 真机上从单聊的聊天信息页点对方头像就是这么炸的）。
  void _openUser(String userId, {String groupId = ''}) => context.push(
    '${AppRoutes.contactsDetail}?id=${Uri.encodeComponent(userId)}'
    '${groupId.isEmpty ? '' : '&group_id=${Uri.encodeComponent(groupId)}'}',
  );

  /// 单聊顶栏那颗「＋」：拿这个人开个群（老端 `editUser(2)` 是同一个入口）
  void _createGroup() => context.push(
    '${AppRoutes.userSelection}'
    '?type=1&contact_id=${Uri.encodeComponent(widget.conversationId)}',
  );

  void _openRecord() => context.push(
    '${AppRoutes.chatRecord}'
    '?id=${Uri.encodeComponent(widget.conversationId)}',
  );

  /// 清空聊天记录。
  ///
  /// 单聊：**本机**清（服务端没有「只清我这边」的接口，所以本地记一份名单，
  /// 之后从服务端拉回来的旧消息会被丢掉，见 [ClearedChatsStore]）。
  /// 群聊：我是群主/管理员时照旧连服务端一起清（所有人的记录都删）。
  Future<void> _clearHistory(Conversation conversation) async {
    final i18n = ref.read(appI18nProvider);
    // 「连服务端一起清」只有群聊（`is_group == 1`）才有这个口子
    final clearForAll = _isGroup(conversation) && _permissions.isOwner;
    final confirmed = await _confirm(
      clearForAll
          ? i18n.t('group.clearMsgTips')
          : i18n.t('chat.clearRecordTips'),
    );
    if (confirmed != true || !mounted) return;
    try {
      final messages = await ref
          .read(messageRepositoryProvider)
          .cached(conversation.id, limit: ClearedChatsStore.maxIdsPerChat);
      await ClearedChatsStore.instance.mark(
        conversation.id,
        ids: <String>{
          for (final message in messages) ...<String>[
            if ((message.msgId ?? '').isNotEmpty) message.msgId!,
            if (message.serverId != null) '${message.serverId}',
          ],
        },
        lastSendTime: messages.isEmpty
            ? 0
            : messages
                  .map((Message item) => item.sendTime)
                  .reduce((a, b) => a > b ? a : b),
      );
      await ref.read(messageRepositoryProvider).deleteFor(conversation.id);
      await ref
          .read(conversationRepositoryProvider)
          .clearPreview(conversation.id);
      if (clearForAll) await _admin.clearMessages(conversation.id);
      if (!mounted) return;
      noticeBus.toast(i18n.t('common.clearOk'));
    } on ApiException catch (error) {
      debugPrint('[聊天信息] 清空记录失败：${error.message}');
      noticeBus.toast(error.message);
    }
  }

  /// 投诉（S13.1，2026-10-11 起是**真的提交**）。
  ///
  /// 以前这里是「只做表面功夫」——用户当时的要求就是点一下弹「提交成功」+ 一个勾
  /// （界面上有这个入口、但不写库）。后来回头补的这三件事之一就是它：点一下
  /// 要真的有人能看到。现在它提交到 `/enterprise/report/submit`，落到 `yu_report`，
  /// 后台有一页可以看、可以处理（`public/report-admin.html`）。
  /// 举报对象：单聊是**对面那个人**（会话 id 就是对方的 `user_id`），
  /// 群聊是**这个群本身**（`group_id`，服务端会校验我在这个群里）。
  Future<void> _complain(Conversation conversation) async {
    await showReportSheet(
      context,
      target: _isGroup(conversation)
          ? ReportTarget.group(
              groupId: conversation.id,
              groupName: conversation.displayName,
            )
          : ReportTarget.user(
              userId: conversation.id,
              userName: conversation.displayName,
              scene: ReportScene.chat,
            ),
      // 入口这一行叫「投诉」，弹层也跟着叫「投诉」（与关于页那条同一个口径）
      titleKey: 'chat.complaint',
    );
  }

  Future<void> _removeGroup() async {
    final i18n = ref.read(appI18nProvider);
    final isOwner = _permissions.isOwner;
    final label = isOwner
        ? i18n.t('group.delGroup')
        : i18n.t('group.exitGroup');
    // 老端就是这么拼的：`common.sure`（确定要）+ 动作 + `common.confirm`（吗？）
    final confirmed = await _confirm(
      '${i18n.t('common.sure')}$label${i18n.t('common.confirm')}',
    );
    if (confirmed != true || !mounted) return;
    try {
      if (isOwner) {
        await _admin.disband(widget.conversationId);
      } else {
        await _admin.quit(
          widget.conversationId,
          ref.read(sessionStoreProvider).userId,
        );
      }
      if (!mounted) return;
      // 老端是 reLaunch 回首页；新端回到消息 tab（会话已经删了）
      context.go(AppRoutes.home);
    } on ApiException catch (error) {
      debugPrint('[聊天信息] 退群失败：${error.message}');
      noticeBus.toast(error.message);
    }
  }

  /// 全站统一的微信白框确认框（清空聊天记录、退群这种）
  Future<bool?> _confirm(String content) =>
      showWeChatConfirm(context, message: content, danger: true);

  // -------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final conversation = ref
        .watch(_conversationProvider(widget.conversationId))
        .value;
    final isGroup = _isGroup(conversation);
    final isPeerChat = _isPeerChat(conversation);

    final body = Column(
      children: <Widget>[
        if (!widget.embedded) _navBar(context, i18n, isGroup: isGroup),
        Expanded(
          child: conversation == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  children: <Widget>[
                    if (isGroup) _membersCard(context, i18n, conversation),
                    // 只有好友会话才有「对方」那一格；系统通知/我的收藏两样都没有
                    if (isPeerChat) _peerCard(context, i18n, conversation),
                    if (isGroup) _groupCard(context, i18n, conversation),
                    _recordCard(context, i18n),
                    _switchCard(context, i18n, conversation),
                    _chatBackgroundCard(context, i18n),
                    _plainCard(
                      context,
                      children: <Widget>[
                        _row(
                          context,
                          label: i18n.t('message.clearRecord'),
                          onTap:
                              widget.onClearRecord ??
                              () => _clearHistory(conversation),
                        ),
                      ],
                    ),
                    // 投诉要有对象：单聊投诉对面的人、群投诉这个群。
                    // 「我的收藏」「系统通知」里投诉谁都不对（那两页没有对象，
                    // 服务端会回「没有指定举报对象」），所以那两页不给入口 ——
                    // 老端那两页有入口但点了什么都不会发生，那是假的。
                    if (isPeerChat || isGroup)
                      _plainCard(
                        context,
                        children: <Widget>[
                          _row(
                            context,
                            label: i18n.t('chat.complaint'),
                            onTap: () => _complain(conversation),
                          ),
                        ],
                      ),
                    if (isGroup)
                      _dangerCard(
                        context,
                        label: _permissions.isOwner
                            ? i18n.t('group.delGroup')
                            : i18n.t('group.exitGroup'),
                        onTap: _removeGroup,
                      ),
                    SizedBox(height: context.rpx(40)),
                  ],
                ),
        ),
      ],
    );

    // 桌面右栏面板里嵌着时：不要再套一层 [Scaffold]（面板自己给底色与左边界）
    if (widget.embedded) return body;
    return Scaffold(backgroundColor: AppColors.page, body: body);
  }

  /// 顶部导航栏：微信那档浅灰 + 一条细线，标题居中；群里右边还有一颗搜索
  Widget _navBar(BuildContext context, AppI18n i18n, {required bool isGroup}) {
    final title = isGroup && _memberCount > 0
        ? '${i18n.t('message.info')}($_memberCount)'
        : i18n.t('message.info');
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.navBar,
        border: Border(
          bottom: BorderSide(color: AppColors.navDivider, width: 0.5),
        ),
      ),
      height: context.statusBarHeight + context.customBarHeight,
      padding: EdgeInsets.only(top: context.statusBarHeight),
      child: Stack(
        children: <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              icon: const Icon(
                Icons.arrow_back_ios_new,
                size: 18,
                color: AppColors.text333,
              ),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
          Align(
            alignment: Alignment.center,
            child: Text(
              title,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: AppColors.text333,
              ),
            ),
          ),
          if (isGroup)
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                icon: const Icon(
                  Icons.search,
                  size: 22,
                  color: AppColors.text333,
                ),
                onPressed: _openRecord,
              ),
            ),
        ],
      ),
    );
  }

  /// 单聊顶上那块：对方头像（点进详情）+ 一颗虚线的「＋」（发起群聊）
  Widget _peerCard(
    BuildContext context,
    AppI18n i18n,
    Conversation conversation,
  ) => Container(
    color: AppColors.white,
    padding: EdgeInsets.symmetric(
      horizontal: context.rpx(20),
      vertical: context.rpx(24),
    ),
    child: Wrap(
      children: <Widget>[
        _memberTile(
          context,
          key: const ValueKey<String>('chatInfo-peer'),
          label: conversation.displayName.isEmpty
              ? conversation.id
              : conversation.displayName,
          avatar: conversation.avatar,
          onTap: () => _openUser(conversation.id),
        ),
        _memberTile(
          context,
          key: const ValueKey<String>('chatInfo-createGroup'),
          label: '',
          dashed: true,
          onTap: _createGroup,
          semantics: i18n.t('chat.createGroup'),
        ),
      ],
    ),
  );

  /// 群成员头像网格（老端那一片 `.user-info`）
  Widget _membersCard(
    BuildContext context,
    AppI18n i18n,
    Conversation conversation,
  ) {
    final inviteOn =
        asText(asMap(conversation.extra['setting'])['invite']) == '1';
    // 老端算的是「最多显示几个头像」：有权限 18、开放邀请 19、都没有 20
    final maxAvatars = _permissions.isAuth ? 18 : (inviteOn ? 19 : 20);
    final canAdd = _permissions.isAuth || inviteOn;

    return Container(
      color: AppColors.white,
      padding: EdgeInsets.symmetric(
        horizontal: context.rpx(20),
        vertical: context.rpx(24),
      ),
      child: Column(
        children: <Widget>[
          Wrap(
            children: <Widget>[
              for (final member in _members.take(maxAvatars))
                _memberTile(
                  context,
                  key: ValueKey<String>('chatInfo-member-${member.userId}'),
                  member: member,
                  label: member.name,
                  onTap: () => _openUser(
                    member.userId,
                    // 群成员：把群会话 id（`group-5`）带上，详情页里的「群内管理」要靠它
                    groupId: widget.conversationId,
                  ),
                ),
              if (canAdd)
                _memberTile(
                  context,
                  key: const ValueKey<String>('chatInfo-addMember'),
                  label: '',
                  dashed: true,
                  onTap: _addMembers,
                  semantics: i18n.t('group.addUser'),
                ),
              // WeChat 的「－」只有管理员看得见（老端也是 `isAuth`）
              if (_permissions.isAuth)
                _memberTile(
                  context,
                  key: const ValueKey<String>('chatInfo-removeMember'),
                  label: '',
                  dashed: true,
                  icon: Icons.remove,
                  onTap: _openMembers,
                  semantics: i18n.t('group.removeUser'),
                ),
            ],
          ),
          if (_loadingMembers)
            Padding(
              padding: EdgeInsets.all(context.rpx(10)),
              child: const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            InkWell(
              onTap: _openMembers,
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: context.rpx(16)),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(
                      '${i18n.t('group.viewAllUser')} $_memberCount ${i18n.t('group.per')}',
                      style: TextStyle(
                        fontSize: context.rpx(26),
                        color: AppColors.text666,
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: context.rpx(32),
                      color: AppColors.text999,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 网格里的一格：头像（或虚线方框）+ 下面一行小字
  Widget _memberTile(
    BuildContext context, {
    required String label,
    required VoidCallback onTap,
    Key? key,
    GroupMember? member,
    String avatar = '',
    bool dashed = false,
    IconData icon = Icons.add,
    String semantics = '',
  }) => Semantics(
    key: key,
    label: semantics,
    button: semantics.isNotEmpty,
    child: SizedBox(
      width: context.rpx(138),
      height: context.rpx(158),
      child: InkWell(
        onTap: onTap,
        child: Column(
          children: <Widget>[
            SizedBox(
              width: context.rpx(100),
              height: context.rpx(100),
              child: member != null
                  ? ContactAvatar(
                      url: member.avatar,
                      circle: false,
                      sizeRpx: 100,
                    )
                  : dashed
                  ? CustomPaint(
                      painter: const _DashedBorderPainter(
                        color: AppColors.text999,
                      ),
                      child: Icon(
                        icon,
                        size: context.rpx(46),
                        color: AppColors.text999,
                      ),
                    )
                  : ContactAvatar(url: avatar, circle: false, sizeRpx: 100),
            ),
            SizedBox(height: context.rpx(8)),
            if (label.isNotEmpty)
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.rpx(26),
                  color: AppColors.text666,
                ),
              ),
          ],
        ),
      ),
    ),
  );

  /// 群：群聊名称 / 群二维码 / 群公告 / 群管理
  ///
  /// ⚠️ 这里**不再有「群通话」那一行**（S6.22）：入口改成只在聊天页的「＋」面板
  /// （与单聊那颗「语音通话」同一个位置）—— 用户 2026-09-27 明确要求
  /// 「群聊资料页那一栏群通话删掉，加号面板已经有了」。
  /// 混两个人把关、一处入口，比两个地方都能进更不容易误触。
  Widget _groupCard(
    BuildContext context,
    AppI18n i18n,
    Conversation conversation,
  ) {
    final notice = asText(conversation.extra['notice']);
    // 老端群二维码那一行挂着 `v-if="contact.setting.invite"`：
    // 群已经关了加群入口时，这颗码扫了也进不来，不画
    final inviteOn =
        asText(asMap(conversation.extra['setting'])['invite']) == '1';
    return _plainCard(
      context,
      children: <Widget>[
        _row(
          context,
          label: i18n.t('group.groupName'),
          value: conversation.displayName,
          onTap: () => _renameGroup(conversation),
        ),
        if (inviteOn)
          _row(
            context,
            label: i18n.t('user.groupQrcode'),
            onTap: () => context.push(
              '${AppRoutes.qrcode}'
              '?group_id=${Uri.encodeComponent(conversation.id)}',
            ),
          ),
        _row(
          context,
          label: i18n.t('group.notice'),
          value: notice.isEmpty ? i18n.t('group.unNotice') : notice,
          onTap: () => _editNotice(conversation),
        ),
        if (_permissions.isAuth)
          _row(
            context,
            label: i18n.t('group.management'),
            onTap: () => _openGroupSettings(conversation),
          ),
      ],
    );
  }

  /// 免打扰 / 置顶
  Widget _switchCard(
    BuildContext context,
    AppI18n i18n,
    Conversation conversation,
  ) => _plainCard(
    context,
    children: <Widget>[
      _switchRow(
        context,
        label: i18n.t('group.noVoice'),
        // 老端那个 switch 是反的：打开 = is_notice 置 0（免打扰）
        value: conversation.muted,
        onChanged: (value) => _conversations.setNotice(
          conversation.id,
          value ? 0 : 1,
          isGroup: conversation.isGroup,
        ),
      ),
      _switchRow(
        context,
        label: i18n.t('chat.isTop'),
        value: conversation.isTop == 1,
        onChanged: (value) => _conversations.setTop(
          conversation.id,
          value ? 1 : 0,
          isGroup: conversation.isGroup,
        ),
      ),
    ],
  );

  /// 聊天背景（老端 `detail.vue` 里那一行 + `setBg` 弹层）。
  ///
  /// 背景是**设备本地偏好**（`chat-bg-info<会话 id>`），不跟随账号；
  /// 单聊群聊都有这一行（老端也是）。
  Widget _chatBackgroundCard(BuildContext context, AppI18n i18n) => _plainCard(
    context,
    children: <Widget>[
      _row(
        context,
        label: i18n.t('chat.setBg'),
        onTap: () => _openChatBackground(i18n),
      ),
    ],
  );

  /// 聊天背景的底部弹层：选图 / 预览 / 移除（老端那三样）
  Future<void> _openChatBackground(AppI18n i18n) async {
    final repo = ref.read(chatBackgroundRepositoryProvider);
    final id = widget.conversationId;

    await showAppSheet<void>(
      context: context,
      backgroundColor: AppColors.white,
      builder: (sheetContext) => SafeArea(
        child: ValueListenableBuilder<int>(
          valueListenable: repo.revision,
          builder: (context, _, _) {
            final background = repo.load(id);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  height: context.rpx(90),
                  alignment: Alignment.center,
                  child: Text(
                    i18n.t('chat.setBg'),
                    style: TextStyle(
                      fontSize: context.rpx(30),
                      color: AppColors.text333,
                    ),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  title: Text(i18n.t('chat.chooseBg')),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: AppColors.text999,
                  ),
                  onTap: () async {
                    Navigator.of(sheetContext).maybePop();
                    await _pickChatBackground(repo, i18n);
                  },
                ),
                if (background.image.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.all(context.rpx(30)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        // 老端这里也是一张 200px 宽的预览
                        SizedBox(
                          width: context.rpx(200),
                          height: context.rpx(200),
                          child: _backgroundPreview(background.image),
                        ),
                        SizedBox(height: context.rpx(20)),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: () async {
                              Navigator.of(sheetContext).maybePop();
                              await repo.remove(id);
                            },
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.red,
                            ),
                            child: Text(i18n.t('chat.removeBg')),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _pickChatBackground(
    ChatBackgroundRepository repo,
    AppI18n i18n,
  ) async {
    try {
      await repo.pickImage(widget.conversationId);
    } on Object catch (error) {
      // 选图失败（权限/文件读不了）只是没背景，不能影响这一页
      debugPrint('[聊天信息] 选背景失败：$error');
      noticeBus.toast(i18n.t('common.notAuth'));
    }
  }

  /// 弹层里那张预览：本地文件走 `Image.file`，`http` 的当网络图
  Widget _backgroundPreview(String path) => path.startsWith('http')
      ? Image.network(
          path,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stack) =>
              const ColoredBox(color: AppColors.page),
        )
      : Image.file(
          File(path),
          fit: BoxFit.cover,
          errorBuilder: (context, error, stack) =>
              const ColoredBox(color: AppColors.page),
        );

  /// 查找聊天记录（S5.4 的页面）
  Widget _recordCard(BuildContext context, AppI18n i18n) => _plainCard(
    context,
    children: <Widget>[
      _row(context, label: i18n.t('chat.searchMsg'), onTap: _openRecord),
    ],
  );

  /// 白卡片：上下留灰缝（微信那一条条白块）
  Widget _plainCard(BuildContext context, {required List<Widget> children}) =>
      Container(
        color: AppColors.white,
        margin: EdgeInsets.only(top: context.rpx(20)),
        child: Column(children: _withDividers(context, children)),
      );

  /// 卡片里的行之间加细线（微信那条**从文字左边开始**的线）
  List<Widget> _withDividers(BuildContext context, List<Widget> rows) {
    final children = <Widget>[];
    for (var index = 0; index < rows.length; index++) {
      if (index > 0) {
        children.add(
          Divider(
            height: 1,
            thickness: 0.5,
            indent: context.rpx(30),
            color: AppColors.line,
          ),
        );
      }
      children.add(rows[index]);
    }
    return children;
  }

  /// 右下角那颗红字按钮（微信「退出群聊」）
  Widget _dangerCard(
    BuildContext context, {
    required String label,
    required VoidCallback onTap,
  }) => Container(
    color: AppColors.white,
    margin: EdgeInsets.only(top: context.rpx(20)),
    child: InkWell(
      onTap: onTap,
      child: SizedBox(
        height: context.rpx(rowRpx),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: context.rpx(labelRpx),
              color: AppColors.red,
            ),
          ),
        ),
      ),
    ),
  );

  Widget _row(
    BuildContext context, {
    required String label,
    String value = '',
    VoidCallback? onTap,
  }) => InkWell(
    onTap: onTap,
    child: Container(
      height: context.rpx(rowRpx),
      padding: EdgeInsets.symmetric(horizontal: context.rpx(30)),
      child: Row(
        children: <Widget>[
          Text(
            label,
            style: TextStyle(
              fontSize: context.rpx(labelRpx),
              color: AppColors.text333,
            ),
          ),
          // 值占满剩下的宽度、右对齐，箭头就跟在它后面贴最右（微信那套）。
          // **别写成「Spacer + Flexible(值)」**：两个 flex 会把剩余空间对半分，
          // 箭头就停在屏幕中间了（用户 2026-09-21 反馈的就是这个）。
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: context.rpx(valueRpx),
                color: AppColors.text999,
              ),
            ),
          ),
          if (onTap != null) ...<Widget>[
            SizedBox(width: context.rpx(8)),
            Icon(
              Icons.chevron_right,
              size: context.rpx(40),
              color: AppColors.text999,
            ),
          ],
        ],
      ),
    ),
  );

  Widget _switchRow(
    BuildContext context, {
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => Container(
    height: context.rpx(rowRpx),
    padding: EdgeInsets.symmetric(horizontal: context.rpx(30)),
    child: Row(
      children: <Widget>[
        Text(
          label,
          style: TextStyle(
            fontSize: context.rpx(labelRpx),
            color: AppColors.text333,
          ),
        ),
        const Spacer(),
        Switch(
          value: value,
          onChanged: onChanged,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    ),
  );

  Widget _sheetBar(
    BuildContext context, {
    required String title,
    required VoidCallback onSave,
  }) => Row(
    children: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(ref.read(appI18nProvider).t('user.cancel')),
      ),
      const Spacer(),
      Text(
        title,
        style: TextStyle(fontSize: context.rpx(30), color: AppColors.text333),
      ),
      const Spacer(),
      TextButton(
        onPressed: onSave,
        child: Text(
          ref.read(appI18nProvider).t('common.save'),
          style: const TextStyle(color: AppColors.brand),
        ),
      ),
    ],
  );

  Widget _switchTile(
    BuildContext context, {
    required String label,
    required String hint,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) => Padding(
    padding: EdgeInsets.symmetric(
      horizontal: context.rpx(30),
      vertical: context.rpx(6),
    ),
    child: Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                label,
                style: TextStyle(
                  fontSize: context.rpx(28),
                  color: AppColors.text333,
                ),
              ),
              Text(
                hint,
                style: TextStyle(
                  fontSize: context.rpx(22),
                  color: AppColors.text999,
                ),
              ),
            ],
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    ),
  );
}

/// 虚线圆角方框（微信那两颗「＋ / －」）
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(6)),
      );
    // 一段实、一段空，绕一圈画出来就是虚线（Flutter 没有内置的虚线边框）
    const dash = 5.0;
    const gap = 4.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final end = (distance + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, end), paint);
        distance = end + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color;
}
