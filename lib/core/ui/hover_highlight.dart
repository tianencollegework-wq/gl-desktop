import 'package:flutter/widgets.dart';

/// 给**没有 `InkWell` 的自绘控件**补一层鼠标悬停反馈（桌面，2026-10-03）。
///
/// 为什么需要它：聊天输入栏那几颗钮（发送、＋、表情、语音）是
/// `GestureDetector + Container` 手画的 —— 微信那套形状与颜色，`InkWell` 的
/// 涟漪在水滴屏上不好看，所以当初就没用。代价是**桌面上它们完全没有悬停提示**：
/// 鼠标划过去像一块死掉的图，用户得先点一下才知道能不能点。
///
/// 这里只做两件事（不改变按下的样子、不加涟漪）：
///
/// 1. 悬停时在最上面压一层半透明蒙版（默认 8% 黑，白底上约等于 `#EDEDED`，
///    也就是微信顶部栏那档灰）；
/// 2. 桌面上把光标换成手型 —— 触摸平台上没有悬停这回事，光标也不存在。
///
/// `InkWell` 那一路（会话行、底部 tab、设置行）**不用**包这个：它们的悬停反馈
/// 由主题的 `hoverColor` 统一给（见 `core/theme/app_theme.dart`）。
class HoverHighlight extends StatefulWidget {
  const HoverHighlight({
    super.key,
    required this.child,
    this.borderRadius,
    this.overlayColor = const Color(0x14000000),
    this.enabled = true,
  });

  final Widget child;

  /// 蒙版形状要与被包住的控件一致（圆角钮要圆角、方块钮不用给）
  final BorderRadius? borderRadius;

  /// 悬停蒙版。深色底上的钮可以换一层白（比如通话页那几颗）
  final Color overlayColor;

  /// 关掉时既不蒙版也不换光标（不可点的钮不该有「能点」的暗示）
  final bool enabled;

  @override
  State<HoverHighlight> createState() => _HoverHighlightState();
}

class _HoverHighlightState extends State<HoverHighlight> {
  bool _hovering = false;

  void _setHovering(bool value) {
    if (!widget.enabled || _hovering == value) return;
    setState(() => _hovering = value);
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.enabled ? SystemMouseCursors.click : MouseCursor.defer,
    onEnter: (_) => _setHovering(true),
    onExit: (_) => _setHovering(false),
    child: Container(
      foregroundDecoration: _hovering
          ? BoxDecoration(
              color: widget.overlayColor,
              borderRadius: widget.borderRadius,
            )
          : null,
      child: widget.child,
    ),
  );
}
