import 'dart:ui' show Locale;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/i18n/locale_controller.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 语言这件事（2026-09-30 用户定的口径）：
/// 打开软件看**系统语言**，对不上落英语；手动选过就听手动那份；
/// 2026-10-01 又补了一档「跟随系统」（选择器最上面那条）—— 选它就把本地
/// 存的那份清掉、回到自动，而且系统语言一变就跟着变。
///
/// 名单：简体 / 繁体 / 英 / 日 / 西 / 法 / 德 —— 每个都得真有语言包，
/// 缺一个选择器里就会点到「满屏 key」（`AppI18n.t` 找不到就返回 key 本身）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('系统语言 → 语言码', () {
    test('中文按脚本/地区分繁简', () {
      expect(LocaleController.codeOf(const Locale('zh', 'CN')), 'zh-Hans');
      expect(LocaleController.codeOf(const Locale('zh', 'SG')), 'zh-Hans');
      expect(LocaleController.codeOf(const Locale('zh')), 'zh-Hans');
      expect(
        LocaleController.codeOf(
          const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
        ),
        'zh-Hans',
      );

      expect(LocaleController.codeOf(const Locale('zh', 'TW')), 'zh-Hant');
      expect(LocaleController.codeOf(const Locale('zh', 'HK')), 'zh-Hant');
      expect(LocaleController.codeOf(const Locale('zh', 'MO')), 'zh-Hant');
      expect(
        LocaleController.codeOf(
          const Locale.fromSubtags(
            languageCode: 'zh',
            scriptCode: 'Hant',
            countryCode: 'TW',
          ),
        ),
        'zh-Hant',
        reason: '安卓有时给 zh-Hant-TW，有时只给 zh-TW，两种都要认',
      );
    });

    test('日/西/法/德/英按语言码认（不管哪个地区）', () {
      expect(LocaleController.codeOf(const Locale('ja', 'JP')), 'ja');
      expect(LocaleController.codeOf(const Locale('es', 'MX')), 'es');
      expect(LocaleController.codeOf(const Locale('fr', 'CA')), 'fr');
      expect(LocaleController.codeOf(const Locale('de', 'AT')), 'de');
      expect(LocaleController.codeOf(const Locale('en', 'GB')), 'en');
    });

    test('认不出来的（韩语/俄语…）整串都对不上才落英语', () {
      expect(LocaleController.codeOf(const Locale('ko', 'KR')), isNull);
      expect(
        LocaleController.systemLocaleCode(const <Locale>[Locale('ko')]),
        'en',
      );
      expect(LocaleController.systemLocaleCode(const <Locale>[]), 'en');
    });

    test('系统给了好几条时，用第一条认得的', () {
      expect(
        LocaleController.systemLocaleCode(const <Locale>[
          Locale('ko'),
          Locale('zh', 'TW'),
          Locale('en'),
        ]),
        'zh-Hant',
      );
    });
  });

  group('递给 Flutter 的 Locale', () {
    test('中文带脚本（Material 那套认脚本，不认地区）', () {
      expect(LocaleController.flutterLocaleOf('zh-Hans').scriptCode, 'Hans');
      expect(LocaleController.flutterLocaleOf('zh-Hant').scriptCode, 'Hant');
      expect(LocaleController.flutterLocaleOf('ja').languageCode, 'ja');
      expect(LocaleController.flutterLocaleOf('de').languageCode, 'de');
    });
  });

  group('清单与语言包', () {
    test('选择器里 7 种语言，每种都真有包（不是空壳）', () async {
      expect(LocaleController.options, hasLength(7));
      for (final option in LocaleController.options) {
        expect(
          AppI18n.supportedLocales,
          contains(option.code),
          reason: '${option.code} 没写进 supportedLocales',
        );
        final pack = await AppI18n.load(option.code);
        expect(
          pack.messageCount,
          greaterThan(500),
          reason: '${option.code} 的语言包像是个空壳',
        );
      }
    });

    test('展示名用该语言自己的写法（切过去还找得到自己那个）', () {
      expect(LocaleController.languageLabelOf('zh-Hans'), '简体中文');
      expect(LocaleController.languageLabelOf('zh-Hant'), '繁體中文');
      expect(LocaleController.languageLabelOf('ja'), '日本語');
      expect(LocaleController.languageLabelOf('es'), 'Español');
      expect(LocaleController.languageLabelOf('fr'), 'Français');
      expect(LocaleController.languageLabelOf('de'), 'Deutsch');
      expect(
        LocaleController.languageLabelOf('xx'),
        'xx',
        reason: '不认识的回落语言码本身',
      );
    });

    test('选择器：最上面一条「跟随系统」，后面才是 7 种语言', () async {
      final pack = await AppI18n.load('ja');
      final items = LocaleController.pickerItems(pack);

      expect(items.first.code, LocaleController.systemCode);
      // 它跟着**当前界面语言**写（语言那几档才是各写各的）
      expect(items.first.label, 'システムに従う');
      expect(items.skip(1).map((item) => item.code), <String>[
        for (final option in LocaleController.options) option.code,
      ]);
      expect(
        LocaleController.labelOf(
          const LocaleChoice(code: 'en', followsSystem: true),
          pack,
        ),
        'システムに従う',
        reason: '跟随系统时那一行写的也是「跟随系统」，不是它落到的 English',
      );
      expect(
        LocaleController.labelOf(
          const LocaleChoice(code: 'en', followsSystem: false),
          pack,
        ),
        'English',
        reason: '手动选了 English：写 English（不跟当前界面语言走）',
      );
    });
  });

  group('默认值', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await CredentialStore.init();
    });

    test('手动选过：听他的，重启（新容器）也保持', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(localeProvider.notifier).setLocale('ja');

      final choice = container.read(localeProvider);
      expect(choice.code, 'ja');
      expect(choice.followsSystem, isFalse);
      expect(choice.selectedCode, 'ja', reason: '选择器给这一项打勾');

      final restarted = ProviderContainer();
      addTearDown(restarted.dispose);
      expect(restarted.read(localeProvider).code, 'ja');
      expect(restarted.read(localeProvider).followsSystem, isFalse);
    });

    test('没选过：跟系统语言，且一定落在名单里', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final expected = LocaleController.systemLocaleCode();
      final choice = container.read(localeProvider);
      expect(choice.code, expected);
      expect(choice.followsSystem, isTrue);
      expect(choice.selectedCode, LocaleController.systemCode);
      expect(AppI18n.supportedLocales, contains(expected));
    });

    test('选过之后再选「跟随系统」：本地那份清掉、回到系统那一档', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await container.read(localeProvider.notifier).setLocale('ja');
      expect(CredentialStore.instance.language, 'ja');

      await container
          .read(localeProvider.notifier)
          .setLocale(LocaleController.systemCode);

      expect(CredentialStore.instance.language, isNull, reason: '本地那份要清掉');
      final choice = container.read(localeProvider);
      expect(choice.code, LocaleController.systemLocaleCode());
      expect(choice.followsSystem, isTrue);
      // 界面用的包也跟着回到系统那一档
      expect(AppI18n.instance.localeCode, choice.code);
    });

    test('跟随系统时系统语言变了：跟着换', () async {
      final binding = TestWidgetsFlutterBinding.instance;
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // 起点先钉成日语（这一档不是宿主默认，相不相信）
      binding.platformDispatcher.localesTestValue = const <Locale>[
        Locale('ja'),
      ];
      addTearDown(binding.platformDispatcher.clearLocalesTestValue);

      final notifier = container.read(localeProvider.notifier);
      expect(notifier.state.code, 'ja');

      // 用户在系统设置里改成了德语
      binding.platformDispatcher.localesTestValue = const <Locale>[
        Locale('de'),
      ];
      await notifier.syncWithSystem();

      expect(container.read(localeProvider).code, 'de');
      expect(container.read(localeProvider).followsSystem, isTrue);
      expect(AppI18n.instance.localeCode, 'de');
      expect(CredentialStore.instance.language, isNull, reason: '跟随时本地一直不存');
    });

    test('手动选过之后系统语言变了：装没看见（用户定的不能被系统改掉）', () async {
      final binding = TestWidgetsFlutterBinding.instance;
      final container = ProviderContainer();
      addTearDown(container.dispose);
      binding.platformDispatcher.localesTestValue = const <Locale>[
        Locale('ja'),
      ];
      addTearDown(binding.platformDispatcher.clearLocalesTestValue);

      await container.read(localeProvider.notifier).setLocale('zh-Hans');
      binding.platformDispatcher.localesTestValue = const <Locale>[
        Locale('de'),
      ];
      await container.read(localeProvider.notifier).syncWithSystem();

      expect(container.read(localeProvider).code, 'zh-Hans');
      expect(container.read(localeProvider).followsSystem, isFalse);
      expect(AppI18n.instance.localeCode, 'zh-Hans');
    });

    test('切到系统正好相同的那一档：也要记下「手动选了它」', () async {
      final binding = TestWidgetsFlutterBinding.instance;
      final container = ProviderContainer();
      addTearDown(container.dispose);
      binding.platformDispatcher.localesTestValue = const <Locale>[
        Locale('ja'),
      ];
      addTearDown(binding.platformDispatcher.clearLocalesTestValue);

      final notifier = container.read(localeProvider.notifier);
      expect(notifier.state.followsSystem, isTrue);
      // 系统是日语、当前也显示日语，但用户明确点了「日本語」这一项
      await notifier.setLocale('ja');

      expect(notifier.state.followsSystem, isFalse);
      expect(CredentialStore.instance.language, 'ja');
      expect(notifier.selectedCode, 'ja');
    });
  });
}
