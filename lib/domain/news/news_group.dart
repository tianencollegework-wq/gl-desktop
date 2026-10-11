import 'news_article.dart';

/// 一个「媒体号」这一轮拉到的东西（用户 2026-09-30 给的公众号截图里，
/// 是**一张卡一个号**：卡头是号的名字与头像，下面是它最近几篇）。
///
/// 上一版是一条条平铺的信息流，用户看完说要改成这个样子 —— 按号成卡之后，
/// 「全是 IT之家」那个问题也顺带没了（每个号各占一张卡）。
class NewsFeedGroup {
  const NewsFeedGroup({required this.sourceKey, required this.articles});

  /// 来源 key（`domain/news/news_feed.dart` 里那几个）
  final String sourceKey;

  /// 这个号的文章，**按发布时间倒序**（没时间的排最后）
  final List<NewsArticle> articles;

  bool get isEmpty => articles.isEmpty;

  /// 最新那篇的时间 —— 卡头右上角那个「14小时前」用它
  DateTime? get newest => articles.isEmpty ? null : articles.first.publishedAt;

  /// 这个号有没有没看过的（卡头头像上那个小红点）
  bool get hasUnread => articles.any((article) => !article.read);
}

/// 按来源分组。
///
/// 卡片顺序：**号里最新那篇越新，这张卡越靠前**（公众号也是这个排法）；
/// 拿不到时间的号排最后。组内保持传入的顺序（`NewsRepository` 出来时已经是
/// 组内时间倒序）。
List<NewsFeedGroup> groupBySource(List<NewsArticle> articles) {
  final buckets = <String, List<NewsArticle>>{};
  for (final article in articles) {
    buckets.putIfAbsent(article.sourceKey, () => <NewsArticle>[]).add(article);
  }
  final groups = buckets.entries
      .map(
        (entry) => NewsFeedGroup(sourceKey: entry.key, articles: entry.value),
      )
      .toList();
  groups.sort((a, b) {
    final left = a.newest;
    final right = b.newest;
    if (left != null && right != null) {
      final byTime = right.compareTo(left);
      if (byTime != 0) return byTime;
    } else if (left != null || right != null) {
      return left != null ? -1 : 1;
    }
    // 同一时刻（或都没时间）：按配置顺序，保证稳定
    return a.sourceKey.compareTo(b.sourceKey);
  });
  return groups;
}
