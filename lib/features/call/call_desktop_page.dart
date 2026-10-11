/// 桌面版通话界面（2026-10-04）：**微信电脑端那套**，尺寸全按逻辑像素写死。
///
/// 为什么不能沿用手机那一版：那边的尺寸都是 `context.rpx(...)`（750rpx = 屏宽），
/// 桌面窗口一宽就整个炸开 —— 用户 2026-10-04 的截图就是那样（麦克风/扬声器/摄像头
/// 三颗钮铺满整屏、挂断钮叠在名字上）。所以这一版：
///
/// * **一个 rpx 都不用**：头像 112、名字 20、圆钮 56、挂断 60 …… 窗口多大都这套；
/// * 版式照微信 PC 的通话窗：上面是对方的画面/头像，底部一条控制栏
///   （麦克风 / 摄像头 / 挂断）；
/// * 来电那一屏仍是「拒绝 + 接听」两颗（微信也这样），只是尺寸收到桌面档；
/// * 桌面没有听筒，**不画「扬声器」那颗**（画了也没意义：桌面就是外放）；
///   屏幕共享（2026-10-05 起）在视频通话、且平台支持时画一颗
///   （`actions.startScreenShare != null`）：点了先选「整个屏幕 / 某个窗口」；
/// * **画中画小窗**（2026-10-05 起）：宿主递了 `actions.togglePip` 就多画一颗
///   （只有通话窗那颗引擎能缩自己），点了原生把那扇窗改成右下角那个置顶小窗
///   （`desktop_window_native.dart::setPip`）；`pip == true` 时整页换小窗那一版
///   —— 只剩画面 + 一排图标钮（见 [_pipLayout]）；
/// * 大窗那块画面**默认按完整放**（`contain`），双击切「铺满」（`cover`）——
///   桌面窗口的宽高比与镜头画面差得多，铺满就是裁掉一大块（见 `_fill`）。
///
/// 它同时给两个宿主用：
/// * **通话窗**（`DesktopWindowKind.call`，第二颗引擎，媒体引擎就在那颗引擎里）；
/// * 主窗里的兜底（通话窗起不来时，`call_page.dart` 直接摆这一页）。
///
/// 所以这一版**不碰 Riverpod、也不碰控制器**：状态与两路流都由调用方递进来，
/// 按钮只回调 —— 谁持有媒体引擎谁去接这些回调。
library;

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show MediaStream, RTCVideoViewObjectFit;

import '../../core/i18n/app_i18n.dart';
import '../../core/theme/app_colors.dart';
import '../../domain/call/call_controller.dart';
import '../../domain/call/call_duration.dart';
import '../../domain/call/call_machine.dart';
import '../contacts/widgets/contact_avatar.dart';
import 'call_colors.dart';
import 'screen_share_picker.dart';
import 'widgets/call_round_button.dart';
import 'widgets/call_video_view.dart';

/// 桌面通话界面对外的动作（通话窗与兜底页各自把这几颗回调接到自己的控制器上）。
class CallDesktopActions {
  const CallDesktopActions({
    required this.accept,
    required this.hangup,
    required this.toggleMicrophone,
    required this.toggleCamera,
    required this.toggleLayout,
    this.diagnostics,
    this.startScreenShare,
    this.togglePip,
  });

  final VoidCallback accept;
  final VoidCallback hangup;
  final VoidCallback toggleMicrophone;
  final VoidCallback toggleCamera;

  /// 点画面：大小窗互换（与手机版那一下同一个动作）
  final VoidCallback toggleLayout;

  /// 右键 / 长按 → 通话诊断（桌面是右键，鼠标没有长按）
  final VoidCallback? diagnostics;

  /// 共享屏幕（桌面，2026-10-05）。**为 null 就不画那颗钮** ——
  /// 平台不支持（iOS）或者这通电话不是视频通话（没有视频轨可换）。
  ///
  /// [sourceId] 是「共享哪一块」：null = 系统默认源（主屏）；
  /// 具体值来自这里弹的那个选择面板（`screen_share_picker.dart`）。
  /// [withAudio] = 连**电脑的声音**一起发（面板里那座开关，默认关）。
  /// 已经在共享时点这颗钮（停止共享）传的是 `(null, false)` —— 停不停由控制器
  /// 说了算。
  final void Function(String? sourceId, bool withAudio)? startScreenShare;

  /// 画中画（桌面，2026-10-05）：把这扇通话窗缩成右下角那个置顶小窗，
  /// 或者从那里回来。
  ///
  /// **为 null 就不画那颗钮**：只有通话窗自己那扇窗有「缩自己」这条能力
  /// （主窗口里的兜底页没有窗可缩）。进没进小窗由 [CallDesktopPage.pip] 说，
  /// 这一颗只负责「用户点了」。
  final VoidCallback? togglePip;
}

/// 画中画小窗的尺寸（逻辑像素；宿主进小窗时照着它设，见 `call_window.dart`）。
///
/// 16:9 —— 正常镜头那一路的宽高比：`contain` 之下比例不一致的画面只会留黑边，
/// 不会被拉变形；屏幕共享那种宽画面也正好。
const Size kCallDesktopPipSize = Size(320, 180);

class CallDesktopPage extends StatefulWidget {
  const CallDesktopPage({
    super.key,
    required this.i18n,
    required this.state,
    required this.localStream,
    required this.remoteStream,
    required this.actions,
    this.pip = false,
  });

  final AppI18n i18n;
  final CallViewState state;
  final MediaStream? localStream;
  final MediaStream? remoteStream;
  final CallDesktopActions actions;

  /// 现在正缩在**画中画小窗**里（那颗窗只有 320×180）：换成小窗那一版版式
  /// （见 [_pipLayout]）。主窗口里那份兜底页永远是 false。
  final bool pip;

  @override
  State<CallDesktopPage> createState() => _CallDesktopPageState();
}

class _CallDesktopPageState extends State<CallDesktopPage> {
  /// 画面上的浮层显不显示（点一下画面切换）——与手机版同一个交互
  bool _controls = true;

  /// 大窗那块画面怎么放：**默认完整**（`contain`，四周留黑边）。
  ///
  /// 双击大窗切成「铺满」（`cover`，多出来的裁掉）。默认取 `contain` 是
  /// 2026-10-05 按用户反馈定的：桌面窗口比手机屏宽得多，镜头画面按 `cover`
  /// 铺满就会裁掉一大块（脸只露中间一条、看着像被拉宽/拉窄——用户的说法是
  /// 「通话全屏后有点变形」）。`contain` 永远把整幅画面放进来，形状一定不会
  /// 走样；想要铺满的观感双击一下就是。微信 PC 的通话窗也是这个口径。
  ///
  /// 另外这一颗还是「对方在共享屏幕」时的救命开关：1:1 通话没有信令告诉咱们
  /// 「他现在发的是屏幕」，看着像被裁过的屏幕画面时双击就能看全。
  bool _fill = false;

  /// 我自己在共享屏幕：这时候本机那一路是**屏幕**，一律 `contain`
  /// （屏幕是一整幅要看清的画面，与群通话那条注释同一个理）。
  bool get _screenSharing => widget.state.screenSharing;

  @override
  Widget build(BuildContext context) {
    final session = widget.state.session;
    if (session.phase == CallPhase.idle) return const SizedBox.shrink();
    // 小窗那一版版式（尺寸差得太多，两版合不到一起：见 [_pipLayout]）
    if (widget.pip) return _pipLayout();
    final video = session.isVideo;
    final showControls = _controls || !video;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        _backdrop(),
        if (video) ..._videoLayers(),
        // 视频通话顶部压暗一层（名字压在画面上才看得清）
        if (video && showControls)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 120,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[
                      CallColors.scrimStrong,
                      CallColors.scrimClear,
                    ],
                  ),
                ),
              ),
            ),
          ),
        // 中间那块：头像 + 名字 + 状态/计时。
        // 视频通话接通之后（画面已经是主角）就收起来，与手机版一致。
        //
        // ⚠️ 这条判据跟上面那层压暗层（`video && showControls`）必须是一对：
        // 以前这里写的是 `!_controls`，于是「收起控制栏」那一刻名字**反而**
        // 冒出来、而压暗层同时没了 —— 白字直接压在亮画面上（2026-10-05 复查）。
        // 现在是「控制栏在 = 名字+压暗一起在；收起 = 只剩干净的画面」。
        if (!video || !widget.state.hasRemoteStream || showControls)
          _peerInfo(),
        if (showControls) _controlsBar(),
      ],
    );
  }

  // ------------------------------------------------------------------ 画面

  /// 大窗放哪一路：按 `remoteBig` 选，选中的那路没流就落到另一路
  /// （与手机版同一条兜底）。大窗与小窗共用。
  MediaStream? _bigStream() {
    final local = widget.localStream;
    final remote = widget.remoteStream;
    return widget.state.remoteBig ? (remote ?? local) : (local ?? remote);
  }

  /// 那层深色渐变底（大窗与小窗共用）
  Widget _backdrop() => const DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[CallColors.backdropTop, CallColors.backdropBottom],
      ),
    ),
  );

  List<Widget> _videoLayers() {
    final local = widget.localStream;
    final remote = widget.remoteStream;
    final big = _bigStream();
    final small = identical(big, local) ? remote : local;

    // 大窗这块怎么放：本机在共享时那块是屏幕 → `contain`；否则按 [_fill]
    // 铺满（cover，默认）/ 完整（contain，双击切）。
    final bigFit = _screenSharing && identical(big, local) || !_fill
        ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
        : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover;

    return <Widget>[
      if (big != null)
        Positioned.fill(
          child: GestureDetector(
            onTap: () => setState(() => _controls = !_controls),
            // 双击：铺满 ⇄ 完整（见 [_fill]）
            onDoubleTap: () => setState(() => _fill = !_fill),
            child: CallVideoView(stream: big, fit: bigFit),
          ),
        ),
      if (small != null)
        Positioned(
          // 右上角那块自己的小窗（微信 PC 也是这个位置）
          top: 16,
          right: 16,
          width: 192,
          height: 144,
          child: GestureDetector(
            onTap: widget.actions.toggleLayout,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CallVideoView(
                stream: small,
                // 小窗里是屏幕时也不能裁（共享时那块就是我的屏幕）
                fit: _screenSharing && identical(small, local)
                    ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
                    : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              ),
            ),
          ),
        ),
    ];
  }

  // -------------------------------------------------------------- 画中画小窗

  /// 小窗那一版（`pip == true`；那颗窗只有 [kCallDesktopPipSize] 那么大）：
  /// **只剩画面 + 底下一排图标钮**。
  ///
  /// 三处与大窗版式不同，都是尺寸逼出来的：
  /// * 圆钮换成 30 的**图标钮**（大窗那套一颗就 84 宽，四颗 336 塞不进 320）；
  ///   文字只留在 tooltip 里 —— 小窗里没有写字的地方；
  /// * 右上角那片本机小窗收起来（它 192×144，比整扇窗还大）；
  /// * 名字那一块只有**语音通话**才有（没有画面时才需要它占地儿；画面里
  ///   那块位置留给对方的脸）。
  ///
  /// 拖动不在这里：那一下由宿主（`call_window.dart`）包在小窗外面 —— 它得
  /// 跟原生说话，而这一页刻意不碰原生（见文件头）。
  Widget _pipLayout() {
    final state = widget.state;
    final big = _bigStream();
    final showControls = _controls || !state.session.isVideo;
    // 小窗里也是「双击切铺满」（与大窗同一个开关，见 [_fill]）；自己在共享屏
    // 幕时那块是屏幕 —— 一律完整放
    final fit = _fill && !(_screenSharing && identical(big, widget.localStream))
        ? RTCVideoViewObjectFit.RTCVideoViewObjectFitCover
        : RTCVideoViewObjectFit.RTCVideoViewObjectFitContain;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        _backdrop(),
        if (big != null)
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() => _controls = !_controls),
              onDoubleTap: () => setState(() => _fill = !_fill),
              child: CallVideoView(stream: big, fit: fit),
            ),
          )
        else
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() => _controls = !_controls),
              child: Center(child: _pipPeerInfo()),
            ),
          ),
        if (showControls) _pipBar(),
      ],
    );
  }

  /// 小窗里的名字那一块（只有没画面可画时才用得上）
  Widget _pipPeerInfo() {
    final session = widget.state.session;
    final name = session.peerName.isEmpty ? session.peerId : session.peerName;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ContactAvatar(url: session.peerAvatar, circle: true, sizePx: 40),
        const SizedBox(height: 8),
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: CallColors.text,
          ),
        ),
        if (session.callTime > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              formatCallDuration(session.callTime),
              style: const TextStyle(fontSize: 12, color: CallColors.textDim),
            ),
          ),
      ],
    );
  }

  // ------------------------------------------------------------------ 中间

  Widget _peerInfo() {
    final session = widget.state.session;
    final i18n = widget.i18n;
    final name = session.peerName.isEmpty ? session.peerId : session.peerName;
    final talking =
        session.phase == CallPhase.connecting ||
        session.phase == CallPhase.connected;
    final video = session.isVideo;
    // ⚠️ 「压在画面上」那一版（小头像 + 贴顶部）只对**真的有画面**的情况成立：
    // 接通后对方那一路、拨号中自己那路预览。**来电那一屏一路媒体都还没取**
    // （`RequestLocalMedia` 要等接听），照 top: 40 摆就是 600×700 的空屏上
    // 挂一个小头像（2026-10-05 复查：跟旁边那屏语音来电一比就很明显）——
    // 所以来电那一屏与语音那一屏一个摆法：头像放大一号、整块居中。
    final overlaid = video && session.phase != CallPhase.incoming;
    // 压在画面上时头像小一号、贴在上面（画面才是主角）
    final avatarSize = overlaid ? 72.0 : 112.0;

    final block = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (!talking || !video) ...<Widget>[
          ContactAvatar(
            url: session.peerAvatar,
            circle: true,
            // 桌面这套是固定像素，不受窗口宽度影响（见文件头）
            sizePx: avatarSize,
          ),
          const SizedBox(height: 18),
        ],
        Text(
          name,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: video ? 20 : 22,
            fontWeight: FontWeight.w600,
            color: CallColors.text,
          ),
        ),
        if (!talking)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              i18n.t(_callingTextKey(session), <String, String>{'name': name}),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: CallColors.textDim),
            ),
          ),
        if (talking && session.callTime > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              formatCallDuration(session.callTime),
              style: const TextStyle(fontSize: 18, color: CallColors.text),
            ),
          ),
      ],
    );

    return overlaid
        ? Positioned(top: 40, left: 0, right: 0, child: block)
        : Positioned(
            left: 0,
            right: 0,
            top: 0,
            // 底下留出控制栏那块位置（两颗圆钮 + 标签）
            bottom: 120,
            child: Center(child: block),
          );
  }

  /// 小窗底下那排图标钮（麦克风 / 摄像头 / 挂断 / 还原；来电那一屏是拒接 + 接听）
  Widget _pipBar() {
    final state = widget.state;
    final i18n = widget.i18n;
    final incoming = state.session.phase == CallPhase.incoming;
    final buttons = <Widget>[
      if (incoming) ...<Widget>[
        _pipButton(
          icon: Icons.call_end_rounded,
          tooltip: i18n.t('call.hangup'),
          background: AppColors.red,
          iconColor: AppColors.white,
          onTap: widget.actions.hangup,
        ),
        _pipButton(
          icon: Icons.call_rounded,
          tooltip: i18n.t('call.answer'),
          background: AppColors.green,
          iconColor: AppColors.white,
          onTap: widget.actions.accept,
        ),
      ] else ...<Widget>[
        _pipButton(
          icon: state.microphoneEnabled
              ? Icons.mic_rounded
              : Icons.mic_off_rounded,
          tooltip: i18n.t(
            state.microphoneEnabled ? 'call.micOnState' : 'call.micOffState',
          ),
          background: state.microphoneEnabled
              ? CallColors.buttonOn
              : CallColors.buttonOff,
          iconColor: state.microphoneEnabled
              ? CallColors.iconOn
              : CallColors.iconOff,
          onTap: widget.actions.toggleMicrophone,
        ),
        if (state.isVideo)
          _pipButton(
            icon: state.cameraEnabled
                ? Icons.videocam_rounded
                : Icons.videocam_off_rounded,
            tooltip: i18n.t(
              state.cameraEnabled
                  ? 'call.cameraOnState'
                  : 'call.cameraOffState',
            ),
            background: state.cameraEnabled
                ? CallColors.buttonOn
                : CallColors.buttonOff,
            iconColor: state.cameraEnabled
                ? CallColors.iconOn
                : CallColors.iconOff,
            onTap: widget.actions.toggleCamera,
          ),
        _pipButton(
          icon: Icons.call_end_rounded,
          tooltip: i18n.t('call.hangup'),
          background: AppColors.red,
          iconColor: AppColors.white,
          onTap: widget.actions.hangup,
        ),
      ],
      // 「回到大窗」：小窗里唯一能出去的那一手（这扇窗没有标题栏，✕ 也点不到）
      if (widget.actions.togglePip != null)
        _pipButton(
          icon: Icons.picture_in_picture_alt_rounded,
          tooltip: i18n.t('call.pipRestore'),
          onTap: widget.actions.togglePip,
        ),
    ];

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: GestureDetector(
        // 这排自己吃掉点击：点到钮与钮之间的空隙不该把控制栏收起来
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[CallColors.scrimClear, CallColors.scrimStrong],
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              for (final button in buttons)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  child: button,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 小窗里那一颗：30 的圈、17 的图标，文字只留在 tooltip 里
  Widget _pipButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    Color background = CallColors.buttonOff,
    Color iconColor = CallColors.iconOff,
  }) => Tooltip(
    message: tooltip,
    child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: background, shape: BoxShape.circle),
        child: Icon(icon, size: 17, color: iconColor),
      ),
    ),
  );

  /// 共享屏幕那颗钮：
  ///
  /// * 已经在共享 → 交给控制器停（`sourceId` 传 null，它用不上）；
  /// * 没在共享 → 先弹「整个屏幕 / 某个窗口」那个选择面板（桌面才有；面板底下
  ///   还有一座「连电脑的声音一起发」的开关，S12.32）；用户取消就什么都不做。
  Future<void> _onScreenShareTap() async {
    final action = widget.actions.startScreenShare;
    if (action == null) return;
    if (_screenSharing) {
      action(null, false);
      return;
    }
    final choice = await showScreenSharePicker(context, widget.i18n);
    if (choice == null || !mounted) return;
    action(choice.sourceId, choice.withAudio);
  }

  String _callingTextKey(CallSession session) {
    if (session.phase == CallPhase.incoming) {
      return session.isVideo ? 'call.incomingVideo' : 'call.incomingVoice';
    }
    return 'call.waitingAnswer';
  }

  // ------------------------------------------------------------------ 控制栏

  Widget _controlsBar() {
    final state = widget.state;
    final i18n = widget.i18n;
    final incoming = state.session.phase == CallPhase.incoming;

    final buttons = incoming
        ? <Widget>[
            _round(
              icon: Icons.call_end_rounded,
              label: i18n.t('call.hangup'),
              color: AppColors.red,
              iconColor: AppColors.white,
              onTap: widget.actions.hangup,
            ),
            _round(
              icon: Icons.call_rounded,
              label: i18n.t('call.answer'),
              color: AppColors.green,
              iconColor: AppColors.white,
              onTap: widget.actions.accept,
            ),
          ]
        : <Widget>[
            _round(
              icon: state.microphoneEnabled
                  ? Icons.mic_rounded
                  : Icons.mic_off_rounded,
              label: i18n.t(
                state.microphoneEnabled
                    ? 'call.micOnState'
                    : 'call.micOffState',
              ),
              color: state.microphoneEnabled
                  ? CallColors.buttonOn
                  : CallColors.buttonOff,
              iconColor: state.microphoneEnabled
                  ? CallColors.iconOn
                  : CallColors.iconOff,
              onTap: widget.actions.toggleMicrophone,
            ),
            if (state.isVideo)
              _round(
                icon: state.cameraEnabled
                    ? Icons.videocam_rounded
                    : Icons.videocam_off_rounded,
                label: i18n.t(
                  state.cameraEnabled
                      ? 'call.cameraOnState'
                      : 'call.cameraOffState',
                ),
                color: state.cameraEnabled
                    ? CallColors.buttonOn
                    : CallColors.buttonOff,
                iconColor: state.cameraEnabled
                    ? CallColors.iconOn
                    : CallColors.iconOff,
                // 共享屏幕期间这颗是灰的（手机版一直是这么做的，桌面版 2026-10-05
                // 复查时才发现漏了）：那一刻摄像头已经被引擎关掉、发出去的是屏幕，
                // 点它只会把一颗没在用的轨道开来关去 —— 界面说一套、对方看另一套。
                enabled: !state.screenSharing,
                onTap: widget.actions.toggleCamera,
              ),
            // 共享屏幕（桌面 2026-10-05）：只在视频通话、且这台机器支持时画
            // （`actions.startScreenShare == null` = 平台不支持 / 语音通话）。
            if (state.isVideo && widget.actions.startScreenShare != null)
              _round(
                icon: state.screenSharing
                    ? Icons.stop_screen_share_rounded
                    : Icons.screen_share_rounded,
                label: i18n.t(
                  state.screenSharing ? 'call.stopShare' : 'call.screenShare',
                ),
                color: state.screenSharing
                    ? CallColors.buttonOn
                    : CallColors.buttonOff,
                iconColor: state.screenSharing
                    ? CallColors.iconOn
                    : CallColors.iconOff,
                onTap: _onScreenShareTap,
              ),
            // 画中画（桌面 2026-10-05）：只有通话窗能画（`togglePip == null`
            // = 这一页是主窗口里的兜底，没有窗可缩）；语音通话也画 —— 那颗小窗
            // 会摆头像 + 计时。
            if (widget.actions.togglePip != null)
              _round(
                icon: Icons.picture_in_picture_alt_rounded,
                label: i18n.t('call.pip'),
                color: CallColors.buttonOff,
                iconColor: CallColors.iconOff,
                onTap: widget.actions.togglePip!,
              ),
            _round(
              icon: Icons.call_end_rounded,
              label: i18n.t('call.hangup'),
              color: AppColors.red,
              iconColor: AppColors.white,
              onTap: widget.actions.hangup,
            ),
          ];

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: GestureDetector(
        onLongPress: widget.actions.diagnostics,
        onSecondaryTapDown: (_) => widget.actions.diagnostics?.call(),
        child: Container(
          padding: const EdgeInsets.only(top: 18, bottom: 26),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[CallColors.scrimClear, CallColors.scrimStrong],
            ),
          ),
          // 用 `Wrap` 而不是 `Row`：视频通话加上「共享屏幕」之后是四颗（4×84 +
          // 3×36 = 444），通话窗窄到 420 时一行就盛不下了（真机之外的窗口可以
          // 被拖窄，真机上的 600 宽视频窗正好卡在边上）。宽了就一行居中，
          // 窄了自动折行 —— 绝不裁掉一颗（RenderFlex 溢出的黄黑条可不是界面）。
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 36,
            runSpacing: 10,
            children: buttons,
          ),
        ),
      ),
    );
  }

  /// 桌面那一档的圆钮：56 的圈、26 的图标、12 的标签（见文件头）。
  ///
  /// [enabled] 为 false 时弄灰、点了没反应（与手机版 [CallRoundToggle] 里那条
  /// 「共享屏幕时摄像头那几颗是灰的」同一条规则）。
  Widget _round({
    required IconData icon,
    required String label,
    required Color color,
    required Color iconColor,
    required VoidCallback onTap,
    bool enabled = true,
  }) => SizedBox(
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
}
