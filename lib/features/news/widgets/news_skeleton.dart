import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';

/// 资讯列表「第一块还没回来、而且本机一格缓存都没有」时的骨架屏。
///
/// 和灵听那边 `LingtingDetailSkeleton` 是同一条做法、同一条规矩：
/// **有缓存或已经有内容时根本不画它**（页面直接画内容），只有「第一次进这一页 +
/// 网络还没回来」才摆这一屏灰块 —— 让用户看出「这一页已经在拿了」，
/// 而不是屏幕正中间一个转圈（那个既看不出拿的是什么，还会让整页先空一下再跳）。
///
/// 灰块照着 `NewsSourceCard` 的版式摆：卡头（圆头像 + 号名 + 右上角相对时间）、
/// 16:9 的大封面、两条「左标题 + 右缩略图」的小行。内容一到是**原位换字**，
/// 版式不跳（S12.3）。
///
/// 与灵听那条一样的硬规矩：**不做闪烁动画**。闪烁动画会把组件测试里的
/// `pumpAndSettle` 挂死，而这一屏要传达的只有「在路上」这一个信息。
class NewsListSkeleton extends StatelessWidget {
  const NewsListSkeleton({super.key, this.cards = 2, this.rows = 2});

  /// 摆几张卡（默认两张：一屏刚好铺满，又不会让人以为列表就这么长）
  final int cards;

  /// 每张卡里的小行有几条
  final int rows;

  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.only(top: context.rpx(12)),
    physics: const AlwaysScrollableScrollPhysics(),
    children: <Widget>[for (var i = 0; i < cards; i++) _Card(rows: rows)],
  );
}

/// 一张号卡的灰模子（尺寸对齐 `NewsSourceCard`，内容来了原地换掉）
class _Card extends StatelessWidget {
  const _Card({required this.rows});

  final int rows;

  @override
  Widget build(BuildContext context) => Container(
    margin: EdgeInsets.fromLTRB(
      context.rpx(20),
      0,
      context.rpx(20),
      context.rpx(16),
    ),
    decoration: BoxDecoration(
      color: AppColors.white,
      borderRadius: BorderRadius.circular(context.rpx(12)),
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 卡头：圆头像 …… 号名 …… 右上角相对时间
        Padding(
          padding: EdgeInsets.fromLTRB(
            context.rpx(28),
            context.rpx(24),
            context.rpx(28),
            context.rpx(20),
          ),
          child: Row(
            children: <Widget>[
              _Block(
                width: context.rpx(64),
                height: context.rpx(64),
                radius: context.rpx(32),
              ),
              SizedBox(width: context.rpx(20)),
              _Block(
                width: context.rpx(220),
                height: context.rpx(30),
                radius: context.rpx(6),
              ),
              const Spacer(),
              _Block(
                width: context.rpx(110),
                height: context.rpx(24),
                radius: context.rpx(6),
              ),
            ],
          ),
        ),
        // 第一篇那块 16:9 的大封面（内容来了这里就是图压标题）
        const AspectRatio(aspectRatio: 16 / 9, child: _Block(radius: 0)),
        // 后面几篇：左两条灰标题 + 右一个方缩略图，行间一条细线
        for (var i = 0; i < rows; i++) ...<Widget>[
          Padding(
            padding: EdgeInsets.only(left: context.rpx(28)),
            child: Container(
              height: context.rpx(2),
              color: AppColors.rowDivider,
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              context.rpx(28),
              context.rpx(26),
              context.rpx(28),
              context.rpx(26),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(top: context.rpx(6)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        _Block(height: context.rpx(26), radius: context.rpx(6)),
                        SizedBox(height: context.rpx(14)),
                        _Block(
                          width: context.rpx(320),
                          height: context.rpx(26),
                          radius: context.rpx(6),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(width: context.rpx(24)),
                _Block(
                  width: context.rpx(132),
                  height: context.rpx(132),
                  radius: context.rpx(8),
                ),
              ],
            ),
          ),
        ],
      ],
    ),
  );
}

/// 骨架里的一个灰块（封面那块不给宽高，由外面的 `AspectRatio` 撑满）
class _Block extends StatelessWidget {
  const _Block({this.width, this.height, required this.radius});

  final double? width;
  final double? height;
  final double radius;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: AppColors.gray,
      borderRadius: BorderRadius.circular(radius),
    ),
  );
}
