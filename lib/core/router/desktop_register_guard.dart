import '../platform/desktop_shell.dart';
import 'app_router.dart';

/// 电脑端**不许注册账号**（用户 2026-10-08：「把电脑端的注册删掉，不允许电脑
/// 注册账号」）。
///
/// 登录页上那颗「注册」按钮已经不画了（见 `features/login/login_page.dart`），
/// 但两条注册路由还在：从「切换账号 › 添加账号 › 注册新账号」，或者旧链接 /
/// 深链接都可能进来。所以这里再拦一道 —— 电脑端访问注册路由，一律送回登录页。
///
/// 手机上原样放行：注册只在手机端开放。
///
/// 抽成纯函数是为了可测：[desktop] 由调用方传进来，用例就能把
/// 「电脑端拦下、手机放行」两张表直接钉住，不必去动全局开关。
String? desktopRegisterRedirect(String location, {required bool desktop}) {
  if (!desktop) return null;
  if (location == AppRoutes.register ||
      location == AppRoutes.accountsAddRegister) {
    return AppRoutes.login;
  }
  return null;
}

/// 生产里用的那一份：电脑端与否取全局开关。
///
/// 用 [desktopFeaturesEnabled] 而不是 `isDesktopRuntime`：后者在测试的桌面宿主机
/// 上也是真（见 `desktop_shell.dart`），会把这条规则误开进手机版式的用例。
String? desktopRegisterBlocked(String location) =>
    desktopRegisterRedirect(location, desktop: desktopFeaturesEnabled);
