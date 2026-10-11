import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/util/link_text.dart';

/// 聊天消息里的网址识别（用户 2026-09-25 反馈：发出去的链接点不动）。
///
/// 这份清单按「微信认哪些」来钉：完整协议、`www.`、裸域名都算链接；
/// 但 `.docx`、`1.5`、`v1.2.3`、邮箱里的域名**不能**被误认成链接，
/// 中文要紧贴着网址时也要在网址那里断句（不然会把中文吞进地址）。
void main() {
  /// 把分段压成「链接用 `<>` 包住」的一行，断言读起来像原文
  String dump(String source) => parseLinkSegments(source)
      .map(
        (segment) => switch (segment) {
          PlainLinkSegment() => segment.text,
          UrlLinkSegment() => '<${segment.url}>',
        },
      )
      .join('|');

  test('整串就是一个链接：原样打开，不改协议', () {
    expect(
      dump('https://gracelink.cc/a?b=1#c'),
      '<https://gracelink.cc/a?b=1#c>',
    );
    expect(dump('http://a.com'), '<http://a.com>');
    // 大小写不敏感（`HTTPS://` 也是链接）
    expect(dump('HTTPS://A.COM/X'), '<HTTPS://A.COM/X>');
  });

  test('夹在中文里的链接：两边文字保留，链接单独成段', () {
    expect(dump('看这个 https://a.com/x 好玩'), '看这个 |<https://a.com/x>| 好玩');
  });

  test('中文紧贴着网址也会断句（不会把中文吞进地址）', () {
    expect(dump('https://a.com/x很好'), '<https://a.com/x>|很好');
    expect(dump('截图见https://a.com/1.png谢谢'), '截图见|<https://a.com/1.png>|谢谢');
  });

  test('网址尾巴上的标点不收进地址（中文标点与英文标点都算）', () {
    expect(dump('官网 gracelink.cc。'), '官网 |<http://gracelink.cc>|。');
    expect(dump('去 https://a.com/x, 然后'), '去 |<https://a.com/x>|, 然后');
    expect(dump('（见 https://a.com/x）'), '（见 |<https://a.com/x>|）');
    expect(dump('(https://a.com/x)'), '(|<https://a.com/x>|)');
  });

  test('`www.` 与裸域名补 `http://`（老端与微信也是这么开的）', () {
    expect(dump('www.a.com/b'), '<http://www.a.com/b>');
    expect(dump('gracelinkim.com'), '<http://gracelinkim.com>');
    expect(dump('a.com.cn/path?x=1'), '<http://a.com.cn/path?x=1>');
  });

  test('不像网址的东西保持原样', () {
    // 不是 TLD 的扩展名（报文件名、`1.5`、版本号）
    expect(dump('报告.docx'), '报告.docx');
    expect(dump('1.5 倍'), '1.5 倍');
    expect(dump('版本 v1.2.3 发布'), '版本 v1.2.3 发布');
    expect(dump('a.command 是命令'), 'a.command 是命令');
  });

  test('邮箱里的域名不单独变成链接', () {
    expect(dump('发到 foo@bar.com 就行'), '发到 foo@bar.com 就行');
    expect(dump('foo@bar.com'), 'foo@bar.com');
  });

  test('没有链接 / 空串', () {
    expect(dump('你好'), '你好');
    expect(parseLinkSegments(''), isEmpty);
  });

  test('一段里多个链接都能认出来', () {
    expect(
      dump('https://a.com 和 https://b.com'),
      '<https://a.com>| 和 |<https://b.com>',
    );
  });

  test('urlOfLink：有协议不动，没协议补 http', () {
    expect(urlOfLink('https://a.com'), 'https://a.com');
    expect(urlOfLink('WWW.a.com'), 'http://WWW.a.com');
    expect(urlOfLink('a.com'), 'http://a.com');
  });

  test('链接显示用的是原文（不显示补出来的 http）', () {
    final segment = parseLinkSegments('a.com').single as UrlLinkSegment;
    expect(segment.text, 'a.com');
    expect(segment.url, 'http://a.com');
  });
}
