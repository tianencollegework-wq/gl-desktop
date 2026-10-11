import 'package:flutter/material.dart';

import 'app_colors.dart';

/// 全局主题。
///
/// 目标是「一眼看出是同一个产品」，所以主色、背景灰、分割线都对齐老端 main.css，
/// 导航栏统一走自定义（老端 `pages.json` 里是 `navigationStyle: custom`）。
abstract final class AppTheme {
  static ThemeData get light {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: AppColors.green,
          brightness: Brightness.light,
        ).copyWith(
          primary: AppColors.brand,
          secondary: AppColors.green,
          error: AppColors.red,
          surface: AppColors.white,
        );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.page,
      splashFactory: InkRipple.splashFactory,
      // 桌面（2026-10-03）：鼠标悬停与键盘焦点。`InkWell` 那一路（会话行、
      // 底部 tab、设置行、通讯录行……）的悬停反馈全部来自这两个值，默认只有
      // 4% 黑，在白底列表上几乎看不出来；这里提到 8%（白底上约 #EBEBEB，
      // 正是微信顶部栏那档灰）。触摸平台上这两个值根本不会被触发。
      hoverColor: const Color(0x14000000),
      focusColor: const Color(0x14000000),
      // 微信的二级页顶部栏是**那档灰**（跟顶部栏、页面底同一个 `#EDEDED`），
      // 不是白底；下面一条细线跟内容分开。标题居中、17dp。
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.navBar,
        foregroundColor: AppColors.text000,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        shape: Border(
          bottom: BorderSide(color: AppColors.navDivider, width: 0.5),
        ),
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w500,
          color: AppColors.text000,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.line,
        thickness: 0.5,
        space: 0.5,
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: AppColors.brand),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.brand,
      ),
      // 微信那种**纯白**弹层卡片：M3 默认拿种子色派生出偏绿的 surfaceContainer，
      // 长按菜单/「＋」菜单都会渲染成淡绿灰，观感不对。
      popupMenuTheme: const PopupMenuThemeData(
        color: AppColors.white,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
        ),
        labelTextStyle: WidgetStatePropertyAll<TextStyle>(
          TextStyle(fontSize: 16, color: AppColors.text333),
        ),
      ),
      // 开关（消息免打扰 / 置顶聊天）照微信：打开是微信绿、白拽子，关上是浅灰
      switchTheme: SwitchThemeData(
        thumbColor: const WidgetStatePropertyAll<Color>(AppColors.white),
        trackColor: WidgetStateProperty.resolveWith<Color>(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.wechatGreen
              : const Color(0xFFDFDFDF),
        ),
        trackOutlineColor: const WidgetStatePropertyAll<Color>(
          Colors.transparent,
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Color(0xCC000000),
      ),
    );
  }
}
