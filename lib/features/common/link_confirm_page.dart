import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/router/app_router.dart';
import '../desktop_window/desktop_link_window.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';

/// 「第三方网址，是否继续访问」（用户 2026-09-25 的要求）。
///
/// 除了我们自己的站点，任何外链都先过这一页 —— 微信打开非官方网页也是这路子。
/// 点「继续访问」才真的建 webview：用 `pushReplacement`（或者是桌面那条
/// 独立网页窗），于是从网页返回时直接回到聊天页，中间这页不会又冒出来。
class LinkConfirmPage extends ConsumerWidget {
  const LinkConfirmPage({super.key, this.url = ''});

  /// 待打开的地址（裸域名在上一跳已经补过 `http://`）
  final String url;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);
    final host = Uri.tryParse(url)?.host ?? '';

    return Scaffold(
      backgroundColor: AppColors.white,
      appBar: AppBar(title: Text(i18n.t('link.confirmTitle'))),
      // 可滚动：地址可能很长（带一长串参数），窄屏上不能直接溢出
      body: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: context.rpx(60),
            vertical: context.rpx(80),
          ),
          child: Column(
            children: <Widget>[
              SizedBox(height: context.rpx(40)),
              // 灰圈问号：既不像红圈那样「你犯错了」，又足够引起注意
              Container(
                width: context.rpx(140),
                height: context.rpx(140),
                decoration: const BoxDecoration(
                  color: AppColors.page,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  '?',
                  style: TextStyle(
                    fontSize: context.rpx(80),
                    height: 1,
                    fontWeight: FontWeight.bold,
                    color: AppColors.text999,
                  ),
                ),
              ),
              SizedBox(height: context.rpx(40)),
              Text(
                i18n.t('link.confirmHeading'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: context.rpx(34),
                  fontWeight: FontWeight.w600,
                  color: AppColors.text333,
                ),
              ),
              SizedBox(height: context.rpx(20)),
              Text(
                i18n.t('link.confirmBody'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: context.rpx(26),
                  height: 1.6,
                  color: AppColors.text999,
                ),
              ),
              if (url.isNotEmpty) ...<Widget>[
                SizedBox(height: context.rpx(36)),
                // 微信那张确认页最下面就是这一行「网页由 xxx.com 提供」
                if (host.isNotEmpty)
                  Text(
                    i18n.t('link.providedBy', <String, String>{'host': host}),
                    style: TextStyle(
                      fontSize: context.rpx(24),
                      color: AppColors.text999,
                    ),
                  ),
                SizedBox(height: context.rpx(10)),
                Text(
                  url,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: context.rpx(22),
                    height: 1.5,
                    color: AppColors.text999,
                  ),
                ),
              ],
              SizedBox(height: context.rpx(60)),
              SizedBox(
                width: double.infinity,
                height: context.rpx(88),
                child: TextButton(
                  onPressed: url.isEmpty ? null : () => _continue(context),
                  style: TextButton.styleFrom(
                    backgroundColor: AppColors.wechatGreen,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(context.rpx(8)),
                    ),
                  ),
                  child: Text(
                    i18n.t('link.confirmContinue'),
                    style: TextStyle(
                      fontSize: context.rpx(30),
                      color: AppColors.white,
                    ),
                  ),
                ),
              ),
              SizedBox(height: context.rpx(20)),
              SizedBox(
                width: double.infinity,
                height: context.rpx(88),
                child: TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: Text(
                    i18n.t('common.cancel'),
                    style: TextStyle(
                      fontSize: context.rpx(30),
                      color: AppColors.text333,
                    ),
                  ),
                ),
              ),
              SizedBox(height: context.rpx(40) + context.bottomSafeHeight),
            ],
          ),
        ),
      ),
    );
  }

  /// 「继续访问」：桌面开成**独立的网页窗**（见 [openExternalLinkWindow]），
  /// 其余情况把这一页换成内嵌浏览器那一页。
  ///
  /// 桌面那条要顺手把自己收掉：网页去了另一扇窗口，本窗这页留着只会挡在
  /// 用户面前 —— 媒体号窗里点「阅读原文」时，收掉之后就回到那篇文章上
  /// （微信 PC 也是这个感觉：窗口弹出来了、聊天还在原地）。
  void _continue(BuildContext context) {
    if (openExternalLinkWindow(context, url)) {
      Navigator.of(context).maybePop();
      return;
    }
    context.pushReplacement(
      '${AppRoutes.webview}'
      '?title=${Uri.encodeComponent(Uri.tryParse(url)?.host ?? '')}'
      '&src=${Uri.encodeComponent(url)}',
    );
  }
}
