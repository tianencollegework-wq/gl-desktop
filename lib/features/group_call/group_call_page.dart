import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show MediaStream, RTCVideoViewObjectFit;
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/notify/message_notification_presenter.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/permission_gate.dart';
import '../../domain/call/call_duration.dart';
import '../../domain/group_call/sfu_room.dart';
import '../call/call_colors.dart';
import '../call/screen_share_picker.dart';
import '../call/widgets/call_round_button.dart';
import '../call/widgets/call_video_view.dart';
import '../contacts/widgets/contact_avatar.dart';
import 'group_call_controller.dart';
import 'group_call_diagnostics_sheet.dart';
import 'group_call_session.dart';
import 'group_call_sync.dart' show groupCallPresenceProvider;
import '../../core/platform/desktop_shell.dart';
import '../../core/ui/desktop_overlay.dart';

/// 群通话页（语音 + 一个人共享屏幕）。
///
/// 界面分三块，从上到下：
/// * **主区域**：有人在共享屏幕就是那块画面；否则有人说话就是「说话人 + 其他人一条
///   条排在下面」；都没人说话就是头像墙（人数决定列数）；
/// * **底部**：成员 / 麦克风 / 共享屏幕 / 挂断 四颗钮（共享屏那颗在不支持的设备上
///   不画 —— 画一颗点不动的钮比不画更糟）；
/// * **成员面板**（点「成员」弹出来）：通话中的人 + 还没进来的人，各带状态。
///
/// 进来与退出的路径：入口在**群资料页**与**聊天页的「＋」面板**（与私聊的
/// 「语音通话」同一个位置），路由带群会话 id 与群名；退出由这里自己 `pop`
/// （1:1 那边是 `CallHost` 统一开关，群通话是"点进去才有"，没有来电那套推送叫醒）。
///
/// ⚠️ 这一页**不是**这一通话的宿主（S6.17 起）：房间、保活、对账都在
/// `GroupCallSession`（常驻）里，这里只是「看着它」——**点返回键只关页面，
/// 通话照旧开着**（小窗接手），要真结束只有那颗红挂断。
///
/// 屏幕共享期间前端服务类型要跟着升/降、投屏授权要先拿 —— 那三步顺序在
/// [GroupCallController.toggleScreenShare] 里（Android 14 的硬要求）。
class GroupCallPage extends ConsumerStatefulWidget {
  const GroupCallPage({
    super.key,
    required this.conversationId,
    required this.name,
  });

  /// 群会话 id（`group-5`）
  final String conversationId;

  /// 群名（顶部标题，也是保活通知里那句「与 {name} 语音通话中」）
  final String name;

  @override
  ConsumerState<GroupCallPage> createState() => _GroupCallPageState();
}

class _GroupCallPageState extends ConsumerState<GroupCallPage> {
  /// 常驻会话的登记处（在 `initState` 里取一次：`dispose` 里还要用它）
  late final GroupCallSessionHost _host = ref.read(groupCallSessionProvider);

  /// 通话计时（时间本身在会话里，这里只负责每秒重画一次）
  Timer? _ticker;

  /// 正在挂断（防连点两次）
  bool _leaving = false;

  /// 这一页真的看着过一道通话（`openPage` 回来之后置上）。
  ///
  /// 拿它区分两种"会话是 null"：刚 push 进来（会话还没建好，要留在页面上
  /// 画「正在加入」）与**这一通被外面收掉了**（页面必须自己退出去）。
  bool _hadSession = false;

  /// 这一页正看着的那一通（由登记处推着变，见下）
  GroupCallSession? get _session => _host.sessionFor(widget.conversationId);

  @override
  void initState() {
    super.initState();
    // 进来 = 打开这一通（已经在通话里就是复用，见 `openPage`）：
    // 这里**不 await**，界面先按「正在加入」画着，状态从会话自己长出来
    unawaited(_open());
    // 人已经进来了：把那条「群里有人开语音」的邀请通知收掉（S6.14）。
    // 两条路都会走到这里：点通知进来（那条已经收过一次，这里是幂等），
    // 以及在群资料页点「群通话」进来（那时通知还挂着——人都在里面了，
    // 通知栏还响着「快进来」就说不过去了）。收一条不存在的通知是空操作。
    unawaited(
      ref.read(messageNotificationPresenterProvider).cancelGroupCallRing(),
    );
    // 应用内那条横幅同理（S6.15）：我自己就是从这个群进来的，横幅该让位给这一页。
    // ⚠️ 得挪到这一帧之后：这一页是在路由里被推出来的，`initState` 还在构建过程中，
    // 那时同步通知界面会让横幅宿主（它不在这一页的祖先链上）当场撞上
    // 「setState() called during build」（`chat_page_test` 抓出来的）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(groupCallPresenceProvider).onJoinedRoom(widget.conversationId);
    });
  }

  Future<void> _open() async {
    // 进群语音之前先确认麦克风（用户 2026-09-27 的要求：通话前再检查一遍权限）。
    //
    // 已经在通话里（从小窗 / 群聊页那条提示回来）就不查了：那一次是**复用**同一通，
    // 权限早过了；这时弹一个框再把人退出去，等于把人踢出通话。
    if (_host.sessionFor(widget.conversationId) == null) {
      final granted = await ensureCallPermissions(context, ref, video: false);
      if (!granted) {
        // 没给权限就别把人留在一间进不去的房间里（页面上只有「进不去」）
        if (mounted) Navigator.of(context).maybePop();
        return;
      }
      if (!mounted) return;
    }
    final session = await _host.openPage(
      conversationId: widget.conversationId,
      name: widget.name,
    );
    _hadSession = true;
    if (!mounted) return;
    session.controller.view.addListener(_maybeStartTimer);
    _maybeStartTimer();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _session?.controller.view.removeListener(_maybeStartTimer);
    // 关页**不等于**挂断（S6.17）：会话留在登记处，声音照旧、小窗与群聊页顶上那条
    // 提醒接手；真要结束就去点那颗红挂断（或小窗上的挂断）。
    _host.closePage();
    super.dispose();
  }

  /// 计时秒表：只在"真的在房间里"那几段里跑。
  ///
  /// 通话结束（挂了/被外面收掉了）就停掉：秒表存在的意义只是让时长那行字
  /// 每秒重画一次，页面上已经没有那行字了还在每秒重画一次就是白耗电；
  /// 重建（`rebuilding`）回来的那一次会自己再起（本方法就是监听回调）。
  void _maybeStartTimer() {
    if (_session?.view.phase != SfuRoomPhase.joined) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  /// 挂断 → 关页。返回键**不再**走这里（那只是退出去，通话还在）。
  ///
  /// ⚠️ 收尾**不等它**：关两条会话要几趟网络往返（真机上是几百毫秒），
  /// 用户点挂断就该马上回到上一页；`end()` 一进去就把会话从登记处摘掉并通知界面
  /// （小窗、群聊页那条提示当场消失），剩下的清理在后台走完。
  /// 顺带记一笔：这里若写成 `await`，整机用例里那串收尾在假异步下走不完
  /// （真机上不影响），用例会卡在「还在通话页上」。
  void _hangup() {
    if (_leaving) return;
    _leaving = true;
    unawaited(_host.end());
    if (mounted && context.canPop()) context.pop();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: CallColors.backdrop,
    body: Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                CallColors.backdropTop,
                CallColors.backdropBottom,
              ],
            ),
          ),
        ),
        // 状态有两个来源：这一通话（`_host` 推来的「进来了/没了」）与它的房间
        // （控制器自己的 `view`）；一起听，两者任一变了都重画
        ListenableBuilder(
          listenable: _host,
          builder: (context, _) {
            final session = _session;
            if (session == null) {
              // 这一通被外面收掉了（有人打 1:1 电话过来顶掉、登出……）：
              // 自己退回去。不退的话页面上会永远挂着一个"正在加入..."。
              _leaveIfCallOver();
              return _joining(context);
            }
            return ValueListenableBuilder<GroupCallView>(
              valueListenable: session.controller.view,
              // 缩进系统小窗（画中画）时**只画内容**：那一刻触摸被系统接管
              // （点一下是「展开 / 菜单」），按钮画上去也点不到（与 1:1 同一套）
              builder: (context, view, _) {
                if (view.inPip) return _pipView(context, session, view);
                // 桌面（S12.37）：窗口够宽就走桌面版式（一屏看全、固定像素），
                // 窄窗仍然走上面那套手机版式。
                if (desktopWideLayout(context, ref)) {
                  // 挂上「桌面框架」标记：[DesktopShell] 有一条「宽窗把内容夹到
                  // 500 居中」的规则（整站是照手机屏宽画的），而群通话在电脑上
                  // 要的恰好是吃满整窗 —— 这个标记就是那条规则的例外开关
                  // （三栏主框架、二级页面板用的是同一个机制）。
                  return DesktopFrameScope(
                    builder: (context) =>
                        _desktopCallView(context, session, view),
                  );
                }
                return _callView(context, session, view);
              },
            );
          },
        ),
      ],
    ),
  );

  /// 小窗卡片上那一行字。
  ///
  /// 三条规则各有理由：
  /// * **我在共享屏幕** → 写「正在共享屏幕」：自己那路画面不回传给我（SFU 不回声），
  ///   不给这行字就会显得「我明明在共享，怎么变成打电话的图标了」；
  /// * 进房间满一秒 → 通话时长（与 1:1 那张小窗一致）；
  /// * 刚进来这一秒 → 人数（与通话页顶上那条一个口径），人还没到齐时比「00:00」有信息量。
  String _pipLabel(
    BuildContext context,
    GroupCallSession session,
    GroupCallView view,
  ) {
    final i18n = ref.watch(appI18nProvider);
    if (view.screenSharing) return i18n.t('call.sharingNotice');
    final seconds = session.elapsed.inSeconds;
    if (seconds > 0) return formatCallDuration(seconds);
    if (view.phase != SfuRoomPhase.joined) return i18n.t('group.callJoining');
    return i18n.t('group.callPeople', <String, String>{
      'n': '${view.inCallMembers.length}',
    });
  }

  /// 这一通被**外面**收掉了：页面自己退回去（不能在 build 里直接 pop）。
  ///
  /// 三种情况会走到这里：有人打 1:1 电话、登出（`GroupCallSessionHost.reset`）、
  /// 以及以后任何"别人替我把这通挂了"的新路径。
  /// `_leaving` 挡的是自己那颗红挂断 —— 那条路本来就自己 pop（不能 pop 两次）。
  void _leaveIfCallOver() {
    if (!_hadSession || _leaving) return;
    _leaving = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && context.canPop()) context.pop();
    });
  }

  /// 通话页正形：顶部信息 + 主区域 + 底部四颗钮 + 左上角那颗「缩成小窗」。
  Widget _callView(
    BuildContext context,
    GroupCallSession session,
    GroupCallView view,
  ) => Stack(
    fit: StackFit.expand,
    children: <Widget>[
      SafeArea(
        // 长按主区域／顶部那块 = 打开群通话诊断（与 1:1 通话页同一个手势：
        // 「听不到他 / 没人说话」时先看订阅有没有建上）
        child: Column(
          children: <Widget>[
            // 桌面（2026-10-03）：右键与长按同一个入口（鼠标没有「长按」这个动作）
            GestureDetector(
              onLongPress: () => unawaited(
                showGroupCallDiagnosticsSheet(context, session.controller),
              ),
              onSecondaryTapDown: (_) => unawaited(
                showGroupCallDiagnosticsSheet(context, session.controller),
              ),
              child: _header(context, session, view),
            ),
            Expanded(
              child: GestureDetector(
                onLongPress: () => unawaited(
                  showGroupCallDiagnosticsSheet(context, session.controller),
                ),
                onSecondaryTapDown: (_) => unawaited(
                  showGroupCallDiagnosticsSheet(context, session.controller),
                ),
                child: _stage(context, session, view),
              ),
            ),
            _controls(context, session, view),
          ],
        ),
      ),
      // 左上角「缩成小窗」：与 1:1 通话页同一颗、同一个位置。
      // 只在**真的在房间里**时给（进不去的那一页上有「重试 / 返回」，缩窗没有意义）；
      // 而且只在**这台机器真有画中画**时给 —— iOS 和桌面上那颗实现是
      // `NoopCallPip`（`supported == false`），画出来就是一颗点不动的钮
      // （与「共享屏那颗在不支持的设备上不画」同一个理，2026-10-06 补齐）。
      if ((view.phase == SfuRoomPhase.joined ||
              view.phase == SfuRoomPhase.rebuilding) &&
          (session.controller.pip?.supported ?? false))
        _minimizeButton(context, session),
    ],
  );

  /// 左上角那颗「缩成小窗」（与 1:1 通话页一模一样）：点一下**立刻**进画中画，
  /// 不用按 Home。
  Widget _minimizeButton(BuildContext context, GroupCallSession session) {
    final i18n = ref.watch(appI18nProvider);
    return Positioned(
      top: context.rpx(60),
      left: context.rpx(20),
      child: Tooltip(
        message: i18n.t('call.minimize'),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => unawaited(session.controller.minimizeToPip()),
          child: Padding(
            padding: EdgeInsets.all(context.rpx(20)),
            child: Icon(
              Icons.picture_in_picture_alt_rounded,
              size: context.rpx(66),
              color: CallColors.text,
            ),
          ),
        ),
      ),
    );
  }

  /// 小窗（画中画）里的内容：**只画内容，一个按钮都不画**。
  ///
  /// 与 1:1 那张小窗同一套读法：
  /// * 有人在共享屏幕 → 那一路画面 **`contain`** 铺满（完整放下、四周留黑边，
  ///   小窗里同样不能把屏幕裁掉）；
  /// * 其余（头像墙 / 说话人 / 我自己在共享）→ 白底 + 绿色话机 + 一行字。
  ///
  /// 尺寸按**窗口**算（不能用 `context.rpx`）：小窗比屏幕小得多，而 `rpx` 是按
  /// 750 设计宽换算的，照搬会把图标和文字缩到看不清（1:1 那张小窗踩过）。
  Widget _pipView(
    BuildContext context,
    GroupCallSession session,
    GroupCallView view,
  ) {
    final stream = view.screen?.stream;
    if (stream is MediaStream) {
      return CallVideoView(
        stream: stream,
        fit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
      );
    }
    return _pipCard(context, session, view);
  }

  /// 小窗里那张「白底 + 绿色话机 + 一行字」的卡片
  Widget _pipCard(
    BuildContext context,
    GroupCallSession session,
    GroupCallView view,
  ) {
    final label = _pipLabel(context, session, view);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return ColoredBox(
          color: CallColors.pipBackground,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.call_rounded,
                  size: width * 0.3,
                  color: CallColors.pipGreen,
                ),
                SizedBox(height: width * 0.08),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: width * 0.12,
                    color: CallColors.pipGreen,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 会话还在路上（`openPage` 还没回来，一般就是几毫秒）：先画「正在加入」
  Widget _joining(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    return SafeArea(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CircularProgressIndicator(color: CallColors.text),
            SizedBox(height: context.rpx(30)),
            Text(
              i18n.t('group.callJoining'),
              style: TextStyle(
                fontSize: context.rpx(28),
                color: CallColors.textDim,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 顶部

  Widget _header(
    BuildContext context,
    GroupCallSession session,
    GroupCallView view,
  ) {
    final i18n = ref.watch(appI18nProvider);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.rpx(40),
        vertical: context.rpx(24),
      ),
      child: Column(
        children: <Widget>[
          Text(
            widget.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: context.rpx(32),
              fontWeight: FontWeight.w600,
              color: CallColors.text,
            ),
          ),
          SizedBox(height: context.rpx(10)),
          Text(
            _subtitle(session, view, i18n),
            style: TextStyle(
              fontSize: context.rpx(24),
              color: CallColors.textDim,
            ),
          ),
          // 人在房间里、但我的麦克风**没真的发布出去**（上游没接受）：
          // 必须说出来。以前这事只有成员行那句「已静音」暗示，看起来就像自己按了静音。
          // 发布**还在路上**时不说这话：进房间那一串里"听见别人"先落地、
          // 自己的发布要再等几秒（候选收集 + 与 Cloudflare 建连），
          // 这中间挂着红字会让人以为坏了。
          if (view.phase == SfuRoomPhase.joined &&
              !view.micPublished &&
              !view.micPublishPending) ...<Widget>[
            SizedBox(height: context.rpx(10)),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.mic_off_rounded,
                  size: context.rpx(24),
                  color: AppColors.red,
                ),
                SizedBox(width: context.rpx(8)),
                Text(
                  i18n.t('group.callMicNotPublished'),
                  style: TextStyle(
                    fontSize: context.rpx(22),
                    color: AppColors.red,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _subtitle(GroupCallSession session, GroupCallView view, AppI18n i18n) {
    switch (view.phase) {
      case SfuRoomPhase.joined:
        final people = i18n.t('group.callPeople', <String, String>{
          'n': '${view.inCallMembers.length}',
        });
        // 时长从**会话**里算（不是从这一页打开算起）：页面关掉再进来接着走
        final seconds = session.elapsed.inSeconds;
        if (seconds <= 0) return people;
        return '$people · ${formatCallDuration(seconds)}';
      case SfuRoomPhase.rebuilding:
        return i18n.t('group.callReconnecting');
      default:
        return i18n.t('group.callJoining');
    }
  }

  // ------------------------------------------------------------------ 主区域

  Widget _stage(
    BuildContext context,
    GroupCallSession session,
    GroupCallView view,
  ) {
    final i18n = ref.watch(appI18nProvider);
    if (view.phase == SfuRoomPhase.failed) {
      return _failed(context, session, view, i18n);
    }
    if (view.phase != SfuRoomPhase.joined) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CircularProgressIndicator(color: CallColors.text),
            SizedBox(height: context.rpx(30)),
            Text(
              i18n.t('group.callJoining'),
              style: TextStyle(
                fontSize: context.rpx(28),
                color: CallColors.textDim,
              ),
            ),
          ],
        ),
      );
    }
    final screen = view.screen;
    final stream = screen?.stream;
    if (stream is MediaStream) {
      return _screenView(context, view, screen!.userId, stream, i18n);
    }
    // 我在共享：自己的画面不回传给自己（SFU 不回声），这里给一块"正在共享"的牌子 ——
    // 否则界面会显得"我明明在共享，怎么还是一片头像"
    if (view.screenSharing) return _myScreenCard(context, i18n);
    final speaker = _memberById(view, view.activeSpeakerId);
    if (speaker != null && view.inCallMembers.length > 1) {
      return _speakerView(context, view, speaker, i18n);
    }
    return _avatarWall(context, view, i18n);
  }

  Widget _failed(
    BuildContext context,
    GroupCallSession session,
    GroupCallView view,
    AppI18n i18n,
  ) => Center(
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: context.rpx(60)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            Icons.error_outline_rounded,
            size: context.rpx(90),
            color: CallColors.textDim,
          ),
          SizedBox(height: context.rpx(24)),
          Text(
            i18n.t('group.callFailed'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: context.rpx(30), color: CallColors.text),
          ),
          if (view.error.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: context.rpx(12)),
              child: Text(
                view.error,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: context.rpx(24),
                  color: CallColors.textDim,
                ),
              ),
            ),
          SizedBox(height: context.rpx(40)),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              _textButton(
                context,
                label: i18n.t('group.callRetry'),
                onTap: () => unawaited(session.controller.start()),
              ),
              SizedBox(width: context.rpx(30)),
              _textButton(
                context,
                label: i18n.t('group.callBack'),
                onTap: _hangup,
              ),
            ],
          ),
        ],
      ),
    ),
  );

  /// 别人共享屏幕：画面铺满这块区域 + 左下角一行字说明是谁在共享
  Widget _screenView(
    BuildContext context,
    GroupCallView view,
    String ownerId,
    MediaStream stream,
    AppI18n i18n,
  ) {
    final owner = _memberById(view, ownerId);
    final name = owner == null ? i18n.t('group.user') : _nameOf(owner, i18n);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // ⚠️ 共享屏**必须用 `contain`**：屏幕是一整幅要看清的画面，`cover` 会把它
        // 裁成中间一块（真机上对方看到的就是"显示不完整"）。
        CallVideoView(
          stream: stream,
          fit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
        ),
        Positioned(
          left: context.rpx(24),
          bottom: context.rpx(24),
          child: _chip(
            context,
            icon: Icons.screen_share_rounded,
            // 整屏都会被采集，所以这行字**对方也看得见**：一眼知道画面为什么变了
            label: i18n.t('group.callIsSharing', <String, String>{
              'name': name,
            }),
          ),
        ),
      ],
    );
  }

  /// 我在共享屏幕（画面不回传给自己）
  Widget _myScreenCard(BuildContext context, AppI18n i18n) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          Icons.screen_share_rounded,
          size: context.rpx(120),
          color: CallColors.pipGreen,
        ),
        SizedBox(height: context.rpx(24)),
        Text(
          i18n.t('call.sharingNotice'),
          style: TextStyle(fontSize: context.rpx(30), color: CallColors.text),
        ),
        SizedBox(height: context.rpx(12)),
        Text(
          i18n.t('group.callMyScreenHint'),
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: context.rpx(24),
            color: CallColors.textDim,
          ),
        ),
      ],
    ),
  );

  /// 说话人视图：说话的人放大（带绿圈）+ 其余人一条排在下面。
  ///
  /// 尺寸按**这块区域的实际高度**算，不写死：写死的话，横屏 / 小窗 / 系统大字体
  /// 会直接把这块撑爆（测试用 800x600 那种又宽又矮的画布就是这种情况）。
  Widget _speakerView(
    BuildContext context,
    GroupCallView view,
    GroupCallMember speaker,
    AppI18n i18n,
  ) => LayoutBuilder(
    builder: (context, constraints) {
      final others = view.inCallMembers
          .where((member) => member.userId != speaker.userId)
          .toList(growable: false);
      // 下面那条（设计稿 210rpx）：不超过这块区域的 42%，而且**放不下一块砖
      // （头像 + 名字）时宁可不画** —— 说话人本身才是这一屏的主角
      final stripRpx = constraints.maxHeight * 0.42 / context.rpx(1);
      final strip = stripRpx >= 120 ? math.min(210.0, stripRpx) : 0.0;
      // 砖里的头像：条高减去名字那两行（~60rpx），上限是设计稿的 150rpx
      final tileRpx = strip == 0 ? 0.0 : math.min(150.0, strip - 60);
      return Column(
        children: <Widget>[
          Expanded(
            child: Center(
              // 地方不够就整体缩小，不报溢出
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _avatar(context, speaker, sizeRpx: 200, speaking: true),
                    SizedBox(height: context.rpx(26)),
                    Text(
                      _nameOf(speaker, i18n),
                      style: TextStyle(
                        fontSize: context.rpx(34),
                        fontWeight: FontWeight.w600,
                        color: CallColors.text,
                      ),
                    ),
                    SizedBox(height: context.rpx(10)),
                    Text(
                      i18n.t('group.callSpeaking'),
                      style: TextStyle(
                        fontSize: context.rpx(24),
                        color: CallColors.pipGreen,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (strip > 0)
            SizedBox(
              height: context.rpx(strip),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: context.rpx(40)),
                itemCount: others.length,
                separatorBuilder: (_, _) => SizedBox(width: context.rpx(40)),
                itemBuilder: (context, index) => Center(
                  child: _tile(
                    context,
                    others[index],
                    i18n,
                    avatarRpx: tileRpx,
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );

  /// 头像墙：没人说话时就是它（列数按人数，跟微信群通话那套一致）
  Widget _avatarWall(BuildContext context, GroupCallView view, AppI18n i18n) {
    final members = view.inCallMembers;
    if (members.isEmpty) {
      return Center(
        child: Text(
          i18n.t('group.callEmpty'),
          style: TextStyle(
            fontSize: context.rpx(28),
            color: CallColors.textDim,
          ),
        ),
      );
    }
    final columns = members.length <= 4
        ? 2
        : members.length <= 9
        ? 3
        : 4;
    return GridView.builder(
      padding: EdgeInsets.all(context.rpx(40)),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: context.rpx(40),
        crossAxisSpacing: context.rpx(40),
        childAspectRatio: 0.82,
      ),
      itemCount: members.length,
      itemBuilder: (context, index) => _tile(context, members[index], i18n),
    );
  }

  /// 一块头像砖：头像（说话时带绿圈、静音时右下角一个小斜杠麦）+ 名字
  Widget _tile(
    BuildContext context,
    GroupCallMember member,
    AppI18n i18n, {
    double avatarRpx = 150,
  }) => Column(
    key: Key('group-call-member-${member.userId}'),
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      _avatar(context, member, sizeRpx: avatarRpx, speaking: member.speaking),
      SizedBox(height: context.rpx(16)),
      Text(
        _nameOf(member, i18n),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: context.rpx(26), color: CallColors.text),
      ),
    ],
  );

  /// 头像：说话时外面套一圈绿灯；静音时右下角一个小「闭麦」。
  /// 共享屏幕的人再加一个屏幕角标（点一下就知道那块画面是谁的）。
  Widget _avatar(
    BuildContext context,
    GroupCallMember member, {
    required double sizeRpx,
    required bool speaking,
  }) {
    final size = context.rpx(sizeRpx);
    final avatar = ContactAvatar(
      url: member.avatar,
      circle: false,
      radiusRpx: sizeRpx * 0.14,
      sizeRpx: sizeRpx,
      fallbackIcon: Icons.person,
    );
    return Container(
      padding: EdgeInsets.all(context.rpx(speaking ? 10 : 0)),
      decoration: BoxDecoration(
        shape: BoxShape.rectangle,
        borderRadius: BorderRadius.circular(size * 0.2),
        border: speaking
            ? Border.all(color: CallColors.pipGreen, width: context.rpx(6))
            : null,
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          avatar,
          if (member.inCall && !member.audio)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                padding: EdgeInsets.all(context.rpx(8)),
                decoration: const BoxDecoration(
                  color: AppColors.red,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.mic_off_rounded,
                  size: size * 0.24,
                  color: AppColors.white,
                ),
              ),
            ),
          if (member.screen)
            Positioned(
              left: 0,
              top: 0,
              child: Container(
                padding: EdgeInsets.all(context.rpx(8)),
                decoration: const BoxDecoration(
                  color: CallColors.pipGreen,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.screen_share_rounded,
                  size: size * 0.24,
                  color: AppColors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 共享屏幕那颗钮（两种版式共用）。
  ///
  /// 桌面上先弹「整个屏幕 / 某个窗口」那个选择面板（S12.38，与 1:1 那颗同一个
  /// 面板；群里那一路声音统一走本机 mic，所以**不带**「连电脑的声音一起发」那座
  /// 开关，见 `showScreenSharePicker(allowAudio: false)`）—— 原生 `getDisplayMedia`
  /// 认的就是取回来的那个源 id。用户取消 → 什么都不做
  /// （取消与「用默认源」是两件事）。安卓上没有面板：系统那个投屏框由
  /// `requestScreenSharePermission` 自己弹。
  Future<void> _onScreenShareTap(
    BuildContext context,
    GroupCallSession session,
    GroupCallView view,
  ) async {
    // ⚠️ 顺序：**先判「此刻能不能开」，再弹选择面板**。已经有人在共享时弹一个
    // 面板出来、选完了才告诉他「等小明的屏幕共享结束」，是白跑一趟。
    final blocked = !view.screenSharing && view.screenSharer != null;
    String? sourceId;
    var withAudio = false;
    if (!view.screenSharing && !blocked && isDesktopRuntime) {
      // 面板走 provider（默认就是真的那个）：它要问 `desktopCapturer`（插件）
      // 拿源列表，组件测试里拿不到 —— 可替换之后那条「选中的源一路带到引擎」
      // 的链子才钉得住（见 `screenSharePickerProvider`）。
      final pick = ref.read(screenSharePickerProvider);
      final choice = await pick(
        context,
        ref.read(appI18nProvider),
        // 桌面群通话也支持「连电脑的声音一起发」（S12.39）。那座开关**默认是关的**：
        // 抓系统声音会把扬声器里放的一切都带进去（包括群里别人说话），得用户自己要。
        // 手机那条走系统投屏框、面板根本不弹，所以这个参数只在电脑上起作用。
        allowAudio: true,
      );
      if (choice == null || !mounted) return;
      sourceId = choice.sourceId;
      withAudio = choice.withAudio;
    }
    await session.controller.toggleScreenShare(
      sourceId: sourceId,
      withAudio: withAudio,
    );
  }

  GroupCallMember? _memberById(GroupCallView view, String? userId) {
    if (userId == null) return null;
    for (final member in view.members) {
      if (member.userId == userId) return member;
    }
    return null;
  }

  /// 名单里没有名字的人（群成员接口没拉到、或刚进来还不认识）显示成「群成员」
  String _nameOf(GroupCallMember member, AppI18n i18n) {
    if (member.name.isNotEmpty) return member.name;
    return member.isMe ? i18n.t('group.callMe') : i18n.t('group.user');
  }

  // ------------------------------------------------------------------ 底部

  Widget _controls(
    BuildContext context,
    GroupCallSession session,
    GroupCallView view,
  ) {
    final i18n = ref.watch(appI18nProvider);
    final enabled = view.phase == SfuRoomPhase.joined;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.rpx(30),
        vertical: context.rpx(40),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: <Widget>[
          CallRoundToggle(
            key: const Key('group-call-members'),
            icon: Icons.people_alt_rounded,
            label: i18n.t('group.callMembers'),
            on: false,
            enabled: enabled,
            onTap: () => unawaited(_showMembers(context)),
          ),
          CallRoundToggle(
            key: const Key('group-call-mic'),
            icon: view.micEnabled ? Icons.mic_rounded : Icons.mic_off_rounded,
            label: i18n.t(
              view.micEnabled ? 'call.micOnState' : 'call.micOffState',
            ),
            on: view.micEnabled,
            enabled: enabled,
            onTap: () => unawaited(session.controller.toggleMicrophone()),
          ),
          // 不支持投屏的设备（iOS）不画这颗：画一颗点不动的钮比不画更糟
          if (view.supportsScreenShare)
            // 已经有人在共享时弄灰：**共享屏同一时刻只能一个人**（两个人同时开
            // 会互相打架），弄灰让"现在不该点"一眼可见；但仍然可点 ——
            // 点一下会告诉他"谁在共享、等他结束"（比一颗纯点不动的钮有用）。
            Opacity(
              opacity:
                  !enabled || (view.screenSharer != null && !view.screenSharing)
                  ? disabledOpacity
                  : 1,
              child: CallRoundToggle(
                key: const Key('group-call-screen'),
                icon: view.screenSharing
                    ? Icons.stop_screen_share_rounded
                    : Icons.screen_share_rounded,
                label: i18n.t(
                  view.screenSharing ? 'call.stopShare' : 'call.screenShare',
                ),
                on: view.screenSharing,
                enabled: enabled,
                onTap: () =>
                    unawaited(_onScreenShareTap(context, session, view)),
              ),
            ),
          CallRoundButton(
            key: const Key('group-call-hangup'),
            size: context.rpx(160),
            background: AppColors.red,
            label: i18n.t('call.hangup'),
            onTap: _hangup,
            child: Icon(
              Icons.call_end_rounded,
              size: context.rpx(80),
              color: AppColors.white,
            ),
          ),
        ],
      ),
    );
  }

  // ==================================================================
  // 桌面版式（S12.37）
  //
  // 为什么单开一套：整站版式是照**手机屏宽**画的（`rpx` = 屏宽 / 750），而
  // [DesktopShell] 在宽窗下会把内容夹到 500 居中 —— 于是电脑上打开群通话，
  // 看到的是一条 500 宽的手机长条：头像墙两列、字号全按 500 算。
  //
  // 电脑上要的是「一屏看全」：主区域吃满窗口，头像与按钮按**固定逻辑像素**排
  // （与 1:1 那套桌面版式同一个口径，见 `call_desktop_page.dart` 文件头）。
  //
  // 触发条件见 [desktopWideLayout]（桌面 + 桌面功能开着 + 真实窗口 ≥ 900）；
  // 窄窗仍然走上面那套手机版式 —— 窗口拉到 600 时，手机那套反而更合适。

  Widget _desktopCallView(
    BuildContext context,
    GroupCallSession session,
    GroupCallView view,
  ) {
    final i18n = ref.watch(appI18nProvider);
    // 右键 / 长按 = 群通话诊断（鼠标没有「长按」这个动作，所以两个都接上；
    // 与手机版同一个入口，见 `_callView`）
    void diagnostics() =>
        unawaited(showGroupCallDiagnosticsSheet(context, session.controller));
    return SafeArea(
      child: Column(
        // 顶栏要**贴左墙**（群名在窗口最左边，微信 PC 那样）：外层这层得把子项
        // 拉伸到整宽，否则内层那个 start 对齐的 Column 会先缩到最宽那行字的宽度，
        // 再被这里默认的 center 整块摆在窗口中间（2026-10-06 真机截图量到的：
        // 群名跑到 x≈531，而窗口宽 1186）
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          GestureDetector(
            onLongPress: diagnostics,
            onSecondaryTapDown: (_) => diagnostics(),
            child: _desktopHeader(context, session, view, i18n),
          ),
          Expanded(
            child: GestureDetector(
              onLongPress: diagnostics,
              onSecondaryTapDown: (_) => diagnostics(),
              child: _desktopStage(context, session, view, i18n),
            ),
          ),
          _desktopControls(context, session, view, i18n),
        ],
      ),
    );
  }

  /// 顶栏（桌面）：左对齐的群名 + 副标题；麦克风没发布出去那条红字也在这
  Widget _desktopHeader(
    BuildContext context,
    GroupCallSession session,
    GroupCallView view,
    AppI18n i18n,
  ) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 20, 28, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          widget.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            color: CallColors.text,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _subtitle(session, view, i18n),
          style: const TextStyle(fontSize: 13, color: CallColors.textDim),
        ),
        // 人在房间里、但我的麦克风**没真的发布出去**（上游没接受）：必须说出来
        // （与手机版同一条；发布还在路上时不说，免得让人以为坏了）
        if (view.phase == SfuRoomPhase.joined &&
            !view.micPublished &&
            !view.micPublishPending) ...<Widget>[
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.mic_off_rounded, size: 15, color: AppColors.red),
              const SizedBox(width: 6),
              Text(
                i18n.t('group.callMicNotPublished'),
                style: const TextStyle(fontSize: 12, color: AppColors.red),
              ),
            ],
          ),
        ],
      ],
    ),
  );

  /// 主区域（桌面）：共享屏 / 我在共享 / 说话人 / 头像墙，四选一
  /// （与手机版同一串判据，只是尺寸换成固定像素）
  Widget _desktopStage(
    BuildContext context,
    GroupCallSession session,
    GroupCallView view,
    AppI18n i18n,
  ) {
    if (view.phase == SfuRoomPhase.failed) {
      return _desktopFailed(session, view, i18n);
    }
    if (view.phase != SfuRoomPhase.joined) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CircularProgressIndicator(color: CallColors.text),
            const SizedBox(height: 18),
            Text(
              i18n.t('group.callJoining'),
              style: const TextStyle(fontSize: 14, color: CallColors.textDim),
            ),
          ],
        ),
      );
    }
    final screen = view.screen;
    final stream = screen?.stream;
    if (stream is MediaStream) {
      return _desktopScreenView(context, view, screen!.userId, stream, i18n);
    }
    // 我在共享：自己的画面不回传给自己（SFU 不回声），给一块「正在共享」的牌子
    if (view.screenSharing) return _desktopMyScreenCard(i18n);
    final speaker = _memberById(view, view.activeSpeakerId);
    if (speaker != null && view.inCallMembers.length > 1) {
      return _desktopSpeakerView(context, view, speaker, i18n);
    }
    return _desktopAvatarWall(context, view, i18n);
  }

  /// 别人共享屏幕（桌面）：画面铺满 + 左下角一行字说明是谁在共享
  Widget _desktopScreenView(
    BuildContext context,
    GroupCallView view,
    String ownerId,
    MediaStream stream,
    AppI18n i18n,
  ) {
    final owner = _memberById(view, ownerId);
    final name = owner == null ? i18n.t('group.user') : _nameOf(owner, i18n);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 与手机版同一条铁律：共享屏一律 `contain` —— `cover` 会把整块屏幕裁成
        // 中间一块（对方看到的就是「显示不完整」）
        CallVideoView(
          stream: stream,
          fit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
        ),
        Positioned(
          left: 24,
          bottom: 24,
          child: _desktopChip(
            icon: Icons.screen_share_rounded,
            // 整屏都会被采集，所以这行字**对方也看得见**
            label: i18n.t('group.callIsSharing', <String, String>{
              'name': name,
            }),
          ),
        ),
      ],
    );
  }

  Widget _desktopChip({required IconData icon, required String label}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: CallColors.scrimStrong,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 15, color: AppColors.white),
            const SizedBox(width: 7),
            Text(
              label,
              style: const TextStyle(fontSize: 12, color: AppColors.white),
            ),
          ],
        ),
      );

  /// 我在共享屏幕（桌面；画面不回传给自己）
  Widget _desktopMyScreenCard(AppI18n i18n) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const Icon(
          Icons.screen_share_rounded,
          size: 64,
          color: CallColors.pipGreen,
        ),
        const SizedBox(height: 16),
        Text(
          i18n.t('call.sharingNotice'),
          style: const TextStyle(fontSize: 17, color: CallColors.text),
        ),
        const SizedBox(height: 8),
        Text(
          i18n.t('group.callMyScreenHint'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: CallColors.textDim),
        ),
      ],
    ),
  );

  /// 说话人视图（桌面）：说话的人放大（带绿圈），其余人一条横着排在下面。
  ///
  /// 尺寸全写死固定像素：这一档**不跟窗口宽走**（跟窗口宽走的就是手机那套
  /// `rpx`，在 1200 宽下会被放大到 1.6 倍）。下面那条按这块区域的高度让出上限，
  /// 放不下一块砖时宁可不画 —— 说话人本身才是主角（与手机版同一个取舍）。
  Widget _desktopSpeakerView(
    BuildContext context,
    GroupCallView view,
    GroupCallMember speaker,
    AppI18n i18n,
  ) => LayoutBuilder(
    builder: (context, constraints) {
      final others = view.inCallMembers
          .where((member) => member.userId != speaker.userId)
          .toList(growable: false);
      final strip = math.min(140.0, constraints.maxHeight * 0.3);
      final showStrip = others.isNotEmpty && strip >= 90;
      return Column(
        children: <Widget>[
          Expanded(
            child: Center(
              // 地方不够就整体缩小，不报溢出
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    _desktopAvatar(context, speaker, size: 150, speaking: true),
                    const SizedBox(height: 18),
                    Text(
                      _nameOf(speaker, i18n),
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w600,
                        color: CallColors.text,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      i18n.t('group.callSpeaking'),
                      style: const TextStyle(
                        fontSize: 13,
                        color: CallColors.pipGreen,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (showStrip)
            SizedBox(
              height: strip,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 28),
                itemCount: others.length,
                separatorBuilder: (_, _) => const SizedBox(width: 28),
                itemBuilder: (context, index) => Center(
                  child: _desktopTile(context, others[index], i18n, avatar: 56),
                ),
              ),
            ),
        ],
      );
    },
  );

  /// 头像墙（桌面）。
  ///
  /// 列数**按可用宽度自己分**（`maxCrossAxisExtent`）：1200 宽的窗口能排下五六列，
  /// 而手机那套写死的 2/3/4 列在电脑上会空掉一大片（用户 2026-10-06 问的就是
  /// 「群通话电脑端现在啥情况」—— 那时的答案是「一条 500 宽的手机长条」）。
  Widget _desktopAvatarWall(
    BuildContext context,
    GroupCallView view,
    AppI18n i18n,
  ) {
    final members = view.inCallMembers;
    if (members.isEmpty) {
      return Center(
        child: Text(
          i18n.t('group.callEmpty'),
          style: const TextStyle(fontSize: 14, color: CallColors.textDim),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // 一屏能排几列：与 delegate 那套算法一致（`ceil(可用宽 / (220 + 缝))`），
        // 所以这里算出的格子宽就是下面真排出来的宽
        const double maxExtent = 220;
        const double gap = 20;
        const double outer = 28;
        final usable = constraints.maxWidth - outer * 2;
        final columns = usable <= maxExtent
            ? 1
            : (usable / (maxExtent + gap)).ceil();
        final cell = (usable - gap * (columns - 1)) / columns;
        // 排不满一行就把这一行**摆到中间**：一两个人时贴着左墙排一列，
        // 右边空掉一大片，看着像没排完（与 1:1 桌面版式里那块居中的画面一个道理）
        final rowWidth = cell * members.length + gap * (members.length - 1);
        final side = members.length < columns
            ? math.max(outer, (usable - rowWidth) / 2 + outer)
            : outer;
        return GridView.builder(
          padding: EdgeInsets.symmetric(horizontal: side, vertical: outer),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: maxExtent,
            mainAxisSpacing: gap,
            crossAxisSpacing: gap,
            childAspectRatio: 0.9,
          ),
          itemCount: members.length,
          itemBuilder: (context, index) =>
              Center(child: _desktopTile(context, members[index], i18n)),
        );
      },
    );
  }

  /// 一块头像砖（桌面）：头像 + 名字（键与手机版同一套，两种版式都认）
  Widget _desktopTile(
    BuildContext context,
    GroupCallMember member,
    AppI18n i18n, {
    double avatar = 84,
  }) => Column(
    key: Key('group-call-member-${member.userId}'),
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      _desktopAvatar(context, member, size: avatar, speaking: member.speaking),
      const SizedBox(height: 10),
      Text(
        _nameOf(member, i18n),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 13, color: CallColors.text),
      ),
    ],
  );

  /// 桌面那块头像：说话时外面套一圈绿灯；静音时右下角一个小「闭麦」；
  /// 共享屏幕的人再加一个屏幕角标（与手机版同一个读法）
  Widget _desktopAvatar(
    BuildContext context,
    GroupCallMember member, {
    required double size,
    required bool speaking,
  }) {
    final corner = size * 0.16;
    return Container(
      padding: EdgeInsets.all(speaking ? 5 : 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(corner + (speaking ? 5 : 0)),
        border: speaking
            ? Border.all(color: CallColors.pipGreen, width: 3)
            : null,
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          ContactAvatar(
            url: member.avatar,
            circle: false,
            sizePx: size,
            // `ContactAvatar` 的圆角只认 rpx：按当前换算比折回去，结果正好是
            // 固定像素（这一档的字号与尺寸都不跟窗口宽走）
            radiusRpx: corner / context.rpx(1),
            fallbackIcon: Icons.person,
          ),
          if (member.inCall && !member.audio)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: AppColors.red,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.mic_off_rounded,
                  size: size * 0.24,
                  color: AppColors.white,
                ),
              ),
            ),
          if (member.screen)
            Positioned(
              left: 0,
              top: 0,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: CallColors.pipGreen,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.screen_share_rounded,
                  size: size * 0.24,
                  color: AppColors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 进不去 / 掉线那一屏（桌面版）：重试与返回
  Widget _desktopFailed(
    GroupCallSession session,
    GroupCallView view,
    AppI18n i18n,
  ) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(
            Icons.error_outline_rounded,
            size: 48,
            color: CallColors.textDim,
          ),
          const SizedBox(height: 14),
          Text(
            i18n.t('group.callFailed'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, color: CallColors.text),
          ),
          if (view.error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                view.error,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: CallColors.textDim),
              ),
            ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              _desktopTextButton(
                label: i18n.t('group.callRetry'),
                onTap: () => unawaited(session.controller.start()),
              ),
              const SizedBox(width: 12),
              _desktopTextButton(
                label: i18n.t('group.callBack'),
                onTap: _hangup,
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Widget _desktopTextButton({
    required String label,
    required VoidCallback onTap,
  }) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
      decoration: BoxDecoration(
        color: CallColors.buttonOff,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 14, color: CallColors.text),
      ),
    ),
  );

  /// 底排四颗（桌面）：成员 / 麦克风 / 共享屏幕 / 挂断。
  ///
  /// 键与手机版**完全一样**（`group-call-members` 那一套）：两种版式只是外面
  /// 那圈尺寸不同，行为与测试的落点都该是一致的。
  Widget _desktopControls(
    BuildContext context,
    GroupCallSession session,
    GroupCallView view,
    AppI18n i18n,
  ) {
    final enabled = view.phase == SfuRoomPhase.joined;
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 22),
      // `Wrap` 而不是 `Row`：窗口被拖窄时折行，绝不裁掉一颗
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 36,
        runSpacing: 10,
        children: <Widget>[
          _desktopRound(
            buttonKey: const Key('group-call-members'),
            icon: Icons.people_alt_rounded,
            label: i18n.t('group.callMembers'),
            color: CallColors.buttonOff,
            iconColor: CallColors.iconOff,
            enabled: enabled,
            onTap: () => unawaited(_showMembers(context)),
          ),
          _desktopRound(
            buttonKey: const Key('group-call-mic'),
            icon: view.micEnabled ? Icons.mic_rounded : Icons.mic_off_rounded,
            label: i18n.t(
              view.micEnabled ? 'call.micOnState' : 'call.micOffState',
            ),
            color: view.micEnabled ? CallColors.buttonOn : CallColors.buttonOff,
            iconColor: view.micEnabled ? CallColors.iconOn : CallColors.iconOff,
            enabled: enabled,
            onTap: () => unawaited(session.controller.toggleMicrophone()),
          ),
          // 不支持投屏的设备（iOS、以及**暂时**的 Windows）不画这颗 ——
          // 画一颗点不动的钮比不画更糟（与手机版同一条）。
          // 桌面上这颗是 S12.38 开的：`sfuScreenShareSupported` 现在也认桌面
          // （Windows/Linux/macOS 走原生 `getDisplayMedia`，与 1:1 那条同一个口径）。
          if (view.supportsScreenShare)
            _desktopRound(
              buttonKey: const Key('group-call-screen'),
              icon: view.screenSharing
                  ? Icons.stop_screen_share_rounded
                  : Icons.screen_share_rounded,
              label: i18n.t(
                view.screenSharing ? 'call.stopShare' : 'call.screenShare',
              ),
              color: view.screenSharing
                  ? CallColors.buttonOn
                  : CallColors.buttonOff,
              iconColor: view.screenSharing
                  ? CallColors.iconOn
                  : CallColors.iconOff,
              // 已经有人在共享时弄灰（共享屏同一时刻只能一个人），但仍然可点 ——
              // 点一下会告诉他「谁在共享、等他结束」（与手机版同一条）
              enabled:
                  enabled && (view.screenSharer == null || view.screenSharing),
              onTap: () => unawaited(_onScreenShareTap(context, session, view)),
            ),
          _desktopRound(
            buttonKey: const Key('group-call-hangup'),
            icon: Icons.call_end_rounded,
            label: i18n.t('call.hangup'),
            color: AppColors.red,
            iconColor: AppColors.white,
            onTap: _hangup,
          ),
        ],
      ),
    );
  }

  /// 桌面那一档的圆钮：56 的圈、26 的图标、12 的标签
  /// （与 1:1 桌面版式里那颗 `_round` 同尺寸，两处对得上眼）
  Widget _desktopRound({
    required Key buttonKey,
    required IconData icon,
    required String label,
    required Color color,
    required Color iconColor,
    required VoidCallback onTap,
    bool enabled = true,
  }) => SizedBox(
    key: buttonKey,
    width: 84,
    child: Opacity(
      opacity: enabled ? 1 : disabledOpacity,
      child: CallRoundButton(
        size: 56,
        background: color,
        label: label,
        labelFontSize: 12,
        labelGap: 6,
        onTap: enabled ? onTap : null,
        child: Icon(icon, size: 26, color: iconColor),
      ),
    ),
  );

  Widget _textButton(
    BuildContext context, {
    required String label,
    required VoidCallback onTap,
  }) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: EdgeInsets.symmetric(
        horizontal: context.rpx(40),
        vertical: context.rpx(18),
      ),
      decoration: BoxDecoration(
        color: CallColors.buttonOff,
        borderRadius: BorderRadius.circular(context.rpx(40)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: context.rpx(28), color: CallColors.text),
      ),
    ),
  );

  Widget _chip(
    BuildContext context, {
    required IconData icon,
    required String label,
  }) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: context.rpx(20),
      vertical: context.rpx(12),
    ),
    decoration: BoxDecoration(
      color: CallColors.scrimStrong,
      borderRadius: BorderRadius.circular(context.rpx(30)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: context.rpx(28), color: AppColors.white),
        SizedBox(width: context.rpx(10)),
        Text(
          label,
          style: TextStyle(fontSize: context.rpx(24), color: AppColors.white),
        ),
      ],
    ),
  );

  // ------------------------------------------------------------------ 成员

  /// 成员面板：通话中的人在前（带麦克风/共享屏状态），还没进来的在后。
  /// 用 `ValueListenableBuilder` 盯着同一份状态 —— 有人在面板开着时进出，
  /// 这里会跟着变（不用手动刷新）。
  Future<void> _showMembers(BuildContext context) {
    // 面板开着的时候可能刚被挂断（会话没了）：那一刻不再画名单
    final session = _session;
    if (session == null) return Future<void>.value();
    return showAppSheet<void>(
      context: context,
      backgroundColor: AppColors.white,
      // 名单可能很长（一群人），给到屏幕的七成高，里面自己滚
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
          ),
          child: ValueListenableBuilder<GroupCallView>(
            valueListenable: session.controller.view,
            builder: (context, view, _) => _membersSheet(context, view),
          ),
        ),
      ),
    );
  }

  Widget _membersSheet(BuildContext context, GroupCallView view) {
    final i18n = ref.watch(appI18nProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          padding: EdgeInsets.symmetric(vertical: context.rpx(28)),
          child: Text(
            i18n.t('group.callMembersTitle', <String, String>{
              'n': '${view.inCallMembers.length}',
            }),
            style: TextStyle(
              fontSize: context.rpx(32),
              color: AppColors.text333,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: view.members.length,
            itemBuilder: (context, index) =>
                _memberRow(context, view.members[index], i18n),
          ),
        ),
        SizedBox(height: context.rpx(20)),
      ],
    );
  }

  Widget _memberRow(
    BuildContext context,
    GroupCallMember member,
    AppI18n i18n,
  ) {
    final state = member.inCall
        ? (member.speaking
              ? i18n.t('group.callSpeaking')
              : member.audio
              ? i18n.t('call.micOnState')
              : i18n.t('group.callMuted'))
        : i18n.t('group.callNotJoined');
    return Container(
      key: Key('group-call-member-row-${member.userId}'),
      height: context.rpx(110),
      padding: EdgeInsets.symmetric(horizontal: context.rpx(40)),
      child: Row(
        children: <Widget>[
          ContactAvatar(
            url: member.avatar,
            circle: false,
            sizeRpx: 70,
            radiusRpx: 10,
          ),
          SizedBox(width: context.rpx(20)),
          Expanded(
            child: Text(
              _nameOf(member, i18n),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.rpx(30),
                color: AppColors.text333,
              ),
            ),
          ),
          if (member.screen)
            Padding(
              padding: EdgeInsets.only(right: context.rpx(16)),
              child: Icon(
                Icons.screen_share_rounded,
                size: context.rpx(34),
                color: CallColors.pipGreen,
              ),
            ),
          if (member.inCall && !member.audio)
            Padding(
              padding: EdgeInsets.only(right: context.rpx(16)),
              child: Icon(
                Icons.mic_off_rounded,
                size: context.rpx(34),
                color: AppColors.red,
              ),
            ),
          Text(
            state,
            style: TextStyle(
              fontSize: context.rpx(26),
              color: member.inCall ? AppColors.text666 : AppColors.text999,
            ),
          ),
        ],
      ),
    );
  }
}
