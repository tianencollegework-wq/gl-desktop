import 'news_article.dart';
import 'news_feed.dart';

/// RSS 2.0 / Atom 解析 + HTML 清洗。**纯 Dart、零新依赖**（没引 `xml` / `html`）。
///
/// 为什么手写而不是引解析库：这一期只想吃四个写死的源，用不上通用 XML 的能力；
/// 而多一个依赖就是多一份要跟着 Flutter 升级走的负担（`package_info_plus`
/// 那条依赖冲突的教训还在 `pubspec.yaml` 的注释里）。代价是**边界必须自己兜**，
/// 所以这个文件配了一组拿真实源报文当输入的单测（`test/news/feed_parser_test.dart`）。
///
/// 真实报文里踩到的四种形态，都得吃下：
///
/// * **CDATA 包裹**（奇客 Solidot）：`<title><![CDATA[八分之一癌症病例由感染引起]]></title>`；
/// * **转义 HTML**（IT之家、少数派）：`<description>&lt;p&gt;...&lt;/p&gt;</description>`；
/// * **真 HTML**（爱范儿的 WordPress `content:encoded`）；
/// * **自闭合带属性**（Atom、`media:content`）：`<link rel="alternate" href="..."/>`。
///
/// 解析不出来就返回空列表（当成「这个源这次没东西」），**绝不抛异常** ——
/// 源返回了 WAF 拦截页那种 HTML 是最常见的情况（36氪 就是这样），
/// 那不该让整个频道报错。
///
/// 摘要截到 [summaryLimit] 个字符：既是缓存体积（SharedPreferences 里存一份
/// 120 条），也是版权口径 —— 只给摘要和缩略图，全文点「阅读原文」去原站。
List<NewsArticle> parseFeedXml(
  String xml, {
  required NewsFeed feed,
  int summaryLimit = 1000,
}) {
  // 认不出是 feed 就别白费劲（WAF 拦截页、超时的错误页都会走到这儿）
  if (xml.isEmpty) return const <NewsArticle>[];
  final lower = xml.toLowerCase();
  final looksAtom = lower.contains('<feed') || lower.contains('<entry');
  final looksRss = lower.contains('<rss') || lower.contains('<channel');
  if (!looksAtom && !looksRss) return const <NewsArticle>[];

  final items = RegExp(
    r'<(item|entry)\b[^>]*>([\s\S]*?)</\1>',
    caseSensitive: false,
  ).allMatches(xml);

  final parsed = <String, NewsArticle>{};
  for (final match in items) {
    final block = match.group(2) ?? '';
    final article = _parseItem(block, feed: feed, summaryLimit: summaryLimit);
    // 同一条新闻在一个源里出现两次是常态（有的源会把更新过的条目再发一遍），
    // 按 id 去重、先到的（也就是更新的那条）留下
    if (article != null && !parsed.containsKey(article.id)) {
      parsed[article.id] = article;
    }
  }
  return parsed.values.toList(growable: false);
}

NewsArticle? _parseItem(
  String block, {
  required NewsFeed feed,
  required int summaryLimit,
}) {
  final title = _plain(_tagText(block, 'title'));
  if (title.isEmpty) return null;

  final link = _normalizeLink(_itemLink(block));

  // 正文：优先 `content:encoded`（WordPress 那套给的是全文），
  // 退到 `description`（RSS 2.0）→ `content`（Atom）→ `summary`（Atom）
  final encoded = _tagText(block, 'content:encoded');
  final rawBody = _cdata(
    _firstNotEmpty(<String>[
      encoded,
      _tagText(block, 'description'),
      _tagText(block, 'content'),
      _tagText(block, 'summary'),
    ]),
  );
  // 缩略图只从**全文**里找：`description` 里那张往往是推广卡片
  // （IT之家的 description 第一张图就是京东商品图），拿它当缩略图很怪
  final image = _firstNotEmpty(<String>[
    _mediaUrl(block),
    encoded.isEmpty ? '' : _firstImageUrl(_cdata(encoded)),
  ]);
  final summary = _truncate(htmlToText(rawBody, selfLink: link), summaryLimit);

  final published =
      _parseDate(_tagText(block, 'pubDate')) ??
      _parseDate(_tagText(block, 'published')) ??
      _parseDate(_tagText(block, 'updated')) ??
      _parseDate(_tagText(block, 'dc:date'));

  final guid = _plain(_tagText(block, 'guid'));
  final atomId = _plain(_tagText(block, 'id'));
  final id = _firstNotEmpty(<String>[guid, atomId, link]);
  if (id.isEmpty) return null;

  return NewsArticle(
    id: id,
    title: title,
    link: link,
    sourceKey: feed.key,
    summary: summary,
    imageUrl: image,
    publishedAt: published,
  );
}

/// 取一个标签的内容（**原样**返回，CDATA 包裹保留，交给调用方自己拆）。
///
/// 拆 CDATA 这件事不能拖到 `htmlToText` 里做 —— 那里的第一步是「去标签」，
/// 而 `<![CDATA[根据本周……<p>` 从 `<` 到第一个 `>` 整段都会当成一个标签删掉，
/// 结果摘要只剩一个孤零零的 `]]>`（这组用例第一次跑就是这个结果）。
///
/// 用正则而不是真解析器，所以**必须**是「有闭合标签」的那种写法：
/// 自闭合的 `<link .../>` 在这里取不到，要属性就得走 [_attr]。
String _tagText(String source, String name) {
  final match = RegExp(
    '<$name(?:\\s[^>]*)?>([\\s\\S]*?)</$name>',
    caseSensitive: false,
  ).firstMatch(source);
  return match?.group(1) ?? '';
}

/// 取某个标签上某个属性的值（Atom 的 `<link href=""/>`、`media:content` 的 url）
String _attr(String source, String name, String attribute) {
  final tags = RegExp(
    '<$name\\b[^>]*>',
    caseSensitive: false,
  ).allMatches(source);
  for (final tag in tags) {
    final value = RegExp(
      '$attribute\\s*=\\s*"([^"]*)"|$attribute\\s*=\\s*\'([^\']*)\'',
      caseSensitive: false,
    ).firstMatch(tag.group(0) ?? '');
    final found = value?.group(1) ?? value?.group(2);
    if (found != null && found.isNotEmpty) return _unescape(found);
  }
  return '';
}

/// 条目地址。
///
/// RSS 2.0 是 `<link>地址</link>`；Atom 是 `<link href="地址"/>`，
/// 而且一个条目上可能挂好几个（`rel="alternate"` 才是给人看的那篇，
/// `rel="self"` / `rel="edit"` 是机器用的）。
String _itemLink(String block) {
  final plain = _plain(_tagText(block, 'link'));
  if (plain.isNotEmpty) return plain;
  // Atom：优先 rel="alternate"
  final tags = RegExp(r'<link\b[^>]*>', caseSensitive: false).allMatches(block);
  var fallback = '';
  for (final tag in tags) {
    final text = tag.group(0) ?? '';
    final href = _attr(text, r'link', 'href');
    if (href.isEmpty) continue;
    if (RegExp(
      r'rel\s*=\s*[">]?alternate',
      caseSensitive: false,
    ).hasMatch(text)) {
      return href;
    }
    if (fallback.isEmpty) fallback = href;
  }
  return fallback;
}

/// `media:content` / `media:thumbnail` / `enclosure` 里的图片地址
String _mediaUrl(String block) {
  for (final tag in <String>['media:content', 'media:thumbnail']) {
    final url = _attr(block, tag, 'url');
    if (url.isNotEmpty && !_isTinyImage(url)) return url;
  }
  // enclosure 也可能是音频/视频，只认图片类型；类型没写时看扩展名
  final tags = RegExp(
    r'<enclosure\b[^>]*>',
    caseSensitive: false,
  ).allMatches(block);
  for (final tag in tags) {
    final text = tag.group(0) ?? '';
    final url = _attr(text, 'enclosure', 'url');
    if (url.isEmpty) continue;
    final type = _attr(text, 'enclosure', 'type');
    if (type.startsWith('image/') || _looksLikeImage(url)) return url;
  }
  return '';
}

/// 正文里第一张还像样的图
String _firstImageUrl(String html) {
  final images = RegExp(r'<img\b[^>]*>', caseSensitive: false).allMatches(html);
  for (final image in images) {
    final tag = image.group(0) ?? '';
    final src = _attr(tag, 'img', 'src');
    if (src.isEmpty) continue;
    // 1px 埋点（`width="1"` 那种）和 data: 内联图都不是缩略图
    if (_isTinyImage(tag) || _isTinyImage(src)) continue;
    return src;
  }
  return '';
}

bool _isTinyImage(String tag) =>
    tag.startsWith('data:') ||
    RegExp(r'(width|height)\s*=\s*["\x27]?1["\x27]?\b').hasMatch(tag);

bool _looksLikeImage(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
  return path.endsWith('.jpg') ||
      path.endsWith('.jpeg') ||
      path.endsWith('.png') ||
      path.endsWith('.webp') ||
      path.endsWith('.gif');
}

/// 从**文章页**里取封面图。
///
/// 为什么要走这一步：源里自己带图的很少（爱范儿那种 WordPress 的 feed 会把
/// 图放进 `content:encoded`，小众软件也带），绝大多数源的 feed 里一张图都没有 ——
/// 不补的话「媒体号」里大部分卡就全是纯文字，跟用户给的公众号那张图差得远。
///
/// 顺序：
///
/// 1. `<meta property="og:image">`（`og:image:url` / `og:image:secure_url` 同理）、
///    `twitter:image`；
/// 2. **页面上第一张像文章配图的 `<img>`**（见 [_firstContentImage]）。
///
/// 第 2 步不是锦上添花，是必需的：**IT之家页面上根本没有 og:image**（2026-09-30
/// 实测的，它的 RSS 里也没有图），它连正文图都是懒加载的 —— `src` 是个 1px 占位
/// （`//img.ithome.com/images/v2/t.png`），真地址在 `data-original` 上。
/// 少了这一步，最勤快、给的文章最多的那个号（IT之家）就永远没有封面。
///
/// 一个都没有就返回空串（调用方画纯文字的那种卡，公众号里也有）。
///
/// [baseUrl] 传文章地址：页面里的图常是相对地址或 `//cdn...`（协议相对）。
String htmlMetaImage(String html, {String? baseUrl}) {
  if (html.isEmpty) return '';
  final meta = _metaImage(html);
  if (meta.isNotEmpty) return _absoluteUrl(meta, baseUrl);
  final body = _firstContentImage(html);
  return body.isEmpty ? '' : _absoluteUrl(body, baseUrl);
}

String _metaImage(String html) {
  if (!html.contains('<meta')) return '';
  var twitter = '';
  for (final match in RegExp(
    r'<meta\b[^>]*>',
    caseSensitive: false,
  ).allMatches(html)) {
    final tag = match.group(0) ?? '';
    final content = _unescape(_attr(tag, 'meta', 'content'));
    if (content.isEmpty || content.startsWith('data:')) continue;
    final property = _attr(tag, 'meta', 'property').toLowerCase();
    if (property == 'og:image' ||
        property == 'og:image:url' ||
        property == 'og:image:secure_url') {
      return content;
    }
    final name = _attr(tag, 'meta', 'name').toLowerCase();
    if ((name == 'twitter:image' || name == 'twitter:image:src') &&
        twitter.isEmpty) {
      twitter = content;
    }
  }
  return twitter;
}

/// 正文里第一张「像文章配图」的 `<img>`。
///
/// 懒加载的几种写法都认（`data-original` / `data-src` / `data-lazy-src` /
/// `data-echo`），因为**只看 `src` 会拿到占位图**：IT之家的 `<img src="//img.ithome.com/
/// images/v2/t.png" class="lazy" data-original="https://img.ithome.com/newsuploadfiles/…">
/// 就是这类（实测）。
///
/// 过滤必须狠一点，否则抓回来的是站点自己的装饰图 —— 奇客 Solidot 的文章页就是
/// 纯文字 + 一堆按钮：板块图标（`width="59" height="57"`）、`php.gif`/`apache.gif`
/// 那样的徽章，拿它们当封面还不如不放图。
String _firstContentImage(String html) {
  const lazyAttributes = <String>[
    'data-original',
    'data-src',
    'data-lazy-src',
    'data-echo',
    'src',
  ];
  for (final match in RegExp(
    r'<img\b[^>]*>',
    caseSensitive: false,
  ).allMatches(html)) {
    final tag = match.group(0) ?? '';
    for (final attribute in lazyAttributes) {
      final url = _attr(tag, 'img', attribute);
      if (url.isEmpty || url.startsWith('data:')) continue;
      if (_isChromeImage(tag, url)) continue;
      return url;
    }
  }
  return '';
}

/// 站点自己的装饰图（logo / 图标 / 按钮 / 二维码 / 占位图）不是文章配图
bool _isChromeImage(String tag, String url) {
  final lower = url.toLowerCase();
  for (final word in const <String>[
    'logo',
    'icon',
    'avatar',
    'qrcode',
    '/btn',
    'button',
    'placeholder',
    'spacer',
    'blank',
    '/t.png',
    'share',
    'weibo',
    'wechat',
  ]) {
    if (lower.contains(word)) return true;
  }
  // 徽章、按钮基本都是 gif；矢量图（svg）也不是照片
  if (lower.endsWith('.gif') || lower.endsWith('.svg')) return true;
  if (!_looksLikeImage(lower)) return true;
  if (_isTinyImage(tag)) return true;
  // 明写着很小的也不要：Solidot 那个 59×57 的板块图标就是这么漏出来的
  final width = _pixelAttr(tag, 'width');
  final height = _pixelAttr(tag, 'height');
  if (width != null && height != null && (width < 300 || height < 200)) {
    return true;
  }
  return false;
}

int? _pixelAttr(String tag, String name) {
  final match = RegExp(
    '$name\\s*=\\s*["\x27]?(\\d+)',
    caseSensitive: false,
  ).firstMatch(tag);
  return match == null ? null : int.tryParse(match.group(1) ?? '');
}

/// 补成绝对地址：`//cdn.x/a.png` → `https://cdn.x/a.png`，`/a.png` → 按文章地址解析
String _absoluteUrl(String url, String? baseUrl) {
  if (url.startsWith('//')) return 'https:$url';
  if (url.startsWith('http://') || url.startsWith('https://')) return url;
  if (baseUrl == null || baseUrl.isEmpty) return url;
  final base = Uri.tryParse(baseUrl);
  if (base == null) return url;
  return base.resolve(url).toString();
}

// ---------------------------------------------------------------- HTML 清洗

/// HTML → 纯文本。信息流里那一堆标签、推广卡片、`data-*` 属性全在这里丢掉。
///
/// [selfLink] 传条目自己的地址：少数派这类源的 `description` 结尾挂着一句
/// **指向自己的**「查看全文」链接（`<a href="同一篇地址">查看全文</a>`），
/// 整句剥掉比在文案层写死「查看全文」干净（那是第三方页面的写法，不该进代码）。
String htmlToText(String raw, {String? selfLink}) {
  if (raw.isEmpty) return '';
  var text = raw;
  // 整块丢掉 script / style（有些源的正文里塞了统计脚本）
  text = text.replaceAll(
    RegExp(r'<(script|style)\b[^>]*>[\s\S]*?</\1>', caseSensitive: false),
    ' ',
  );
  // 第一次解码是「结构层」：`&lt;p&gt;` 要变回真标签才能按标签切段
  text = _unescape(text);
  if (selfLink != null && selfLink.isNotEmpty) {
    text = _stripSelfLinks(text, selfLink);
  }
  // 块级结束标签 → 换行；`<li>` 前面加个点，列表才不至于糊成一行
  text = text
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(
        RegExp(
          r'</(p|div|li|h[1-6]|tr|blockquote|section|article)\s*>',
          caseSensitive: false,
        ),
        '\n\n',
      )
      .replaceAll(RegExp(r'<(li|tr)\b[^>]*>', caseSensitive: false), '\n· ');
  // 余下的标签一律换成空格（不是空串：`<b>粗</b>体` 不能粘成「粗体」）
  text = text.replaceAll(RegExp(r'<[^>]*>'), ' ');
  // 第二次解码是「展示层」：`&amp;#39;` 这种二次转义也要还原成 `'`
  text = _unescape(text);

  final lines = <String>[];
  for (final line in text.split('\n')) {
    final trimmed = line.replaceAll(RegExp(r'[ \t\u00a0\u3000]+'), ' ').trim();
    if (trimmed.isEmpty) {
      // 正文里的空行是段落分隔，只留一个
      if (lines.isNotEmpty && lines.last.isNotEmpty) lines.add('');
      continue;
    }
    lines.add(trimmed);
  }
  while (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines.join('\n');
}

/// 剥掉指向条目自身地址的 `<a>`（连文字一起）
String _stripSelfLinks(String html, String selfLink) {
  final target = _linkIdentity(selfLink);
  return html.replaceAllMapped(
    RegExp(r'<a\b[^>]*>[\s\S]*?</a>', caseSensitive: false),
    (match) {
      final tag = match.group(0) ?? '';
      final href = _attr(tag, 'a', 'href');
      if (href.isEmpty) return tag;
      return _linkIdentity(href) == target ? ' ' : tag;
    },
  );
}

/// 比较链接是不是同一个：去跟踪参数、去 `#` 片段、去尾斜杠
String _linkIdentity(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return url.trim();
  final query = Map<String, String>.from(uri.queryParameters)
    ..removeWhere((key, _) => key.toLowerCase().startsWith('utm_'));
  final normalized = _rebuild(uri, query: _encodeQuery(query));
  var text = normalized.toString();
  while (text.endsWith('/')) {
    text = text.substring(0, text.length - 1);
  }
  return text.toLowerCase();
}

/// 归一化条目地址：同样的去跟踪参数，`#comments` 这类片段也去掉 ——
/// 同一条新闻两次抓取时参数不同（WordPress 会带 utm）就会算成两条
String _normalizeLink(String raw) {
  final url = _plain(raw);
  if (url.isEmpty) return '';
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  final query = Map<String, String>.from(uri.queryParameters)
    ..removeWhere(
      (key, _) =>
          key.toLowerCase().startsWith('utm_') ||
          key.toLowerCase() == 'spm' ||
          key.toLowerCase() == 'from',
    );
  return _rebuild(uri, query: _encodeQuery(query)).toString();
}

/// 重新拼一个 Uri：把「空 query」「空 fragment」真的去掉。
///
/// **不能用 `uri.replace(query: ...)`**：`replace` 的 null 参数是「保留原值」的意思，
/// 传空串又会留下一个光秃的 `?` / `#`（Atom 那组用例就是这么抓出来的 ——
/// 归一化后的地址尾巴上挂了个 `#`，于是同一条新闻算成两条）。
Uri _rebuild(Uri uri, {required String? query}) {
  // 相对地址/认不出的地址：原样返回（只把可能挂着的空 `#` 摘掉）
  if (uri.host.isEmpty) {
    final text = uri.toString();
    return text.endsWith('#')
        ? Uri.parse(text.substring(0, text.length - 1))
        : uri;
  }
  return Uri(
    scheme: uri.scheme,
    userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
    query: (query == null || query.isEmpty) ? null : query,
  );
}

String? _encodeQuery(Map<String, String> query) => query.isEmpty
    ? null
    : query.entries.map((e) => '${e.key}=${e.value}').join('&');

/// CDATA / 转义实体 → 纯文本（标签**不**动，交给 [htmlToText]）
String _plain(String raw) => _unescape(_cdata(raw)).trim();

String _cdata(String raw) {
  final match = RegExp(
    r'<!\[CDATA\[([\s\S]*?)\]\]>',
    caseSensitive: false,
  ).firstMatch(raw);
  return match?.group(1) ?? raw;
}

/// 实体还原：数字（十进制 / 十六进制）+ 常见命名实体。
///
/// `&amp;` 放在最后替换 —— 先换它会把 `&amp;lt;` 变成 `&lt;`，
/// 接着那轮就把它换成了 `<`，等于凭空多了一次解码。
String _unescape(String raw) {
  if (!raw.contains('&')) return raw;
  var text = raw.replaceAllMapped(
    RegExp(r'&#x([0-9a-fA-F]+);'),
    (match) => _charFromCode(match.group(1)!, radix: 16),
  );
  text = text.replaceAllMapped(
    RegExp(r'&#(\d+);'),
    (match) => _charFromCode(match.group(1)!, radix: 10),
  );
  const named = <String, String>{
    '&nbsp;': ' ',
    '&lt;': '<',
    '&gt;': '>',
    '&quot;': '"',
    '&apos;': "'",
    '&ldquo;': '“',
    '&rdquo;': '”',
    '&lsquo;': '‘',
    '&rsquo;': '’',
    '&mdash;': '—',
    '&ndash;': '–',
    '&hellip;': '…',
    '&middot;': '·',
    '&amp;': '&',
  };
  named.forEach((entity, value) {
    text = text.replaceAll(entity, value);
    text = text.replaceAll(entity.toUpperCase(), value);
  });
  return text;
}

String _charFromCode(String code, {required int radix}) {
  final value = int.tryParse(code, radix: radix);
  if (value == null || value <= 0 || value > 0x10FFFF) return '';
  return String.fromCharCode(value);
}

/// 取第一个非空值（正文/图片有几个候选，谁先有内容用谁）
String _firstNotEmpty(List<String> values) {
  for (final value in values) {
    if (value.trim().isNotEmpty) return value.trim();
  }
  return '';
}

String _truncate(String text, int limit) {
  if (text.length <= limit) return text;
  return '${text.substring(0, limit).trimRight()}…';
}

// ------------------------------------------------------------------ 日期解析

const List<String> _months = <String>[
  'jan',
  'feb',
  'mar',
  'apr',
  'may',
  'jun',
  'jul',
  'aug',
  'sep',
  'oct',
  'nov',
  'dec',
];

/// RSS 的日期格式五花八门，这里吃三种：
///
/// * **RFC 822**（RSS 2.0 的标准写法，也是实际最常见的一种）：
///   `Tue, 29 Sep 2026 23:25:25 +0800`；时区缺失或写 `GMT` / `UT` 时按 UTC 算；
/// * **ISO 8601**（Atom）：`2026-09-29T23:25:25+08:00`，直接交给 `DateTime.parse`；
/// * **裸本地时间**（少数源不写时区）：`2026-09-29 23:25:25` —— 按**北京时间**
///   算。源全是中文站点，这个假设比「按 UTC 算」错得少（真按 UTC 会整整差
///   8 小时，用户一眼就看出来「3小时前」变成了「11小时前」）。
///
/// 认不出来就返回 null：宁可不显示时间，也不要显示一个错的时间。
DateTime? _parseDate(String raw) {
  final text = _plain(raw);
  if (text.isEmpty) return null;

  // 先看有没有显式时区。**这一步不能省**：Dart 的 `DateTime.tryParse` 对
  // `2026-09-29 23:25:25` 这种裸时间也会成功，并按**设备本地时区**理解 ——
  // 同一个源在两种时区的机器上就是两个时间，得自己按北京时间算（见下）。
  if (RegExp(r'(Z|[+-]\d{2}:?\d{2})$').hasMatch(text.trim())) {
    final iso = DateTime.tryParse(text);
    if (iso != null) return iso.toLocal();
  }

  final match = RegExp(
    r'(\d{1,2})\s+([A-Za-z]{3})[a-z]*\s+(\d{4})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([+-]\d{4}|[A-Za-z]{1,4})?',
  ).firstMatch(text);
  if (match != null) {
    final month = _months.indexOf(match.group(2)!.toLowerCase()) + 1;
    if (month == 0) return null;
    return _zoned(
      year: int.parse(match.group(3)!),
      month: month,
      day: int.parse(match.group(1)!),
      hour: int.parse(match.group(4)!),
      minute: int.parse(match.group(5)!),
      second: int.tryParse(match.group(6) ?? '') ?? 0,
      zone: match.group(7) ?? '',
    );
  }

  final bare = RegExp(
    r'(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?',
  ).firstMatch(text);
  if (bare != null) {
    return _zoned(
      year: int.parse(bare.group(1)!),
      month: int.parse(bare.group(2)!),
      day: int.parse(bare.group(3)!),
      hour: int.tryParse(bare.group(4) ?? '') ?? 0,
      minute: int.tryParse(bare.group(5) ?? '') ?? 0,
      second: int.tryParse(bare.group(6) ?? '') ?? 0,
      // 没写时区 → 按北京时间（见 [_zoned]）
      zone: '',
    );
  }
  return null;
}

DateTime _zoned({
  required int year,
  required int month,
  required int day,
  required int hour,
  required int minute,
  required int second,
  required String zone,
}) {
  final utc = DateTime.utc(year, month, day, hour, minute, second);
  final offset = _zoneOffset(zone);
  if (offset == null) {
    // 没写时区：中文源基本都写 +0800，缺省按北京时间理解
    return utc.subtract(const Duration(hours: 8)).toLocal();
  }
  return utc.subtract(offset).toLocal();
}

Duration? _zoneOffset(String zone) {
  final match = RegExp(r'^([+-])(\d{2})(\d{2})$').firstMatch(zone);
  if (match != null) {
    final minutes =
        int.parse(match.group(2)!) * 60 + int.parse(match.group(3)!);
    final signed = match.group(1) == '-' ? -minutes : minutes;
    return Duration(minutes: signed);
  }
  final upper = zone.toUpperCase();
  if (upper == 'GMT' || upper == 'UT' || upper == 'UTC' || upper == 'Z') {
    return Duration.zero;
  }
  // 美式缩写（EST/PST…）不猜：猜错就是几小时的偏差，不如走缺省那条
  return null;
}
