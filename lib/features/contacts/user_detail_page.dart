import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/net/api_exception.dart';
import '../../core/router/app_router.dart';
import '../../core/store/session_store.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/ui/permission_gate.dart';
import '../../core/ui/text_prompt_dialog.dart';
import '../../core/ui/wechat_dialog.dart';
import '../../core/util/json_value.dart';
import '../../data/model/global_config.dart';
import '../../data/model/user_detail.dart';
import '../../data/repo/contact_repository.dart';
import '../../data/repo/conversation_repository.dart';
import '../../data/repo/group_admin_repository.dart';
import '../../domain/call/call_controller.dart';
import '../../domain/call/call_signal.dart';
import '../../domain/chat/group_admin.dart';
import '../../domain/chat/user_group_manage.dart';
import '../../domain/contacts/user_detail_actions.dart';
import '../../domain/report/report_reasons.dart';
import '../chat/image_preview.dart';
import '../common/report_sheet.dart';
import '../group_call/group_call_session.dart' show groupCallBusyProvider;
import '../chat/widgets/group_member_sheets.dart';
import 'widgets/contact_avatar.dart';
import 'widgets/contacts_empty.dart';
import '../../core/ui/desktop_overlay.dart';

/// 用户详情（好友资料），对应老端 `pages/contacts/detail.vue`（S5.2）。
///
/// 观感照微信「好友资料」那一页（用户给的截图，1080×2316、3x → 1rpx = 1.44px）：
///
/// | 元素 | 微信实测 | 这里 |
/// |---|---|---|
/// | 顶栏 | **纯白、没有标题**（左上返回箭头 + 右上「⋯」）、没有底下那条灰线 | 同 |
/// | 头像 | 163×163px，左缩 48px | `ContactAvatar(sizeRpx: 113)` + 左缩 `rpx(32)` |
/// | 头像右 → 名字左 | 63px，名字与头像**顶对齐** | `rpx(44)` |
/// | 名字 | 57px 粗体 | `rpx(40)` w600 |
/// | 恩信号 / 地区 | 40px、`#666` 一档灰，行距 72px | `rpx(28)` + `rpx(10)` 间隔 |
/// | 「朋友资料」那一栏 | 标题 40px + 两行灰说明（39rpx 行距），右侧箭头 `#B2B2B2` | 见 `_friendDataRow` |
/// | 底部动作栏 | **居中「图标 + 蓝字」的一栏一项**：图标 55px、间距 27px、字 43px、行高 150px | `rpx(38)` / `rpx(19)` / `rpx(30)` / `rpx(104)` |
/// | 动作栏底色/分割线 | 白底，两栏之间那条**通栏** | 同 |
///
/// 与老端的差别（刻意的）：
/// * **不再显示邮箱、也不再显示 IP 那一行**（用户要求；地区那一行还在 —— 它是服务端
///   按上次登录 IP 查出来的归属地，不含 IP 本身，见 `Im::getUserInfo` 的 `location`）；
/// * 「备注」不再是详情页里一行弹框，而是进 **`FriendDataPage`**（那一页还有对方的
///   个性签名与性别）；
/// * **删除好友搬进右上角「⋯」菜单**（微信也在那儿）；
/// * 底部的「发消息 / 音视频通话 / 打电话 / 添加朋友」从实心按钮改成微信那种
///   居中的蓝色一栏一项；
/// * 「群内管理」块（S5.2b，从群成员进来时才有）原样保留。
///
/// 另外这里的动作按钮**都交给通话控制器/仓库**，入口自己不拼 URL：
/// 音视频通话由 `CallHost` 跟着通话会话开关通话页（老端是 `navigateTo`）。
class UserDetailPage extends ConsumerStatefulWidget {
  const UserDetailPage({
    super.key,
    required this.userId,
    this.groupId = '',
    this.embedded = false,
    this.onDeleted,
  });

  final String userId;

  /// 从群成员列表点进来时才有（群内管理块用，S5.3）
  final String groupId;

  /// 桌面通讯录**右栏**形态（2026-10-03）：不带自己的 `Scaffold` / 返回箭头，
  /// 资料内容直接摆在栏里（顶栏由三栏框架摆）—— 换人时不重建页面，
  /// 由 [didUpdateWidget] 重拉。窄窗 / 手机上永远是 false，版式一点不变。
  final bool embedded;

  /// 右栏里把好友删掉之后干什么（整页形态是 `context.pop()`，右栏没有页面可 pop，
  /// 交给外面把选中那行清掉）
  final VoidCallback? onDeleted;

  @override
  ConsumerState<UserDetailPage> createState() => _UserDetailPageState();
}

class _UserDetailPageState extends ConsumerState<UserDetailPage> {
  UserDetail? _detail;
  bool _loading = true;
  bool _failed = false;

  /// 失败原因（服务端那句话或网络错误文案）。空着就按「暂无数据」显示。
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(covariant UserDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 桌面右栏里换人是在同一个 State 上换 `userId`（同一棵子树、页面不重建），
    // 不重拉就会一直显示上一个人的资料。
    if (widget.userId != oldWidget.userId ||
        widget.groupId != oldWidget.groupId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_load());
      });
    }
  }

  Future<void> _load() async {
    // id 空的时候**不发请求**：`getUserInfo` 拿不到 `user_id` 时服务端的
    // `User::find(null)` 会抛 InvalidArgumentException → HTTP 500 →
    // 界面上就是那句莫名其妙的「服务器繁忙」。这里直接短路。
    if (widget.userId.isEmpty) {
      setState(() {
        _loading = false;
        _failed = true;
        _errorMessage = '';
      });
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
      _errorMessage = '';
    });
    try {
      final detail = await ref
          .read(contactRepositoryProvider)
          .userDetail(widget.userId, groupId: widget.groupId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } on ApiException catch (error) {
      debugPrint('[用户详情] 加载失败：$error');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
        _errorMessage = error.message;
      });
    } on Object catch (error) {
      debugPrint('[用户详情] 加载失败：$error');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
        _errorMessage = '';
      });
    }
  }

  /// 弹一个单行输入框（老端那些 `showModal({editable: true})`）
  Future<String?> _prompt({required String title, String initial = ''}) =>
      showTextPrompt(context, title: title, initial: initial);

  Future<void> _previewAvatar(UserDetail detail) async {
    if (detail.avatar.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) =>
            ImagePreviewPage(urls: <String>[detail.avatar], index: 0),
      ),
    );
  }

  /// 发消息：老端先 `appendContacts(detail.contactInfo)` 再进聊天页
  Future<void> _sendMessage(UserDetail detail) async {
    if (detail.userId.isEmpty) return;
    await ref
        .read(conversationRepositoryProvider)
        .ensureFromContact(detail.toContact());
    if (!mounted) return;
    context.push('${AppRoutes.chat}?id=${Uri.encodeComponent(detail.userId)}');
  }

  /// 打电话：老端 `uni.makePhoneCall`，Flutter 用 `tel:` 唤起拨号盘
  ///
  /// 提醒：`getUserInfo` 返回的 `account` 是**打过码的**（`138******00`），
  /// 老端那个手机号正则对它永远不成立 —— 所以这颗按钮在真机上基本不会出现，
  /// 逻辑留着是为了以后服务端不打码时不丢功能。
  Future<void> _callPhone(UserDetail detail) async {
    final uri = Uri(scheme: 'tel', path: detail.account.trim());
    try {
      final launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        debugPrint('[用户详情] 拨号盘没打开：$uri');
      }
    } on Object catch (error) {
      debugPrint('[用户详情] 拨号失败：$error');
      if (mounted) {
        noticeBus.toast(ref.read(appI18nProvider).t('common.notAuth'));
      }
    }
  }

  /// 音视频通话（老端那个底部弹层）
  Future<void> _openCallSheet(UserDetail detail) async {
    final i18n = ref.read(appI18nProvider);
    final isVideo = await showAppSheet<bool>(
      context: context,
      backgroundColor: AppColors.white,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _sheetItem(
              sheetContext,
              label: i18n.t('message.voiceCall'),
              onTap: () => Navigator.of(sheetContext).pop(false),
            ),
            const Divider(height: 1, color: AppColors.line),
            _sheetItem(
              sheetContext,
              label: i18n.t('message.videoCall'),
              onTap: () => Navigator.of(sheetContext).pop(true),
            ),
            const Divider(height: 1, color: AppColors.line),
            _sheetItem(
              sheetContext,
              label: i18n.t('user.cancel'),
              color: AppColors.red,
              onTap: () => Navigator.of(sheetContext).pop(),
            ),
          ],
        ),
      ),
    );
    if (isVideo == null || !mounted) return;
    await _startCall(detail, isVideo: isVideo);
  }

  /// 起一通电话（S6.3）。
  ///
  /// 老端是 `navigateTo('/pages/message/call?msg_id=&type=&status=1&id=&name=&avatar=')`，
  /// 新端把对端与类型直接交给通话控制器：通话页由 `CallHost` 自动打开。
  /// 三道拦截（没开 webrtc / 关了私聊 / 已在通话中）在状态机里。
  Future<void> _startCall(UserDetail detail, {required bool isVideo}) async {
    // 群语音在跑也不给拨（S6.20）：两套通话都要麦克风，而前台服务只有一份。
    // 与聊天页 + 面板那颗钮同一个口径（两边都得拦，不然从这边能绕过去）。
    if (ref.read(groupCallBusyProvider)) {
      noticeBus.toast(ref.read(appI18nProvider).t('group.callBusy'));
      return;
    }
    // 拨号前先确保麦克风（视频再确保摄像头），与聊天页那个入口同一个口径
    if (!await ensureCallPermissions(context, ref, video: isVideo)) return;
    if (!mounted) return;
    // 「来电全屏显示」没开时提醒一句（S12.8）：与聊天页那个入口同一个口径
    await remindFullScreenBeforeCall(context, ref);
    if (!mounted) return;
    final config = ref.read(sessionStoreProvider).config;
    await ref
        .read(callControllerProvider)
        .start(
          peerId: detail.userId,
          peerName: detail.realName,
          peerAvatar: detail.avatar,
          type: isVideo ? CallType.video : CallType.voice,
          webrtcEnabled: config.webrtcEnabled,
          simpleChatEnabled: config.chatInfo.simpleChat == 1,
        );
  }

  Future<void> _addFriend(UserDetail detail) async {
    final i18n = ref.read(appI18nProvider);
    final remark = await _prompt(title: i18n.t('friend.inputVerify'));
    if (remark == null) return;
    if (remark.isEmpty) {
      // 老端这里弹的是「请输入备注！」（`friend.inputRemark`），照抄
      noticeBus.toast(i18n.t('friend.inputRemark'));
      return;
    }
    try {
      final message = await ref
          .read(contactRepositoryProvider)
          .addFriend(userId: detail.userId, remark: remark);
      if (message.isNotEmpty) noticeBus.toast(message);
    } on ApiException catch (error) {
      debugPrint('[用户详情] 加好友失败：${error.message}');
      noticeBus.toast(error.message);
    }
  }

  /// 进「朋友资料」（备注名 / 个性签名 / 性别）。
  /// 那一页改过东西会 `pop(true)`，这里就重拉一次详情（备注行、名字都要变）。
  Future<void> _openFriendData(UserDetail detail) async {
    final changed = await context.push<bool>(
      '${AppRoutes.contactsFriendData}?id=${Uri.encodeComponent(detail.userId)}',
    );
    if (changed == true && mounted) await _load();
  }

  /// 禁言 / 取消禁言对方（弹层与群成员管理页共用）
  Future<void> _muteGroupMember(UserDetail detail) async {
    if (widget.groupId.isEmpty) return;
    final i18n = ref.read(appI18nProvider);
    final info = asMap(detail.groupInfo['userInfo']);
    final result = await showNoSpeakSheet(
      context,
      i18n,
      days: asInt(info['no_speak_day'], 0),
      muted: noSpeakExpiryLabel(asInt(info['no_speak_time'], 0)).isNotEmpty,
    );
    if (result == null || !mounted) return;
    try {
      await ref
          .read(groupAdminRepositoryProvider)
          .muteMember(
            groupId: widget.groupId,
            userId: detail.userId,
            choice: result.choice,
          );
      // 服务端回执里没有详情，重新拉一次（禁言文案要变）
      await _load();
    } on ApiException catch (error) {
      debugPrint('[用户详情] 禁言失败：${error.message}');
      noticeBus.toast(error.message);
    }
  }

  /// 设 / 撤管理员（老端 `setManage(rol)`：`rol==2 ? 3 : 2`）
  Future<void> _toggleGroupManager(UserDetail detail) async {
    if (widget.groupId.isEmpty) return;
    final i18n = ref.read(appI18nProvider);
    final targetIsManager =
        asInt(asMap(detail.groupInfo['userInfo'])['role'], 0) ==
        groupRoleManager;
    final confirmed = await showGroupConfirm(
      context,
      i18n,
      targetIsManager
          ? i18n.t('group.cancelManageTips')
          : i18n.t('group.setManageTips'),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(groupAdminRepositoryProvider)
          .setManager(
            groupId: widget.groupId,
            userId: detail.userId,
            role: targetIsManager ? groupRoleMember : groupRoleManager,
          );
      await _load();
    } on ApiException catch (error) {
      debugPrint('[用户详情] 设置管理员失败：${error.message}');
      noticeBus.toast(error.message);
    }
  }

  /// 从群里移出对方（老端移完 `uni.navigateBack()`，这里就地返回）
  Future<void> _removeFromGroup(UserDetail detail) async {
    if (widget.groupId.isEmpty) return;
    final i18n = ref.read(appI18nProvider);
    final isBlack = await showRemoveMemberSheet(context, i18n);
    if (isBlack == null || !mounted) return;
    try {
      await ref
          .read(groupAdminRepositoryProvider)
          .removeMember(
            groupId: widget.groupId,
            userId: detail.userId,
            isBlack: isBlack,
          );
      if (!mounted) return;
      context.pop();
    } on ApiException catch (error) {
      debugPrint('[用户详情] 移出群聊失败：${error.message}');
      noticeBus.toast(error.message);
    }
  }

  /// 删除好友（老端那个带「加入黑名单」开关的底部弹层）
  Future<void> _deleteFriend(UserDetail detail) async {
    final i18n = ref.read(appI18nProvider);
    var isBlack = false;
    final confirmed = await showAppSheet<bool>(
      context: context,
      backgroundColor: AppColors.white,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(height: context.rpx(30)),
              Icon(
                Icons.error_outline,
                size: context.rpx(60),
                color: AppColors.orange,
              ),
              SizedBox(height: context.rpx(10)),
              Text(
                i18n.t('friend.comfirmDel'),
                style: TextStyle(fontSize: context.rpx(28)),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Text(
                    i18n.t('common.joinBlackList'),
                    style: TextStyle(fontSize: context.rpx(26)),
                  ),
                  Switch(
                    value: isBlack,
                    onChanged: (value) => setSheetState(() => isBlack = value),
                  ),
                ],
              ),
              SizedBox(height: context.rpx(10)),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(),
                    child: Text(i18n.t('common.cancel')),
                  ),
                  SizedBox(width: context.rpx(40)),
                  TextButton(
                    onPressed: () => Navigator.of(sheetContext).pop(true),
                    child: Text(
                      i18n.t('common.ok'),
                      style: const TextStyle(color: AppColors.green),
                    ),
                  ),
                ],
              ),
              SizedBox(height: context.rpx(20)),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    await _doDeleteFriend(detail, isBlack: isBlack);
  }

  /// 加入黑名单（S13.2，2026-10-11）。
  ///
  /// 以前「拉黑」只是「删除好友」那个弹层里的一个开关（`common.joinBlackList`）：
  /// 想拉黑一个人，得先点删除、再在一个弹层里找到那个开关 —— 相当于没有这个功能。
  /// 现在它是「⋯」菜单里独立的一项（与微信「朋友资料 › ⋯ › 加入黑名单」同一个位置）。
  ///
  /// **服务端语义一点没变**（`Friend::del` 的 `is_black=1`）：删掉好友关系、
  /// 双方聊天记录一起删、并拦下对方再加我（他那行 `status=3` 会被 `add()` 认出来）。
  /// 所以这里的确认文案必须把话说全 —— 只写「加入黑名单」会让人以为好友还在。
  Future<void> _blacklist(UserDetail detail) async {
    final i18n = ref.read(appI18nProvider);
    final confirmed = await showWeChatConfirm(
      context,
      message: i18n.t('user.blacklistConfirm'),
      danger: true,
    );
    if (confirmed != true || !mounted) return;
    await _doDeleteFriend(detail, isBlack: true);
  }

  /// 投诉这个人（S13.1）：资料页就能报，不用先进聊天再长按
  Future<void> _report(UserDetail detail) async {
    await showReportSheet(
      context,
      target: ReportTarget.user(
        userId: detail.userId,
        userName: detail.displayName,
        scene: ReportScene.profile,
      ),
    );
  }

  /// 删好友 / 拉黑的共同尾巴（两处只差一个 `is_black`）
  Future<void> _doDeleteFriend(
    UserDetail detail, {
    required bool isBlack,
  }) async {
    try {
      final message = await ref
          .read(contactRepositoryProvider)
          .deleteFriend(detail.userId, isBlack: isBlack);
      if (message.isNotEmpty) noticeBus.toast(message);
      if (!mounted) return;
      // 老端删完是 reLaunch 回消息页；新端整页形态就地返回（通讯录里那行已经没了）。
      // 右栏形态没有页面可 pop（pop 会把主界面弹掉），交给外面把选中清掉。
      if (widget.embedded) {
        widget.onDeleted?.call();
      } else {
        context.pop();
      }
    } on ApiException catch (error) {
      debugPrint('[用户详情] 删好友失败：${error.message}');
      noticeBus.toast(error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final myId = ref.watch(
      sessionStoreProvider.select((state) => state.userId),
    );
    final config = ref.watch(
      sessionStoreProvider.select((state) => state.config),
    );
    final detail = _detail;
    final actions = (detail == null || detail.userId.isEmpty)
        ? null
        : userDetailActionsOf(
            detail: detail,
            myUserId: myId,
            runMode: config.sysInfo.runMode,
            webrtcEnabled: config.chatInfo.webrtc == 1,
            simpleChatEnabled: config.chatInfo.simpleChat == 1,
          );

    final body = _body(
      context,
      i18n,
      myId: myId,
      config: config,
      actions: actions,
    );
    // 桌面通讯录右栏（[embedded]）：没有自己的顶栏（那一栏由三栏框架摆），
    // 但把「⋯」留在最上面 —— 删除好友那颗钮不能因为换了摆法就没了。
    if (widget.embedded) {
      final showMenu =
          detail != null && actions != null && actions.deleteFriend;
      return ColoredBox(
        color: AppColors.page,
        child: Column(
          children: <Widget>[
            if (showMenu) _embeddedBar(context, i18n, detail, actions),
            Expanded(child: body),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(
        // 微信这一页是**纯白顶栏 + 没有标题**（只有左上返回箭头与右上「⋯」）
        backgroundColor: AppColors.white,
        shape: const Border(),
        title: const SizedBox.shrink(),
        actions: <Widget>[
          // 「⋯」里目前只有「删除好友」（微信那一栏也在这儿）
          if (actions != null && actions.deleteFriend)
            _moreMenu(context, i18n, detail!, actions),
        ],
      ),
      body: body,
    );
  }

  /// 右栏形态顶上那条：白底、右下角一颗「⋯」（与整页那份 AppBar 的 actions 同一颗）
  Widget _embeddedBar(
    BuildContext context,
    AppI18n i18n,
    UserDetail detail,
    UserDetailActions actions,
  ) => Container(
    height: context.rpx(88),
    padding: EdgeInsets.symmetric(horizontal: context.rpx(8)),
    decoration: const BoxDecoration(
      color: AppColors.white,
      border: Border(bottom: BorderSide(color: AppColors.line, width: 0.5)),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: <Widget>[_moreMenu(context, i18n, detail, actions)],
    ),
  );

  /// 右上角「⋯」：微信那个**深色小卡片**
  Widget _moreMenu(
    BuildContext context,
    AppI18n i18n,
    UserDetail detail,
    UserDetailActions actions,
  ) => PopupMenuButton<String>(
    tooltip: '',
    icon: Icon(Icons.more_horiz, size: 24, color: AppColors.text000),
    color: AppColors.menuDark,
    elevation: 8,
    position: PopupMenuPosition.under,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(context.rpx(12)),
    ),
    onSelected: (value) {
      if (value == _menuDelete) {
        unawaited(_deleteFriend(detail));
      } else if (value == _menuBlacklist) {
        unawaited(_blacklist(detail));
      } else if (value == _menuReport) {
        unawaited(_report(detail));
      }
    },
    itemBuilder: (menuContext) => <PopupMenuEntry<String>>[
      // 从轻到重：投诉 → 加入黑名单 → 删除好友
      _menuItem(context, i18n.t('chat.complaint'), _menuReport),
      _menuItem(context, i18n.t('common.joinBlackList'), _menuBlacklist),
      _menuItem(context, i18n.t('user.delFriend'), _menuDelete),
    ],
  );

  /// 菜单里的一项（微信那个深色小卡片上的一行）
  PopupMenuItem<String> _menuItem(
    BuildContext context,
    String label,
    String value,
  ) => PopupMenuItem<String>(
    value: value,
    height: context.rpx(96),
    child: SizedBox(
      width: context.rpx(300),
      child: Text(
        label,
        style: const TextStyle(fontSize: 15, color: AppColors.white),
      ),
    ),
  );

  static const String _menuDelete = 'delete';
  static const String _menuBlacklist = 'blacklist';
  static const String _menuReport = 'report';

  Widget _body(
    BuildContext context,
    AppI18n i18n, {
    required String myId,
    required GlobalConfig config,
    required UserDetailActions? actions,
  }) {
    final detail = _detail;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_failed || detail == null || actions == null) {
      // 老端这里就是一句「暂无数据」，什么都不说；服务端那句原因直接给用户看，
      // 外带一个「重试」——否则网络抖一下就只能退出去重进。
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ContactsEmpty(
              text: _errorMessage.isEmpty
                  ? i18n.t('common.noData')
                  : _errorMessage,
            ),
            if (!_loading) ...<Widget>[
              SizedBox(height: context.rpx(24)),
              TextButton(
                onPressed: () => unawaited(_load()),
                child: Text(i18n.t('common.retry')),
              ),
            ],
          ],
        ),
      );
    }

    // 朋友资料那一栏只对「好友」显示（老端那个 `showRemark`，runMode 2 = 有好友体系）
    final showFriendData =
        config.sysInfo.runMode == 2 && detail.isFriend && detail.userId != myId;

    return ListView(
      children: <Widget>[
        _header(context, i18n, detail),
        if (showFriendData) _friendDataRow(context, i18n, detail),
        ..._groupManageSection(context, i18n, detail, myId: myId),
        ..._actionRows(context, i18n, actions, detail),
        SizedBox(height: context.rpx(40)),
      ],
    );
  }

  /// 顶部白卡片：头像 + 名字 + 恩信号 + 地区（微信那张卡就这三样）
  Widget _header(BuildContext context, AppI18n i18n, UserDetail detail) =>
      Container(
        color: AppColors.white,
        padding: EdgeInsets.fromLTRB(
          context.rpx(32),
          context.rpx(34),
          context.rpx(30),
          context.rpx(45),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            GestureDetector(
              onTap: () => _previewAvatar(detail),
              child: ContactAvatar(
                url: detail.avatar,
                circle: true,
                sizeRpx: 113,
              ),
            ),
            SizedBox(width: context.rpx(44)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // 设过备注就显示备注（微信也是：资料页顶上那个名字就是备注名）
                  Text(
                    detail.displayName,
                    style: TextStyle(
                      fontSize: context.rpx(40),
                      fontWeight: FontWeight.w600,
                      color: AppColors.text000,
                    ),
                  ),
                  // 服务端把账号打码了（`138******00`），微信也就是这么显示的
                  if (detail.account.isNotEmpty) ...<Widget>[
                    SizedBox(height: context.rpx(10)),
                    Text(
                      '${i18n.t('user.wechatId')}：${detail.account}',
                      style: TextStyle(
                        fontSize: context.rpx(28),
                        color: AppColors.text666,
                      ),
                    ),
                  ],
                  if (detail.location.isNotEmpty) ...<Widget>[
                    SizedBox(height: context.rpx(10)),
                    Text(
                      '${i18n.t('user.region')}：${detail.location}',
                      style: TextStyle(
                        fontSize: context.rpx(28),
                        color: AppColors.text666,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );

  /// 「朋友资料」那一栏：标题 + 一行灰说明 + 右侧箭头（微信那一格是这么排的）
  Widget _friendDataRow(
    BuildContext context,
    AppI18n i18n,
    UserDetail detail,
  ) => InkWell(
    onTap: () => unawaited(_openFriendData(detail)),
    child: Container(
      color: AppColors.white,
      padding: EdgeInsets.fromLTRB(
        context.rpx(32),
        context.rpx(38),
        context.rpx(30),
        context.rpx(38),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  i18n.t('user.friendData'),
                  style: TextStyle(
                    fontSize: context.rpx(28),
                    color: AppColors.text000,
                  ),
                ),
                SizedBox(height: context.rpx(20)),
                Text(
                  i18n.t('user.friendDataHint'),
                  style: TextStyle(
                    fontSize: context.rpx(24),
                    height: 1.6,
                    color: AppColors.text999,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right,
            size: context.rpx(36),
            color: AppColors.chevron,
          ),
        ],
      ),
    ),
  );

  /// 底部「图标 + 蓝字」的一栏一项（微信那一块是**居中**排的，不是按钮）
  List<Widget> _actionRows(
    BuildContext context,
    AppI18n i18n,
    UserDetailActions actions,
    UserDetail detail,
  ) {
    final rows = <Widget>[
      if (actions.sendMessage)
        _actionRow(
          context,
          label: i18n.t('message.send'),
          icon: Icons.chat_bubble_outline,
          onTap: () => unawaited(_sendMessage(detail)),
        ),
      if (actions.webrtc)
        _actionRow(
          context,
          label: i18n.t('common.webrtc'),
          icon: Icons.videocam_outlined,
          onTap: () => unawaited(_openCallSheet(detail)),
        ),
      if (actions.callPhone)
        _actionRow(
          context,
          label: i18n.t('message.call'),
          icon: Icons.call_outlined,
          onTap: () => unawaited(_callPhone(detail)),
        ),
      if (actions.addFriend)
        _actionRow(
          context,
          label: i18n.t('user.addFriend'),
          icon: Icons.person_add_alt_outlined,
          onTap: () => unawaited(_addFriend(detail)),
        ),
    ];
    if (rows.isEmpty) return const <Widget>[];
    return <Widget>[
      SizedBox(height: context.rpx(16)),
      for (var i = 0; i < rows.length; i++) ...<Widget>[
        rows[i],
        // 微信这两栏之间那条线是**通栏**的（实测 x 0..1079）
        if (i != rows.length - 1)
          Container(height: 0.5, color: AppColors.rowDivider),
      ],
    ];
  }

  Widget _actionRow(
    BuildContext context, {
    required String label,
    required IconData icon,
    required VoidCallback onTap,
  }) => InkWell(
    onTap: onTap,
    child: Container(
      height: context.rpx(104),
      color: AppColors.white,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: context.rpx(38), color: AppColors.wechatLinkBlue),
          SizedBox(width: context.rpx(19)),
          Text(
            label,
            style: TextStyle(
              fontSize: context.rpx(30),
              color: AppColors.wechatLinkBlue,
            ),
          ),
        ],
      ),
    ),
  );

  /// 「群内管理」块（S5.2b，老端 `detail.vue` 55～94 行）。
  ///
  /// 不满足显示条件时返回空列表；条件与文案全在 [userGroupManageBlockOf] 里定。
  ///
  /// 多一道**没有 `group_id` 就不显示**：这里的三个动作都要带群 id 才能发请求，
  /// 而老端只看了 `groupInfo`（它从通讯录进来时 `group_id` 是空的，动作会打在空群上）。
  List<Widget> _groupManageSection(
    BuildContext context,
    AppI18n i18n,
    UserDetail detail, {
    required String myId,
  }) {
    if (widget.groupId.isEmpty) return const <Widget>[];
    final block = userGroupManageBlockOf(
      groupInfo: detail.groupInfo,
      targetUserId: detail.userId,
      myUserId: myId,
    );
    if (block == null) return const <Widget>[];
    return <Widget>[
      SizedBox(height: context.rpx(20)),
      // 小标题（老端那个 `uni-section`：标题 + 右侧副标题）
      Container(
        color: AppColors.white,
        padding: EdgeInsets.symmetric(
          horizontal: context.rpx(30),
          vertical: context.rpx(20),
        ),
        child: Row(
          children: <Widget>[
            Container(
              width: context.rpx(8),
              height: context.rpx(32),
              margin: EdgeInsets.only(right: context.rpx(16)),
              decoration: BoxDecoration(
                color: AppColors.green,
                borderRadius: BorderRadius.circular(context.rpx(4)),
              ),
            ),
            Expanded(
              child: Text(
                block.groupName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.rpx(30),
                  color: AppColors.text333,
                ),
              ),
            ),
            Text(
              i18n.t('group.managementUser'),
              style: TextStyle(
                fontSize: context.rpx(24),
                color: AppColors.text999,
              ),
            ),
          ],
        ),
      ),
      if (block.roleLabelKeyOrEmpty.isNotEmpty)
        _groupRow(
          context,
          label: i18n.t('group.userRole'),
          value: i18n.t(block.roleLabelKeyOrEmpty),
          valueColor: _roleColor(block.targetRole),
        ),
      _groupRow(
        context,
        label: i18n.t('group.setNoSpeak'),
        value: block.mutedUntil.isEmpty
            ? ''
            : '${i18n.t('group.noSpeakTo')}：${block.mutedUntil}',
        valueColor: AppColors.red,
        showArrow: true,
        onTap: () => _muteGroupMember(detail),
      ),
      if (block.canToggleManager)
        _groupRow(
          context,
          label: block.targetIsManager
              ? i18n.t('group.cancelManage')
              : i18n.t('group.setManage'),
          showArrow: true,
          onTap: () => _toggleGroupManager(detail),
        ),
      _groupRow(
        context,
        label: i18n.t('group.removeUser'),
        labelColor: AppColors.red,
        showArrow: true,
        onTap: () => _removeFromGroup(detail),
      ),
    ];
  }

  Color _roleColor(int role) {
    if (role == groupRoleOwner) return AppColors.red;
    if (role == groupRoleManager) return AppColors.orange;
    return AppColors.text999;
  }

  /// 「群内管理」块里的一行（老端那个 `cu-item`：左边文字，右边说明 + 箭头）
  Widget _groupRow(
    BuildContext context, {
    required String label,
    String value = '',
    Color valueColor = AppColors.text999,
    Color labelColor = AppColors.text333,
    bool showArrow = false,
    VoidCallback? onTap,
  }) => InkWell(
    onTap: onTap,
    child: Container(
      height: context.rpx(100),
      padding: EdgeInsets.symmetric(horizontal: context.rpx(30)),
      color: AppColors.white,
      child: Row(
        children: <Widget>[
          Text(
            label,
            style: TextStyle(fontSize: context.rpx(30), color: labelColor),
          ),
          const Spacer(),
          if (value.isNotEmpty)
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: context.rpx(26), color: valueColor),
              ),
            ),
          if (showArrow)
            Icon(
              Icons.chevron_right,
              size: context.rpx(36),
              color: AppColors.text999,
            ),
        ],
      ),
    ),
  );

  Widget _sheetItem(
    BuildContext context, {
    required String label,
    required VoidCallback onTap,
    Color color = AppColors.text333,
  }) => InkWell(
    onTap: onTap,
    child: Container(
      height: context.rpx(100),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(fontSize: context.rpx(30), color: color),
      ),
    ),
  );
}
