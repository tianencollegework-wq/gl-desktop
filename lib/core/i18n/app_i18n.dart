import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'locale_controller.dart';

/// 多语言，对应老端 `locales/*.json`（结构与 key 完全一致）。
///
/// 老端用的是 vue-i18n，key 形如 `user.message`、`chat.send`。这里保持同一份 key，
/// 直接把老端的两份 json 当资源加载，避免重写文案时漏项。
///
/// 加载方式：在 `main()` 里 `await AppI18n.load('zh-Hans')`，之后全局通过
/// `ref.watch(appI18nProvider).t('user.message')` 取词。
class AppI18n {
  AppI18n._(this._messages, this.localeCode);

  final Map<String, String> _messages;

  /// 'zh-Hans' 或 'en'
  final String localeCode;

  static AppI18n? _instance;

  /// 已加载的语言包。未加载时抛错，避免静默返回 key 让人误以为文案缺失。
  static AppI18n get instance {
    final loaded = _instance;
    if (loaded == null) {
      throw StateError('AppI18n 尚未初始化：请在 main() 中先 await AppI18n.load(...)');
    }
    return loaded;
  }

  static Future<AppI18n> load(String localeCode) async {
    final raw = await rootBundle.loadString('assets/i18n/$localeCode.json');
    final decoded = json.decode(raw) as Map<String, dynamic>;
    final merged = <String, String>{
      for (final entry in decoded.entries) entry.key: entry.value.toString(),
    };
    final instance = AppI18n._(merged, localeCode);
    _instance = instance;
    return instance;
  }

  /// 有语言包的语言码（与 `assets/i18n/*.json` 一一对应，顺序无关）。
  ///
  /// 用户 2026-09-30 定的名单：简体 / 繁体 / 英 / 日 / 西 / 法 / 德，
  /// 也都进了选择器（见 `locale_controller.dart` 的 [LocaleController.options]）。
  static const List<String> supportedLocales = <String>[
    'zh-Hans',
    'zh-Hant',
    'en',
    'ja',
    'es',
    'fr',
    'de',
  ];

  /// 取词；缺失时返回 key 本身（与 vue-i18n 的 fallback 行为一致），便于定位漏项。
  ///
  /// [params] 替换文案里的 `{xxx}` 占位（S6.3 起用：通话页那句
  /// 「{name} 正在请求与您视频通话」老端是在模板里手拼的，译文拼不到一起去）。
  String t(String key, [Map<String, String>? params]) {
    final text = _messages[key] ?? key;
    if (params == null || params.isEmpty) return text;
    var result = text;
    for (final entry in params.entries) {
      result = result.replaceAll('{${entry.key}}', entry.value);
    }
    return result;
  }

  bool has(String key) => _messages.containsKey(key);

  int get messageCount => _messages.length;
}

final appI18nProvider = Provider<AppI18n>((ref) {
  // 跟随语言切换：切语言时 [AppI18n.load] 会换掉单例，这里要重算一次，
  // 否则页面还拿着旧语言包。
  ref.watch(localeProvider);
  return AppI18n.instance;
});
