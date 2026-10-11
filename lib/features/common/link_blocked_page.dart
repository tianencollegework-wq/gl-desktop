import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';

/// 「已停止访问该网页」（用户 2026-09-25 的要求：微信/腾讯那一系的地址一律拦住）。
///
/// 版式照微信那张拦截页：一整个白底、居中一个**红圈 + 感叹号**，
/// 下面一句大字标题、一句灰色说明，最底下用浅灰小字把那条网址列出来
/// （用户看得出来自己点的是什么，也方便截图反馈）。
class LinkBlockedPage extends ConsumerWidget {
  const LinkBlockedPage({super.key, this.url = ''});

  /// 被拦下的地址（原样显示，不做跳转）
  final String url;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);

    return Scaffold(
      backgroundColor: AppColors.white,
      appBar: AppBar(title: Text(i18n.t('link.blockedAppBar'))),
      body: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: context.rpx(80),
            vertical: context.rpx(60),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              // 红圈 + 感叹号（微信那张拦截页最显眼的就是这个）
              Container(
                width: context.rpx(180),
                height: context.rpx(180),
                decoration: const BoxDecoration(
                  color: AppColors.red,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  '!',
                  style: TextStyle(
                    fontSize: context.rpx(110),
                    height: 1,
                    fontWeight: FontWeight.bold,
                    color: AppColors.white,
                  ),
                ),
              ),
              SizedBox(height: context.rpx(48)),
              Text(
                i18n.t('link.blockedTitle'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: context.rpx(36),
                  fontWeight: FontWeight.w600,
                  color: AppColors.text333,
                ),
              ),
              SizedBox(height: context.rpx(24)),
              Text(
                i18n.t('link.blockedBody'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: context.rpx(26),
                  height: 1.6,
                  color: AppColors.text999,
                ),
              ),
              if (url.isNotEmpty) ...<Widget>[
                SizedBox(height: context.rpx(40)),
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: context.rpx(20),
                    vertical: context.rpx(16),
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.page,
                    borderRadius: BorderRadius.circular(context.rpx(8)),
                  ),
                  child: Text(
                    url,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: context.rpx(22),
                      height: 1.5,
                      color: AppColors.text999,
                    ),
                  ),
                ),
              ],
              SizedBox(height: context.rpx(60)),
              SizedBox(
                width: double.infinity,
                height: context.rpx(88),
                child: TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  style: TextButton.styleFrom(
                    backgroundColor: AppColors.page,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(context.rpx(8)),
                    ),
                  ),
                  child: Text(
                    i18n.t('common.back'),
                    style: TextStyle(
                      fontSize: context.rpx(30),
                      color: AppColors.text333,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
