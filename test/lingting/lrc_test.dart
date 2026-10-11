import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/lingting/lyric.dart';

void main() {
  group('LRC 解析', () {
    test('基本形态：分:秒.毫秒', () {
      final lines = parseLrc('[00:12.50]第一句\n[01:05.00]第二句');
      expect(lines.length, 2);
      expect(lines[0].at, const Duration(seconds: 12, milliseconds: 500));
      expect(lines[0].text, '第一句');
      expect(lines[1].at, const Duration(minutes: 1, seconds: 5));
    });

    test('一行多个时间标签：全部展开，正文只一份', () {
      final lines = parseLrc('[00:10.00][01:20.00]副歌');
      expect(lines.length, 2);
      expect(lines[0].text, '副歌');
      expect(lines[1].at, const Duration(minutes: 1, seconds: 20));
      expect(lines[1].text, '副歌');
    });

    test('毫秒位 1/2/3 位都按小数处理（.5 = 500ms、.50 = 500ms、.500 = 500ms）', () {
      expect(
        parseLrc('[00:01.5]x').single.at,
        const Duration(seconds: 1, milliseconds: 500),
      );
      expect(
        parseLrc('[00:01.50]x').single.at,
        const Duration(seconds: 1, milliseconds: 500),
      );
      expect(
        parseLrc('[00:01.500]x').single.at,
        const Duration(seconds: 1, milliseconds: 500),
      );
    });

    test('时间标签冒号分毫秒的写法（[mm:ss:xx]）也认', () {
      expect(
        parseLrc('[00:03:25]x').single.at,
        const Duration(seconds: 3, milliseconds: 250),
      );
    });

    test('offset 标签整体平移', () {
      final lines = parseLrc('[offset:500]\n[00:10.00]晚半秒');
      expect(lines.single.at, const Duration(seconds: 10, milliseconds: 500));
    });

    test('负 offset 不会把时间推成负数（截到 0）', () {
      final lines = parseLrc('[offset:-5000]\n[00:01.00]开头');
      expect(lines.single.at, Duration.zero);
    });

    test('元信息行（ti/ar/al/by）与无时间的行都丢掉', () {
      final lines = parseLrc(
        '[ti:聖潔主]\n[ar:e麦合唱团]\n[al:坚定]\n[by:某人]\n'
        '这一行没有时间标签\n[00:05.00]只有这句是歌词',
      );
      expect(lines.length, 1);
      expect(lines.single.text, '只有这句是歌词');
    });

    test('空行与纯时间标签行（没正文）丢掉', () {
      expect(parseLrc('\n[00:01.00]\n\n'), isEmpty);
    });

    test('解析不出任何时间标签 → 空列表（调用方据此走纯文本那条路）', () {
      expect(parseLrc('这是没有时间轴的歌词\n第二行'), isEmpty);
      expect(parseLrc(''), isEmpty);
      expect(parseLrc('   '), isEmpty);
    });

    test('乱序标签会排好（时间轴必须单调）', () {
      final lines = parseLrc('[00:30.00]后\n[00:10.00]前');
      expect(lines.map((line) => line.text).toList(), <String>['前', '后']);
    });

    test('CRLF 换行也认（老 MP3 的 .lrc 常见）', () {
      final lines = parseLrc('[00:01.00]a\r\n[00:02.00]b\r\n');
      expect(lines.length, 2);
      expect(lines[1].text, 'b');
    });
  });

  group('纯文本歌词', () {
    test('按行拆开、去掉空行与首尾空白', () {
      expect(plainLyricLines(' a \n\n  b\n'), <String>['a', 'b']);
    });

    // 下面三条盯着真机截图上的那两个毛病：歌词铺成一坨、歌名带方括号。
    // 灵听列表接口的 `lyric` 是**用 `;` 把整首歌连成一行**的纯文本（`;;` = 空行），
    // 实测抽 180 首，**一首都没有真换行** —— 不拆分号就是一整块连着的文字。
    test('分号当换行、双分号当空行（真接口原样）', () {
      expect(
        plainLyricLines('《敬拜的心》;;词曲：赵治德;演唱：江真;;;我献上一颗敬拜的心;指的就是我全所有;'),
        <String>['《敬拜的心》', '词曲：赵治德', '演唱：江真', '我献上一颗敬拜的心', '指的就是我全所有'],
      );
    });

    test('全角分号也认', () {
      expect(plainLyricLines('第一句；第二句'), <String>['第一句', '第二句']);
    });

    test('搜索命中标记的方括号不进正文', () {
      expect(plainLyricLines('[一]粒[麦子]'), <String>['一粒麦子']);
    });
  });

  group('当前行定位', () {
    final lyric = LingtingLyric(
      lines: <LyricLine>[
        const LyricLine(at: Duration.zero, text: 'a'),
        const LyricLine(at: Duration(seconds: 10), text: 'b'),
        const LyricLine(at: Duration(seconds: 20), text: 'c'),
      ],
    );

    test('开始前是 -1（前奏期间不高亮）', () {
      expect(lyric.activeIndex(const Duration(milliseconds: -1)), -1);
    });

    test('正好落在某一行上是那一行', () {
      expect(lyric.activeIndex(Duration.zero), 0);
      expect(lyric.activeIndex(const Duration(seconds: 10)), 1);
    });

    test('两行之间是前一行', () {
      expect(lyric.activeIndex(const Duration(seconds: 15)), 1);
      expect(
        lyric.activeIndex(const Duration(seconds: 19, milliseconds: 999)),
        1,
      );
    });

    test('超过最后一行是最后一行', () {
      expect(lyric.activeIndex(const Duration(minutes: 5)), 2);
    });

    test('没有时间轴时永远是 -1', () {
      expect(LingtingLyric.empty.activeIndex(const Duration(seconds: 5)), -1);
    });
  });

  group('歌词字段的两种形态', () {
    test('http 开头且没有换行 → 当成地址（要去下载 .lrc）', () {
      final source = LingtingLyricSource.parse(
        'https://listen-to-heart.oss.com/music/voice/x.lrc',
      );
      expect(source.isUrl, isTrue);
      expect(source.value, isNotEmpty);
    });

    test('正文（哪怕里面有 http 字样，只要换行）→ 不当地址', () {
      final source = LingtingLyricSource.parse('《这是恩典之路》;作词：某某\n感谢阿爸父');
      expect(source.isUrl, isFalse);
    });

    test('空串 → 空来源', () {
      final source = LingtingLyricSource.parse('   ');
      expect(source.isUrl, isFalse);
      expect(source.value, isEmpty);
    });
  });
}
