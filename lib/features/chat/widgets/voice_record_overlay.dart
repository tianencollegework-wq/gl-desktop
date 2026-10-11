import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';

/// 按住说话时手指落在哪个区（微信那三个：发送 / 取消 / 转文字）
enum VoiceRecordZone {
  /// 默认：松手就发出去
  send,

  /// 滑到左下角「取消」
  cancel,

  /// 滑到右下角「滑到这里 转文字」
  transcribe,
}

/// 浮层的状态（输入区的那个手势在改它，浮层只负责画）
@immutable
class VoiceRecordState {
  const VoiceRecordState({
    this.seconds = 0,
    this.zone = VoiceRecordZone.send,
    this.transcribing = false,
  });

  /// 已录秒数（老端的 `recLength`，1 秒一跳）
  final int seconds;

  /// 当前手指所在的区
  final VoiceRecordZone zone;

  /// 松手后正在上传识别（这一小段时间浮层还留着，显示「正在转文字…」）
  final bool transcribing;

  VoiceRecordState copyWith({
    int? seconds,
    VoiceRecordZone? zone,
    bool? transcribing,
  }) => VoiceRecordState(
    seconds: seconds ?? this.seconds,
    zone: zone ?? this.zone,
    transcribing: transcribing ?? this.transcribing,
  );
}

/// 录音浮层（微信那套：整屏压暗 + 中间一个绿色声波气泡 + 底上「取消 / 转文字」两区）。
///
/// 它是插进根 `Overlay` 的一个**不接收触摸**的层：手势始终由输入区那个
/// 「按住说话」控件持有，所以滑到哪里、松手与否都不会被浮层截走。
class VoiceRecordOverlay extends StatefulWidget {
  const VoiceRecordOverlay({
    super.key,
    required this.state,
    required this.amplitude,
    required this.cancelLabel,
    required this.cancelSendLabel,
    required this.transcribeLabel,
    required this.sendLabel,
    required this.transcribeSendLabel,
    required this.transcribingLabel,
    this.desktop = false,
  });

  /// 桌面版式（鼠标 + 宽窗口）。
  ///
  /// 桌面为什么不能直接照搬手机那套（2026-10-06 用户报「语音录音的 UI 还没适配
  /// 电脑」）：
  ///
  /// * 那套的尺寸全是 `rpx`（= 窗宽 / 750）。桌面上窗口 2400 物理 / 1200 逻辑时，
  ///   浮层里那个气泡会胀到 830 逻辑宽、底下那个托盘 350 高 —— 一张巨画；
  /// * 「武装线」在手机上离底 220rpx（≈屏高的 1/4，手指一下就能到），桌面上同样的
  ///   公式是 352 逻辑像素，用鼠标往上拖那么远很别扭；
  /// * 整屏压暗那层是给手指弹出的浮层看的，桌面上看着像出错弹窗。
  ///
  /// 桌面这档改成：**底部居中的一张紧凑卡片（固定像素、不吃 rpx）+ 更短的武装线**，
  /// 手势语义一点不改（还是按住说话、上滑选取消/转文字、松手发送）。
  final bool desktop;

  /// 由输入区更新的状态（秒数、所在区、是否在转文字）
  final ValueListenable<VoiceRecordState> state;

  /// 录音音量流（0..1），画中间那条声波
  final Stream<double> amplitude;

  /// 左下角那块的「取消」
  final String cancelLabel;

  /// 滑到取消区时托盘上的「松开取消」
  final String cancelSendLabel;

  /// 右下角那块的「滑到这里 转文字」
  final String transcribeLabel;

  /// 「松开发送」（滑到取消区时换成「松开取消」）
  final String sendLabel;

  /// 滑到转文字区时托盘上的「松开转文字」
  final String transcribeSendLabel;

  /// 「正在转文字…」
  final String transcribingLabel;

  /// 声波条数（微信那一排大约 20 多根）
  static const int barCount = 22;

  /// 「武装线」：手指从麦克风往上滑进这条线以上，才会进「取消 / 转文字」两区。
  ///
  /// 之所以要这条线，是因为麦克风按钮本身就在屏幕最下面：如果直接拿「底部一条带」
  /// 当区间，按下去那一下就已经在区里了。
  static const double armRpx = 220;

  /// 桌面上「武装线」离窗口底边多高（逻辑像素；比手机那 220rpx 短得多，
  /// 鼠标往上拖一小段就够了）
  static const double desktopArmPx = 72;

  /// 桌面那张卡片的宽度（逻辑像素）
  static const double desktopCardWidth = 360;

  /// 底下那条托盘（「松开发送」）的高度 —— 微信里它盖住了输入栏
  static const double trayRpx = 220;

  /// 托盘上面那一行「取消 / 滑到这里 转文字」的高度
  static const double zoneRpx = 200;

  @override
  State<VoiceRecordOverlay> createState() => _VoiceRecordOverlayState();
}

class _VoiceRecordOverlayState extends State<VoiceRecordOverlay> {
  /// 最近 [VoiceRecordOverlay.barCount] 帧的音量（最新的在右边）
  final List<double> _samples = <double>[];
  StreamSubscription<double>? _subscription;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(VoiceRecordOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.amplitude != widget.amplitude) {
      _subscription?.cancel();
      _listen();
    }
  }

  void _listen() {
    _subscription = widget.amplitude.listen((value) {
      if (!mounted) return;
      setState(() {
        _samples.add(value);
        while (_samples.length > VoiceRecordOverlay.barCount) {
          _samples.removeAt(0);
        }
      });
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ⚠️ 外层这个 `Material` 是**必须**的：浮层插在根 Overlay 上，祖先里没有
    // `Material`，`MaterialApp` 会给这种 Text 一份调试样式（红字 + 两条黄色下划线，
    // 见 `material/app.dart` 的 `_errorTextStyle`）—— 用户 2026-09-30 报的
    // 「很多提示都有两条黄色下划线」就是这个。包一层透明 Material 就正常了。
    return Material(
      type: MaterialType.transparency,
      child: ValueListenableBuilder<VoiceRecordState>(
        valueListenable: widget.state,
        builder: (context, state, _) => IgnorePointer(
          child: widget.desktop
              ? _desktopBody(context, state)
              : Stack(
                  key: const Key('voice-record-phone'),
                  children: <Widget>[
                    // 整屏压暗（微信这里不是全黑，能看见后面的聊天）
                    const Positioned.fill(
                      child: ColoredBox(
                        key: Key('voice-record-scrim'),
                        color: AppColors.voiceOverlayScrim,
                      ),
                    ),
                    Center(child: _bubble(context, state)),
                    _bottom(context, state),
                  ],
                ),
        ),
      ),
    );
  }

  /// 桌面那一档：底部居中一张紧凑卡片（固定像素）。
  ///
  /// * 不压暗整窗（不是弹窗，是一个正在录音的小面板）；
  /// * 声波、计时、两个区的位置都用**固定逻辑像素**（不吃 rpx）；
  /// * 命中区与手机的语义完全一致：滑过武装线上左 = 取消、上右 = 转文字、
  ///   不滑就是发送 —— 只是那条线短得多（[desktopArmPx]）。
  Widget _desktopBody(BuildContext context, VoiceRecordState state) {
    final active = state.zone;
    final hint = state.transcribing
        ? widget.transcribingLabel
        : switch (active) {
            VoiceRecordZone.cancel => widget.cancelSendLabel,
            VoiceRecordZone.transcribe => widget.transcribeSendLabel,
            VoiceRecordZone.send => widget.sendLabel,
          };
    return Stack(
      key: const Key('voice-record-desktop'),
      children: <Widget>[
        Positioned(
          left: 0,
          right: 0,
          bottom: 16,
          child: Center(
            child: Container(
              key: const Key('voice-record-card'),
              width: VoiceRecordOverlay.desktopCardWidth,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              decoration: BoxDecoration(
                color: AppColors.voiceOverlayScrim,
                borderRadius: BorderRadius.circular(12),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 18,
                    offset: Offset(0, 6),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(
                    height: 38,
                    width: 260,
                    child: state.transcribing
                        ? const Center(
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.voiceOverlayBubble,
                              ),
                            ),
                          )
                        : _wave(context, fixed: true),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    state.transcribing ? '' : '${state.seconds}″ · $hint',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xCCFFFFFF),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      _desktopZone(
                        label: widget.cancelLabel,
                        icon: Icons.keyboard_arrow_left,
                        highlighted: active == VoiceRecordZone.cancel,
                      ),
                      _desktopZone(
                        label: widget.transcribeLabel,
                        icon: Icons.keyboard_arrow_right,
                        highlighted: active == VoiceRecordZone.transcribe,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 桌面卡片里那两颗区标签（固定像素）：滑到哪个区哪个亮
  Widget _desktopZone({
    required String label,
    required IconData icon,
    required bool highlighted,
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: highlighted ? const Color(0x66FFFFFF) : const Color(0x22FFFFFF),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          icon,
          size: 16,
          color: highlighted ? AppColors.white : const Color(0xB3FFFFFF),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: highlighted ? AppColors.white : const Color(0xB3FFFFFF),
          ),
        ),
      ],
    ),
  );

  /// 中间那个绿色声波气泡（带一个朝下的小尖角）
  Widget _bubble(BuildContext context, VoiceRecordState state) {
    final width = math.min(
      MediaQuery.sizeOf(context).width * 0.46,
      context.rpx(520),
    );
    final height = width * 0.52;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: width,
          height: height,
          child: state.transcribing
              ? const _BubbleShape(
                  child: Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: AppColors.voiceOverlayWave,
                      ),
                    ),
                  ),
                )
              : _BubbleShape(
                  child: Center(
                    child: SizedBox(
                      width: width * 0.72,
                      height: height * 0.52,
                      child: _wave(context),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  /// 声波：静音时是一排小圆点，有声音就按音量起伏（左右对称）。
  ///
  /// [fixed] = 桌面那一档：固定逻辑像素（在那个窄卡片里，rpx 会把它撑爆）。
  Widget _wave(BuildContext context, {bool fixed = false}) {
    final barWidth = fixed ? 3.0 : context.rpx(7);
    final gap = fixed ? 4.0 : context.rpx(8);
    // 不足的用 0 补齐，让整排从左往右长出来
    final samples = <double>[
      ...List<double>.filled(
        math.max(0, VoiceRecordOverlay.barCount - _samples.length),
        0,
      ),
      ..._samples,
    ];
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        for (final sample in samples)
          Container(
            width: barWidth,
            // 微信那排条子是按音量高低对称的：最小 2rpx，最大整格
            height: fixed
                ? math.max(4, 4 + sample * 30)
                : math.max(
                    context.rpx(6),
                    context.rpx(6) + sample * (gap + context.rpx(56)),
                  ),
            decoration: BoxDecoration(
              color: fixed
                  ? AppColors.voiceOverlayBubble
                  : AppColors.voiceOverlayWave,
              borderRadius: BorderRadius.circular(barWidth),
            ),
          ),
      ],
    );
  }

  /// 底部：「取消 / 滑到这里 转文字」两条 + 最下面那条「松开 发送」
  Widget _bottom(BuildContext context, VoiceRecordState state) {
    final trayHeight = context.rpx(VoiceRecordOverlay.trayRpx);
    final zoneHeight = context.rpx(VoiceRecordOverlay.zoneRpx);
    final active = state.zone;
    final sendText = switch (active) {
      VoiceRecordZone.cancel => widget.cancelSendLabel,
      VoiceRecordZone.transcribe => widget.transcribeSendLabel,
      VoiceRecordZone.send => widget.sendLabel,
    };

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SizedBox(
        height: trayHeight + zoneHeight,
        child: Column(
          children: <Widget>[
            // 上半：两个区（手指滑上来才会亮）
            SizedBox(
              height: zoneHeight,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: context.rpx(24)),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: _zone(
                        context,
                        label: widget.cancelLabel,
                        icon: Icons.keyboard_arrow_left,
                        highlighted: active == VoiceRecordZone.cancel,
                        alignment: Alignment.centerLeft,
                      ),
                    ),
                    SizedBox(width: context.rpx(20)),
                    Expanded(
                      child: _zone(
                        context,
                        label: widget.transcribeLabel,
                        icon: Icons.keyboard_arrow_right,
                        highlighted: active == VoiceRecordZone.transcribe,
                        alignment: Alignment.centerRight,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // 下半：白色圆角托盘，写当前松手会发生什么
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: AppColors.white,
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(context.rpx(40)),
                  ),
                ),
                alignment: Alignment.center,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(
                      state.transcribing ? widget.transcribingLabel : sendText,
                      // 微信那条是加粗近黑（未转文字/取消时文案跟着变）
                      style: TextStyle(
                        fontSize: context.rpx(32),
                        fontWeight: FontWeight.w600,
                        color: AppColors.voiceOverlayText,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _zone(
    BuildContext context, {
    required String label,
    required IconData icon,
    required bool highlighted,
    required Alignment alignment,
  }) {
    final color = highlighted
        ? AppColors.white
        : AppColors.white.withValues(alpha: 0.72);
    return Align(
      alignment: alignment,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: context.rpx(28),
          vertical: context.rpx(18),
        ),
        decoration: BoxDecoration(
          // 微信：滑上来那一侧会亮起来，另一侧是灰的
          color: highlighted
              ? const Color(0x66FFFFFF)
              : const Color(0x22FFFFFF),
          borderRadius: BorderRadius.circular(context.rpx(16)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: context.rpx(34), color: color),
            SizedBox(width: context.rpx(8)),
            Text(
              label,
              style: TextStyle(fontSize: context.rpx(28), color: color),
            ),
          ],
        ),
      ),
    );
  }
}

/// 气泡形状：圆角矩形 + 底下正中的小尖角（微信那个绿气泡）
class _BubbleShape extends StatelessWidget {
  const _BubbleShape({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _BubblePainter(
      color: AppColors.voiceOverlayBubble,
      radius: context.rpx(24),
      tailSize: context.rpx(16),
    ),
    child: child,
  );
}

class _BubblePainter extends CustomPainter {
  const _BubblePainter({
    required this.color,
    required this.radius,
    required this.tailSize,
  });

  final Color color;
  final double radius;
  final double tailSize;

  @override
  void paint(Canvas canvas, Size size) {
    final body = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width, size.height - tailSize * 0.5),
          Radius.circular(radius),
        ),
      );
    // 底下的小尖角：一个等腰三角形，从气泡底边中间往下伸
    final tail = Path()
      ..moveTo(size.width / 2 - tailSize, size.height - tailSize * 0.6)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width / 2 + tailSize, size.height - tailSize * 0.6)
      ..close();
    final paint = Paint()..color = color;
    canvas.drawPath(body, paint);
    canvas.drawPath(tail, paint);
  }

  @override
  bool shouldRepaint(_BubblePainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.radius != radius ||
      oldDelegate.tailSize != tailSize;
}
