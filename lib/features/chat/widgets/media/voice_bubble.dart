import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/audio/voice_player.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_dimens.dart';
import '../../../../domain/chat/message_media.dart';
import '../message_bubble.dart' show bubbleColorOf;

/// 语音消息（老端 `components/messageType/im-voice.vue`）。
///
/// 微信那套（用户 2026-09-20 的截图）：
/// * **自己和对方都是同一个气泡**（自己绿、对方白），宽度按时长长出来：
///   `最短 + 秒数 × 每秒钟多少`，再夹一道上限。老端是 `秒数 × 3px` 夹 160…400rpx，
///   但那个 3px 是**逻辑像素**、而夹取用的是 rpx，两套单位混着，结果短语音永远顶在最小宽度
///   （4 秒和 20 秒一样宽）；这里统一按 rpx 算。
/// * 内容就两样：**时长 + 声波图标**，图标在「靠外」的那一侧（自己的在右、对方的在左）。
/// * 播放时气泡底色不变，变的是那个声波 —— 三道弧会一道道亮起来（微信的动画）。
/// * 点一下开始播，再点一下停（老端 `playVoice`）。
///
/// 老端用一个全局下标 `playIndex` 记「哪条在播」，下标一变高亮就错位；
/// 这里按**语音地址**判断（见 [VoicePlayerNotifier]）。
class VoiceBubble extends ConsumerWidget {
  const VoiceBubble({super.key, required this.payload, required this.mine});

  final VoicePayload payload;
  final bool mine;

  /// 气泡高度（微信约 44dp）
  static const double heightRpx = 88;

  /// 最短 / 最长宽度（4 秒和 60 秒的差别就靠这两头夹出来）
  static const double minWidthRpx = 180;
  static const double maxWidthRpx = 460;

  /// 每多一秒长多少
  static const double perSecondRpx = 9;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playing = ref.watch(voicePlayingProvider) == payload.url;
    final minWidth = context.rpx(minWidthRpx);
    final maxWidth = context.rpx(maxWidthRpx);
    final width = (minWidth + payload.duration * context.rpx(perSecondRpx))
        .clamp(minWidth, maxWidth);

    return GestureDetector(
      onTap: () => ref.read(voicePlayingProvider.notifier).toggle(payload.url),
      child: Container(
        width: width,
        height: context.rpx(heightRpx),
        padding: EdgeInsets.symmetric(horizontal: context.rpx(24)),
        decoration: BoxDecoration(
          // 微信：自己的那条绿、对方的白；播放中**不变色**（变的是声波动画）
          color: bubbleColorOf(mine),
          borderRadius: BorderRadius.circular(context.rpx(20)),
        ),
        child: Row(
          // 自己的那条图标在右（老端 im-rows-reverse）
          textDirection: mine ? TextDirection.rtl : TextDirection.ltr,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Transform.flip(
              // 自己的消息镜像一下：**圆点在最外侧、光弧朝里对着时长**
              // （老端 `im-voice.vue` 也是这么干的：`isSelf ? rotate225 : rotate45`）
              flipX: mine,
              child: VoiceWaveIcon(
                playing: playing,
                color: AppColors.text111,
                size: context.rpx(44),
              ),
            ),
            Text(
              '${payload.duration} "',
              style: TextStyle(
                fontSize: context.rpx(32),
                color: AppColors.text111,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 微信语音气泡里那个「声波」：三道光弧 + 一个实心点。
///
/// 不播的时候三道光弧都在；**播的时候一道道亮起来**（1 → 2 → 3 循环），
/// 这就是微信那个「波纹会变」的细节。
class VoiceWaveIcon extends StatefulWidget {
  const VoiceWaveIcon({
    super.key,
    required this.playing,
    required this.color,
    required this.size,
  });

  final bool playing;
  final Color color;
  final double size;

  @override
  State<VoiceWaveIcon> createState() => _VoiceWaveIconState();
}

class _VoiceWaveIconState extends State<VoiceWaveIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.playing) _controller.repeat();
  }

  @override
  void didUpdateWidget(VoiceWaveIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing == oldWidget.playing) return;
    if (widget.playing) {
      _controller.repeat();
    } else {
      _controller.stop();
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    builder: (context, _) => SizedBox(
      width: widget.size,
      height: widget.size,
      child: CustomPaint(
        painter: _VoiceWavePainter(
          color: widget.color,
          // 不播时三道全亮；播的时候按进度露出 1 / 2 / 3 道
          arcs: widget.playing ? 1 + (_controller.value * 3).floor() : 3,
        ),
      ),
    ),
  );
}

/// 那个「声波」的画法：**一个实心圆点 + 围绕它的三道同心弧**（微信那套）。
///
/// 原来的画法是错的，所以看着丑（用户 2026-09-21 抓到的）：三道弧各画了一个
/// **半圆**（±90°，所以弧高到 `size` 高）、圆心还摆在右半边（半径 0.5 的弧直接
/// 画到方块外面去了），于是三圈一大一小的“C”形叠在一起、还漏到时长文字上。
///
/// 现在：
/// * 圆心就是那个点（同心弧，不是三个各摆各的）；
/// * 张开的角度只有 ~100°（微信也不是半圆），粗细 0.085、圆头；
/// * 最外圈的半径 0.52，加上圆点的 0.24，刚好落在方块里（不会溢出）。
class _VoiceWavePainter extends CustomPainter {
  const _VoiceWavePainter({required this.color, required this.arcs});

  /// 弧张开多少弧度（约 100°）
  static const double _sweep = 1.75;

  /// 圆点离左边多远（自己那条会被镜像到右边，就是「圆点在最外侧」）
  static const double _dotX = 0.24;

  final Color color;

  /// 亮起几道光弧（1…3）
  final int arcs;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final center = Offset(side * _dotX, size.height / 2);

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = side * 0.085;

    for (var index = 0; index < arcs; index++) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: side * (0.26 + index * 0.13)),
        -_sweep / 2,
        _sweep,
        false,
        paint,
      );
    }

    // 实心点（声音的源头）
    canvas.drawCircle(center, side * 0.12, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_VoiceWavePainter oldDelegate) =>
      oldDelegate.arcs != arcs || oldDelegate.color != color;
}
