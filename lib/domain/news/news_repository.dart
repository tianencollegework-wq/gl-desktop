import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/net/api_exception.dart';
import '../../core/store/credential_store.dart';
import 'feed_parser.dart';
import 'news_article.dart';
import 'news_feed.dart';

/// 资讯频道的数据来源：**手机自己去拉那几个公开 RSS**（用户 2026-09-29 定的方案）。
///
/// 服务端一个字不动，所以有几件事只有在客户端才兜得住，这里都做了：
///
/// * **单个源挂掉不影响别的源**：源是并发的、各自 try/catch，失败的只进
///   [NewsFetchResult.failedFeeds]（界面上**不提示**，只进日志），不抛给页面；
/// * **网络全挂时回读上次的缓存**（[NewsFetchResult.fromCache]）：断网还能看
///   已经拉到过的，比一句「加载失败」有用；
/// * **只看公开源**：不接任何要 key 的商业接口 —— APK 里藏不住 key。
///
/// 缓存和「已读」都放在本机 SharedPreferences 里（不是数据库）：
/// 这份数据是**公开内容、不属于任何账号**，所以换账号时刻意**不清**
/// （清了只会让用户切回来时白等一次重新拉取）。量也不大：最多
/// [maxArticles] 条、摘要截到 1000 字，一份 JSON 一百多 KB。
class NewsRepository {
  NewsRepository({Dio? dio, this.store}) : _dio = dio ?? _buildDio();

  /// 缓存里的文章上限（每次抓取后裁到这个数）
  static const int maxArticles = 120;

  /// 「已读」id 上限：只留最近这些条，免得键值无限长
  static const int maxReadIds = 300;

  static const String keyCache = 'newsCache';
  static const String keyRead = 'newsReadIds';
  static const String keyCovers = 'newsCovers';

  /// 封面缓存上限（id → 图片地址；空串表示「查过了，这页真没有」）
  static const int maxCovers = 200;

  /// 存储**可注入**：用例拿它塞一份假的 SharedPreferences
  final CredentialStore? store;

  final Dio _dio;

  CredentialStore get _prefs => store ?? CredentialStore.instance;

  /// 独立于聊天客户端的 Dio：这是**第三方**站点，不该带 `Authorization`
  /// （后端那套请求头塞给 IT之家只会让人家觉得被扫），也不要它的 baseUrl。
  static Dio _buildDio() {
    final dio = Dio();
    dio.options
      ..connectTimeout = const Duration(seconds: 12)
      ..receiveTimeout = const Duration(seconds: 12)
      // 自己判状态码，并**原样拿字符串**：源出问题时返回的常是 HTML 错误页，
      // 让 Dio 的 JSON transformer 去解析会连状态码一起吞掉
      ..responseType = ResponseType.plain
      ..headers = const <String, String>{
        'Accept':
            'application/rss+xml, application/atom+xml, '
            'application/xml, text/xml;q=0.9, */*;q=0.8',
        'User-Agent': 'GracelinkIM/1.0 (+news)',
      }
      // 这条必须放在最后：箭头函数会把下面的 `..` 当成函数体吃掉
      ..validateStatus = (code) => code != null && code < 600;
    return dio;
  }

  /// 抓一遍所有源（等全部回来）。失败：一个源都没成功且没有缓存 → 抛 [ApiException]。
  ///
  /// 就是 [fetchStream] 的「最后那一份」（[Stream.last]）；页面走的是流式那条（见下）。
  Future<NewsFetchResult> fetch() => fetchStream().last;

  /// 抓一遍所有源，**一块一块地吐**（用户 2026-09-30：「哪个源先回来先铺哪几条，
  /// 不再等最慢的那个」）。
  ///
  /// 老做法是 `Future.wait` 等 12 个源全回来才吐一份 —— 最慢的那个源（超时 12 秒）
  /// 把整页拖在那儿转圈，而它前面的 11 个源早就拿到了。现在：
  ///
  /// * **谁先回来谁先吐**：每回来一个源就吐一份「到目前为止的合并结果」。合并规则
  ///   不变（按源轮转 + 截断，见 [_merge]），所以已经铺出去的那几条不会被后面的源
  ///   挤走位置，也不会重复；
  /// * **还没回来的源先让缓存顶着**（见 [_frame]）：不然第一批到达时，页面会从
  ///   「缓存那 100 多条」突然缩成「刚回来的这个源的 3 条」，看着像内容被删了；
  /// * 一个源都没拉到、但本机有缓存 → 吐缓存那份（[NewsFetchResult.fromCache] = true）；
  /// * 全回来之后再把最后那份**落盘**并吐一次（这一份是权威的）；
  /// * 一个源都没拉到且没有缓存 → `addError`（页面画「加载失败 + 重试」）。
  ///
  /// 注意：中间态那几份**不写盘**（只写最后一份）—— 磁盘上始终是一份完整的快照，
  /// 免得一个只回了 3 条的源把缓存覆盖成一页残废的列表。
  Stream<NewsFetchResult> fetchStream() {
    final controller = StreamController<NewsFetchResult>();
    unawaited(_runFetch(controller));
    return controller.stream;
  }

  Future<void> _runFetch(StreamController<NewsFetchResult> controller) async {
    final arrived = <NewsArticle>[];

    /// 这一轮**已经用新内容回答过**的源（缓存顶位时按它排除）
    final answered = <String>{};
    final failed = <String>[];
    var remaining = kNewsFeeds.length;

    Future<void> one(NewsFeed feed) async {
      // `_fetchFeed` 内部把异常都吞了 → 这里一定回得来（会往下减）
      final got = await _fetchFeed(feed) ?? const <NewsArticle>[];
      remaining -= 1;
      // 解析出 0 条也算失败：源返回 WAF 拦截页（36氪 就是这样）时
      // HTTP 是 200，只看状态码会以为「这个源今天没内容」
      if (got.isEmpty) {
        failed.add(feed.key);
      } else {
        arrived.addAll(got);
        answered.add(feed.key);
      }
      if (controller.isClosed) return;
      if (remaining == 0) {
        await _finish(controller, arrived, answered, failed);
        return;
      }
      // 中间态：手上有什么先铺什么（这就是「哪个源先回来先铺哪几条」）。
      // **空手回来的源不吐那一帧**：它没让内容变多，吐出去只是一份一模一样的
      // 片 —— 12 个源里十个超时的话，那十次失败会各吐一次同样的一帧。
      if (got.isNotEmpty) {
        controller.add(_frame(arrived, answered, failed, fromCache: false));
      }
    }

    await Future.wait(kNewsFeeds.map(one));
    // 一个源都没配（或在上面那次并发里全被 cancel 掉了）：这里收尾，别把流挂着
    if (!controller.isClosed) {
      await _finish(controller, arrived, answered, failed);
    }
  }

  /// 收尾：合排 + 落盘 + 吐权威的那一份（没内容就退缓存 / 报错）。
  ///
  /// 落盘的只有**这一轮真的拉到的**（[arrived]）—— 缓存顶上来的那几行不写回盘，
  /// 否则上一版留下的旧内容会一轮一轮地续命。
  Future<void> _finish(
    StreamController<NewsFetchResult> controller,
    List<NewsArticle> arrived,
    Set<String> answered,
    List<String> failed,
  ) async {
    if (controller.isClosed) return;
    final fresh = _merge(arrived);
    final frame = _frame(arrived, answered, failed, fromCache: fresh.isEmpty);
    if (frame.articles.isEmpty) {
      controller.addError(const NetworkUnavailableException('资讯加载失败，请检查网络后重试'));
      await controller.close();
      return;
    }
    if (fresh.isNotEmpty) {
      await _saveCache(fresh);
    } else {
      debugPrint('[资讯] 所有源都没拉到，回读本机缓存 ${frame.articles.length} 条');
    }
    controller.add(frame);
    await controller.close();
  }

  /// 一帧：**这一轮已经拉到的** + 还没回答的源**先拿缓存那几行顶着**。
  ///
  /// 为什么要有后半句：分层加载时第一帧往往只有一个源的几条。没有顶位的话，
  /// 页面会从「缓存里的 100 多条」突然缩成「3 条」，然后一条一条长回来 ——
  /// 看起来像是内容被删了。用缓存顶住，列表只会**变新/变多**，不会凭空变少。
  ///
  /// 判据是「这个源这一轮**有没有拿新内容回答**」：还没回来、或者回来了但是空的
  /// （超时、拦截页）都算，所以某个源今天挂了时，它昨天那几条还留在列表里。
  ///
  /// 已读状态在每一帧上都要贴（[_withReadState]）—— 不贴的话，流一路过小圆点
  /// 就会闪一下没了、最后那一帧才回来。
  NewsFetchResult _frame(
    List<NewsArticle> arrived,
    Set<String> answered,
    List<String> failed, {
    required bool fromCache,
  }) {
    // 顺序上 arrived 在前：同一篇（id 一样）以**这一轮拉到的**为准
    final articles = <NewsArticle>[
      ...arrived,
      for (final article in cachedArticles())
        if (!answered.contains(article.sourceKey)) article,
    ];
    return NewsFetchResult(
      articles: _withReadState(_merge(articles)),
      failedFeeds: <String>[...failed],
      fromCache: fromCache,
    );
  }

  /// 拉一个源；任何异常都吞掉并返回 null（调用方把它记进 failedFeeds）
  Future<List<NewsArticle>?> _fetchFeed(NewsFeed feed) async {
    try {
      final response = await _dio.get<dynamic>(
        feed.url,
        options: Options(responseType: ResponseType.plain),
      );
      final body = response.data;
      final text = body is String ? body : '';
      if (text.isEmpty) {
        debugPrint('[资讯] ${feed.key} 返回空内容（HTTP ${response.statusCode}）');
        return null;
      }
      final parsed = parseFeedXml(text, feed: feed);
      if (parsed.isEmpty) {
        debugPrint('[资讯] ${feed.key} 解析出 0 条（多半不是 feed，是拦截页）');
      }
      return parsed;
    } on DioException catch (error) {
      debugPrint('[资讯] ${feed.key} 拉取失败：${error.type.name}');
      return null;
    } on Object catch (error) {
      debugPrint('[资讯] ${feed.key} 解析异常：$error');
      return null;
    }
  }

  /// 合并 + **按源轮转** + 截断。
  ///
  /// 为什么不排成一条纯时间倒序（用户 2026-09-30 提的：「建议混着排，不然容易全是
  /// IT之家」）：IT之家一天发几十条，纯按时间排时开头连着十几条都是它，少数派/
  /// 爱范儿会被压到看不见 —— 那不像一个资讯频道，像 IT之家的镜像。
  /// 所以的做法是：**每个源各自按时间倒序，源之间轮流取一条**。
  ///
  /// 代价是整条列表不再严格时间递减（第 2 条可能比第 1 条旧）。换来每个源轮着露脸，
  /// 而这个列表本来就是「随便看看」的形态，不是时间轴。
  ///
  /// 源之间的顺序按 [kNewsFeeds] 里配的顺序（不认识的源排最后），所以同样的内容
  /// 排出来的顺序每次一样，刷新时列表不会跳。
  List<NewsArticle> _merge(List<NewsArticle> articles) {
    final byId = <String, NewsArticle>{};
    for (final article in articles) {
      byId.putIfAbsent(article.id, () => article);
    }

    final buckets = <String, List<NewsArticle>>{};
    for (final article in byId.values) {
      buckets
          .putIfAbsent(article.sourceKey, () => <NewsArticle>[])
          .add(article);
    }
    for (final bucket in buckets.values) {
      bucket.sort(_newestFirst);
    }
    final order = buckets.keys.toList()
      ..sort((a, b) => _feedOrder(a).compareTo(_feedOrder(b)));

    final merged = <NewsArticle>[];
    final cursors = <String, int>{for (final key in order) key: 0};
    var progressed = true;
    while (progressed && merged.length < maxArticles) {
      progressed = false;
      for (final key in order) {
        final bucket = buckets[key]!;
        final cursor = cursors[key]!;
        if (cursor >= bucket.length) continue;
        cursors[key] = cursor + 1;
        merged.add(bucket[cursor]);
        progressed = true;
        if (merged.length >= maxArticles) break;
      }
    }
    return merged;
  }

  /// 源内排序：时间倒序，**没有时间的排最后**（不能因为拿不到时间就把它顶到最前）；
  /// 时间一样时按标题，保证顺序稳定。
  int _newestFirst(NewsArticle a, NewsArticle b) {
    final left = a.publishedAt;
    final right = b.publishedAt;
    if (left != null && right != null) {
      final byTime = right.compareTo(left);
      if (byTime != 0) return byTime;
    } else if (left != null || right != null) {
      return left != null ? -1 : 1;
    }
    return a.title.compareTo(b.title);
  }

  int _feedOrder(String key) {
    final index = kNewsFeeds.indexWhere((feed) => feed.key == key);
    // 不认识的源（缓存是上一版 App 写的）排到最后
    return index < 0 ? kNewsFeeds.length : index;
  }

  // ------------------------------------------------------------------ 缓存读写

  List<NewsArticle> cachedArticles() {
    final raw = _prefs.getJson(keyCache);
    if (raw == null) return const <NewsArticle>[];
    final items = raw['items'];
    if (items is! List) return const <NewsArticle>[];
    final articles = items
        .map(NewsArticle.fromJson)
        .whereType<NewsArticle>()
        .toList();
    return _withReadState(articles);
  }

  /// 上次抓取的时间（毫秒；没抓过是 0）。列表页拿它显示「更新于 …」。
  int cachedAt() {
    final raw = _prefs.getJson(keyCache);
    final value = raw?['fetchedAt'];
    return value is int ? value : 0;
  }

  Future<void> _saveCache(List<NewsArticle> articles) =>
      _prefs.setJson(keyCache, <String, dynamic>{
        'fetchedAt': DateTime.now().millisecondsSinceEpoch,
        'items': articles.map((article) => article.toJson()).toList(),
      });

  Set<String> readIds() {
    final raw = _prefs.getString(keyRead);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final decoded = json.decode(raw);
      if (decoded is! List) return <String>{};
      return decoded.map((id) => id.toString()).toSet();
    } on FormatException {
      return <String>{};
    }
  }

  /// 把已读状态贴到文章上（列表里那个小圆点）
  List<NewsArticle> _withReadState(List<NewsArticle> articles) {
    final read = readIds();
    if (read.isEmpty) return articles;
    return articles
        .map(
          (article) => read.contains(article.id)
              ? article.copyWith(read: true)
              : article,
        )
        .toList(growable: false);
  }

  // ------------------------------------------------------------------ 封面

  /// 已经解析过的封面（id → 图片地址）。空串是**有效值**：表示查过这页、它真没有图，
  /// 下次不用再拉一遍页面。
  Map<String, String> cachedCovers() {
    final raw = _prefs.getJson(keyCovers);
    if (raw == null) return <String, String>{};
    return <String, String>{
      for (final entry in raw.entries) entry.key: entry.value?.toString() ?? '',
    };
  }

  /// 取一篇原文的封面（`og:image`，没有就退到正文第一张图）。
  ///
  /// **只在 feed 自己没给图时才调**（见 `htmlMetaImage` 的注释：三个源一个图都不给），
  /// 而且结果会落盘 —— 一篇文章只拉一次页面。失败一律返回空串（不抛）：封面是锦上添花，
  /// 拉不到就画纯文字的那种卡。
  Future<String> resolveCover(NewsArticle article) async {
    if (article.link.isEmpty) return '';
    // 有的源**不允许**去原文页抓封面（`pageCovers: false`）：site123 搭的站把
    // `og:image` 写成全站同一张头图，抓回来就是「一个号的每篇文章都贴着同一张图」。
    // 这里直接返回空串，**不发请求也不落盘**（调用方会把空串记在内存里，不会反复问）。
    if (!(newsFeedByKey(article.sourceKey)?.pageCovers ?? true)) return '';
    final known = cachedCovers()[article.id];
    if (known != null) return known;
    try {
      final response = await _dio.get<dynamic>(
        article.link,
        options: Options(responseType: ResponseType.plain),
      );
      final html = response.data is String ? response.data as String : '';
      final image = htmlMetaImage(html, baseUrl: article.link);
      await _saveCover(article.id, image);
      return image;
    } on Object catch (error) {
      debugPrint('[媒体号] 取封面失败（${article.link}）：$error');
      // 失败**不落盘**：下次刷新时再试（网络问题不该被当成「这页没有图」）
      return '';
    }
  }

  Future<void> _saveCover(String id, String url) async {
    final covers = cachedCovers()..[id] = url;
    if (covers.length > maxCovers) {
      // JSON map 保持插入顺序，丢掉最早那批
      final keep = covers.keys.toList().sublist(covers.length - maxCovers);
      await _prefs.setJson(keyCovers, <String, dynamic>{
        for (final key in keep) key: covers[key]!,
      });
      return;
    }
    await _prefs.setJson(keyCovers, <String, dynamic>{...covers});
  }

  /// 标记已读（进详情页时调用）。返回值 = 状态有没有真的变（没变就不用刷界面）
  Future<bool> markRead(String id) async {
    if (id.isEmpty) return false;
    final read = readIds();
    if (read.contains(id)) return false;
    // 用列表保序（LinkedHashSet 的插入序），超出上限就丢最早的那批
    final oldestFirst = read.toList()..add(id);
    final trimmed = oldestFirst.length > maxReadIds
        ? oldestFirst.sublist(oldestFirst.length - maxReadIds)
        : oldestFirst;
    await _prefs.setString(keyRead, json.encode(trimmed));
    return true;
  }
}
