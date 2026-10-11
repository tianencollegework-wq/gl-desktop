import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';

/// 「彻底拿不到内容」时那一屏的通用画法：一句说明 + 一颗「重试」。
///
/// 灵听（歌单 / 歌手 / 专辑详情）和资讯列表用的是**同一个组件** —— 同一件事在
/// 两处长得一样，用户才不用重新认一遍；以后想调字体/颜色也只有这一处。
/// （原来这个画法长在灵听的 `LingtingRetryView` 里，S12.3 提到 `core/ui`
/// 是因为资讯列表也要用它。）
///
/// 文案都由调用方给（走语言包）：这里不管哪一页失败、为什么失败，只负责画。
class RetryView extends StatelessWidget {
  const RetryView({
    super.key,
    required this.message,
    required this.retryLabel,
    required this.onRetry,
  });

  final String message;
  final String retryLabel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      // 说明可能是一整句（资讯那边接口的话就比较长）：留出边距、居中，
      // 免得它顶着屏幕两边
      padding: EdgeInsets.symmetric(horizontal: context.rpx(60)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: context.rpx(28),
              color: AppColors.text999,
            ),
          ),
          SizedBox(height: context.rpx(20)),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(foregroundColor: AppColors.wechatGreen),
            child: Text(
              retryLabel,
              style: TextStyle(fontSize: context.rpx(28)),
            ),
          ),
        ],
      ),
    ),
  );
}
