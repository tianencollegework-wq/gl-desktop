import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';

/// 号的「头像」：没有真实 logo，就用品牌色的圆底 + 一个标记（公众号的头像也是
/// 圆底 + 一个标记，远看是同一个印象）。
///
/// 列表的卡头和文章详情页**共用这一个**：同一个号在列表和详情页里长得一样，
/// 用户才认得出「我刚才点的是谁」。尺寸由调用方给（卡头 64、详情页 48，单位 rpx）。
class NewsSourceAvatar extends StatelessWidget {
  const NewsSourceAvatar({
    super.key,
    required this.sourceKey,
    this.diameter = 64,
  });

  final String sourceKey;

  /// 直径（rpx）
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final style = NewsSourceStyle.of(sourceKey);
    final single = style.badge.length == 1;
    return Container(
      width: context.rpx(diameter),
      height: context.rpx(diameter),
      alignment: Alignment.center,
      decoration: BoxDecoration(color: style.color, shape: BoxShape.circle),
      child: Text(
        style.badge,
        style: TextStyle(
          color: AppColors.white,
          // 两个字的徽标（IT / CB / IQ）字号小一档，不然会把圆撑满
          fontSize: context.rpx(diameter * (single ? 0.47 : 0.375)),
          fontWeight: FontWeight.w600,
          height: 1,
        ),
      ),
    );
  }
}

/// 号的配色：颜色尽量贴各家品牌色，并且**故意错开** —— IT之家和少数派都是红的，
/// 纯红＋纯红放在同一屏里两张卡会分不清。
///
/// 源从 4 个扩到 12 个后这条更要紧（蓝色系一下就有三个）：所以除了色相，
/// 还靠**两三个字符的徽标**区分（`IT` / `派` / `爱` / `钛` / `界` / `CB` …），
/// 远看是同一个印象，近看不会认错。没配到的源用 [fallback]。
class NewsSourceStyle {
  const NewsSourceStyle({required this.color, required this.badge});

  final Color color;
  final String badge;

  static const NewsSourceStyle fallback = NewsSourceStyle(
    color: AppColors.wechatGreen,
    badge: 'N',
  );

  static const Map<String, NewsSourceStyle> _styles = <String, NewsSourceStyle>{
    'ithome': NewsSourceStyle(color: Color(0xFFD7312C), badge: 'IT'),
    'sspai': NewsSourceStyle(color: Color(0xFFB01C25), badge: '派'),
    'ifanr': NewsSourceStyle(color: Color(0xFF1E7FE0), badge: '爱'),
    'geekpark': NewsSourceStyle(color: Color(0xFF00838F), badge: '极'),
    'tmtpost': NewsSourceStyle(color: Color(0xFF455A64), badge: '钛'),
    'jiemian': NewsSourceStyle(color: Color(0xFF1751A0), badge: '界'),
    'solidot': NewsSourceStyle(color: Color(0xFF2E7D46), badge: 'S'),
    'cnbeta': NewsSourceStyle(color: Color(0xFF263238), badge: 'CB'),
    'qbitai': NewsSourceStyle(color: Color(0xFF6A3DE8), badge: '量'),
    'infoq': NewsSourceStyle(color: Color(0xFF0E7C7B), badge: 'IQ'),
    'appinn': NewsSourceStyle(color: Color(0xFFE8730C), badge: '小'),
    'xinghua': NewsSourceStyle(color: Color(0xFFB4881F), badge: '兴'),
  };

  static NewsSourceStyle of(String sourceKey) => _styles[sourceKey] ?? fallback;
}
