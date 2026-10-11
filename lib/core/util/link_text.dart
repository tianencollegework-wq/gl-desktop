/// 纯文本里的链接识别（用户 2026-09-25 反馈：聊天里发出去的网址点不动）。
///
/// 微信的规则，我们照做：
/// * `http://…` / `https://…` 整串算链接；
/// * `www.` 开头的算链接（打开时补 `http://`）；
/// * **裸域名**也算（`gracelinkim.com`、`a.com.cn`），补 `http://` 打开。
///
/// 「补 http 而不是 https」是刻意的：浏览器/WebView 对 HSTS 站点会把 http 内部升级，
/// 反过来（给只支持 http 的老站点硬套 https）会直接 TLS 报错 —— 老端与微信也是这么做的。
///
/// 这里只管**识别**，不碰导航（打开动作在 `core/ui/link_opener.dart::openChatLink`，
/// 聊天与扫一扫共用那一条路），
/// 也不碰表情 token —— 调用方先按表情拆段，再把纯文字那几段丢进来（见
/// `features/chat/widgets/message_bubble.dart::_MessageRichText`）。
library;

/// 能出现在网址里的字符（RFC 3986 的那套 ASCII 子集）。
///
/// 刻意**不用**「除空白以外的所有字符」：中文例句「看这个http://a.com很好」
/// 那样写会把「很好」一起吞进链接。中文、引号、书名号都不在这个集合里，
/// 于是它们天然就是链接的结束符。
const String _urlChars = r"A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%";

/// 裸域名认得出的后缀。
///
/// 不做「任意 TLD」是因为那会把 `报告.docx`、`1.5`、`index.html` 之类误判成网址；
/// 这份清单覆盖常见后缀与常见国别域名（含 `com.cn` 这种二级后缀 —— 域名正则按
/// 「最后一段」匹配，`a.com.cn` 靠 `cn` 命中）。
const List<String> _topLevelDomains = <String>[
  'com',
  'net',
  'org',
  'cn',
  'io',
  'me',
  'cc',
  'tv',
  'app',
  'dev',
  'xyz',
  'top',
  'vip',
  'club',
  'shop',
  'site',
  'online',
  'info',
  'tech',
  'live',
  'fun',
  'edu',
  'gov',
  'co',
  'uk',
  'us',
  'hk',
  'tw',
  'jp',
  'kr',
  'sg',
  'my',
  'de',
  'fr',
  'ru',
  'au',
];

/// 域名最后一段：`(?![A-Za-z0-9])` 保证 `a.command` 里的 `com` 不算数
final String _tldPattern =
    '(?:${_topLevelDomains.map(RegExp.escape).join('|')})(?![A-Za-z0-9])';

/// 带协议的，或以 `www.` 开头的：后面吃掉所有网址字符
final RegExp _schemeLink = RegExp(
  '(?:https?://|www\\.)[$_urlChars]+',
  caseSensitive: false,
);

/// 裸域名：`gracelinkim.com`、`www` 之外的 `a.b.com/path?x=1`
final RegExp _bareLink = RegExp(
  '(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\\.)+$_tldPattern'
  '(?:/[$_urlChars]*)?',
  caseSensitive: false,
);

/// 一整段里的链接（两种写法合在一起扫，按出现位置排）
final RegExp linkPattern = RegExp(
  '${_schemeLink.pattern}|${_bareLink.pattern}',
  caseSensitive: false,
);

/// 链接**末尾**不收的标点。
///
/// 句子末尾的句号/逗号、中文标点、包裹链接的括号都不属于网址，
/// 不然「我在 gracelinkim.com。你也去」会把那个句号带进地址里。
const String _trailingPunctuation = '.!,;:?\'"、。，；：！？））》】…”’';

/// 链接结尾处需要一起吐回去的括号（`(说明)` 这种包裹）
const String _trailingBrackets = ')]}';

/// 一段文本或一个链接
sealed class LinkSegment {
  const LinkSegment();
}

/// 普通文字（原样显示）
class PlainLinkSegment extends LinkSegment {
  const PlainLinkSegment(this.text);

  final String text;
}

/// 一个链接：[text] 是原文（要显示的那截），[url] 是真正要打开的地址
/// （裸域名/`www.` 开头的会在这里补上 `http://`）。
class UrlLinkSegment extends LinkSegment {
  const UrlLinkSegment(this.text, this.url);

  final String text;
  final String url;
}

/// 把一段纯文本拆成「文字 / 链接」交替的分段（没有链接时就是一段文字）。
List<LinkSegment> parseLinkSegments(String source) {
  if (source.isEmpty) return const <LinkSegment>[];

  final segments = <LinkSegment>[];
  var cursor = 0;

  for (final match in linkPattern.allMatches(source)) {
    if (match.start < cursor) continue; // 与上一段重叠（前面的匹配更长）
    final text = _trimTrailingPunctuation(match.group(0)!);
    if (text.isEmpty) continue;
    // 裸域名要防「邮箱里的域名」：`foo@bar.com` 不该把 `bar.com` 变成链接
    final isBare = !RegExp(
      '^(?:https?://|www\\.)',
      caseSensitive: false,
    ).hasMatch(text);
    if (isBare && _gluedToWord(source, match.start)) continue;

    final end = match.start + text.length;
    if (match.start > cursor) {
      segments.add(PlainLinkSegment(source.substring(cursor, match.start)));
    }
    segments.add(UrlLinkSegment(text, urlOfLink(text)));
    cursor = end;
  }

  if (cursor < source.length) {
    segments.add(PlainLinkSegment(source.substring(cursor)));
  }
  return segments;
}

/// 显示用原文 → 真正要打开的地址（没有协议就补 `http://`）。
String urlOfLink(String text) {
  if (RegExp('^https?://', caseSensitive: false).hasMatch(text)) return text;
  return 'http://$text';
}

/// 去掉链接尾巴上的标点与包裹用的括号。
String _trimTrailingPunctuation(String text) {
  var end = text.length;
  while (end > 0) {
    final char = text[end - 1];
    if (_trailingPunctuation.contains(char) ||
        _trailingBrackets.contains(char)) {
      end--;
      continue;
    }
    break;
  }
  return text.substring(0, end);
}

/// 这个位置前面紧挨着一个「词内字符」吗（`@`、字母数字、点、下划线、连字符）。
///
/// 用来挡掉邮箱和文件名的中间部分：`foo@bar.com`、`v1.2.com` 这类不该被当成链接。
bool _gluedToWord(String source, int start) {
  if (start == 0) return false;
  final previous = source[start - 1];
  return RegExp(r'[A-Za-z0-9_@.\-]').hasMatch(previous);
}
