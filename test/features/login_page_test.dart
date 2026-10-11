import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/i18n/locale_controller.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/theme/app_colors.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/model/global_config.dart';
import 'package:gracelinkim/features/login/login_page.dart';
import 'package:gracelinkim/features/login/register_page.dart';
import 'package:gracelinkim/features/login/widgets/auth_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 登录 / 注册页的排版细节。
///
/// 起因是用户报的一个怪现象：在登录页点输入框（系统键盘弹出来）时，
/// 钉在屏幕底部的版本号会被顶到「登录」和「注册」按钮中间。
/// 根因是 `Scaffold` 默认会把 body 按键盘高度往上缩。
///
/// 2026-09-29 用户嫌这两页丑，整体换成「淡绿渐变底 + 白卡片表单 + 圆角填充输入框
/// + 通栏药丸按钮」那套现代风，下面几条断言跟着改成了新版面，顺手把新加的两个
/// 零件（语言药丸、密码框那颗眼睛）也钉住。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    db = memoryDatabase();
    adapter = StubAdapter();
    sessionGuard.update(ready: true, hasSession: false); // 未登录 → 落在登录页
  });

  tearDown(() async {
    sessionGuard.update(ready: false, hasSession: false);
    await db.close();
  });

  /// 把测试窗口摆成一台正常手机（360×780 逻辑像素）。
  ///
  /// 测试默认窗口是 800×600（又宽又矮），而 `rpx` 是按**宽度**换算的
  /// （750rpx = 屏宽）—— 于是这套界面在测试里会比真机上高一大截，输入框直接掉到
  /// 屏幕外，`tap()` 会打空（真机上 273dp 的地方在测试里变成 583px）。
  void usePhoneSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  Future<void> pumpLogin(WidgetTester tester) async {
    usePhoneSurface(tester);
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

  /// 底部那行版本号（`{站点名} for {版本}`）。
  /// 站点名没拉到 / 服务端报的还是老端那个默认的 `Im` 时，显示的是 Gracelink
  Finder footer() => find.textContaining('for 1.0.0');

  testWidgets('键盘弹出时：版本号不上浮（仍然钉在屏幕底部）', (tester) async {
    addTearDown(tester.view.reset);
    await pumpLogin(tester);
    expect(footer(), findsOneWidget);

    final before = tester.getCenter(footer());

    // 模拟系统键盘：底部 300 逻辑像素
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();

    final after = tester.getCenter(footer());
    // 不上浮 = 位置一点不变。修之前它会正好上移 300（键盘高度），
    // 也就是跑到「登录 / 注册」两个按钮中间去（用户看到的现象）
    expect(after.dy, before.dy, reason: '版本号不该跟着键盘往上跑');
  });

  testWidgets('键盘的输入框仍然能滚出来（键盘高度加进了滚动内容）', (tester) async {
    addTearDown(tester.view.reset);
    await pumpLogin(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();

    // 账号输入框点一下能聚焦、内容还能滚动（键盘没把它压死在屏幕外）
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);
  });

  testWidgets('现代风那几件都在：白卡片表单 + 圆角填充输入框 + 通栏药丸按钮', (tester) async {
    addTearDown(tester.view.reset);
    await pumpLogin(tester);

    expect(find.byType(LoginPage), findsOneWidget);
    // 输入区被一张白卡片框起来（老版是白底 + 一根根下划线；卡片有圆角和投影）
    expect(find.byType(AuthCard), findsOneWidget);
    final card = tester.widget<AuthCard>(find.byType(AuthCard));
    expect(card.children, isNotEmpty);

    // 两行输入：账号 / 密码（看行标题，不要数屏幕上的字 —— hint 现在独立成一个 key）
    final rows = tester
        .widgetList<AuthFormRow>(find.byType(AuthFormRow))
        .map((row) => row.title)
        .toList();
    expect(rows, <String>['账号', '密码']);
    expect(find.byType(AuthTextField), findsNWidgets(2));

    final button = tester.widget<ElevatedButton>(
      find.ancestor(of: find.text('登录'), matching: find.byType(ElevatedButton)),
    );
    final style = button.style!;
    expect(
      style.backgroundColor?.resolve(<WidgetState>{}),
      AppColors.wechatGreen,
      reason: '主按钮还是品牌绿，只是换成了通栏药丸',
    );
    final shape =
        style.shape?.resolve(<WidgetState>{}) as RoundedRectangleBorder;
    final buttonHeight = tester.getSize(find.byType(AuthButton)).height;
    expect(
      (shape.borderRadius as BorderRadius).topLeft.x,
      greaterThan(buttonHeight / 2 - 1),
      reason: '圆角给到半个高度才是现在这种药丸按钮',
    );

    // 忘记密码还是白底上的绿色文字链接（不是描边按钮）
    expect(find.byType(AuthTextLink), findsWidgets);
    expect(find.text('忘记密码'), findsOneWidget);
  });

  testWidgets('新加的两处：右上角语言药丸、密码框那颗眼睛', (tester) async {
    addTearDown(tester.view.reset);
    await pumpLogin(tester);

    // 语言切换从「一行灰字」升级成药丸，注册页现在也有了
    expect(find.byType(AuthLanguageChip), findsOneWidget);

    // 药丸上写的是**当前**语言那一项。这台机器没手动选过语言，按 2026-09-30
    // 定的口径就是「跟随系统」（2026-10-01 起选择器里最上面那条）——
    // 它跟着当前界面语言写，而用例里的包固定是简中，所以这里就是「跟随系统」。
    expect(find.text('跟随系统'), findsOneWidget);

    // 密码默认遮着，点一下变明文（老端没这个，手机上很容易戳错）
    expect(find.byIcon(Icons.visibility_off_rounded), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).last).obscureText,
      isTrue,
    );
    await tester.tap(find.byIcon(Icons.visibility_off_rounded));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.visibility_rounded), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).last).obscureText,
      isFalse,
    );
  });

  testWidgets('手动选过语言：药丸写的是存下来的那份（不跟系统）', (tester) async {
    // 用户 2026-09-30 定的口径：手动选过就听他的（重启也一样）。
    // 这里模拟「上次选了繁体、这次冷启动」：存好再起 App。
    await CredentialStore.instance.saveLanguage('zh-Hant');
    addTearDown(() => CredentialStore.instance.saveLanguage(null));
    await pumpLogin(tester);

    expect(find.text('繁體中文'), findsOneWidget);
    expect(find.text('跟随系统'), findsNothing, reason: '存过语言就不该再写「跟随系统」');
  });

  testWidgets('窄屏（320dp）：七种语言下登录页都不溢出', (tester) async {
    // 320dp = 老手机的宽度（全站版式按 `rpx` 画，窄屏最容易顶爆）。
    // 同一句话各语言长度差得很远（中文 4 个字 vs 德语一长串），所以七种都过一遍。
    tester.view.physicalSize = const Size(960, 1707);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    addTearDown(() => CredentialStore.instance.saveLanguage(null));

    for (final option in LocaleController.options) {
      await CredentialStore.instance.saveLanguage(option.code);
      await tester.runAsync(() => AppI18n.load(option.code));

      await tester.pumpWidget(
        ProviderScope(
          // 每一档都换一棵新树：ProviderScope 类型相同的话元素会被复用，
          // 容器里 `localeProvider` 还是第一次算出来的那一档，后面几轮白验。
          key: ValueKey<String>(option.code),
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            apiClientProvider.overrideWithValue(adapter.apiClient()),
          ],
          child: const GracelinkApp(),
        ),
      );
      await tester.pumpAndSettle();

      // 确实在画这一档的字（不然七轮验的都是同一种语言）
      expect(
        find.text(option.label),
        findsWidgets,
        reason: '${option.code} 没画出来',
      );

      // 顶爆的话框架会把「RenderFlex overflowed」记成一次异常
      expect(
        tester.takeException(),
        isNull,
        reason: '${option.code} 在 320dp 下把版面顶爆了',
      );
    }
  });

  testWidgets('版面顺序：品牌在顶 → 卡片里的输入行 → 记住我/忘记密码 → 通栏按钮', (tester) async {
    addTearDown(tester.view.reset);
    await pumpLogin(tester);

    final brand = tester.getCenter(find.byType(Image).first);
    final card = tester.getRect(find.byType(AuthCard));
    final accountRow = tester.getCenter(find.byType(AuthFormRow).first);
    final button = tester.getCenter(find.byType(AuthButton));
    final link = tester.getCenter(find.text('忘记密码'));

    expect(brand.dy, lessThan(card.top), reason: 'logo + 站点名在卡片外面、上面');
    expect(accountRow.dy, greaterThan(card.top));
    expect(accountRow.dy, lessThan(link.dy));
    expect(link.dy, lessThan(button.dy), reason: '忘记密码夹在输入和登录按钮之间');
    expect(button.dy, lessThan(card.bottom), reason: '登录按钮也在卡片里（卡片是整块表单）');

    // 通栏：按钮宽度占掉屏幕大半（不是原来那种窄窄一颗）
    final screenWidth =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(
      tester.getSize(find.byType(AuthButton)).width,
      greaterThan(screenWidth * 0.6),
    );
  });

  testWidgets('「忘记密码」切到验证码登录：密码框整行换成验证码框（发送按钮在框里）', (tester) async {
    addTearDown(tester.view.reset);
    await pumpLogin(tester);

    await tester.tap(find.text('忘记密码'));
    await tester.pumpAndSettle();

    final rows = tester
        .widgetList<AuthFormRow>(find.byType(AuthFormRow))
        .map((row) => row.title)
        .toList();
    expect(rows, <String>['账号', '验证码'], reason: '密码框换成了验证码框');
    // 发送验证码那颗按钮现在**在输入框里**（以前挂在行尾），点得动、不溢出
    expect(find.byType(AuthCodeButton), findsOneWidget);
    expect(find.text('发送验证码'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '框里多一颗按钮不能把行撑破');

    // 切回来：密码框和那颗眼睛都回来
    await tester.tap(find.text('密码登陆'));
    await tester.pumpAndSettle();
    expect(find.byType(AuthCodeButton), findsNothing);
    expect(find.byIcon(Icons.visibility_off_rounded), findsOneWidget);
  });

  testWidgets('演示模式那三行提示走的是语言包（以前是写死的中文）', (tester) async {
    addTearDown(tester.view.reset);
    await pumpLogin(tester);
    expect(find.text('站点仅用于演示，演示账号'), findsNothing);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    container
        .read(sessionStoreProvider.notifier)
        .applyConfig(
          const GlobalConfig(
            sysInfo: SysInfo(name: '恩信'),
            chatInfo: ChatInfo(),
            compass: CompassConfig(),
            demonMode: true,
          ),
        );
    await tester.pumpAndSettle();

    expect(find.text('站点仅用于演示，演示账号'), findsOneWidget);
    expect(find.text('账号：13800000002~13800000020'), findsOneWidget);
    expect(find.text('密码：123456'), findsOneWidget);
  });

  testWidgets('开放注册时：登录按钮下面是一颗描边「注册」按钮（不再是行小字）', (tester) async {
    addTearDown(tester.view.reset);
    await pumpLogin(tester);

    // 默认 `SysInfo.regtype` 是 2（仅邀请）→ 用户 2026-09-29 的 `registerOpen` 才是 1
    expect(find.byType(AuthSecondaryButton), findsNothing);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    container
        .read(sessionStoreProvider.notifier)
        .applyConfig(
          GlobalConfig(
            sysInfo: const SysInfo(name: '恩信', regtype: 1),
            chatInfo: const ChatInfo(),
            compass: const CompassConfig(),
            demonMode: false,
          ),
        );
    await tester.pumpAndSettle();

    expect(find.byType(AuthSecondaryButton), findsOneWidget);
    expect(
      tester.getCenter(find.byType(AuthSecondaryButton)).dy,
      greaterThan(tester.getCenter(find.byType(AuthButton)).dy),
      reason: '注册是次按钮，挂在登录按钮下面',
    );
  });

  testWidgets('底部那行：站点名是老端默认的 Im 时写 Gracelink，管理员改过就听服务端', (tester) async {
    addTearDown(tester.view.reset);
    await pumpLogin(tester);

    // 没拉到全局配置：`SysInfo` 的默认名就是 `Im`（老端的默认值）
    expect(find.text('Gracelink for 1.0.0'), findsOneWidget);
    expect(find.text('Im for 1.0.0'), findsNothing);

    // 管理员真配了个名字 → 原样显示（不是无脑换成 Gracelink）
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    container
        .read(sessionStoreProvider.notifier)
        .applyConfig(
          GlobalConfig(
            sysInfo: const SysInfo(name: '恩信'),
            chatInfo: const ChatInfo(),
            compass: const CompassConfig(),
            demonMode: false,
          ),
        );
    await tester.pumpAndSettle();
    expect(find.text('恩信 for 1.0.0'), findsOneWidget);
  });

  testWidgets('注册页：昵称只占一行（以前同一个位置并排画了两行昵称）', (tester) async {
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(adapter.apiClient()),
        ],
        child: const MaterialApp(home: RegisterPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(RegisterPage), findsOneWidget);
    expect(find.text('用户名/昵称'), findsOneWidget, reason: '昵称那一行不该出现两次');
    expect(find.byType(AuthButton), findsOneWidget);
  });

  testWidgets('注册页与登录页是同一套观感：卡片表单 + 左上返回 + 右上语言药丸', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(adapter.apiClient()),
        ],
        child: const MaterialApp(home: RegisterPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AuthCard), findsOneWidget);
    // 登录页没有上一级、不画返回；注册页要有（以前靠 AppBar 自带的那颗）
    expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsOneWidget);
    // 语言切换以前只有登录页能做，注册页现在也有一颗
    expect(find.byType(AuthLanguageChip), findsOneWidget);
    // 底部那颗「已有账号？登录」的绿字链接
    expect(find.text('已有账号？'), findsOneWidget);
    expect(find.text('Gracelink for 1.0.0'), findsOneWidget);
  });
}
