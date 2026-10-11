/// 资讯频道（「发现」里那一栏）的订阅源定义。
///
/// 用户 2026-09-29：「想做一个微信公众号一样的功能，但我懒得自己发文章，
/// 有没有办法自动获取到新闻资讯然后显示出来」。方案（用户选定）：
/// **纯客户端**，手机自己去拉公开 RSS —— 服务端一个字不动。
///
/// 几条写在这里免得以后被当成 bug 改掉的事：
///
/// * **源写死在客户端**：所以换源要发版。要「换源不发版」「新文章能推送」
///   就得走服务端聚合（客户端只读自家接口），那是另一轮的事。
/// * **只用公开 RSS，不接任何要 key 的商业聚合 API**：APK 里藏不住 key，
///   一旦漏出去就是一个别人拿去刷的账号。公开 RSS 没有这个问题。
/// * **源名是第三方品牌名**，所以名字走语言包（`news.source.*`）——
///   和 App 里其它可翻译文案一套规矩：中文包写 `IT之家`、英文包写 `ITHome`。
/// * **只放中国大陆能直连的中文源**，而且**每一个都实测过**（2026-09-30 又扩了
///   一批，见下面「试过但没放」）。海外源（BBC/路透那类 RSS 很规整）国内设备
///   到不了，也刻意不放。
///
/// 试过但**没放**的（都是实测结果，别再试一遍）：
///
/// | 源 | 为什么不放 |
/// | --- | --- |
/// | 36氪 `36kr.com/feed` | HTTP 200 但返回的是 WAF 拦截页（「正在进行安全检测」），解析出 0 条 |
/// | 虎嗅 `huxiu.com/rss/0.xml` | 直接超时 |
/// | 品玩 `pingwest.com/feed` / 机器之心 `jiqizhixin.com/rss` | 200 但只有 1~3KB，解析出 0 条 |
/// | 果壳 `guokr.com/rss/` / 澎湃 `thepaper.cn/rss.xml` | 404（RSS 早就停了） |
/// | 数字尾巴 `dgtle.com/rss` | 403 |
/// | 新浪科技 `rss.sina.com.cn/tech/rollnews.xml` | 能拉，但最近一条是 **2018 年**的，早就不更新了 |
/// | 中关村在线 `rss.zol.com.cn/news.xml` | 能拉，但是 **GBK** 编码（标题全是乱码） |
/// | 雷锋网 `leiphone.com/feed` / 开源中国 `oschina.net/news/rss` | 能拉，但一个 330KB、一个把推广/招募贴在新闻流里 |
/// | V2EX `v2ex.com/index.xml` | 是论坛帖子，不是资讯 |
///
/// 单个源挂掉不影响别的源：抓取是并发的、各自 try/catch，
/// 失败的源只会在列表底部留一句提示（见 `NewsListPage`）。
library;

class NewsFeed {
  const NewsFeed({
    required this.key,
    required this.nameKey,
    required this.url,
    required this.home,
    this.pageCovers = true,
  });

  /// 稳定标识：进缓存、去重、日志都用它（**不要改**，改了等于缓存全部失效）
  final String key;

  /// 显示名的语言包 key
  final String nameKey;

  /// RSS / Atom 地址
  final String url;

  /// 站点首页：详情页「阅读原文」在拿不到文章地址时兜底
  final String home;

  /// 允许去**原文页**抓封面吗（`og:image` / 正文第一张图）。
  ///
  /// 默认允许 —— 大多数源的 feed 里一张图都没有，不补的话卡片全是纯文字。
  /// 但有的站把 `og:image` 写成**全站同一张图**（site123 搭的站就是），
  /// 硬抓的结果是同一个号的每篇文章都贴着同一张头图，看着像坏了；
  /// 这种源就关掉，老实画纯标题卡（`false`）。
  final bool pageCovers;
}

/// 十一个源。
///
/// **顺序就是轮转混排的取用顺序**（越靠前越优先），也是「条数上限 [120] 用完时
/// 谁先被截掉」的顺序 —— 所以大致按信息密度排。
///
/// 注意：**号卡的前后顺序不在这张表上**，是按「号里最新那篇的时间」排的
/// （见 `groupBySource`）—— 半小时不更新的号自然会沉下去，跟公众号一样。
const List<NewsFeed> kNewsFeeds = <NewsFeed>[
  NewsFeed(
    key: 'ithome',
    nameKey: 'news.source.ithome',
    url: 'https://www.ithome.com/rss/',
    home: 'https://www.ithome.com/',
  ),
  NewsFeed(
    key: 'sspai',
    nameKey: 'news.source.sspai',
    url: 'https://sspai.com/feed',
    home: 'https://sspai.com/',
  ),
  NewsFeed(
    key: 'ifanr',
    nameKey: 'news.source.ifanr',
    url: 'https://www.ifanr.com/feed',
    home: 'https://www.ifanr.com/',
  ),
  NewsFeed(
    key: 'geekpark',
    nameKey: 'news.source.geekpark',
    url: 'https://www.geekpark.net/rss',
    home: 'https://www.geekpark.net/',
  ),
  NewsFeed(
    key: 'tmtpost',
    nameKey: 'news.source.tmtpost',
    url: 'https://www.tmtpost.com/rss.xml',
    home: 'https://www.tmtpost.com/',
  ),
  NewsFeed(
    key: 'jiemian',
    nameKey: 'news.source.jiemian',
    url: 'https://a.jiemian.com/index.php?m=article&a=rss',
    home: 'https://www.jiemian.com/',
  ),
  NewsFeed(
    key: 'solidot',
    nameKey: 'news.source.solidot',
    url: 'https://www.solidot.org/index.rss',
    home: 'https://www.solidot.org/',
  ),
  NewsFeed(
    key: 'cnbeta',
    nameKey: 'news.source.cnbeta',
    url: 'https://www.cnbeta.com.tw/backend.php',
    home: 'https://www.cnbeta.com.tw/',
  ),
  NewsFeed(
    key: 'qbitai',
    nameKey: 'news.source.qbitai',
    url: 'https://www.qbitai.com/feed',
    home: 'https://www.qbitai.com/',
  ),
  NewsFeed(
    key: 'infoq',
    nameKey: 'news.source.infoq',
    url: 'https://www.infoq.cn/feed',
    home: 'https://www.infoq.cn/',
  ),
  NewsFeed(
    key: 'appinn',
    nameKey: 'news.source.appinn',
    url: 'https://www.appinn.com/feed/',
    home: 'https://www.appinn.com/',
  ),
  // 用户自己的：协会通知网（2026-09-30 给的地址）。放在最后 —— 它是**协会公告**
  // 不是媒体，轮转取用时不跟新闻抢前面的位置（号卡顺序本来也只按「号里最新那篇」
  // 排，所以更新了自然会浮上去）。两个特点记在这里：feed 里 `description` 全空
  // （所以是纯标题卡，详情页那句「这条来源没给摘要」会说清楚），
  // 以及 `pageCovers: false`（site123 把 og:image 写成了全站同一张头图）。
  NewsFeed(
    key: 'xinghua',
    nameKey: 'news.source.xinghua',
    url: 'https://691f6a1b5b559.site123.me/rss.xml',
    home: 'https://691f6a1b5b559.site123.me/',
    pageCovers: false,
  ),
];

/// 按 key 取源（缓存里的文章要回填源名、排版顺序）
NewsFeed? newsFeedByKey(String key) {
  for (final feed in kNewsFeeds) {
    if (feed.key == key) return feed;
  }
  return null;
}
