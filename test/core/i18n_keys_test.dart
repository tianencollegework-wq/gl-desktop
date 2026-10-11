import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/i18n/locale_controller.dart';
import 'package:gracelinkim/domain/news/news_feed.dart';

/// 文案 key 的静态体检（2026-09-25 整体排查时从临时脚本固化下来的）。
///
/// 起因：`AppI18n.t` 找不到 key 时会**返回 key 本身**（与 vue-i18n 一致），
/// 于是界面上直接显示 `chat.emojiFlags` 这种东西 —— 不崩、不报错、测试也全绿，
/// 只能靠人肉看截图发现。这份用例把「代码里用到的 key 都得在语言包里」钉死。
///
/// 2026-09-30 起语言包从 2 个变成 7 个（简 / 繁 / 英 / 日 / 西 / 法 / 德），
/// 所以下面每一条都是**对每一份包**跑一遍 —— 少一条就等着界面上冒 key。
///
/// 只能覆盖**字面量** key（`t('chat.send')` 这种写法）。动态拼出来的那 30 来处
/// （`t(tab.labelKey)`）由各自的用例守（它们大多在 switch 里返回字面量，
/// 也能被这条规则捎带查到）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 除中文外的那几份（中文是“母本”，key 以它为准）
  final otherCodes = LocaleController.options
      .map((option) => option.code)
      .where((code) => code != 'zh-Hans')
      .toList();

  test('代码里用到的每个文案 key 都在**每一份**语言包里', () {
    final pattern = RegExp(r"(?:\.t|translate)\(\s*'([^']+)'");
    final missing = <String, List<String>>{};
    var checked = 0;

    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    for (final file in files) {
      final source = file.readAsStringSync();
      for (final match in pattern.allMatches(source)) {
        checked++;
        final key = match.group(1)!;
        for (final code in LocaleController.options.map((o) => o.code)) {
          if (!_packKeys[code]!.contains(key)) {
            missing
                .putIfAbsent('$code 缺 $key', () => <String>[])
                .add(file.path);
          }
        }
      }
    }

    expect(
      checked,
      greaterThan(300),
      reason: '扫描到 ${files.length} 个 dart 文件，$checked 处取词',
    );
    expect(missing.keys.toList(), isEmpty, reason: '$missing');
  });

  test('每个媒体号源都有**每一种语言**的号名（源名是动态拼的，上面那条扫不到）', () {
    for (final feed in kNewsFeeds) {
      for (final code in LocaleController.options.map((o) => o.code)) {
        expect(
          _packKeys[code]!.contains(feed.nameKey),
          isTrue,
          reason: '$code 缺 ${feed.key} 的号名（${feed.nameKey}）',
        );
      }
    }
  });

  test('所有语言包的 key 与简体那份对齐', () {
    // 老端 en 包里多写了一个 `common.SearchNone`（S 大写），代码里用的是
    // `common.searchNone`。留着是为了不动老端的资源，只在用例里记一笔。
    const legacyExtraInEnglish = <String>{'common.SearchNone'};
    final zh = _packKeys['zh-Hans']!;
    final problems = <String>[];
    for (final code in otherCodes) {
      final keys = _packKeys[code]!;
      final allowedExtra = code == 'en'
          ? legacyExtraInEnglish
          : const <String>{};

      final missing = zh.difference(keys);
      final extra = keys.difference(zh).difference(allowedExtra);
      if (missing.isNotEmpty) {
        problems.add('$code 缺 ${missing.length} 条：${missing.toList()..sort()}');
      }
      if (extra.isNotEmpty) {
        problems.add('$code 多 ${extra.length} 条：${extra.toList()..sort()}');
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('每条文案都得真的翻了（不许照抄 key、也不许留空）', () async {
    final problems = <String>[];
    for (final code in LocaleController.options.map((o) => o.code)) {
      final pack = await AppI18n.load(code);
      for (final key in _packKeys[code]!) {
        final text = pack.t(key);
        if (text.trim().isEmpty || text == key) {
          problems.add('$code: $key → "$text"');
        }
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}

/// 各语言包的 key 清单（从文件里直接读，比 `AppI18n` 的私有 map 更直接）
final Map<String, Set<String>> _packKeys = <String, Set<String>>{
  for (final code in LocaleController.options.map((option) => option.code))
    code: _keysOf('assets/i18n/$code.json'),
};

/// 从语言包里抠出 key 清单（`"key": …` 的左边）。
///
/// 用全局扫而**不是按行扫**：语言包里有几行写了两个 key
/// （`"a":"…",  "b":"…"`），按行取只能拿到第一个，会冤枉成「另一个包缺 key」。
Set<String> _keysOf(String path) {
  final pattern = RegExp(r'"([^"\\]+)"\s*:');
  final content = File(path).readAsStringSync();
  return <String>{
    for (final match in pattern.allMatches(content)) match.group(1)!,
  };
}
