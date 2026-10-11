import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/util/emoji.dart';

/// 表情（S4.4b：**系统表情**）。
///
/// 老端是「token + 服务端 png」，新端把 token 解成 Unicode 字符交给系统字体。
/// 这一份用例钉住三件事：**码值解得出字符**、**解不出就保留原文**、
/// **预览/复制里显示的是表情本身**（不再是空一块）。
void main() {
  group('码值 → 系统表情字符', () {
    test('单码点', () {
      expect(emojiCharOf('1f600'), '😀');
      expect(emojiCharOf('263a'), '☺');
    });

    test('超出 BMP 的码点走代理对', () {
      expect(emojiCharOf('1f970')!.runes.length, 1);
      expect(emojiCharOf('1faf0'), '🫰');
    });

    test('非法码值返回 null（调用方保留原文）', () {
      expect(emojiCharOf('nope'), isNull);
      expect(emojiCharOf(''), isNull);
      expect(emojiCharOf('110000'), isNull); // 超出 Unicode 上限
      expect(emojiCharOf('d800'), isNull); // 代理区不能单独成字符
    });

    test('多段码值拼成一个字符（旗子就是两个区域指示符）', () {
      // 面板里新加的旗子那一栏用 `-` 把两段接起来写：1f1e8 + 1f1f3 = 🇨🇳
      expect(emojiCharOf('1f1e8-1f1f3'), '🇨🇳');
      expect(emojiCharOf('1f1ef-1f1f5'), '🇯🇵');
      // 两段各自超出 BMP，拼出来是 2 个码点（国旗就是这个形态）
      expect(emojiCharOf('1f1e8-1f1f3')!.runes.length, 2);
      // 只要有一段不合法，整串不认（宁可保留原文，不画半个旗子）
      expect(emojiCharOf('1f1e8-nope'), isNull);
      expect(emojiCharOf('1f1e8-'), isNull);
      expect(emojiCharOf('-1f1e8'), isNull);
    });

    test('token 里带 `-` 的多段代码也认（网页端/历史消息那种写法）', () {
      expect(previewText('去北京 [!1f1e8-1f1f3]'), '去北京 🇨🇳');
      expect(
        parseEmojiSegments(
          '[!1f1e8-1f1f3]',
        ).whereType<EmojiCharSegment>().single.char,
        '🇨🇳',
      );
    });
  });

  group('拆成文字 / 表情交替的分段', () {
    test('文字夹表情', () {
      final segments = parseEmojiSegments('你好[!1f600]再见');

      expect(segments.length, 3);
      expect((segments[0] as TextEmojiSegment).text, '你好');
      expect((segments[1] as EmojiCharSegment).code, '1f600');
      expect((segments[1] as EmojiCharSegment).char, '😀');
      expect((segments[2] as TextEmojiSegment).text, '再见');
    });

    test('连续表情之间不会夹出空文字段', () {
      final segments = parseEmojiSegments('[!1f600][!1f601]');

      expect(segments.length, 2);
      expect(segments.every((s) => s is EmojiCharSegment), isTrue);
    });

    test('不认识的代码保留原文（与老端 fallback 一致）', () {
      final segments = parseEmojiSegments(
        'a[!nope]b',
        isKnown: (code) => code == '1f600',
      );

      expect(segments.length, 1);
      expect((segments.single as TextEmojiSegment).text, 'a[!nope]b');
    });

    test('码值非法（不是十六进制）也保留原文，不能变成空白', () {
      final segments = parseEmojiSegments('a[!zzz]b');

      expect(segments.length, 1);
      expect((segments.single as TextEmojiSegment).text, 'a[!zzz]b');
    });

    test('没有表情时原样返回一段文字', () {
      final segments = parseEmojiSegments('普通消息');

      expect(segments.length, 1);
      expect((segments.single as TextEmojiSegment).text, '普通消息');
    });

    test('空串返回空列表', () {
      expect(parseEmojiSegments(''), isEmpty);
    });
  });

  group('会话列表的纯文本预览', () {
    test('表情 token 变成系统表情字符（列表里看得到表情）', () {
      expect(previewText('下午[!1f600]见'), '下午😀见');
    });

    test('全是表情时留下那个表情', () {
      expect(previewText('[!1f600]'), '😀');
    });

    test('网页端那串表情图片还原出来的 token 也是字符', () {
      expect(
        previewText('<p>看这个<img emoji-name="1f600" src="x.png"></p>'),
        '看这个😀',
      );
    });

    test('普通文本与空串不受影响', () {
      expect(previewText('在吗'), '在吗');
      expect(previewText(''), '');
    });
  });
}
