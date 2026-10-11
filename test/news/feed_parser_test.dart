import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/domain/news/feed_parser.dart';
import 'package:gracelinkim/domain/news/news_feed.dart';

/// RSS / Atom 解析。报文是从**真实源**上抄下来的片段（不是自己编的理想 XML），
/// 因为当初踩的坑全在这些不规整的地方：CDATA、被转义的 HTML、自闭合的 Atom 标签、
/// 正文里混着的推广卡片、以及「HTTP 200 但返回的是 WAF 拦截页」。
void main() {
  const feed = NewsFeed(
    key: 'test',
    nameKey: 'news.title',
    url: 'https://example.test/feed',
    home: 'https://example.test',
  );

  // ------------------------------------------------------------ 奇客 Solidot
  // 真实报文：全部字段包在 CDATA 里，正文末尾还挂着一个空的 `<p></p>`
  const solidot = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
<channel>
<title>奇客Solidot&#8211;传递最新科技情报</title>
<atom:link href="https://www.solidot.org/index.rss" rel="self" type="application/rss+xml"/>
<item>
<title><![CDATA[八分之一癌症病例由感染引起]]></title>
<link><![CDATA[https://www.solidot.org/story?sid=85507]]></link>
<description><![CDATA[根据本周发表的一项研究，全世界八分之一癌症病例由感染引起。
<p></p>
]]></description>
<pubDate>Tue, 29 Sep 2026 23:25:25 +0800</pubDate>
</item>
</channel>
</rss>
''';

  test('CDATA 包裹的源：标题、链接、摘要、时间都取到', () {
    final articles = parseFeedXml(solidot, feed: feed);

    expect(articles, hasLength(1));
    final article = articles.single;
    expect(article.title, '八分之一癌症病例由感染引起');
    expect(article.link, 'https://www.solidot.org/story?sid=85507');
    expect(article.sourceKey, 'test');
    // 正文尾部那个空 `<p></p>` 不该留下一串空行
    expect(article.summary, '根据本周发表的一项研究，全世界八分之一癌症病例由感染引起。');
    expect(article.publishedAt!.toUtc(), DateTime.utc(2026, 9, 29, 15, 25, 25));
  });

  // -------------------------------------------------------------- 少数派
  // 真实报文：description 里是**转义过的** HTML，结尾挂一句指向自己的「查看全文」
  const sspai = '''
<rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><channel><title>少数派</title><item><title>社区速递 160 | 水月雨首款游戏耳机</title><link>https://sspai.com/post/115153</link><description>除了首页时间流和侧栏的精选展位，还有很多内容无法得到有效曝光。&lt;a href=&#34;https://sspai.com/post/115153&#34; target=&#34;_blank&#34;&gt;查看全文&lt;/a&gt;</description><author>Matrix机器人</author><pubDate>Tue, 29 Sep 2026 17:03:00 +0800</pubDate></item></channel></rss>
''';

  test('转义 HTML 的源：标签洗掉，指向自己的「查看全文」也剥掉', () {
    final article = parseFeedXml(sspai, feed: feed).single;

    expect(article.title, '社区速递 160 | 水月雨首款游戏耳机');
    expect(
      article.summary,
      '除了首页时间流和侧栏的精选展位，还有很多内容无法得到有效曝光。',
      reason: '「查看全文」是源的排版习惯，不该出现在摘要里',
    );
    expect(article.summary, isNot(contains('&lt;')));
    expect(article.summary, isNot(contains('href')));
    expect(article.publishedAt!.toUtc(), DateTime.utc(2026, 9, 29, 9, 3));
  });

  // -------------------------------------------------------------- IT之家
  // 真实报文：description 里塞着带 `data-*` 的 HTML，第一张图是**京东商品卡**
  const ithome = '''
<rss version="2.0">
<channel>
<title>IT之家</title>
<item>
<title>松下 Technics 首款磁流体头戴耳机 EAH-A1000 发布，国行 2599 元</title>
<link>https://www.ithome.com/0/863/291.htm</link>
<description>&lt;p data-vmark="a6bf"&gt;IT之家 9 月 30 日消息，松下旗下音频品牌 Technics 昨日发布了全新旗舰无线头戴耳机。&lt;/p&gt;&lt;dir&gt;&lt;a href="https://u.jd.com/4rXSk8S"&gt;&lt;span class="card"&gt;&lt;img src="https://img14.360buyimg.com/pop/jfs/t1/523441/19/14789/97882/6abb8050F234624f7/00833e83e818bb9c.jpg" w="1000" h="1000"&gt;&lt;/span&gt;&lt;/a&gt;&lt;/dir&gt;</description>
<pubDate>Thu, 30 Sep 2026 08:00:00 +0800</pubDate>
</item>
</channel>
</rss>
''';

  test('推广卡片型的 description：正文干净，且**不拿商品图当缩略图**', () {
    final article = parseFeedXml(ithome, feed: feed).single;

    expect(article.title, '松下 Technics 首款磁流体头戴耳机 EAH-A1000 发布，国行 2599 元');
    expect(article.summary, startsWith('IT之家 9 月 30 日消息'));
    expect(article.summary, isNot(contains('data-vmark')));
    expect(article.summary, isNot(contains('京东')));
    expect(
      article.imageUrl,
      '',
      reason: '缩略图只从全文（content:encoded）里找，description 里那张往往是推广图',
    );
  });

  // -------------------------------------------------------------- 爱范儿
  // 真实报文：WordPress 那套，正文在 `<content:encoded>` 里，链上带 utm
  const ifanr = '''
<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
<channel>
<title>爱范儿</title>
<item>
<title>DeepSeek Harness 桌面版实测</title>
<link>https://www.ifanr.com/1682532?utm_source=rss&amp;utm_medium=rss&amp;utm_campaign=</link>
<content:encoded><![CDATA[<p>更像「个人助理」，还给你送钱。</p><p><img src="https://img.ifanr.com/cover.jpg" alt="封面"></p><p>第二段正文。</p>]]></content:encoded>
<pubDate>Tue, 29 Sep 2026 16:07:49 +0000</pubDate>
</item>
</channel>
</rss>
''';

  test('全文里的源：正文按段落洗成文本，封面图取到，utm 参数去掉', () {
    final article = parseFeedXml(ifanr, feed: feed).single;

    expect(article.link, 'https://www.ifanr.com/1682532', reason: '跟踪参数要去掉');
    expect(article.summary, '更像「个人助理」，还给你送钱。\n\n第二段正文。');
    expect(article.imageUrl, 'https://img.ifanr.com/cover.jpg');
    // +0000 就是 UTC
    expect(article.publishedAt!.toUtc(), DateTime.utc(2026, 9, 29, 16, 7, 49));
  });

  test('同一个链接带不同跟踪参数 = 同一条（去重靠归一化后的地址）', () {
    const messy = '''
<rss version="2.0"><channel><title>x</title>
<item><title>一</title><link>https://a.test/p/1?utm_source=rss</link></item>
<item><title>一</title><link>https://a.test/p/1</link></item>
</channel></rss>
''';

    expect(parseFeedXml(messy, feed: feed), hasLength(1));
  });

  test('有 guid 就用 guid（同一个链接改了标题也算两条，源自己说了算）', () {
    const guidFeed = '''
<rss version="2.0"><channel><title>x</title>
<item><title>一</title><link>https://a.test/p/1</link><guid isPermaLink="false">post-91</guid></item>
</channel></rss>
''';

    expect(parseFeedXml(guidFeed, feed: feed).single.id, 'post-91');
  });

  // ------------------------------------------------------------------ Atom
  const atom = '''
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>Example</title>
  <entry>
    <title>Atom 的条目</title>
    <link rel="edit" href="https://example.test/edit/1"/>
    <link rel="alternate" href="https://example.test/posts/1"/>
    <id>tag:example.test,2026:1</id>
    <published>2026-09-29T23:25:25+08:00</published>
    <summary type="html">&lt;p&gt;摘要里有 &amp;lt;转义&amp;gt; 和 &amp;#39;引号&amp;#39;&lt;/p&gt;</summary>
    <media:content url="https://cdn.test/atom.jpg" type="image/jpeg"/>
  </entry>
</feed>
''';

  test('Atom：rel=alternate 才是给人看的那篇，media:content 当缩略图', () {
    final article = parseFeedXml(atom, feed: feed).single;

    expect(article.link, 'https://example.test/posts/1');
    expect(article.id, 'tag:example.test,2026:1');
    expect(article.imageUrl, 'https://cdn.test/atom.jpg');
    expect(article.publishedAt!.toUtc(), DateTime.utc(2026, 9, 29, 15, 25, 25));
    // 两层转义都要还原：`&amp;lt;` → `<`、`&amp;#39;` → `'`
    expect(article.summary, "摘要里有 <转义> 和 '引号'");
  });

  // ------------------------------------------------------- 时间 / 异常报文
  test('时区不同的三种写法都算对同一个时刻', () {
    String feedWith(String pubDate) =>
        '''
<rss version="2.0"><channel><title>x</title>
<item><title>一</title><link>https://a.test/p/1</link><pubDate>$pubDate</pubDate></item>
</channel></rss>
''';

    expect(
      parseFeedXml(
        feedWith('Tue, 29 Sep 2026 23:25:25 +0800'),
        feed: feed,
      ).single.publishedAt!.toUtc(),
      DateTime.utc(2026, 9, 29, 15, 25, 25),
    );
    expect(
      parseFeedXml(
        feedWith('Tue, 29 Sep 2026 15:25:25 GMT'),
        feed: feed,
      ).single.publishedAt!.toUtc(),
      DateTime.utc(2026, 9, 29, 15, 25, 25),
    );
    // 裸时间（没写时区）按北京时间算 —— 不能交给 DateTime.parse，
    // 那会按设备时区理解，同一个源在不同机器上变成两个时间
    expect(
      parseFeedXml(
        feedWith('2026-09-29 23:25:25'),
        feed: feed,
      ).single.publishedAt!.toUtc(),
      DateTime.utc(2026, 9, 29, 15, 25, 25),
    );
  });

  test('时间认不出来就留空（宁可不显示，也不要显示一个错的时间）', () {
    const weird = '''
<rss version="2.0"><channel><title>x</title>
<item><title>一</title><link>https://a.test/p/1</link><pubDate>刚刚</pubDate></item>
</channel></rss>
''';

    expect(parseFeedXml(weird, feed: feed).single.publishedAt, isNull);
  });

  test('无标题的条目丢掉（列表画不出来）', () {
    const noTitle = '''
<rss version="2.0"><channel><title>x</title>
<item><link>https://a.test/p/1</link></item>
<item><title>有的</title><link>https://a.test/p/2</link></item>
</channel></rss>
''';

    final articles = parseFeedXml(noTitle, feed: feed);
    expect(articles.map((a) => a.title), <String>['有的']);
  });

  test('WAF 拦截页（HTTP 200 但返回 HTML）解析出空列表，而不是抛异常', () {
    // 36氪 现在就是这样：状态码 200，内容是「正在进行安全检测...」
    const waf = '''
<html><head><title>安全检测</title></head>
<body><p>为保障您的访问安全，系统正在检测当前网络环境</p></body></html>
''';

    expect(parseFeedXml(waf, feed: feed), isEmpty);
    expect(parseFeedXml('', feed: feed), isEmpty);
    expect(parseFeedXml('{"code":0}', feed: feed), isEmpty);
  });

  test('摘要超长会截断（缓存体积 + 只给摘要不给全文）', () {
    final long = '<p>${'字' * 20}</p>' * 200;
    const head =
        '<rss version="2.0"><channel><title>x</title><item><title>长文</title>'
        '<link>https://a.test/long</link>';
    const tail = '</item></channel></rss>';
    final xml =
        '$head<content:encoded><![CDATA[$long]]></content:encoded>$tail';

    final article = parseFeedXml(xml, feed: feed).single;
    expect(article.summary.length, lessThanOrEqualTo(1001));
    expect(article.summary, endsWith('…'));
  });

  test('列表里那个源的名字走语言包（不是写死的中文）', () {
    for (final item in kNewsFeeds) {
      expect(item.nameKey, startsWith('news.source.'));
    }
  });

  // ------------------------------------------------------------ 文章页的封面
  //
  // 四个号里只有爱范儿的 feed 自带图，另外三个要回原文页取（`og:image`）。
  // 这几条报文也是实拍的：IT之家**没有 og:image**、图是懒加载的（`src` 是 1px
  // 占位，真地址在 `data-original`）；奇客 Solidot 是纯文字 + 一堆 `php.gif` 徽章，
  // 抓错了就会拿人家的按钮当封面。
  group('htmlMetaImage（原文页封面）', () {
    test('og:image 优先，协议相对的补成 https', () {
      const html =
          '<head><meta property="og:image" content="//cdn.test/a.jpg">'
          '<img src="/body.png"></head>';
      expect(
        htmlMetaImage(html, baseUrl: 'https://a.test/post/1'),
        'https://cdn.test/a.jpg',
      );
    });

    test('没有 og:image 就看正文第一张图，相对地址按文章地址解析', () {
      const html =
          '<body><p>正文</p><img src="/upload/b.png"><img src="/c.png"></body>';
      expect(
        htmlMetaImage(html, baseUrl: 'https://a.test/post/1'),
        'https://a.test/upload/b.png',
      );
    });

    test('懒加载的图认 data-original（IT之家：src 是 1px 占位）', () {
      // 实拍报文，`title` 一类属性略掉了
      const html =
          '<body><div class="post_content">'
          '<img src="//img.ithome.com/images/v2/t.png" w="1440" h="810" '
          'class="lazy" data-original="https://img.ithome.com/newsuploadfiles/2026/9/x.jpg">'
          '</div></body>';
      expect(
        htmlMetaImage(html, baseUrl: 'https://www.ithome.com/1/008/551.htm'),
        'https://img.ithome.com/newsuploadfiles/2026/9/x.jpg',
        reason: '只看 src 会拿到那张 1px 占位图',
      );
    });

    test('站点自己的装饰图不算配图（Solidot：徽章、板块图标、顶部 icon）', () {
      // 实拍报文：整页就这几张图，一张都不是文章配图
      const html =
          '<body>'
          '<img width="59" height="57" src="https://icon.solidot.org/images/topics/topic Medicine.png?123">'
          '<img style="height:16px;" src="https://icon.solidot.org/images/a7c7.png">'
          '<img border="0" src="https://icon.solidot.org/images/btn/php.gif">'
          '<img src="//icon.zhiding.cn/beian/icon.png">'
          '</body>';
      expect(
        htmlMetaImage(html, baseUrl: 'https://www.solidot.org/story?sid=85507'),
        '',
        reason: '宁可画纯文字的卡，也不要把人家的按钮当封面',
      );
    });

    test('twitter:image 也能当备用，data: 内联图一律不要', () {
      expect(
        htmlMetaImage(
          '<meta name="twitter:image" content="https://cdn.test/tw.png">',
        ),
        'https://cdn.test/tw.png',
      );
      expect(htmlMetaImage('<img src="data:image/png;base64,AAA">'), '');
      expect(htmlMetaImage('<!DOCTYPE html><html></html>'), '');
    });
  });
}
