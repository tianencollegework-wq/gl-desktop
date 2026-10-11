import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/i18n/locale_controller.dart';
import 'package:gracelinkim/core/platform/desktop_shell.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/domain/mine/profile_form.dart';
import 'package:gracelinkim/features/common/not_found_page.dart';
import 'package:gracelinkim/features/mine/doc_page.dart';
import 'package:gracelinkim/features/mine/feature_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「界面上的字都走语言包」这条规矩的几处兜底（S12.9）。
///
/// 起因：语言从 2 种加到 7 种时，`i18n_keys_test` 那条扫的是**字面量**
/// `t('…')`，扫不到这几类漏网之鱼：
/// * **404 页**（`errorBuilder`）——写死中文，切到日语/西语还是中文；
/// * **帮助中心正文**（`helpTopics`）——标题与段落以前是写死的中文常量，
///   连 key 都没有，等于这页根本没进多语言；
/// * **功能介绍正文**（`aboutFeatureKeys`）——2026-10-10 之前也是写死的中文
///   （上游那七条卖点），现在是 `feature.item1` …，同样只能靠这一页守。
/// 所以这几页各钉一条：**换一份包就换一份字**。
///
/// 顺带把「占位符别漏」也钉住（`{path}` 没被替换掉的话界面上会露一大括号）。
///
/// 切语言走的是设置页那颗药丸同一条路（[LocaleController.setLocale]）：
/// 读语言包 + 落偏好 + 换 `localeProvider`。这里面有真实的 asset 读取与
/// SharedPreferences 通道，`testWidgets` 的 fake-async 推不动，得用
/// `tester.runAsync` 放行真异步（与 `mine_pages_test` 那条同一个坑）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    container = ProviderContainer();
  });

  tearDown(() => container.dispose());

  /// 把 App 摆成「用户之前选过这一档」的样子（真实启动就是这条链：
  /// 存的那份 → `AppI18n.load` → `localeProvider`）。
  Future<void> bootWith(WidgetTester tester, String code) async {
    await tester.runAsync(() async {
      await CredentialStore.instance.saveLanguage(code);
      await AppI18n.load(code);
    });
  }

  /// 切语言：与设置页那颗药丸完全同一条链
  Future<void> switchTo(WidgetTester tester, String code) async {
    await tester.runAsync(
      () => container.read(localeProvider.notifier).setLocale(code),
    );
  }

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: page),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('404 页跟着语言包走，路径原样写出来', (tester) async {
    await bootWith(tester, 'zh-Hans');
    await pumpPage(tester, const RouteNotFoundPage(path: '/no/such'));

    expect(find.text('页面不存在'), findsOneWidget);
    expect(find.text('未匹配的路径：/no/such'), findsOneWidget);

    // 切到日语（宿主系统语言算出来是 en，切 en 等于没切，验不出东西）
    await switchTo(tester, 'ja');
    await pumpPage(tester, const RouteNotFoundPage(path: '/no/such'));

    expect(find.text('ページが見つかりません'), findsOneWidget);
    expect(find.text('一致するルートがありません：/no/such'), findsOneWidget);
    expect(find.text('页面不存在'), findsNothing);
  });

  testWidgets('帮助中心正文跟着语言包走（以前是写死的中文常量）', (tester) async {
    // 竖屏高一点：第一条默认展开，正文很长，小屏上第二条标题会被挤出视口
    // （ListView 不构建视口外的行，`find.text` 就找不到它）
    tester.view.physicalSize = const Size(1170, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await bootWith(tester, 'zh-Hans');
    await pumpPage(tester, const DocPage());

    expect(find.text('如何开启手机通知'), findsOneWidget);
    expect(find.text('为什么账号显示为未认证'), findsOneWidget);
    // 第一条默认展开，正文第一段露在外面
    expect(find.textContaining('允许通知'), findsWidgets);

    await switchTo(tester, 'de');
    await pumpPage(tester, const DocPage());

    expect(find.text('So aktivierst du Benachrichtigungen'), findsOneWidget);
    // 中文那一份不该再出现（证明真的换了包，而不是两份都画了）
    expect(find.text('如何开启手机通知'), findsNothing);

    // 第二条：德语比中文长，第一条展开后它被挤出视口了 —— 滚下去再断言
    await tester.drag(find.byType(ListView), const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(
      find.text('Warum das Konto als unbestätigt angezeigt wird'),
      findsOneWidget,
    );
  });

  testWidgets('功能介绍正文跟着语言包走（以前是写死的中文常量）', (tester) async {
    // 十一条比一屏长，ListView 不构建视口外的行 —— 把视口先拉高
    tester.view.physicalSize = const Size(1170, 12000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await bootWith(tester, 'zh-Hans');
    await pumpPage(tester, const FeaturePage());

    expect(find.textContaining('客户端不是网页套壳'), findsOneWidget);
    expect(find.textContaining('群里随时开多人通话'), findsOneWidget);
    expect(find.textContaining('灵听'), findsOneWidget);
    // 这一屏（测试里桌面总开关是关的）就是手机端那一份：
    // 托盘/独立窗口那条电脑专属描述不该出现，后台保活那条该在
    expect(find.textContaining('关掉窗口会缩到托盘'), findsNothing);
    expect(find.textContaining('退到后台仍保持在线'), findsOneWidget);

    await switchTo(tester, 'ja');
    await pumpPage(tester, const FeaturePage());

    expect(
      find.textContaining('クライアントは Web ページのラッパーではありません'),
      findsOneWidget,
    );
    // 中文那一份不该再出现（证明真的换了包，而不是两份都画了）
    expect(find.textContaining('客户端不是网页套壳'), findsNothing);
  });

  testWidgets('功能介绍按端过滤：把桌面总开关拧开就换成电脑端那一份', (tester) async {
    tester.view.physicalSize = const Size(1170, 12000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    // 这一条要的是「桌面」那一份，所以换个带 override 的容器。还没有页面挂过
    // setUp 里那个容器，直接换掉是安全的（挂过之后就不能这样换了）。
    container.dispose();
    container = ProviderContainer(
      overrides: [desktopFeaturesProvider.overrideWithValue(true)],
    );

    await bootWith(tester, 'zh-Hans');
    await pumpPage(tester, const FeaturePage());

    expect(find.textContaining('关掉窗口会缩到托盘'), findsOneWidget);
    expect(find.textContaining('退到后台仍保持在线'), findsNothing);
  });

  test('每一份语言包的功能介绍都在', () async {
    final problems = <String>[];
    for (final option in LocaleController.options) {
      final pack = await AppI18n.load(option.code);
      for (final item in aboutFeatures) {
        final text = pack.t(item.key);
        if (text == item.key || text.trim().isEmpty) {
          problems.add('${option.code} 少了 ${item.key}');
        }
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('每一份语言包的帮助正文都在，且不含没换掉的占位符', () async {
    final problems = <String>[];
    for (final option in LocaleController.options) {
      final pack = await AppI18n.load(option.code);
      for (final key in <String>[
        'help.notifyTitle',
        'help.notifyP1',
        'help.notifyP2',
        'help.notifyP3',
        'help.notifyP4',
        'help.notifyP5',
        'help.notifyP6',
        'help.certTitle',
        'help.certP1',
        'common.pageNotFound',
      ]) {
        final text = pack.t(key);
        if (text == key || text.trim().isEmpty) {
          problems.add('${option.code} 少了 $key');
        }
      }
      // `{path}` 只在 404 那一条里，且必须真的能被替换掉
      final unmatched = pack.t('common.routeUnmatched', <String, String>{
        'path': '/x',
      });
      if (!unmatched.contains('/x') || unmatched.contains('{')) {
        problems.add('${option.code} 的 common.routeUnmatched：$unmatched');
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
