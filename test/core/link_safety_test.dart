import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/util/link_safety.dart';

/// 点链接之后走哪条路（用户 2026-09-25 定的规矩）：
/// 官方站点直开、微信/腾讯系拦住、其它第三方先问一句。
void main() {
  test('自己的站点（含子域名）算官方：直接进 webview', () {
    for (final url in <String>[
      'https://gracelink.cc',
      'https://gracelink.cc/help?a=1',
      'http://www.gracelink.cc',
      'https://film.gracelink.cc/movie/1',
      'https://a.b.gracelink.cc',
      'gracelink.cc/help', // 裸域名（上一跳会补 http://）
      'https://message.gracelink.cc/api',
    ]) {
      expect(linkSafetyOf(url), LinkSafety.official, reason: url);
    }
  });

  test('只是「参数里带了我们的域名」不算官方：那是别人的站', () {
    expect(
      linkSafetyOf('https://evil.com/?ref=gracelink.cc'),
      LinkSafety.thirdParty,
    );
    // 拿域名当子域的骗术（`gracelink.cc.evil.com` 的主人是 evil.com）
    expect(
      linkSafetyOf('https://gracelink.cc.evil.com/x'),
      LinkSafety.thirdParty,
    );
  });

  test('微信/腾讯那一系一律拦住', () {
    for (final url in <String>[
      'https://weixin.qq.com/r/xxx',
      'https://mp.weixin.qq.com/s/abc',
      'https://wechat.com/download',
      'https://www.tencent.com',
      'https://pay.tenpay.com/app',
      'https://mail.qq.com',
      'https://www.qq.com/news',
      'https://wx.qq.cn/x',
      'https://foxmail.com',
      // 中文写法也认（用户说的「腾讯相关字眼」）
      'https://example.com/腾讯新闻',
      'https://example.com/微信支付',
    ]) {
      expect(linkSafetyOf(url), LinkSafety.blocked, reason: url);
    }
  });

  test('大小写不敏感（`WEIXIN.QQ.COM` 一样拦）', () {
    expect(linkSafetyOf('HTTPS://WEIXIN.QQ.COM/R/X'), LinkSafety.blocked);
    expect(linkSafetyOf('HTTPS://FILM.GRACELINK.CC/M/1'), LinkSafety.official);
  });

  test('其它第三方：先确认再访问', () {
    for (final url in <String>[
      'https://github.com/gracelink',
      'https://www.baidu.com/s?wd=1',
      'gracelinkim.com/a',
      'http://192.168.1.5:8080/x',
    ]) {
      expect(linkSafetyOf(url), LinkSafety.thirdParty, reason: url);
    }
  });

  test('isOfficialLink：主机名才算，路径/参数里的域名不算', () {
    expect(isOfficialLink('https://film.gracelink.cc/a'), isTrue);
    expect(isOfficialLink('https://gracelink.cc'), isTrue);
    expect(isOfficialLink('https://evil.com/gracelink.cc'), isFalse);
    expect(isOfficialLink(''), isFalse);
  });

  test('空串不为官方（别把空地址当自家站放进去）', () {
    expect(linkSafetyOf(''), isNot(LinkSafety.official));
    expect(isOfficialLink('   '), isFalse);
  });
}
