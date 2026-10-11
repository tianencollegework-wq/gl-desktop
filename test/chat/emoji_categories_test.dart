import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/util/emoji.dart';
import 'package:gracelinkim/core/util/emoji_pack.dart';

/// 表情面板的分类清单。
///
/// 这份清单是**手写的**（不像老端那样从服务端拉图），所以最怕两件事：
/// 码点写错（渲染成豆腐块/空字符串）、同一栏里同一个表情出现两遍。
/// 这两件事都用用例钉住，免得以后加表情时一不留神。
/// 去掉 emoji 变体选择符（U+FE0F）：`❤️` 与 `❤` 视为同一个字
String _stripVariation(String char) => char.replaceAll('\uFE0F', '');

void main() {
  test('分类不少于五个，且每栏都有名字与代表图标', () {
    expect(builtinEmojiCategories.length, greaterThanOrEqualTo(5));
    for (final category in builtinEmojiCategories) {
      expect(category.name, isNotEmpty);
      expect(category.labelKey, startsWith('chat.emoji'));
      expect(category.codes, isNotEmpty, reason: '${category.name} 是空的');
      // 分类条上那颗代表图标必须是**本栏里的一个表情**（不能让用户点了「动物」
      // 结果图标是张脸），比较前把变体选择符（U+FE0F）去掉：
      // 「❤️ / ✈️」这类带选择符的写法与本栏里的纯码点看起来是同一个字。
      final chars = category.codes
          .map(emojiCharOf)
          .whereType<String>()
          .map(_stripVariation)
          .toSet();
      expect(
        chars,
        contains(_stripVariation(category.icon)),
        reason: '${category.name} 的分类图标不在本栏里',
      );
    }
    // name 不重样（面板分类条靠它区分）
    final names = builtinEmojiCategories.map((c) => c.name).toSet();
    expect(names, hasLength(builtinEmojiCategories.length));
  });

  test('每一栏里的码点都能解成字符，且同一栏不重复', () {
    for (final category in builtinEmojiCategories) {
      final seen = <String, int>{};
      for (final code in category.codes) {
        expect(
          emojiCharOf(code),
          isNotNull,
          reason: '${category.name} 里的 $code 不是合法码点',
        );
        expect(
          seen.containsKey(code),
          isFalse,
          reason: '${category.name} 里 $code 出现了两次',
        );
        seen[code] = 1;
      }
    }
  });

  test('第一栏「常用」原样照抄老端那 66 个（顺序与码值都不动）', () {
    expect(legacyEmojiCodes, hasLength(66));
    expect(builtinEmojiCategories.first.name, 'common');
    expect(builtinEmojiCategories.first.codes, legacyEmojiCodes);
    // 老端那份的开头几个（写死在这里，改动了就是「用户原来那个位置的表情换了」）
    expect(legacyEmojiCodes.take(3), <String>['1f600', '1f62c', '1f601']);
  });

  test('十栏（含旗子）加起来有足够多的表情（面板不能是一屏就到底）', () {
    expect(builtinEmojiCategories, hasLength(10));
    expect(
      builtinEmojiCategories.map((c) => c.name),
      containsAll(<String>['objects', 'symbols', 'flags']),
    );
    final total = builtinEmojiCategories.fold<int>(
      0,
      (sum, category) => sum + category.codes.length,
    );
    expect(total, greaterThan(300));
  });

  test('旗子那一栏的图标就是国旗本身，且每面旗都是两段码值拼的', () {
    final flags = builtinEmojiCategories.singleWhere((c) => c.name == 'flags');
    expect(flags.icon, '\u{1f1e8}\u{1f1f3}'); // 🇨🇳
    expect(flags.labelKey, 'chat.emojiFlags');
    // 国旗 = 两个区域指示符（U+1F1E6–U+1F1FF）；面板点它要能进输入框，
    // 所以每一条都得是「A-B」两段，且各自落在区域指示符范围内。
    for (final code in flags.codes) {
      final parts = code.split('-');
      expect(parts, hasLength(2), reason: '$code 不是两段码值');
      for (final part in parts) {
        final value = int.parse(part, radix: 16);
        expect(
          value >= 0x1F1E6 && value <= 0x1F1FF,
          isTrue,
          reason: '$part 不是区域指示符（0x1F1E6–0x1F1FF）',
        );
      }
      expect(emojiCharOf(code)!.runes.length, 2);
    }
    expect(flags.length, greaterThanOrEqualTo(20));
  });
}
