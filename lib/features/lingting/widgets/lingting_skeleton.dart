import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';

/// 详情页（歌单 / 歌手 / 专辑）第一块还没回来时的骨架。
///
/// 这一层是「分层加载」的兜底观感：**有缓存或已经有数据时根本不画它**
/// （页面直接画内容），只有「第一次进这个页面 + 网络还没回来」才摆这一屏灰块，
/// 让用户看出「这一页已经在拿了」，而不是一个居中的转圈。
///
/// 与首页那个骨架同一条规矩：**不做闪烁动画** —— 那会把组件测试里的
/// `pumpAndSettle` 挂死，而这里要的只是「在路上」这一个信息。
class LingtingDetailSkeleton extends StatelessWidget {
  const LingtingDetailSkeleton({super.key, this.rows = 6});

  /// 头部底下摆几行歌曲占位
  final int rows;

  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.only(top: context.rpx(24)),
    children: <Widget>[
      // 头部：封面 + 两条灰线（这里就是歌单/歌手/专辑那个大头）
      Padding(
        padding: EdgeInsets.symmetric(horizontal: context.rpx(30)),
        child: Row(
          children: <Widget>[
            _Block(
              width: context.rpx(200),
              height: context.rpx(200),
              radius: context.rpx(16),
            ),
            SizedBox(width: context.rpx(24)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _Block(height: context.rpx(34), radius: context.rpx(6)),
                  SizedBox(height: context.rpx(18)),
                  _Block(
                    width: context.rpx(200),
                    height: context.rpx(24),
                    radius: context.rpx(6),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      SizedBox(height: context.rpx(36)),
      for (var i = 0; i < rows; i++)
        Padding(
          padding: EdgeInsets.fromLTRB(
            context.rpx(30),
            context.rpx(12),
            context.rpx(30),
            context.rpx(12),
          ),
          child: Row(
            children: <Widget>[
              _Block(
                width: context.rpx(28),
                height: context.rpx(28),
                radius: context.rpx(6),
              ),
              SizedBox(width: context.rpx(24)),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _Block(height: context.rpx(26), radius: context.rpx(6)),
                    SizedBox(height: context.rpx(14)),
                    _Block(
                      width: context.rpx(220),
                      height: context.rpx(22),
                      radius: context.rpx(6),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

/// 骨架里的一个灰块
class _Block extends StatelessWidget {
  const _Block({this.width, required this.height, required this.radius});

  final double? width;
  final double height;
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
