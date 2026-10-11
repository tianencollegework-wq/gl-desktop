import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// 通话页配色。
///
/// 底色与文案沿用老端 `hybrid/html/index.html` 那套（`.webrtc-box` 的 `#666`、
/// 文字与按钮标签的 `#f6f6f6`，挂断/接听两张 PNG 是红/绿圆钮，这里用
/// [AppColors.red] / [AppColors.green] 顶上）。
///
/// 2026-09-19 改版：界面按**微信**那套重排（用户指定），背景从老端那张
/// `wallpaper.png` 换成固定的深色渐变，并新增「按钮开着/关着」两套配色
/// （开 = 白底 + 深色图标，关 = 半透明白底 + 白图标）。
abstract final class CallColors {
  /// 背景（没有画面的那片深色；也是 [Scaffold] 的底色）
  static const Color backdrop = Color(0xFF2A2D34);

  /// 背景渐变（上浅下深，微信语音通话页那种深灰蓝）
  static const Color backdropTop = Color(0xFF3C404A);
  static const Color backdropBottom = Color(0xFF1B1D22);

  /// 名字、状态文案、计时、按钮标签
  static const Color text = Color(0xFFF6F6F6);

  /// 次要文字（「等待对方接受邀请..」这类状态文案，比名字淡一档）
  static const Color textDim = Color(0xA6FFFFFF);

  /// 圆钮：**开着**的样子（白底 + 深色图标）
  static const Color buttonOn = Color(0xFFFFFFFF);
  static const Color iconOn = Color(0xFF15171C);

  /// 圆钮：**关着**的样子（半透明白底 + 白色图标，微信那颗关掉的麦克风）
  static const Color buttonOff = Color(0x2BFFFFFF);
  static const Color iconOff = Color(0xFFFFFFFF);

  /// 视频通话顶部那层渐变压暗（名字/计时压在画面上才看得清）
  static const Color scrimStrong = Color(0x8C000000);
  static const Color scrimClear = Color(0x00000000);

  /// 小窗（画中画）卡片的底色：微信那种白底
  static const Color pipBackground = AppColors.white;

  /// 小窗里的主色（话机图标与文字）：用本 App 主绿，跟通话页那颗「接听」绿一致
  static const Color pipGreen = AppColors.green;
}
