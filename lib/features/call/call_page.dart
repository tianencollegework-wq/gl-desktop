import 'dart:async';

// 通话页这套图标 2026-09-19 由用户在真机对照页里选定：**整套用 Material 的圆角变体**
// （`Icons.xxx_rounded`，与微信那种实心圆润最接近），**只有「翻转摄像头」用苹果那颗**
// （`CupertinoIcons.switch_camera_solid`，Material 那个翻转字形太碎）。
// 备用方案与挑法见 REFACTOR_PLAN 的 S6.3f。
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show MediaStream, RTCVideoViewObjectFit;

import '../../core/i18n/app_i18n.dart';
import '../../core/platform/desktop_shell.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../domain/call/call_controller.dart';
import '../../domain/call/call_duration.dart';
import '../../domain/call/call_machine.dart';
import '../contacts/widgets/contact_avatar.dart';
import 'call_colors.dart';
import 'call_desktop_page.dart';
import 'call_diagnostics_sheet.dart';
import 'widgets/call_round_button.dart';
import 'widgets/call_video_fit.dart';
import 'widgets/call_video_view.dart';

/// 通话页（S6.3）。对应老端 `pages/message/call.vue` **里面那个 WebView**
/// （`hybrid/html/index.html`）——老端自己是「一个空页面 + 一个 WebView」，
/// 真正的界面全在 HTML 里；新端直接就是一个 Flutter 页面。
///
/// 老端一个页面同时承担三件事（来电台、拨号台、通话中），靠 `status` 切换：
/// 1 拨号中 / 2 通话中 / 3 来电中。新端也一样：**只 watch 控制器**，
/// 不再从 URL 参数取对端信息（信令里已经有了）。
///
/// 与老端逐项对齐的部分：
/// * 视频通话：大窗 + 右上角小窗，点大窗收起/展开按钮、点小窗交换大小窗；
/// * 语音通话：头像 + 名字 + 计时；
/// * 按钮的显隐规则照 `status` 那套：来电中只有「接听 + 挂断」，
///   拨号中/通话中才有「麦克风」、「扬声器」（视频通话另有「摄像头」）。
///
/// **2026-09-19 改版：界面按微信那套重排**（用户指定的观感，见 `REFACTOR_PLAN.md`
/// 的 S6.3e）：
/// * 背景：固定深色渐变（微信语音通话页那种），**不再铺老端那张 `wallpaper.png`**
///   （文件还留在 `assets/` 里，没删）；
/// * 中间：**大圆角方形头像** + 名字 + 状态文案（拨号中是「等待对方接受邀请..」，
///   接通后换成计时）；视频通话时头像收到顶部、盖在一层渐变压暗上；视频接通后
///   头像收起（画面才是主角，与老端 `v-if="status!=2 || !is_video"` 一致）；
/// * 底部圆钮：**开着 = 白底 + 深色图标，关着 = 半透明白底 + 白色图标**，
///   文字用**状态**而不是动作（「麦克风已开」而不是「关闭麦克风」）；
/// * 视频通话多一排：左「缩成小窗」+ 中红色挂断 + 右「翻转摄像头」，
///   视频还比老端多了「免提」与「摄像头开/关」两颗；
/// * 左上角一颗「缩成小窗」：点一下**立刻**进画中画（不用按 Home）。
///
/// 另外加了一个老端没有的入口：**长按浮层打开通话诊断面板**（ICE 状态、候选、
/// RTT/丢包、时间线，可复制/导出）。打不通时它能在几秒内分出「没候选」还是
/// 「缺 TURN」，见 `call_diagnostics_sheet.dart`。
///
/// 与老端刻意的两处差异：
/// 1. **返回键 = 挂断**。老端按返回会直接把通话页 pop 掉，通话就那么僵着
///    （WebView 里的 `onUnload` 只清 `wsData`，一条信令都不发），新端拦下来当挂断；
/// 2. 老端按钮用的是 `guaduan.png` / `jieting.png` 这类位图，新端全换成字形图标
///    （Material 为主，换摄像头那颗用 `CupertinoIcons`），省掉一堆位图，
///    观感与项目其余页面一致。
///    （S12.4 之前这里用的是老端那两套 iconfont 字形；那两套字体连同映射表
///    已没人用，一并清掉了。）
class CallPage extends ConsumerStatefulWidget {
  const CallPage({super.key});

  @override
  ConsumerState<CallPage> createState() => _CallPageState();
}

class _CallPageState extends ConsumerState<CallPage> {
  /// 按钮浮层是否显示（老端 `displayBtn`：点大画面切一下）
  bool _controls = true;

  /// 大窗那一路**原生报上来的画面尺寸**（第一帧之后才有）。
  ///
  /// 1:1 通话没有「对方在共享屏幕」这条信令，只能按比例自己判这块区域该
  /// 「铺满」还是「完整放」（见 `widgets/call_video_fit.dart`）。
  Size? _bigFrame;

  /// 用户双击大画面之后**自己挑的那一档**：null = 跟着比例自动。
  ///
  /// 口径与桌面那颗双击同一个：自动只是默认，用户说了算（他挑过之后就不再自动）。
  bool? _fillOverride;

  /// 控制器只在 `initState` 取一次：`dispose` 里还要用它收尾，
  /// 而那时 `ref` 已经不能用了（与聊天页同一个理由）。
  late final CallController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(callControllerProvider);
    // 老端判忙线看的是「当前路由是不是 pages/message/call」，新端就是这个标记
    _controller.pageActive = true;
  }

  @override
  void dispose() {
    _controller.pageActive = false;
    // 关页收尾：停铃、放掉本机媒体、状态机回 idle。
    // 老端对应 `call.vue::onUnload`（`wsData = null; main_id = null`）+ WebView 销毁。
    unawaited(_controller.reset());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 通话中按返回键不该静默退出（老端就是直接 pop，通话断在那儿）
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        unawaited(_controller.hangup());
      },
      child: Scaffold(
        backgroundColor: CallColors.backdrop,
        body: ValueListenableBuilder<CallViewState>(
          valueListenable: _controller.view,
          builder: (context, state, _) => _body(context, state),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 主体

  Widget _body(BuildContext context, CallViewState state) {
    final i18n = ref.watch(appI18nProvider);
    final session = state.session;
    // 通话已经结束（页面正在关）：只留背景，别闪出半个界面
    if (session.phase == CallPhase.idle) return const SizedBox.shrink();
    // 小窗（画中画）：只画内容，**一个按钮都不画** —— 进了 PiP 之后触摸被系统
    // 接管（点一下是「展开 / 菜单」，不是我们的界面），按钮画上去也点不到。
    // 微信那个小窗就是这样，这是产品要求。
    if (state.inPip) return _pipView(state, i18n);
    // 桌面：微信 PC 那套版式（固定逻辑尺寸，见 `call_desktop_page.dart`）。
    // 手机那一版的尺寸全是 `context.rpx(...)`（750rpx = 屏宽），桌面窗口一宽
    // 就整个放大变形（用户 2026-10-04 的截图）。这里只换版式，控制器、按钮
    // 动作、诊断入口都是同一套。
    //
    // ⚠️ 判据用 `desktopFeaturesProvider`，**不是 `isDesktopRuntime`**：组件测试
    // 就跑在桌面宿主机上（那个为真），而通话那批用例钉的是手机那套界面
    // （扬声器那颗、小窗、共享屏幕……）——用 `isDesktopRuntime` 会把它们全打成
    // 「找不到『扬声器已开』」。
    if (ref.watch(desktopFeaturesProvider)) {
      return _desktopBody(context, state, i18n);
    }
    // 通话中收起浮层时，用户唯一能做的就是再点一下画面把它放出来，
    // 所以「视频通话 + 有画面」这个前提下才允许收起来。
    final showControls = _controls || !session.isVideo;
    final incoming = session.phase == CallPhase.incoming;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 背景：固定深色渐变（微信那套，不再铺老端那张壁纸）
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
        ..._videoWindows(state),
        // 视频通话：顶部压暗一层，名字/计时才压得住画面（微信就是这么干的）
        if (session.isVideo && showControls) _topScrim(context),
        if (showControls) _overlay(context, state, i18n),
        // 左上角「缩成小窗」：来电响铃时不给（那一刻要的是接听/拒接两颗大钮）
        if (showControls && !incoming) _minimizeButton(context, i18n),
      ],
    );
  }

  /// 桌面版式：把状态与两路流递给 `CallDesktopPage`（它不认识控制器）。
  ///
  /// 主窗里这一支只是**兜底**（通话窗起不来时用）：正常桌面上通话界面在
  /// 独立的通话窗里（`DesktopWindowKind.call`），那边也摆着同一页。
  Widget _desktopBody(
    BuildContext context,
    CallViewState state,
    AppI18n i18n,
  ) => CallDesktopPage(
    i18n: i18n,
    state: state,
    localStream: state.hasLocalStream ? _controller.localStream : null,
    remoteStream: state.hasRemoteStream ? _controller.remoteStream : null,
    actions: CallDesktopActions(
      accept: () => unawaited(_controller.accept()),
      hangup: () => unawaited(_controller.hangup()),
      toggleMicrophone: () => unawaited(_controller.toggleMicrophone()),
      toggleCamera: () => unawaited(_controller.toggleCamera()),
      toggleLayout: _controller.toggleLayout,
      diagnostics: () =>
          showCallDiagnosticsSheet(context, _controller.diagnostics),
      // 共享屏幕（桌面）：平台支持 + 视频通话才画那颗钮；点完选好的 sourceId
      // 与「要不要连电脑声音一起发」原样交给控制器
      // （null = 系统默认源 / 停止共享；声音那座开关只在桌面版面板里）
      startScreenShare: state.canShareScreen
          ? (sourceId, withAudio) => unawaited(
              _controller.toggleScreenShare(
                sourceId: sourceId,
                withAudio: withAudio,
              ),
            )
          : null,
    ),
  );

  /// 小窗（画中画）的内容。
  ///
  /// 对齐微信：视频通话接通后是「对方画面铺满 + 右上角自己的小窗」，
  /// 其余情况（语音通话 / 还没接通 / 对方画面还没到）是白底 + 绿色话机图标 +
  /// 一行字（还没人接听时「等待接听」，接通后换成通话时长）。
  ///
  /// 尺寸全按**窗口**算（不能用 `context.rpx`）：小窗比屏幕小得多，而 `rpx`
  /// 是按 750 设计宽换算的，照搬会把图标和文字缩到看不清。
  Widget _pipView(CallViewState state, AppI18n i18n) {
    final remote = state.hasRemoteStream ? _controller.remoteStream : null;
    final local = state.hasLocalStream ? _controller.localStream : null;
    if (!state.isVideo || remote == null) return _pipCard(state, i18n);

    return LayoutBuilder(
      builder: (context, constraints) {
        final insetWidth = constraints.maxWidth * 0.3;
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // 对方画面：`CallVideoView` 用的就是 cover（裁切铺满），不留黑边
            CallVideoView(stream: remote),
            // 共享屏幕期间不放右上角那块（同 `_videoWindows` 的理由：会套娃）
            if (local != null && !state.screenSharing)
              Positioned(
                // 别贴死顶边：12+ 点一下会在右上角冒出系统图标，会盖住小窗
                top: constraints.maxHeight * 0.06,
                right: constraints.maxWidth * 0.05,
                width: insetWidth,
                height: insetWidth * 4 / 3,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(insetWidth * 0.12),
                  child: CallVideoView(stream: local),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 小窗里那张「白底 + 绿色话机 + 一行字」的卡片（未接通的视频通话也用它）
  Widget _pipCard(CallViewState state, AppI18n i18n) {
    // 微信的规则：还没人接听时显示「等待接听」，接通（计时开始）后换成时长。
    // 我们的计时是在「双方都就绪」那一刻才起跳的，所以这条规则天然对得上。
    final seconds = state.session.callTime;
    final label = seconds > 0
        ? formatCallDuration(seconds)
        : i18n.t('call.pipWaiting');
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

  /// 视频通话的两块画面。老端是「大窗 = 本地、小窗 = 远端」，
  /// 收到远端流 50ms 后把大窗换成对方（`streamType = 2`）——
  /// 新端这一步在控制器里（`onRemoteStream` 时 `remoteBig: true`）。
  /// 原生报上来大窗那一路的画面尺寸（见 [CallVideoView.onFrameSize]）
  void _onBigFrame(Size size) {
    if (!mounted || size == _bigFrame) return;
    setState(() => _bigFrame = size);
  }

  /// 大窗这一档放法：用户长按挑过就听他的，否则按比例自动
  /// （电脑屏幕 16:10 放进手机那块竖长条，`cover` 会把左右两边裁掉 —— 见
  /// `widgets/call_video_fit.dart`）
  RTCVideoViewObjectFit _bigFit(BuildContext context) =>
      fitFor(_bigFrame, MediaQuery.sizeOf(context), fill: _fillOverride);

  /// **自动**那一档（不掺杂用户挑的）：`true` = 铺满
  bool _autoFill() =>
      fitFor(_bigFrame, MediaQuery.sizeOf(context)) ==
      RTCVideoViewObjectFit.RTCVideoViewObjectFitCover;

  /// 长按大画面（桌面是双击）：铺满 ⇄ 完整。
  ///
  /// 头一下换成「自动之外的那一档」（自动已经是铺满就换完整、反之换铺满），
  /// 之后再按就是在两档之间翻 —— 每次按一下都一定看得到变化。
  void _toggleFill() {
    _fillOverride = !(_fillOverride ?? _autoFill());
    setState(() {});
  }

  List<Widget> _videoWindows(CallViewState state) {
    if (!state.isVideo) return const <Widget>[];

    final local = state.hasLocalStream ? _controller.localStream : null;
    final remote = state.hasRemoteStream ? _controller.remoteStream : null;

    // 共享屏幕期间：**只留对方那一路**，自己那块小窗收掉（摄像头也已经被停掉了）。
    // 理由（真机试过之后定的，见 S6.7）：屏幕本来就在你手里，再镜一层既没有信息量，
    // 还会出现「小窗里套小窗」的递归观感；而且那一刻摄像头根本不发，预览留着反而
    // 让人以为对方还能看到你的脸。
    if (state.screenSharing) {
      if (remote == null) return const <Widget>[];
      return <Widget>[
        Positioned.fill(
          child: GestureDetector(
            // 点一下画面仍然可以收起/放出下面那排按钮
            onTap: () => setState(() => _controls = !_controls),
            // 长按：铺满 ⇄ 完整（桌面那一版是双击）。
            // ⚠️ 不用 `onDoubleTap`：与 `onTap` 同时挂上时，**单击会等那 300ms
            // 双击超时**才生效 —— 点一下收按钮要等半拍，手感明显变差。
            onLongPress: _toggleFill,
            child: CallVideoView(
              stream: remote,
              fit: _bigFit(context),
              onFrameSize: _onBigFrame,
            ),
          ),
        ),
      ];
    }
    // 大窗按 `remoteBig` 选，选中的那路没流就落到另一路（老端也是靠 `v-show` 兜）
    final MediaStream? big = state.remoteBig
        ? (remote ?? local)
        : (local ?? remote);
    final MediaStream? small = identical(big, local) ? remote : local;

    return <Widget>[
      if (big != null)
        Positioned.fill(
          child: GestureDetector(
            // 老端 `localvideo @click="displayBtn = !displayBtn"`
            onTap: () => setState(() => _controls = !_controls),
            // 长按：铺满 ⇄ 完整（见 [_toggleFill] / `call_video_fit.dart`）
            onLongPress: _toggleFill,
            child: CallVideoView(
              stream: big,
              fit: _bigFit(context),
              onFrameSize: _onBigFrame,
            ),
          ),
        ),
      if (small != null)
        Positioned(
          // 老端 `.remotevideo`：top 40px / right 15px / 100×160px
          top: context.rpx(80),
          right: context.rpx(30),
          width: context.rpx(200),
          height: context.rpx(320),
          child: GestureDetector(
            // 老端 `remotevideo @click="changeVideo()"`：大小窗互换
            onTap: _controller.toggleLayout,
            child: CallVideoView(stream: small),
          ),
        ),
    ];
  }

  /// 视频通话顶部那层渐变压暗（名字/计时压在画面之上才看得清）。
  ///
  /// 微信就是这么干的：不管画面多亮，顶部这一段总是暗下来。
  /// 注意：[IgnorePointer] 不能省 —— `DecoratedBox` 自己会吃掉命中的触摸，
  /// 不加的话顶部这一整块（含右上角自己的小窗）就再也点不动了（真机上实测过）。
  Widget _topScrim(BuildContext context) => Positioned(
    top: 0,
    left: 0,
    right: 0,
    height: context.rpx(430),
    child: IgnorePointer(
      child: const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[CallColors.scrimStrong, CallColors.scrimClear],
          ),
        ),
      ),
    ),
  );

  /// 左上角那颗「缩成小窗」（微信通话页左上角就是它）：
  /// 点一下**立刻**进画中画，不用按 Home 离开应用。
  Widget _minimizeButton(BuildContext context, AppI18n i18n) => Positioned(
    top: context.rpx(60),
    left: context.rpx(20),
    child: _plainButton(
      context,
      icon: Icons.picture_in_picture_alt_rounded,
      tooltip: i18n.t('call.minimize'),
      onTap: () => unawaited(_controller.minimizeToPip()),
    ),
  );

  /// 浮层：中间的对端信息（头像/名字/状态/计时）+ 底部的按钮。
  ///
  /// 两块都支持长按 → 通话诊断面板：视频通话接通后头像会收起来，
  /// 所以不能像以前那样只把长按挂在头像那一层。
  Widget _overlay(BuildContext context, CallViewState state, AppI18n i18n) {
    final session = state.session;
    void diagnostics() =>
        showCallDiagnosticsSheet(context, _controller.diagnostics);

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 语音通话：头像块居中偏上（微信的位置）；
        // 视频通话：贴顶部、盖在那层压暗上
        Positioned(
          left: 0,
          right: 0,
          top: session.isVideo ? context.rpx(270) : null,
          bottom: session.isVideo ? null : context.rpx(620),
          // 桌面（2026-10-03）：右键与长按同一个入口（鼠标没有「长按」这个动作）
          child: GestureDetector(
            onLongPress: diagnostics,
            onSecondaryTapDown: (_) => diagnostics(),
            child: _peerInfo(context, state, i18n),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: context.rpx(60),
          child: GestureDetector(
            onLongPress: diagnostics,
            onSecondaryTapDown: (_) => diagnostics(),
            child: _controlsRow(context, state, i18n),
          ),
        ),
      ],
    );
  }

  /// 中间那块：**大圆角方形头像** + 名字 + 状态文案 / 计时。
  ///
  /// 按用户给的微信截图重排：
  /// * 头像是圆角方形（不是圆），语音通话大一点、视频通话小一号；
  /// * 名字在头像正下方；
  /// * 没接通时名字下面写「等待对方接受邀请..」，接通后换成计时；
  /// * 视频通话接通后头像收起来（老端 `v-if="status!=2 || !is_video"` 也是这个意思，
  ///   那一刻画面才是主角）。
  Widget _peerInfo(BuildContext context, CallViewState state, AppI18n i18n) {
    final session = state.session;
    final name = session.peerName.isEmpty ? session.peerId : session.peerName;
    final talking =
        session.phase == CallPhase.connecting ||
        session.phase == CallPhase.connected;
    final video = session.isVideo;
    final avatarRpx = video ? 130.0 : 190.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (!talking || !video) ...<Widget>[
          ContactAvatar(
            url: session.peerAvatar,
            circle: false,
            // 微信是圆角方形（不是圆）：圆角取边长的 14% 左右
            radiusRpx: avatarRpx * 0.14,
            sizeRpx: avatarRpx,
          ),
          SizedBox(height: context.rpx(26)),
        ],
        Text(
          name,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: context.rpx(video ? 30 : 36),
            fontWeight: FontWeight.w600,
            color: CallColors.text,
          ),
        ),
        if (!talking)
          Padding(
            padding: EdgeInsets.only(top: context.rpx(14)),
            child: Text(
              i18n.t(_callingTextKey(session), <String, String>{'name': name}),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.rpx(28),
                color: CallColors.textDim,
              ),
            ),
          ),
        if (talking && session.callTime > 0)
          Padding(
            padding: EdgeInsets.only(top: context.rpx(14)),
            child: Text(
              formatCallDuration(session.callTime),
              style: TextStyle(
                fontSize: context.rpx(44),
                color: CallColors.text,
              ),
            ),
          ),
        // 正在共享屏幕（S6.7）：绿点 + 一行字。
        // 位置就在名字/计时下面；另外因为整屏会被采集，**对方也能看到这行字**，
        // 对方一眼就知道「画面为什么变成屏幕了」（微信也这么干）。
        if (state.screenSharing)
          Padding(
            padding: EdgeInsets.only(top: context.rpx(16)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: context.rpx(16),
                  height: context.rpx(16),
                  decoration: const BoxDecoration(
                    color: CallColors.pipGreen,
                    shape: BoxShape.circle,
                  ),
                ),
                SizedBox(width: context.rpx(12)),
                Text(
                  i18n.t('call.sharingNotice'),
                  style: TextStyle(
                    fontSize: context.rpx(24),
                    color: CallColors.pipGreen,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 没接通时那句文案。
  ///
  /// 微信在**拨号中**写的是「等待对方接受邀请..」（名字已经在上面了，不再重复
  /// 一遍）；来电响铃继续用老端那两句（`{name} 正在请求与您语音/视频通话`）。
  String _callingTextKey(CallSession session) {
    if (session.phase == CallPhase.incoming) {
      return session.isVideo ? 'call.incomingVideo' : 'call.incomingVoice';
    }
    return 'call.waitingAnswer';
  }

  /// 底部按钮：来电响铃 / 语音通话 / 视频通话三套（与微信一一对应）。
  Widget _controlsRow(BuildContext context, CallViewState state, AppI18n i18n) {
    final session = state.session;
    if (session.phase == CallPhase.incoming) {
      // 来电响铃这一版没改（用户选的：只改拨号中/通话中）：
      // 红色挂断 + 绿色接听两颗大钮
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: <Widget>[
          _bigButton(
            context,
            icon: Icons.call_end_rounded,
            label: i18n.t('call.hangup'),
            color: AppColors.red,
            onTap: () => unawaited(_controller.hangup()),
          ),
          _bigButton(
            context,
            icon: Icons.call_rounded,
            label: i18n.t('call.answer'),
            color: AppColors.green,
            onTap: () => unawaited(_controller.accept()),
          ),
        ],
      );
    }
    return session.isVideo
        ? _videoButtons(context, state, i18n)
        : _voiceButtons(context, state, i18n);
  }

  /// 语音通话：麦克风 / 挂断 / 扬声器（微信那颗免提也带文字）
  Widget _voiceButtons(
    BuildContext context,
    CallViewState state,
    AppI18n i18n,
  ) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceAround,
    children: <Widget>[
      _toggleButton(
        context,
        icon: state.microphoneEnabled
            ? Icons.mic_rounded
            : Icons.mic_off_rounded,
        label: i18n.t(
          state.microphoneEnabled ? 'call.micOnState' : 'call.micOffState',
        ),
        on: state.microphoneEnabled,
        onTap: () => unawaited(_controller.toggleMicrophone()),
      ),
      _hangupButton(context, state, i18n),
      _toggleButton(
        context,
        icon: state.speakerEnabled
            ? Icons.volume_up_rounded
            : Icons.volume_off_rounded,
        label: i18n.t(
          state.speakerEnabled ? 'call.speakerOnState' : 'call.speakerOffState',
        ),
        on: state.speakerEnabled,
        onTap: () => unawaited(_controller.toggleSpeaker()),
      ),
    ],
  );

  /// 视频通话：上面三颗带文字的（麦克风 / 扬声器 / 摄像头），
  /// 下面一排「缩成小窗 / 挂断 / 翻转摄像头」——和微信视频通话一样。
  ///
  /// 比老端多出来两颗：视频通话里的**免提**与**摄像头开关**。
  Widget _videoButtons(
    BuildContext context,
    CallViewState state,
    AppI18n i18n,
  ) => Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: <Widget>[
          _toggleButton(
            context,
            icon: state.microphoneEnabled
                ? Icons.mic_rounded
                : Icons.mic_off_rounded,
            label: i18n.t(
              state.microphoneEnabled ? 'call.micOnState' : 'call.micOffState',
            ),
            on: state.microphoneEnabled,
            onTap: () => unawaited(_controller.toggleMicrophone()),
          ),
          _toggleButton(
            context,
            icon: state.speakerEnabled
                ? Icons.volume_up_rounded
                : Icons.volume_off_rounded,
            label: i18n.t(
              state.speakerEnabled
                  ? 'call.speakerOnState'
                  : 'call.speakerOffState',
            ),
            on: state.speakerEnabled,
            onTap: () => unawaited(_controller.toggleSpeaker()),
          ),
          _toggleButton(
            context,
            // 「关着」直接用带斜杠的那个字形（以前是自己在摄像头上画一条斜杠）
            icon: state.cameraEnabled
                ? Icons.videocam_rounded
                : Icons.videocam_off_rounded,
            label: i18n.t(
              state.cameraEnabled
                  ? 'call.cameraOnState'
                  : 'call.cameraOffState',
            ),
            on: state.cameraEnabled,
            // 共享屏幕时发出去的是屏幕，摄像头那颗没意义（微信也弄灰）
            enabled: !state.screenSharing,
            onTap: () => unawaited(_controller.toggleCamera()),
          ),
        ],
      ),
      SizedBox(height: context.rpx(36)),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: <Widget>[
          // 左边那颗：**微信在这个位置是「模糊背景」**，那要逐帧处理本机画面，
          // 我们这套媒体插件不给口子（结论见 REFACTOR_PLAN 的 S6.7），所以换成
          // 同一位置上一件真能做到的事：把屏幕共享给对方。
          if (state.canShareScreen)
            _plainButton(
              context,
              // iconfont 里没有「投屏」那个字形，这里用两个 Material 图标顶替；
              // 共享中换成「停止共享」，再配一层主题色，状态一眼能看出来
              icon: state.screenSharing
                  ? Icons.stop_screen_share_rounded
                  : Icons.screen_share_rounded,
              tooltip: i18n.t(
                state.screenSharing ? 'call.stopShare' : 'call.screenShare',
              ),
              active: state.screenSharing,
              onTap: () => unawaited(_controller.toggleScreenShare()),
            )
          else
            // 不支持共享屏幕的平台（iOS）留个同样大的空位，挂断钮才居中
            SizedBox(width: context.rpx(106), height: context.rpx(106)),
          _hangupButton(context, state, i18n),
          _plainButton(
            context,
            // 整套里唯一一颗苹果字形：Material 那个「翻转摄像头」太碎（对照页看出来的）
            icon: CupertinoIcons.switch_camera_solid,
            tooltip: i18n.t('call.switchCamera'),
            // 共享屏幕时画面是屏幕，没有「翻摄像头」这回事
            enabled: !state.screenSharing,
            onTap: () => unawaited(_controller.switchCamera()),
          ),
        ],
      ),
    ],
  );

  /// 挂断那颗：拨号中写「取消」、接通后写「挂断」（微信就这么分的）
  Widget _hangupButton(
    BuildContext context,
    CallViewState state,
    AppI18n i18n,
  ) => _bigButton(
    context,
    icon: Icons.call_end_rounded,
    label: i18n.t(
      state.session.phase == CallPhase.outgoing ? 'call.cancel' : 'call.hangup',
    ),
    color: AppColors.red,
    onTap: () => unawaited(_controller.hangup()),
  );

  /// 微信那种开关圆钮：**开着 = 白底 + 深色图标，关着 = 半透明白底 + 白色图标**
  ///
  /// [enabled] = false 时弄灰、点了没有任何反应（共享屏幕期间该颗无意义）。
  /// 开关圆钮（麦克风/扬声器/摄像头）：观感在 [CallRoundToggle] 里，
  /// **群通话页共用同一颗**，两处不会各长一个样。
  Widget _toggleButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required bool on,
    required VoidCallback onTap,
    bool enabled = true,
  }) => CallRoundToggle(
    icon: icon,
    label: label,
    on: on,
    onTap: onTap,
    enabled: enabled,
  );

  /// 通话中那颗大圆钮（挂断/接听：红或绿，比两边略大，图标是白的）
  Widget _bigButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) => _circleButton(
    context,
    size: context.rpx(160),
    background: color,
    label: label,
    onTap: onTap,
    child: Icon(icon, size: context.rpx(80), color: AppColors.white),
  );

  /// 带圆底的按钮（圆钮 + 下面的文字）。[onTap] 给 null = 禁用（点不动）。
  /// 实现在 [CallRoundButton]（群通话页共用同一颗）。
  Widget _circleButton(
    BuildContext context, {
    required double size,
    required Color background,
    required String label,
    required VoidCallback? onTap,
    required Widget child,
  }) => CallRoundButton(
    size: size,
    background: background,
    label: label,
    onTap: onTap,
    child: child,
  );

  /// 没有圆底的纯图标按钮（视频底部那排的「共享屏幕」「翻转摄像头」，
  /// 以及左上角那颗小窗入口）——微信这几个就是裸图标 + 长按提示。
  ///
  /// [active] = 那个功能正开着（共享屏幕中）：图标换成主题色，状态一眼能看出来。
  /// [enabled] = false 时弄灰、点不动。
  Widget _plainButton(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool active = false,
    bool enabled = true,
  }) => Tooltip(
    message: tooltip,
    child: Opacity(
      opacity: enabled ? 1 : _disabledOpacity,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: EdgeInsets.all(context.rpx(20)),
          child: Icon(
            icon,
            size: context.rpx(66),
            color: active ? CallColors.pipGreen : CallColors.text,
          ),
        ),
      ),
    ),
  );

  /// 禁用态的不透明度（共享屏幕时那两颗摄像头相关的钮）
  static const double _disabledOpacity = disabledOpacity;
}
