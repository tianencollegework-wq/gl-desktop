import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../data/model/lingting/lyric.dart';

/// 歌词显示。
///
/// 两种情况：
/// * **有时间轴**（详情接口的 `.lrc`）→ 逐行列表，当前那一行高亮并自动滚到中间；
/// * **只有正文**（搜索接口给的歌词就是这种）→ 平铺显示，不做滚动、不做高亮。
///
/// 自动滚动用 `animateTo`（而不是 `jumpTo`）：歌词换行时平滑一点，
/// 不会出现「刷一下跳过去」的观感。用户手动拖动时也照旧跟随 ——
/// 音乐类 App 都是这个直觉（不像聊天那样「拖动后就不自动滚」）。
///
/// 有时间轴时**点某一行就跳到那一句**（[onLineTap]，微信/网易云都是这个手感）：
/// 想听副歌直接点那一行，不用拖进度条。没有时间轴的纯文本点不了（不知道对应哪一秒）。
class LingtingLyricView extends StatefulWidget {
  const LingtingLyricView({
    super.key,
    required this.lyric,
    required this.position,
    this.onLineTap,
    this.fontSizeRpx = 36,
    this.activeFontSizeRpx = 42,
    this.activeColor = AppColors.white,
    this.baseColor = const Color(0xB3FFFFFF),
    this.lineHeightRpx = 104,
  });

  final LingtingLyric lyric;

  /// 当前播放进度（用来算高亮哪一行）
  final Duration position;

  /// 点某一行 → 跳到那一刻（没时间轴的歌词不会调它）
  final void Function(LyricLine line)? onLineTap;

  final double fontSizeRpx;
  final double activeFontSizeRpx;
  final Color activeColor;
  final Color baseColor;
  final double lineHeightRpx;

  @override
  State<LingtingLyricView> createState() => _LingtingLyricViewState();
}

class _LingtingLyricViewState extends State<LingtingLyricView> {
  final ScrollController _controller = ScrollController();
  int _lastActive = -1;

  @override
  void didUpdateWidget(LingtingLyricView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final active = widget.lyric.activeIndex(widget.position);
    if (active != _lastActive) {
      _lastActive = active;
      _scrollTo(active);
    }
  }

  void _scrollTo(int index) {
    if (index < 0 || !_controller.hasClients) return;
    final offset = index * context.rpx(widget.lineHeightRpx);
    final max = _controller.position.maxScrollExtent;
    _controller.animateTo(
      offset.clamp(0, max),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.lyric.isEmpty) {
      return Center(
        child: Text(
          '♪',
          style: TextStyle(fontSize: context.rpx(60), color: widget.baseColor),
        ),
      );
    }
    if (!widget.lyric.hasTimeline) {
      // 只有正文：平铺 + 上下留白，能滚（长歌词）
      return SingleChildScrollView(
        padding: EdgeInsets.symmetric(vertical: context.rpx(40)),
        child: Text(
          widget.lyric.plain,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: context.rpx(widget.fontSizeRpx),
            height: 1.8,
            color: widget.baseColor,
          ),
        ),
      );
    }

    final active = widget.lyric.activeIndex(widget.position);
    return LayoutBuilder(
      builder: (context, constraints) {
        final lineHeight = context.rpx(widget.lineHeightRpx);
        // 上下各留半屏，这样第一行和最后一行都能滚到正中间
        final padding = (constraints.maxHeight - lineHeight) / 2;
        return ListView.builder(
          controller: _controller,
          padding: EdgeInsets.symmetric(vertical: padding < 0 ? 0 : padding),
          itemExtent: lineHeight,
          itemCount: widget.lyric.lines.length,
          itemBuilder: (context, index) {
            final line = widget.lyric.lines[index];
            final isActive = index == active;
            return GestureDetector(
              // 整行都能点（不用正好戳到字上）
              behavior: HitTestBehavior.opaque,
              onTap: widget.onLineTap == null
                  ? null
                  : () => widget.onLineTap!(line),
              child: Center(
                child: Text(
                  line.text,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.rpx(
                      isActive ? widget.activeFontSizeRpx : widget.fontSizeRpx,
                    ),
                    height: 1.3,
                    color: isActive ? widget.activeColor : widget.baseColor,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
