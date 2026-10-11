import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/router/app_router.dart';
import 'package:gracelinkim/core/router/desktop_register_guard.dart';

/// 电脑端不许注册账号（用户 2026-10-08）。
///
/// 登录页上那颗「注册」按钮已经不画了，但**路由还在**：从「切换账号 › 添加账号 ›
/// 注册新账号」，或者旧链接 / 深链接都可能进来。这里钉住那一层拦截：
/// 电脑端访问两条注册路由一律送回登录页，手机上原样放行。
void main() {
  test('电脑端：两条注册路由都送去登录页', () {
    expect(
      desktopRegisterRedirect(AppRoutes.register, desktop: true),
      AppRoutes.login,
    );
    expect(
      desktopRegisterRedirect(AppRoutes.accountsAddRegister, desktop: true),
      AppRoutes.login,
    );
  });

  test('手机：注册照旧放行', () {
    expect(desktopRegisterRedirect(AppRoutes.register, desktop: false), isNull);
    expect(
      desktopRegisterRedirect(AppRoutes.accountsAddRegister, desktop: false),
      isNull,
    );
  });

  test('别的路由一律不插手（登录、添加账号、主界面…）', () {
    for (final location in <String>[
      AppRoutes.login,
      AppRoutes.accountsAdd,
      AppRoutes.home,
      AppRoutes.splash,
      AppRoutes.mineSetting,
    ]) {
      expect(
        desktopRegisterRedirect(location, desktop: true),
        isNull,
        reason: '$location 不该被这条规则动到',
      );
    }
  });
}
