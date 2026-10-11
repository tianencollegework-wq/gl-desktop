import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/router/app_router.dart';
import 'package:gracelinkim/core/router/session_guard.dart';

void main() {
  tearDown(() => sessionGuard.update(ready: false, hasSession: false));

  group('本地会话未恢复：停在启动页', () {
    test('任何路径都先去启动页，启动页自己不再跳', () {
      sessionGuard.update(ready: false, hasSession: false);
      expect(guardRedirect(AppRoutes.home), AppRoutes.splash);
      expect(guardRedirect(AppRoutes.chat), AppRoutes.splash);
      expect(guardRedirect(AppRoutes.splash), isNull);
    });
  });

  group('未登录', () {
    setUp(() => sessionGuard.update(ready: true, hasSession: false));

    test('主界面与业务页一律回登录页', () {
      expect(guardRedirect(AppRoutes.home), AppRoutes.login);
      expect(guardRedirect(AppRoutes.chat), AppRoutes.login);
      expect(guardRedirect(AppRoutes.mineSetting), AppRoutes.login);
    });

    test('登录 / 注册页放行', () {
      expect(guardRedirect(AppRoutes.login), isNull);
      expect(guardRedirect(AppRoutes.register), isNull);
    });

    test('扫码登录确认页不放行：它要拿本机登录态去确认，没登录就先请去登录', () {
      // 老端把它放在 `pages/login/` 目录下只是文件摆放，不是「游客可进」；
      // 放进白名单的话，已登录的人扫到登录码会被弹回首页（功能等于不通）。
      expect(guardRedirect(AppRoutes.qrLogin), AppRoutes.login);
    });

    test('启动页就绪后自动让开', () {
      expect(guardRedirect(AppRoutes.splash), AppRoutes.login);
    });
  });

  group('已登录', () {
    setUp(() => sessionGuard.update(ready: true, hasSession: true));

    test('登录页不再停留（登录成功的跳转就靠这条）', () {
      expect(guardRedirect(AppRoutes.login), AppRoutes.home);
      expect(guardRedirect(AppRoutes.register), AppRoutes.home);
    });

    test('启动页让开去主界面', () {
      expect(guardRedirect(AppRoutes.splash), AppRoutes.home);
    });

    test('业务页放行', () {
      expect(guardRedirect(AppRoutes.home), isNull);
      expect(guardRedirect(AppRoutes.chat), isNull);
    });

    test('扫码登录确认页也放行（扫一扫就在主界面里，扫到直接进）', () {
      expect(guardRedirect(AppRoutes.qrLogin), isNull);
    });
  });

  test('状态没变化时不会重复通知（避免守卫无意义重算）', () {
    var notifications = 0;
    void listener() => notifications++;
    sessionGuard.addListener(listener);
    addTearDown(() => sessionGuard.removeListener(listener));

    sessionGuard.update(ready: true, hasSession: false);
    sessionGuard.update(ready: true, hasSession: false);
    expect(notifications, 1);

    sessionGuard.update(ready: true, hasSession: true);
    expect(notifications, 2);
  });
}
