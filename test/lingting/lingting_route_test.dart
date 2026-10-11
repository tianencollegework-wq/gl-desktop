import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/router/app_router.dart';
import 'package:gracelinkim/core/router/session_guard.dart';

/// 灵听进得来的那条路 + 它自己的路由。
///
/// **入口变了**（2026-09-27）：从前是服务端「发现」配置里填
/// `/pages/lingting/index`，由 `compassRouteOf` 剥掉 `pages` 前缀才落到
/// `/lingting/index`；现在「发现」那一页是**客户端写死的**，那一栏直接指
/// `AppRoutes.lingtingHome`（那一栏本身由 `test/features/compass_page_test.dart`
/// 盯着），所以这里只管两件事：**路由表里真有这几个页面**、
/// 以及**没登录时照样被守卫弹回登录页**。
void main() {
  test('灵听的六个路由都不在「待实现占位」名单里（进了就是真页面）', () {
    const lingtingRoutes = <String>[
      AppRoutes.lingtingHome,
      AppRoutes.lingtingSearch,
      AppRoutes.lingtingSheet,
      AppRoutes.lingtingSinger,
      AppRoutes.lingtingAlbum,
      AppRoutes.lingtingPlayer,
    ];
    for (final route in lingtingRoutes) {
      expect(
        pendingRoutePaths,
        isNot(contains(route)),
        reason: '$route 不该还挂着占位页',
      );
    }
  });

  test('没登录时灵听也会被守卫弹回登录页（和别的站内页一个待遇）', () {
    expect(AppRoutes.isAuthRoute(AppRoutes.lingtingHome), isFalse);
    // 会话已恢复完、但没有登录态 → 非白名单路径一律回登录页
    sessionGuard.update(ready: true, hasSession: false);
    expect(guardRedirect(AppRoutes.lingtingHome), AppRoutes.login);

    // 登录着就放行（否则「发现」里那一条点进去会跳回登录页）
    sessionGuard.update(ready: true, hasSession: true);
    expect(guardRedirect(AppRoutes.lingtingHome), isNull);
  });
}
