import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/i18n/locale_controller.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/features/mine/display_setting_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「跟随系统」这一档（2026-10-01 用户提的）：选择器最上面多一条，
/// 点了就回到自动 —— 本地存的那份清掉、按系统语言算。
///
/// 顺带钉两件容易做错的事：
/// * 它自己的写法跟着**当前界面语言**走（切到日语就该写「システムに従う」），
///   而语言那几档永远是各自的写法；
/// * 系统语言正好等于当前那一档时，点它**也要**记下「这次是手动选的」
///   （只看语言码会以为什么都没变，用户以为选定了、其实还在跟随）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    container = ProviderContainer();
  });

  tearDown(() => container.dispose());

  /// 把 App 摆成「上次选了这一档」（传 null = 从没选过，跟随系统）
  Future<void> bootWith(WidgetTester tester, String? code) async {
    await tester.runAsync(() async {
      await CredentialStore.instance.saveLanguage(code);
      await AppI18n.load(code ?? LocaleController.systemLocaleCode());
    });
  }

  Future<void> pumpPage(WidgetTester tester) async {
    // 竖屏高一点：弹框里一条「跟随系统」+ 7 种语言，矮窗口底下那条会被挤出去
    tester.view.physicalSize = const Size(1170, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: DisplaySettingPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// `setLocale` / `setSystem` 里有 await（读语言包 + 存偏好），走的是真事件循环，
  /// `testWidgets` 的 fake-async 推不动 —— 用 `runAsync` 等它落地再断言。
  Future<void> settleLocale(WidgetTester tester, bool Function() done) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 200 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
  }

  testWidgets('从没选过：那一行写「跟随系统」，弹框里第一条也是它', (tester) async {
    await bootWith(tester, null);
    await pumpPage(tester);

    final i18n = AppI18n.instance;
    // 这一行右侧写的是「跟随系统」（这时界面语言就是系统语言那一档，
    // 所以那条的写法也正好是当前包的写法）
    expect(find.text(i18n.t('user.language')), findsOneWidget);
    expect(find.text(i18n.t('common.followSystem')), findsOneWidget);

    await tester.tap(find.text(i18n.t('user.language')));
    await tester.pumpAndSettle();

    // 一条「跟随系统」+ 7 种语言，一个都不能少
    expect(find.text(i18n.t('common.followSystem')), findsWidgets);
    for (final option in LocaleController.options) {
      expect(
        find.text(option.label),
        findsOneWidget,
        reason: '弹框里少了 ${option.code}',
      );
    }
  });

  testWidgets('选过语言之后点「跟随系统」：本地那份清掉、界面回到系统那一档', (tester) async {
    // 用户上次选了日语，这次冷启动
    await bootWith(tester, 'ja');
    await pumpPage(tester);

    expect(find.text('日本語'), findsOneWidget, reason: '这一行写着存的那份');

    // 点开弹框：界面是日语，所以「跟随系统」这条得是日语的写法
    await tester.tap(find.text(AppI18n.instance.t('user.language')));
    await tester.pumpAndSettle();
    expect(find.text('システムに従う'), findsOneWidget);

    await tester.tap(find.text('システムに従う'));
    await tester.pumpAndSettle();
    await settleLocale(
      tester,
      () =>
          CredentialStore.instance.language == null &&
          container.read(localeProvider).followsSystem,
    );

    final systemCode = LocaleController.systemLocaleCode();
    expect(CredentialStore.instance.language, isNull);
    final choice = container.read(localeProvider);
    expect(choice.code, systemCode);
    expect(choice.followsSystem, isTrue);
    expect(choice.selectedCode, LocaleController.systemCode);
    expect(AppI18n.instance.localeCode, systemCode);

    // 界面真的换了：这一行右侧从「日本語」变成当前那档的「跟随系统」写法
    expect(find.text('日本語'), findsNothing);
    expect(
      find.text(AppI18n.instance.t('common.followSystem')),
      findsOneWidget,
    );
  });

  testWidgets('系统语言正好是当前这一档时点它：也要记成「手动选了它」', (tester) async {
    await bootWith(tester, null);
    await pumpPage(tester);

    // 宿主算出来的那一档：点它之前是「跟随系统」
    final current = container.read(localeProvider);
    expect(current.followsSystem, isTrue);
    final nativeLabel = LocaleController.languageLabelOf(current.code);

    await tester.tap(find.text(AppI18n.instance.t('user.language')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(nativeLabel));
    await tester.pumpAndSettle();
    await settleLocale(
      tester,
      () => CredentialStore.instance.language == current.code,
    );

    final choice = container.read(localeProvider);
    expect(choice.code, current.code, reason: '界面文字没变（本来就是这一档）');
    expect(choice.followsSystem, isFalse, reason: '但已经不是跟随系统了');
    expect(choice.selectedCode, current.code, reason: '勾要移到语言那一项');
    expect(CredentialStore.instance.language, current.code);
    // 行右侧从「跟随系统」换成该语言自己的写法
    expect(find.text(nativeLabel), findsOneWidget);
  });
}
