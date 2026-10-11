import 'package:flutter/material.dart';

/// uni-app 的 rpx 换算与安全区尺寸。
///
/// 老端 everywhere 用 `rpx`（750rpx = 屏幕宽度）和 `upx2px(100)`，
/// Flutter 端统一通过 `context.rpx(...)` 表达，保证换算口径一致。
extension AppSizeContext on BuildContext {
  /// 750rpx = 屏幕逻辑宽度
  double rpx(double value) => MediaQuery.sizeOf(this).width / 750 * value;

  /// 状态栏高度（老端 `e.statusBarHeight`）
  double get statusBarHeight => MediaQuery.paddingOf(this).top;

  /// 底部安全区（老端 `inlineTools` / `paddingB`）
  double get bottomSafeHeight => MediaQuery.paddingOf(this).bottom;

  /// 老端 `App.vue` 里的自定义导航栏高度：`uni.upx2px(100)`
  double get customBarHeight => rpx(100);

  /// 老端 `CustomBar = statusBarHeight + (android ? 50 : 45)`
  double get customNavTotalHeight => statusBarHeight + (customBarHeight);
}

abstract final class AppDimens {
  /// 底部 tab 栏高度（rpx 值，交给上文的扩展换算）
  static const double tabBarRpx = 100;

  /// 圆角
  static const double radius = 10;

  // ------------------------------------------------ 微信的列表规矩
  //
  // 微信里所有列表（会话、通讯录、设置、「我」）**共用同一组尺寸**，不是一页一样。
  // 数值是从微信截图（1080×2316，3x）量出来的：行高 150px、分割线左缩进 43px、
  // 行首文字距左边 47px。都用 rpx（750 = 屏宽）表示，换机器不会跑掉。

  /// 行高：150px @3x = 50dp
  static const double listRowRpx = 96;

  /// 行左右内边距：47px @3x ≈ 16dp
  static const double listPadRpx = 30;

  /// 行首图标（通讯录的入口方块 / 好友头像，「我」页的线稿图标）
  static const double listIconRpx = 80;

  /// 图标与文字之间的间距
  static const double listGapRpx = 24;

  /// 行与行之间那条细线的左缩进。
  ///
  /// * 没有行首图标（微信的设置页）→ 从内边距开始（16dp）；
  /// * 有行首图标 → **从文字左边开始**（微信的通讯录、我页）。
  static const double listDividerRpx = listPadRpx;
  static const double listIconDividerRpx =
      listPadRpx + listIconRpx + listGapRpx;
}
