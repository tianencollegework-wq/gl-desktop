import 'news_feed.dart';

/// 一条资讯。字段全是**从 RSS 里洗出来的纯文本**（HTML 标签在解析阶段就去掉了，
/// 见 `feed_parser.dart`）——详情页不做富文本渲染，也就不需要 `flutter_html` 这类
/// 新依赖，顺带避开「整篇转载」的版权问题：这里只留摘要 + 缩略图，
/// 想看全文点「阅读原文」去原站。
class NewsArticle {
  const NewsArticle({
    required this.id,
    required this.title,
    required this.link,
    required this.sourceKey,
    required this.summary,
    this.imageUrl = '',
    this.publishedAt,
    this.read = false,
  });

  /// 稳定标识：有 `<guid>` / Atom `<id>` 就用它，否则用归一化后的链接
  /// （把 `utm_*` 那串跟踪参数、`#comments` 去掉，同一条新闻才不会因为
  /// 两次抓取的参数不同而算成两条）
  final String id;

  final String title;

  /// 原文地址（「阅读原文」用它）
  final String link;

  /// 来源（[NewsFeed.key]）；显示名在渲染时查语言包
  final String sourceKey;

  /// 摘要纯文本（可能为空 —— 有些源的 `description` 就是一句「查看全文」）
  final String summary;

  /// 缩略图（可能为空）。优先 `media:content` / `enclosure`，其次正文里第一张图
  final String imageUrl;

  /// 发布时间。解析不出来就是 null（RSS 的日期格式五花八门，宁缺勿错）
  final DateTime? publishedAt;

  /// 点进详情的那一刻会调用它，列表里那些「未读」小圆点据此消失
  final bool read;

  NewsArticle copyWith({bool? read}) => NewsArticle(
    id: id,
    title: title,
    link: link,
    sourceKey: sourceKey,
    summary: summary,
    imageUrl: imageUrl,
    publishedAt: publishedAt,
    read: read ?? this.read,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'title': title,
    'link': link,
    'source': sourceKey,
    'summary': summary,
    if (imageUrl.isNotEmpty) 'image': imageUrl,
    if (publishedAt != null) 'published': publishedAt!.toIso8601String(),
  };

  /// 宽松解析：缓存是**上一版 App 写的**，字段缺了/类型不对都不能让整页崩掉
  static NewsArticle? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString() ?? '';
    final link = raw['link']?.toString() ?? '';
    final title = raw['title']?.toString() ?? '';
    if (title.isEmpty || (id.isEmpty && link.isEmpty)) return null;
    final published = DateTime.tryParse(raw['published']?.toString() ?? '');
    return NewsArticle(
      id: id.isEmpty ? link : id,
      title: title,
      link: link,
      sourceKey: raw['source']?.toString() ?? '',
      summary: raw['summary']?.toString() ?? '',
      imageUrl: raw['image']?.toString() ?? '',
      publishedAt: published,
    );
  }
}

/// 一次抓取的结果。
///
/// [failedFeeds] / [fromCache] 都是**给日志和用例看的**：用户 2026-09-30 明确
/// 不要界面上出现「这几个来源这次没更新」这种话，所以列表页不再把它们拿出来渲染。
class NewsFetchResult {
  const NewsFetchResult({
    required this.articles,
    this.failedFeeds = const <String>[],
    this.fromCache = false,
  });

  final List<NewsArticle> articles;

  /// 这次没拉到的源（空 = 全部成功）。**全部失败**时上层会抛错，
  /// 只有「部分成功」才带着它回来。
  final List<String> failedFeeds;

  /// true = 这份数据是网络全挂时从磁盘缓存里回读的（界面照样画，只是不再解释）
  final bool fromCache;

  bool get isEmpty => articles.isEmpty;
}
