import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../store/credential_store.dart';
import 'app_i18n.dart';

/// 语言切换，对应老端 `common/config.js` 的 `langList()` +
/// 登录页右上角那个 `picker`，外加选择器最上面那条「跟随系统」。
///
/// 老端把选中的语言整对象存进 `language`（`{key:'简体中文', value:'zh-Hans'}`）；
/// 新端只存语言码，展示名由 [LocaleOption.label] 提供。
///
/// 三档口径（用户 2026-09-30 定的默认，2026-10-01 补了「跟随系统」这一档）：
/// * 手动选过某一档 → 用存的那份（重启也保持，这是他自己定的）；
/// * 选「跟随系统」（或从没选过）→ 本地不存语言，按系统语言算，
///   而且**系统语言一变就跟着变**（`app.dart` 里听着，见 [syncWithSystem]）；
/// * 系统语言一档都对不上（韩语、俄语、阿拉伯语…）→ [fallbackLocale]（英语）。
class LocaleController extends Notifier<LocaleChoice> {
  @override
  LocaleChoice build() {
    final saved = CredentialStore.instance.language;
    return LocaleChoice(
      code: saved ?? systemLocaleCode(),
      followsSystem: saved == null,
    );
  }

  /// 「跟随系统」在选择器里的哨兵码。
  ///
  /// 它**不是**语言码：不在 [options] 里（那份名单是「有哪些语言」，
  /// `app.dart` 还要拿它生成 `MaterialApp.supportedLocales`），
  /// 也不会交给 [AppI18n.load]。只在「该给哪一项打勾」时出现。
  static const String systemCode = 'system';

  /// 系统语言一档都对不上时落到这里（用户定的：英语）
  static const String fallbackLocale = 'en';

  /// 老端 `langList()` 的等价物，顺序就是选择器里的顺序。
  ///
  /// 展示名一律用**该语言自己的写法**（微信、系统设置里都是这么列的）：
  /// 用当前语言去翻译别的语言名，切换之后那一列会跟着变，反而找不到自己要的那个。
  static const List<LocaleOption> options = <LocaleOption>[
    LocaleOption('zh-Hans', '简体中文'),
    LocaleOption('zh-Hant', '繁體中文'),
    LocaleOption('en', 'English'),
    LocaleOption('ja', '日本語'),
    LocaleOption('es', 'Español'),
    LocaleOption('fr', 'Français'),
    LocaleOption('de', 'Deutsch'),
  ];

  /// 选择器里真正列出来的条目：最上面一条「跟随系统」，下面才是 [options]。
  ///
  /// 「跟随系统」得跟着**当前界面语言**写（切到日语就该是「システムに従う」），
  /// 所以要把 i18n 传进来；语言那几档与当前语言无关，用它们自己的写法。
  static List<LocaleOption> pickerItems(AppI18n i18n) => <LocaleOption>[
    LocaleOption(systemCode, i18n.t('common.followSystem')),
    ...options,
  ];

  /// 当前该显示 / 该打勾的那一项（跟随系统时是 [systemCode]）
  String get selectedCode => state.selectedCode;

  /// 现在是不是「跟随系统」
  bool get followsSystem => state.followsSystem;

  /// 选一项：语言码走存下来那条路，[systemCode] 走回「跟随系统」
  Future<void> setLocale(String localeCode) async {
    if (localeCode == systemCode) return setSystem();
    // 已经手动选过这一档：什么都不用做。
    // 注意不能只看 `state.code` —— 跟随系统时它恰好等于系统那一档，
    // 这时点同一个语言**要**存下来，否则用户以为选定了、其实还在跟随。
    if (!state.followsSystem && localeCode == state.code) return;
    await AppI18n.load(localeCode);
    await CredentialStore.instance.saveLanguage(localeCode);
    state = LocaleChoice(code: localeCode, followsSystem: false);
  }

  /// 回到「跟随系统」：把本地存的那份清掉，按当前系统语言重算
  Future<void> setSystem() async {
    if (state.followsSystem) return;
    final code = systemLocaleCode();
    await AppI18n.load(code);
    await CredentialStore.instance.saveLanguage(null);
    // 这里必须换掉整个 state：语言码可能没变（系统语言正好就是当前这份），
    // 但「跟随系统」这个勾要跟上，界面得重建。
    state = LocaleChoice(code: code, followsSystem: true);
  }

  /// 系统语言变了（安卓在「设置 → 语言」里一改就会通知过来）。
  ///
  /// 只在「跟随系统」那一档下生效；手动选过就装没看见 —— 用户自己定的语言，
  /// 不能被系统改掉。
  Future<void> syncWithSystem() async {
    if (!state.followsSystem) return;
    final code = systemLocaleCode();
    // 系统换了语言但落到同一档（比如 en_GB → en_US）：界面不用动
    if (code == state.code) return;
    await AppI18n.load(code);
    state = LocaleChoice(code: code, followsSystem: true);
  }

  /// 某项该显示成什么字（「跟随系统」那一项按当前界面语言写）
  static String labelOf(LocaleChoice choice, AppI18n i18n) {
    if (choice.followsSystem) return i18n.t('common.followSystem');
    return languageLabelOf(choice.code);
  }

  /// 某个**语言码**的展示名（找不到时回落语言码本身）
  static String languageLabelOf(String localeCode) {
    for (final option in options) {
      if (option.code == localeCode) return option.label;
    }
    return localeCode;
  }

  /// 语言码 → Flutter 的 [Locale]（Material / Cupertino 自己那套本地化按它挑）。
  ///
  /// 中文必须带**脚本**（`Hans` / `Hant`）：`GlobalMaterialLocalizations` 认的是
  /// 脚本而不是地区，只给 `zh` 会落到「通用中文」那一档。
  static Locale flutterLocaleOf(String code) {
    switch (code) {
      case 'zh-Hans':
        return const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans');
      case 'zh-Hant':
        return const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant');
      default:
        return Locale(code);
    }
  }

  /// 当前该用哪个语言码：**手动选过就用手动的**，没选过就看系统。
  ///
  /// 给 `main()` 与后台推送 isolate 用（那时候还没有 ProviderContainer）。
  static String systemLocaleCode([List<Locale>? preferred]) {
    final locales = preferred ?? _deviceLocales();
    for (final locale in locales) {
      final code = codeOf(locale);
      if (code != null) return code;
    }
    return fallbackLocale;
  }

  /// 单个系统 locale → 语言码；不认识就返回 null（让调用方看下一个）
  ///
  /// 中文分繁简的规则（安卓/iOS 都可能给成 `zh_TW`、`zh_Hant_TW` 或 `zh-Hant`）：
  /// 脚本是 `Hant`、或者地区是 TW / HK / MO 的算繁体，其余一律简体。
  static String? codeOf(Locale locale) {
    switch (locale.languageCode.toLowerCase()) {
      case 'zh':
        final script = (locale.scriptCode ?? '').toLowerCase();
        final country = (locale.countryCode ?? '').toUpperCase();
        final traditional =
            script == 'hant' ||
            const <String>{'TW', 'HK', 'MO'}.contains(country);
        return traditional ? 'zh-Hant' : 'zh-Hans';
      case 'en':
        return 'en';
      case 'ja':
        return 'ja';
      case 'es':
        return 'es';
      case 'fr':
        return 'fr';
      case 'de':
        return 'de';
      default:
        return null;
    }
  }

  /// 设备上的语言列表（第一条是用户的首选）。
  ///
  /// 先走 `WidgetsBinding` 那个 dispatcher：**同一个引擎**，但它能被测试替换
  /// （`tester.platformDispatcher.localesTestValue`），用例才验得了「系统语言变了
  /// 就跟着换」；后台推送 isolate / 引擎还没起时没有 binding，退回
  /// `PlatformDispatcher.instance`；两个都拿不到就返回空表 → 落英语
  /// （那时候只是弹一条通知，语言包用英语也不影响什么）。
  static List<Locale> _deviceLocales() {
    try {
      return WidgetsBinding.instance.platformDispatcher.locales;
    } on Object {
      // 后台推送 isolate / 引擎刚起：没有 binding，退回引擎那一份
      try {
        return PlatformDispatcher.instance.locales;
      } on Object catch (error) {
        debugPrint('[i18n] 读系统语言失败（$error），先按英语加载');
        return const <Locale>[];
      }
    }
  }
}

/// 当前语言的快照：**实际在用的那一档** + **是不是「跟随系统」**。
///
/// 为什么不是一个字符串：界面语言永远是具体的一档（`MaterialApp.locale` 不认
/// 「跟随系统」这种东西），可「跟随系统」又得让选择器给它打上勾 —— 两份信息都要，
/// 所以打包成一个值对象（相等实现好，Riverpod 才判得出该不该重建界面：
/// 语言没变、只是从「手动选了 English」换成「跟随系统」时，界面文字不用换，
/// 但那个勾要移）。
class LocaleChoice {
  const LocaleChoice({required this.code, required this.followsSystem});

  /// 实际在用的语言码（永远是 [LocaleController.options] 里的具体某一档）
  final String code;

  /// 是不是「跟随系统」（本地没存语言就是）
  final bool followsSystem;

  /// 选择器里该打勾的那一项：跟随系统时是哨兵 [LocaleController.systemCode]
  String get selectedCode => followsSystem ? LocaleController.systemCode : code;

  @override
  bool operator ==(Object other) =>
      other is LocaleChoice &&
      other.code == code &&
      other.followsSystem == followsSystem;

  @override
  int get hashCode => Object.hash(code, followsSystem);

  @override
  String toString() => 'LocaleChoice($code, followsSystem: $followsSystem)';
}

class LocaleOption {
  const LocaleOption(this.code, this.label);

  final String code;
  final String label;
}

final localeProvider = NotifierProvider<LocaleController, LocaleChoice>(
  LocaleController.new,
);
