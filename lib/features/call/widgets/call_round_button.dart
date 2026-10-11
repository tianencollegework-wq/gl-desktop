import 'package:flutter/material.dart';

import '../../../core/theme/app_dimens.dart';
import '../call_colors.dart';

/// 通话页那种「圆钮 + 下面一行字」。
///
/// 抽出来是因为**群通话页要用同一套观感**（2026-09-19 那次改版定的：
/// 开着 = 白底 + 深色图标，关着 = 半透明白底 + 白色图标），而 1:1 通话页里
/// 它是私有的 `_circleButton`。与其在群通话页抄一份，不如把这一颗共用。
///
/// [size] 是**逻辑像素**（调用方自己 `context.rpx(...)`）：1:1 那边算完尺寸才
/// 传进来，群通话那边按同样的 750 设计宽换算。
class CallRoundButton extends StatelessWidget {
  const CallRoundButton({
    super.key,
    required this.size,
    required this.background,
    required this.label,
    required this.onTap,
    required this.child,
    this.labelFontSize,
    this.labelGap,
  });

  final double size;
  final Color background;
  final String label;

  /// 标签字号 / 标签与圆钮的间距（逻辑像素）。
  ///
  /// 不传就是手机那档（`rpx(24)` / `rpx(10)`）；桌面版通话界面那套写死 12/6
  /// —— 那边一个 rpx 都不用，窗口一宽 rpx 就会把标签拉成大字（见
  /// `call_desktop_page.dart` 的文件头）。
  final double? labelFontSize;
  final double? labelGap;

  /// null = 禁用（点不动，界面不弄灰 —— 弄灰由调用方决定）
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    behavior: HitTestBehavior.opaque,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: background, shape: BoxShape.circle),
          child: child,
        ),
        Padding(
          padding: EdgeInsets.only(top: labelGap ?? context.rpx(10)),
          child: Text(
            label,
            style: TextStyle(
              fontSize: labelFontSize ?? context.rpx(24),
              color: CallColors.text,
            ),
          ),
        ),
      ],
    ),
  );
}

/// 开关圆钮（麦克风/共享屏幕那种"开着/关着"）：
/// **开着 = 白底 + 深色图标，关着 = 半透明白底 + 白色图标**。
///
/// [enabled] = false 时弄灰、点了没有任何反应（与 1:1 那边同一条规则）。
class CallRoundToggle extends StatelessWidget {
  const CallRoundToggle({
    super.key,
    required this.icon,
    required this.label,
    required this.on,
    required this.onTap,
    this.sizeRpx = 144,
    this.iconScale = 0.52,
    this.enabled = true,
  });

  final IconData icon;
  final String label;

  /// 这个功能正开着
  final bool on;
  final VoidCallback onTap;
  final double sizeRpx;
  final double iconScale;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final size = context.rpx(sizeRpx);
    return Opacity(
      opacity: enabled ? 1 : disabledOpacity,
      child: CallRoundButton(
        size: size,
        background: on ? CallColors.buttonOn : CallColors.buttonOff,
        label: label,
        onTap: enabled ? onTap : null,
        child: Icon(
          icon,
          size: size * iconScale,
          color: on ? CallColors.iconOn : CallColors.iconOff,
        ),
      ),
    );
  }
}

/// 禁用态的不透明度（共享屏幕时摄像头那几颗、以及点了没用的钮）
const double disabledOpacity = 0.35;
