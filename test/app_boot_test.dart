import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/config/app_config.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/features/notify/notification_host.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_database.dart';

void main() {
  group('AppConfig（对应老端 common/config.js）', () {
    const config = AppConfig(
      env: AppEnv.prod,
      scheme: 'https',
      host: 'message.gracelink.cc',
      hostToken: 'sha740A9C7018B2CB55C7CC93D75BE0E8D9bi',
    );

    test('apiUrl / wssUrl 拼接与老端一致', () {
      expect(config.apiUrl, 'https://message.gracelink.cc');
      expect(config.wssUrl, 'wss://message.gracelink.cc/wss');
    });

    test('hostToken 算法与老端一致（sha + md5(md5(host)) + bi）', () {
      // 这两个 md5 值用独立的 md5sum 实现核对过，不是从本算法反推出来的
      expect(config.expectedHostToken, 'sha33a368c6b977f663e8cb1c07eeec03f5bi');
    });

    test('线上这份 hostToken 与实际域名对不上（老端遗留问题，记录在案）', () {
      expect(config.hostTokenMatches, isFalse);
    });
  });

  group('主外壳与登录守卫', () {
    late AppI18n i18n;
    late AppDatabase db;
    late StubAdapter adapter;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await CredentialStore.init();
      i18n = await AppI18n.load('zh-Hans');
      // 主界面现在会渲染真会话列表（M4），所以要给它一个内存库和假网络，
      // 否则真文件库在测试环境下会一直挂在加载态
      db = memoryDatabase();
      adapter = StubAdapter()..ok(ChatPaths.contacts, data: const <Object>[]);
    });

    tearDown(() async {
      sessionGuard.update(ready: false, hasSession: false);
      await db.close();
    });

    Future<void> pumpApp(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            apiClientProvider.overrideWithValue(adapter.apiClient()),
          ],
          child: const GracelinkApp(),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// 收尾：拆掉整棵树，让 drift 关闭查询流时留下的零延迟定时器跑完
    /// （不消化掉，框架会报「Timer 未结束」并连带影响后续用例）
    Future<void> disposeApp(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    }

    testWidgets('语言包能加载（300+ 条文案）', (tester) async {
      expect(i18n.messageCount, greaterThan(300));
    });

    testWidgets('已登录：渲染底部 tab', (tester) async {
      sessionGuard.update(ready: true, hasSession: true);
      await pumpApp(tester);

      // 四个 tab。注意「发现」**不再等服务端** `compass.status == 1` 了
      // （2026-09-27 起那一页是纯客户端写死的，里面只有「灵听」一条），
      // 所以服务端什么都没配时它照样在。
      // 第一个 tab 与顶部标题都显示应用名（微信：顶部「微信」、底部也是「微信」）
      expect(find.text(i18n.t('user.appName')), findsWidgets);
      expect(find.text(i18n.t('user.contacts')), findsWidgets);
      // 底部第三个 tab 按微信写单个「我」字（顶部标题仍是「我的」）
      expect(find.text(i18n.t('user.mineTab')), findsWidgets);
      expect(find.text(i18n.t('user.compass')), findsWidgets);

      await disposeApp(tester);
    });

    testWidgets('未登录：直接落在登录页，看不到主界面', (tester) async {
      sessionGuard.update(ready: true, hasSession: false);
      await pumpApp(tester);

      expect(find.text(i18n.t('user.login')), findsWidgets);
      expect(find.text(i18n.t('user.remenberMe')), findsOneWidget);
      // 默认配置 regtype = 2（不开放注册），所以没有注册按钮
      expect(find.text(i18n.t('user.register')), findsNothing);
      expect(find.text(i18n.t('user.contacts')), findsNothing);

      await disposeApp(tester);
    });

    testWidgets('系统超大字号被压在 1.3 倍以内（版式按 rpx 画，撑不住 2 倍）', (tester) async {
      sessionGuard.update(ready: true, hasSession: true);
      // 用户在系统里把字号调到「超大」（2.0×）——这是最常见的无障碍设置
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await pumpApp(tester);

      // 取一处**在钳制之内**的 context：它看到的比例就是全站生效的比例。
      // NotificationHost 是最外层宿主，正好在钳制层里面。
      final scaler = MediaQuery.textScalerOf(
        tester.element(find.byType(NotificationHost)),
      );
      expect(scaler.scale(10), 13);

      await disposeApp(tester);
    });

    /// 摆成一台正常手机（360×780 逻辑像素）。
    ///
    /// 默认那个 800×600 的窗口又宽又矮，而 `rpx` 是按**宽度**换算的 —— 于是
    /// 字号被放大到接近 26px，「登录状态保持 / 忘记密码」那种行会假溢出。
    void usePhoneSurface(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
    }

    /// 把宿主「系统语言」换成这一档，并走真正的系统通知（`handleLocaleChanged`），
    /// 让 `GracelinkApp` 那个 observer 收到 —— 不是直接调 provider。
    ///
    /// [expectPack] 是这次**应该**换成的语言包（不该换就传 null）。换语言要读
    /// 语言包，那是真异步，`testWidgets` 的 fake-async 推不动，得用 `runAsync`
    /// 等它落地再断言。
    Future<void> changeSystemLocale(
      WidgetTester tester,
      Locale locale, {
      String? expectPack,
    }) async {
      tester.platformDispatcher.localesTestValue = <Locale>[locale];
      final before = AppI18n.instance.localeCode;

      await tester.runAsync(() async {
        WidgetsBinding.instance.handleLocaleChanged();
        for (var i = 0; i < 200; i++) {
          if (expectPack != null) {
            if (AppI18n.instance.localeCode == expectPack) return;
          } else if (i == 20) {
            // 不该换：给它两小格时间去换（真换了马上就会被逮住）
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(
          AppI18n.instance.localeCode,
          before,
          reason: '等 $expectPack 落地等超时了',
        );
      });
      await tester.pumpAndSettle();
    }

    testWidgets('跟随系统：系统语言一改，界面马上跟着换（不用重启）', (tester) async {
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      usePhoneSurface(tester);
      sessionGuard.update(ready: true, hasSession: false);
      await pumpApp(tester);

      // 没存过语言 = 跟随系统
      expect(CredentialStore.instance.language, isNull);

      await changeSystemLocale(tester, const Locale('ja'), expectPack: 'ja');

      // 语言包换成日语了，界面上的字也跟着换（登录页那颗按钮）
      expect(AppI18n.instance.localeCode, 'ja');
      expect(find.text('ログイン'), findsWidgets);
      // 跟随时**不落库**：下次启动还是看系统
      expect(CredentialStore.instance.language, isNull);

      await disposeApp(tester);
    });

    testWidgets('手动选过：系统语言改了也不动（用户定的不能被系统改掉）', (tester) async {
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);
      usePhoneSurface(tester);
      await CredentialStore.instance.saveLanguage('zh-Hans');
      addTearDown(() => CredentialStore.instance.saveLanguage(null));
      sessionGuard.update(ready: true, hasSession: false);
      await pumpApp(tester);

      await changeSystemLocale(tester, const Locale('de'));

      expect(AppI18n.instance.localeCode, 'zh-Hans');
      expect(find.text('登录'), findsWidgets);
      expect(find.text('Log in'), findsNothing);

      await disposeApp(tester);
    });

    testWidgets('本地会话未恢复：停在启动页', (tester) async {
      sessionGuard.update(ready: false, hasSession: false);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            apiClientProvider.overrideWithValue(adapter.apiClient()),
          ],
          child: const GracelinkApp(),
        ),
      );
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text(i18n.t('user.login')), findsNothing);

      await disposeApp(tester);
    });
  });
}
