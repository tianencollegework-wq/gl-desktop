import 'package:flutter/material.dart';

import '../../../core/theme/app_dimens.dart';
import 'lingting_cover.dart';

/// 会转的唱片封面（播放页中间那块）。
///
/// 播放时才转、暂停就**停在原地**（不是跳回 0 度），跟实体唱片一样。
/// 用 `AnimationController` 的 `repeat()` + `value` 续接实现这一点：
/// 暂停时 `stop(canceled: false)`，恢复时接着 `repeat()`。
class LingtingSpinningCover extends StatefulWidget {
  const LingtingSpinningCover({
    super.key,
    required this.url,
    this.sizeRpx = 460,
    required this.playing,
  });

  final String url;
  final double sizeRpx;
  final bool playing;

  @override
  State<LingtingSpinningCover> createState() => _LingtingSpinningCoverState();
}

class _LingtingSpinningCoverState extends State<LingtingSpinningCover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  );

  @override
  void initState() {
    super.initState();
    if (widget.playing) _controller.repeat();
  }

  @override
  void didUpdateWidget(LingtingSpinningCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing == oldWidget.playing) return;
    if (widget.playing) {
      _controller.repeat();
    } else {
      // canceled: false → 停在当前角度，不清回 0
      _controller.stop(canceled: false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = context.rpx(widget.sizeRpx);
    return RotationTransition(
      turns: _controller,
      child: Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 24,
              spreadRadius: 2,
            ),
          ],
        ),
        child: ClipOval(
          child: LingtingCover(
            url: widget.url,
            circular: true,
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }
}
