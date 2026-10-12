import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';

/// 微信那种设置列表。三条规矩（全站共用，不是一页一样）：
///
/// 1. **通栏白底**：微信的「卡片」就是整块白，没有圆角、没有左右留白；
/// 2. **行高 50dp、行首文字距左 16dp**（量自截图：150px / 47px @3x）；
/// 3. 行与行之间一条 `#E5E5E5` 的 0.5 细线，**从文字左边开始**——没有行首图标
///    时就从内边距（16dp）起，有图标时从图标后面起（见 [dividerIndentRpx]）。
///
/// 组与组之间靠**页面底色的灰缝**分开（不加圆角卡片），可选的 [header] 就是
/// 微信那条灰色分组标题（它本身也落在灰底上）。
class MineList extends StatelessWidget {
  const MineList({
    super.key,
    required this.children,
    this.header = '',
    this.gapBefore = true,
    this.dividerIndentRpx = AppDimens.listDividerRpx,
    this.paddingRpx = 0,
  });

  final List<Widget> children;

  /// 分组标题（微信：「账号」「通用」「功能」「帮助与关于」）。空则不画。
  final String header;

  /// 上面留一条灰缝（8dp）。贴着页头时可以关掉。
  final bool gapBefore;

  /// 细线的左缩进，默认「从文字左边起」的两档见 [AppDimens]。
  final double dividerIndentRpx;

  /// 整块白底的左右缩进。
  ///
  /// 微信大多数列表是**通栏**的（0），但「关于」页那一块是往里缩的：
  /// 细线左右各距屏边 64px @3x = 44rpx（实测），所以那一页传 44
  /// （配合 `dividerIndentRpx: 0`，细线就正好是那一块的通宽）。
  final double paddingRpx;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(horizontal: context.rpx(paddingRpx)),
    child: _buildList(context),
  );

  Widget _buildList(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      if (gapBefore) SizedBox(height: context.rpx(16)),
      if (header.isNotEmpty)
        Container(
          height: context.rpx(62),
          alignment: Alignment.centerLeft,
          padding: EdgeInsets.symmetric(
            horizontal: context.rpx(AppDimens.listPadRpx),
          ),
          child: Text(
            header,
            style: TextStyle(
              fontSize: context.rpx(28),
              color: AppColors.text666,
            ),
          ),
        ),
      for (var i = 0; i < children.length; i++) ...<Widget>[
        children[i],
        if (i != children.length - 1)
          Container(
            height: 0.5,
            margin: EdgeInsets.only(left: context.rpx(dividerIndentRpx)),
            color: AppColors.rowDivider,
          ),
      ],
    ],
  );
}

/// 一行：可选的彩色线稿图标 + 标题 +（可选）右侧灰值 + 箭头。
///
/// 微信的图标是**裸的彩色字形**（绿的服务、黄的表情、蓝的设置…），不是白字 + 圆底，
/// 颜色见 [AppColors.iconGreen] 那一组（逐个从截图取的主色）。
class MineListItem extends StatelessWidget {
  const MineListItem({
    super.key,
    required this.label,
    this.icon,
    this.iconColor = AppColors.iconBlue,
    this.trailing = '',
    this.trailingColor,
    this.trailingWidget,
    this.onTap,
    this.showChevron = true,
  });

  final String label;

  /// 行首图标；设置页那几行没有图标（微信也是）
  final IconData? icon;
  final Color iconColor;

  /// 右侧的灰字（版本号、语言名都走它）。
  ///
  /// 太长（客服邮箱这种）会**省略号截断**而不是报 overflow：
  /// 它以前是个不伸缩的 `Text`，「关于」页那两行联系方式（2026-10-11 新增）
  /// 在窄屏上把整行撑出 1.9px 的溢出 —— 那是一个开发期就报错、真机上
  /// 画一条黄黑条纹的绘制缺陷，不该由每一页的文案长度去撞运气。
  final String trailing;

  /// 右侧值的颜色，默认那档灰；要表达「已开启 / 需处理」这种状态时才改它
  final Color? trailingColor;

  /// 右侧放个别的（开关之类），与 [trailing] 二选一
  final Widget? trailingWidget;

  /// 为 null 就是不可点
  final VoidCallback? onTap;

  /// 开关行整行可点、但不画箭头
  final bool showChevron;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Container(
      height: context.rpx(AppDimens.listRowRpx),
      color: AppColors.white,
      padding: EdgeInsets.symmetric(
        horizontal: context.rpx(AppDimens.listPadRpx),
      ),
      child: Row(
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: context.rpx(50), color: iconColor),
            SizedBox(width: context.rpx(AppDimens.listGapRpx)),
          ],
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: context.rpx(32),
                color: AppColors.text000,
              ),
            ),
          ),
          if (trailing.isNotEmpty)
            Flexible(
              child: Text(
                trailing,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: context.rpx(28),
                  color: trailingColor ?? AppColors.text666,
                ),
              ),
            ),
          ?trailingWidget,
          if (onTap != null && showChevron)
            Icon(
              Icons.chevron_right,
              size: context.rpx(36),
              color: AppColors.chevron,
            ),
        ],
      ),
    ),
  );
}

/// 一个开关行（微信的开关是品牌绿，主题里已经定好）。
class MineSwitchItem extends StatelessWidget {
  const MineSwitchItem({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => MineListItem(
    label: label,
    // 整行可点（微信里点行内任意处都能拨动开关），但不画箭头
    onTap: () => onChanged(!value),
    showChevron: false,
    trailingWidget: Switch(
      value: value,
      onChanged: onChanged,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
  );
}
