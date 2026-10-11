import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/config/app_info.dart';
import 'package:gracelinkim/features/splash/splash_page.dart';

/// 启动页（Flutter 这一段，Android 启动窗口那一段见 core/launch_resources_test）。
///
/// 两件事都是用户 2026-09-26 定的：
/// * logo **固定用本地原图**，不再优先取服务端下发的 `sysInfo.logo`
///   —— 要和桌面图标、Android 启动窗口那一屏保持同一个视觉；
/// * 图片下面**不再叠一行站点名**：这张 logo 里已经写着 GraceLink，
///   再叠一行就一屏两个品牌名。
void main() {
  testWidgets('启动页：本地原图 + 转圈，图片下面没有第二处品牌名', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SplashPage()));

    final logo = tester.widget<Image>(find.byType(Image));
    expect(
      (logo.image as AssetImage).assetName,
      AppInfo.logoAsset,
      reason: 'logo 要用本地原图（assets/images/logo.png）',
    );
    expect(logo.fit, BoxFit.cover);
    // 图上不叠任何文字：品牌名只出现在图片本身里
    expect(find.byType(Text), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
