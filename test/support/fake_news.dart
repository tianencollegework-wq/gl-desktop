import 'dart:async';

import 'package:gracelinkim/core/net/api_exception.dart';
import 'package:gracelinkim/domain/news/news_article.dart';
import 'package:gracelinkim/domain/news/news_repository.dart';

/// 造一条资讯（用例里只需要关心要看的那几个字段）
NewsArticle fakeArticle({
  required String id,
  required String title,
  String source = 'ithome',
  String summary = '这里是摘要。',
  String image = '',
  DateTime? published,
  String? link,
}) => NewsArticle(
  id: id,
  title: title,
  link: link ?? 'https://www.ithome.com/0/863/$id.htm',
  sourceKey: source,
  summary: summary,
  imageUrl: image,
  publishedAt: published ?? DateTime(2026, 9, 29, 20),
);

/// 只换掉仓库的假实现：页面拿到的 `NewsFetchResult` 语义与真仓库一致。
///
/// 抓取/缓存/已读那套真逻辑由 `test/news/news_repository_test.dart` 盯着，
/// 这里只负责「页面要什么就给什么」，所以**不碰网络**。
class FakeNewsRepository extends NewsRepository {
  FakeNewsRepository(
    this.articles, {
    this.failedFeeds = const <String>[],
    this.throwOnFetch = false,
    this.cached = const <NewsArticle>[],
    this.cachedAtMillis,
    this.fetchDelay,
  });

  List<NewsArticle> articles;
  List<String> failedFeeds;
  bool throwOnFetch;
  List<NewsArticle> cached;

  /// 「上次抓到」的时间戳。默认就是**现在**（刚抓过 = 不该自动刷新）。
  /// 要验「过期就自己刷」时塞一个半小时以前的进去。
  int? cachedAtMillis;

  /// 被标记已读的 id（验「进详情页就标已读」）
  final List<String> marked = <String>[];

  /// 抓过几次（搜索是筛本机那批，不该让它变多）
  int fetchCount = 0;

  /// 封面：真实现要去原文页拉 `og:image`（要联网），这里直接给一张现成的。
  /// 只在 `cachedCovers()` 里给——就像「本机已经补好图了」那种状态。
  Map<String, String> covers = <String, String>{};

  /// 真的去「补图」时记下的 id（用来确认：列表只给**露出来的那几篇**补，
  /// 不是一进页面就把整批都拉一遍）
  final List<String> coverRequests = <String>[];

  @override
  Map<String, String> cachedCovers() => covers;

  @override
  Future<String> resolveCover(NewsArticle article) async {
    coverRequests.add(article.id);
    return covers[article.id] ?? '';
  }

  /// 让抓取慢一点：验「刷新期间页面画的是什么」时要赶在那个窗口里看一眼
  Duration? fetchDelay;

  /// 一次抓取**分几块**吐（每一块 = 那会儿新回来的那些源）。
  ///
  /// 不给就按 [articles] 一次吐完（大多数用例只关心最后画成什么样）；
  /// 给了就是真仓库那种分层的样子：第 i 块 = 前面几块拼起来。
  List<List<NewsArticle>>? batches;

  /// 每一块**之前**的闸门：`gates[i]` 没放开，第 i 块就一直不吐。
  /// 用它把后面的块卡住，页面就有时间停在「先回来的那几条」上（见 [open]）。
  final Map<int, Completer<void>> gates = <int, Completer<void>>{};

  /// 放开第 [index] 块
  void open(int index) => gates.remove(index)?.complete();

  /// 抓一遍。真仓库也是这条：`fetch()` 就是 `fetchStream().last`。
  ///
  /// * [throwOnFetch] → 整条流吐一个错（页面上是「加载失败 + 重试」）；
  /// * [fetchDelay] → 第一块之前先拖一会儿（验「刷新期间画的是旧内容」）；
  /// * [gates] → 卡住某一块（验「先回来的先铺，不等最慢的」）。
  ///
  /// 计数放在这儿（不在下面的 `async*` 里）：起一轮就算一次，不等流真的开始跑。
  @override
  Stream<NewsFetchResult> fetchStream() {
    fetchCount += 1;
    return _frames();
  }

  Stream<NewsFetchResult> _frames() async* {
    if (fetchDelay != null) await Future<void>.delayed(fetchDelay!);
    if (throwOnFetch) {
      throw const NetworkUnavailableException('资讯加载失败，请检查网络后重试');
    }
    final frames = batches ?? <List<NewsArticle>>[articles];
    final arrived = <NewsArticle>[];
    for (var index = 0; index < frames.length; index++) {
      final gate = gates[index];
      if (gate != null) await gate.future;
      arrived.addAll(frames[index]);
      final last = index == frames.length - 1;
      yield NewsFetchResult(
        articles: <NewsArticle>[...arrived],
        // 失败的源是整轮跑完才知道的，所以只挂在最后一块上
        failedFeeds: last ? failedFeeds : const <String>[],
      );
    }
  }

  @override
  List<NewsArticle> cachedArticles() =>
      cached.isEmpty ? const <NewsArticle>[] : cached;

  @override
  int cachedAt() => cachedAtMillis ?? DateTime.now().millisecondsSinceEpoch;

  @override
  Future<bool> markRead(String id) async {
    if (id.isEmpty || marked.contains(id)) return false;
    marked.add(id);
    return true;
  }
}
