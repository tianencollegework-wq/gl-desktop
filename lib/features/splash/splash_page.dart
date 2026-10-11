import 'package:flutter/material.dart';

import '../../core/config/app_info.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';

/// 启动页。
///
/// 老端没有这个页面：它一启动就画主界面，等接口 401 了再把人踢去登录页。
/// 新端在这里多停一下（只是一个本地存储的同步读取，通常不到一帧），
/// 目的是让路由守卫能一次性决定去主界面还是登录页，避免主页闪一下再跳走。
/// 真正的启动工作（连 WS、拉全局配置）在 [SessionService.bootstrap] 里，
/// 而且**不阻塞**这里——网络慢也只是晚一点拿到配置，不影响进界面。
///
/// 两处刻意为之：
/// * logo **固定用本地 [AppInfo.logoAsset]**，不再优先取服务端 `sysInfo.logo`
///   —— 品牌视觉要和桌面图标、Android 启动窗口那一屏保持一致（用户指定）。
/// * 图片下面**不再另起一行站点名**：这张 logo 里已经写着 GraceLink，
///   再叠一行就一屏两个品牌名了（图片本身不做任何裁切）。
class SplashPage extends StatelessWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.white,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            ClipRRect(
              borderRadius: BorderRadius.circular(context.rpx(18)),
              child: Image.asset(
                AppInfo.logoAsset,
                width: context.rpx(180),
                height: context.rpx(180),
                fit: BoxFit.cover,
              ),
            ),
            SizedBox(height: context.rpx(40)),
            SizedBox(
              width: context.rpx(48),
              height: context.rpx(48),
              child: const CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.blue,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
