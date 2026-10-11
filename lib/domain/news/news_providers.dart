import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'news_article.dart';
import 'news_group.dart';
import 'news_repository.dart';

final newsRepositoryProvider = Provider<NewsRepository>(
  (ref) => NewsRepository(),
);

/// 列表页的状态：**抓到的那一份** + 每个号现在露几条。
///
/// 「露几条」是**按号**算的（公众号那张图里就是每张卡露出头几条，剩下的收在
/// 「余下N篇」后面）：上一版是全局一个 `visibleCount` 的平铺分页，现在一张卡
/// 一个计数，点哪张卡的「余下N篇」就展开哪张。
class NewsListState {
  const NewsListState({
    required this.result,
    this.expanded = const <String, int>{},
    this.updating = false,
  });

  /// 每个号先露几条（一张卡里：封面那张 + 两条小的 + 「余下N篇」）
  static const int defaultPerSource = 3;

  /// 点一次「余下N篇」再露几条
  static const int expandStep = 10;

  final NewsFetchResult result;

  /// sourceKey → 当前露出的条数（没记过的就是 [defaultPerSource]）
  final Map<String, int> expanded;

  /// 正在后台抓新的一份（顶上那条「正在更新…」）。
  ///
  /// **刻意不用 `AsyncLoading`**：自动刷新每半小时就会跑一次，切成 loading 会让
  /// 整页闪一下、已经点开的「余下N篇」也会缩回去（见 [NewsListController.refresh]）。
  final bool updating;

  List<NewsArticle> get all => result.articles;

  /// 按号分好组（卡片的顺序在这儿定）
  List<NewsFeedGroup> get groups => groupBySource(all);

  bool get fromCache => result.fromCache;

  /// 这个号现在露几条
  int visibleOf(String sourceKey) => expanded[sourceKey] ?? defaultPerSource;

  /// 这个号还有没有藏着没露的
  bool hasMoreOf(NewsFeedGroup group) =>
      group.articles.length > visibleOf(group.sourceKey);

  /// 还有几篇藏着（「余下N篇」上的数字）
  int hiddenOf(NewsFeedGroup group) {
    final hidden = group.articles.length - visibleOf(group.sourceKey);
    return hidden > 0 ? hidden : 0;
  }

  NewsListState copyWith({
    NewsFetchResult? result,
    Map<String, int>? expanded,
    bool? updating,
  }) => NewsListState(
    result: result ?? this.result,
    expanded: expanded ?? this.expanded,
    updating: updating ?? this.updating,
  );
}

/// 媒体号列表。
///
/// 抓取是**一块一块出画**的（用户 2026-09-30：「哪个源先回来先铺哪几条，
/// 不再等最慢的那个」）：
///
/// * [build] 只等**第一块** —— 第一块到手，页面就从骨架屏变成内容；剩下的源还在路上，
///   回来一块就往上补一块（见 [_onChunk]）；
/// * 本机缓存**不用等网络**（页面自己同步读一份先画着，见 `news_list_page.dart`）；
/// * 自动刷新是页面进来按一次 [refreshIfStale]、开着的时候每 [staleCheckInterval]
///   再问一次（用户 2026-09-30：「把下拉刷新功能去掉，就改成每半个小时自动刷新一次」）。
///   判据只看**上次真的抓到的时间**（`cachedAt`），所以抓失败也会一直算「该更新」，
///   下个检查点自己再试；
/// * [refresh]（自动刷新 / 失败重试）等的是**整轮**：调用方 `await` 完就是「刷完了」。
///
/// 刻意**不**用 `AsyncValue` 表示「正在刷新」（切成 `AsyncLoading` 会让整页闪一下、
/// 已经点开的「余下N篇」也会缩回去）：刷新期间页面画的一直是上一份内容，
/// 顶上转个小圈（见 [NewsListState.updating]）。
class NewsListController extends AsyncNotifier<NewsListState> {
  /// 数据超过这个岁数就算「该更新了」（用户要的「每半个小时自动刷新一次」）
  static const Duration autoRefreshInterval = Duration(minutes: 30);

  /// 页面开着时多久问一次「该更新了吗」。
  ///
  /// **故意比 [autoRefreshInterval] 密**：每次问只是比一下时间戳（不发请求），
  /// 所以问得勤一点，数据才不会比 30 分钟旧太多（最坏 30+5 分钟）。
  /// 反过来说，抓失败时也就变成了「每 5 分钟自己重试一次」。
  static const Duration staleCheckInterval = Duration(minutes: 5);

  /// 什么都不用等的时候的那一份空状态（首屏还没到手时用它顶位）
  static const NewsListState _emptyState = NewsListState(
    result: NewsFetchResult(articles: <NewsArticle>[]),
  );

  /// 手上这一轮的订阅。换一轮就把上一轮掐掉 —— 两条流同时往 `state` 上写，
  /// 页面上的列表会来回跳
  StreamSubscription<NewsFetchResult>? _sub;

  /// 首屏那一轮的**第一块**交给谁（`build` 在等它）。
  ///
  /// 刷新（[refresh]）那一路不用这个 —— 那时 `state` 已经有内容，每一块直接画。
  Completer<NewsListState>? _first;

  /// 攒到的最新一份（每一块都会覆盖它）
  NewsListState? _latest;

  /// 手上这一轮还在路上吗。
  ///
  /// 分层之后「还没抓完」不再等于 `state.isLoading`（第一块一到就不 loading 了，
  /// 但剩下的源还在跑），所以另记一个开关：[refreshIfStale] 靠它不叠第二轮
  /// （顺便也挡住「自动刷新把正在跑的那一轮掐掉」）。
  bool _pulling = false;

  @override
  Future<NewsListState> build() async {
    final repo = ref.watch(newsRepositoryProvider);
    // 整轮的那张「完事了」的票据这里不接：首屏不等它（要的就是「第一块到手就出画」），
    // 但没人接它的错就是「没人接的异常」，所以挂个空 handler 兜住 ——
    // 错已经交给 `_first` 了，`build` 会把它变成页面上的「加载失败 + 重试」
    unawaited(
      _subscribe(
        repo,
        handOffFirstChunk: true,
      ).onError((Object _, StackTrace _) {}),
    );
    ref.onDispose(_stop);
    // 这一等就是「不再等最慢的那个」：第一块一到就返回，页面从骨架屏变成内容
    await _first!.future;
    return _latest ?? _emptyState;
  }

  /// 起一轮抓取。返回的 future 在**整轮**结束时完成（[refresh] 的调用方在等它）；
  /// [build] 等的是另一件事 —— 第一块（`handOffFirstChunk`）。
  Future<void> _subscribe(
    NewsRepository repo, {
    bool handOffFirstChunk = false,
  }) {
    final round = Completer<void>();
    _first = handOffFirstChunk ? Completer<NewsListState>() : null;
    _latest = null;
    _pulling = true;
    unawaited(_sub?.cancel());
    _sub = repo.fetchStream().listen(
      _onChunk,
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[资讯] 抓取失败：$error');
        _pulling = false;
        final first = _first;
        if (first != null && !first.isCompleted) {
          first.completeError(error, stackTrace);
        }
        if (!round.isCompleted) round.completeError(error, stackTrace);
        // 已经有内容在画时（抓一半才断）把顶上那条「正在更新…」收掉
        _settle();
      },
      onDone: () {
        _pulling = false;
        // 一条都没吐就关上了（边角：一个源都没配）：别把首屏挂在骨架屏上
        final first = _first;
        if (first != null && !first.isCompleted) {
          first.complete(_latest ?? _emptyState);
        }
        if (!round.isCompleted) round.complete();
        _settle();
      },
    );
    return round.future;
  }

  /// 一块到手：补到 `state` 上。
  ///
  /// 这一块里除了刚回来的源，还有**还没回来的源顶上来的缓存那几行**（见仓库里
  /// [_frame]），所以列表只会变新/变多，不会在第一块到达时凭空变少。
  ///
  /// 首屏那一块交给 [build]（它等着这个），后面的每一块直接画 —— 包括
  /// 「一进页面就已经有一块在路上」时的那点重叠：`build` 返回的是 [_latest]，
  /// 就算某一块抢在它返回前到了也不会丢。
  void _onChunk(NewsFetchResult result) {
    if (!ref.mounted) return;
    final next = NewsListState(
      result: result,
      // 已经点开的「余下N篇」不缩回去：每一块都按同一个 expanded 画
      expanded: state.value?.expanded ?? const <String, int>{},
      updating: true,
    );
    _latest = next;
    final first = _first;
    if (first != null && !first.isCompleted) {
      first.complete(next);
      return;
    }
    state = AsyncData<NewsListState>(next);
  }

  /// 这一轮结束了（流关上）：把顶上那条「正在更新…」收掉。
  ///
  /// 首屏那一轮的「结束」往往紧跟在第一块后面（源都很快时就是同一口），而那时
  /// `build` 还没返回（`state` 还是 loading）—— 那种时候只改 [_latest]，
  /// 等 `build` 把它交出去；写 `state` 是白写，会被 `build` 的返回值盖掉。
  void _settle() {
    final live = state.value;
    final current = live ?? _latest;
    if (current == null || !current.updating) return;
    final settled = current.copyWith(updating: false);
    _latest = settled;
    if (live != null) state = AsyncData<NewsListState>(settled);
  }

  /// 别再往 `state` 上写了（provider 被销毁时）
  void _stop() {
    _first = null;
    _pulling = false;
    unawaited(_sub?.cancel());
    _sub = null;
  }

  /// 这份数据是不是已经该更新了。
  ///
  /// 从没抓到过（`cachedAt == 0`）也算该更新 —— 那个值是**成功抓到**时才写的，
  /// 所以「一直失败」会一直重试，而不是认命。
  bool isStale() {
    final at = ref.read(newsRepositoryProvider).cachedAt();
    if (at <= 0) return true;
    return DateTime.now().millisecondsSinceEpoch - at >=
        autoRefreshInterval.inMilliseconds;
  }

  /// 过期就悄悄刷一次。
  ///
  /// 正在抓的时候不叠第二次：**首次进页面**本来就在抓（`build` 里那次），
  /// 这一路检查不该再甩一轮请求出去（那会把还没回来的源掐掉、从头再拉一遍）。
  Future<void> refreshIfStale() async {
    if (_pulling) return;
    if (!isStale()) return;
    await refresh();
  }

  /// 重新抓一遍。
  ///
  /// 三条必须守住的：
  /// * **刷新期间保留上一份内容** —— 不切成 `AsyncLoading`，列表不闪；
  /// * **不动**已经展开的号 —— 某张卡点开成 20 条了，刷新后还是 20 条；
  /// * 抓回来的每一块**立刻画出来**（和首屏同一套），`await` 完才是「整轮都回来了」。
  ///
  /// 失败时：本来就有内容 → 留着旧内容、标成「显示的是上次拉到的内容」；
  /// 本来就没内容（首次进页面就失败）→ 才把错误交给页面画「加载失败 + 重试」。
  Future<void> refresh() async {
    final previous = state.value;
    // 手上有内容就留着画（不切成 loading，列表不闪）；手上什么都没有（比如首屏
    // 就失败后点「重试」）就是骨架屏 —— 别把空列表画成「暂无数据」
    state = previous == null
        ? const AsyncValue<NewsListState>.loading()
        : AsyncData<NewsListState>(previous.copyWith(updating: true));
    try {
      await _subscribe(ref.read(newsRepositoryProvider));
    } on Object catch (error, stackTrace) {
      if (previous == null) {
        state = AsyncError<NewsListState>(error, stackTrace);
        return;
      }
      state = AsyncData<NewsListState>(
        previous.copyWith(
          result: NewsFetchResult(
            articles: previous.all,
            failedFeeds: previous.result.failedFeeds,
            fromCache: true,
          ),
        ),
      );
    }
  }

  /// 点某张卡的「余下N篇」→ 这个号再露 10 条
  void expand(String sourceKey) {
    final current = state.value;
    if (current == null) return;
    final next = <String, int>{
      ...current.expanded,
      sourceKey: current.visibleOf(sourceKey) + NewsListState.expandStep,
    };
    state = AsyncData<NewsListState>(current.copyWith(expanded: next));
  }

  /// 进详情页时把这条标成已读。
  ///
  /// 只改内存里那一条（不整份重拉）：`markRead` 返回 false 表示「本来就已读」，
  /// 那就不用刷界面。
  Future<void> markRead(String id) async {
    final current = state.value;
    if (current == null || id.isEmpty) return;
    final changed = await ref.read(newsRepositoryProvider).markRead(id);
    if (!changed) return;
    state = AsyncData<NewsListState>(
      current.copyWith(
        result: NewsFetchResult(
          articles: current.all
              .map(
                (article) =>
                    article.id == id ? article.copyWith(read: true) : article,
              )
              .toList(growable: false),
          failedFeeds: current.result.failedFeeds,
          fromCache: current.result.fromCache,
        ),
      ),
    );
  }
}

final newsListProvider =
    AsyncNotifierProvider<NewsListController, NewsListState>(
      NewsListController.new,
    );

/// 封面（原文页的 `og:image`）：文章 id → 图片地址。
///
/// 为这么一件事单开一个 provider，是因为它**必须能一张一张地回来**：
/// `resolveCover` 要拉一次原文页（几百 KB），拉完一张就让界面刷一次，
/// 而不是等四张都齐了才动（那样卡片会空白好几秒）。
///
/// 已经在 feed 里带图的文章不进这里（爱范儿自带封面，不用多拉一次页面）。
class NewsCoversNotifier extends Notifier<Map<String, String>> {
  /// 正在拉的 id，避免同一个页子被反复拉（每帧重建都会调 [ensure]）
  final Set<String> _pending = <String>{};
  bool _disposed = false;

  @override
  Map<String, String> build() {
    ref.onDispose(() => _disposed = true);
    return ref.watch(newsRepositoryProvider).cachedCovers();
  }

  /// 同时最多拉几张原文页。
  ///
  /// 封面是一篇一次 HTTP（原文页几百 KB），不拦一下会在进页面那一刻同时甩出几十个
  /// 请求。用不着自己排队：没排上的那批会在下一次重建时再进 [ensure]
  /// （每补到一张封面 provider 都会刷一次，所以列表不会卡住不动）。
  static const int maxInFlight = 4;

  /// 给这些文章补封面（后台补，补到一张刷一次）
  void ensure(List<NewsArticle> articles) {
    for (final article in articles) {
      if (article.imageUrl.isNotEmpty) continue;
      if (state.containsKey(article.id) || _pending.contains(article.id)) {
        continue;
      }
      if (_pending.length >= maxInFlight) return;
      _pending.add(article.id);
      unawaited(_resolve(article));
    }
  }

  Future<void> _resolve(NewsArticle article) async {
    var url = '';
    try {
      url = await ref.read(newsRepositoryProvider).resolveCover(article);
    } on Object catch (error) {
      // 拉不到封面是常态（源站可能挂、可能防盗链），静默降级成纯文字卡
      debugPrint('[媒体号] 补封面失败（${article.link}）：$error');
    } finally {
      _pending.remove(article.id);
    }
    if (_disposed) return;
    state = <String, String>{...state, article.id: url};
  }
}

final newsCoversProvider =
    NotifierProvider<NewsCoversNotifier, Map<String, String>>(
      NewsCoversNotifier.new,
    );

/// 这一篇该用哪张图：自己带的优先，其次补回来的封面
String newsImageOf(NewsArticle article, Map<String, String> covers) =>
    article.imageUrl.isNotEmpty ? article.imageUrl : (covers[article.id] ?? '');

/// 按 id 找一条。详情页只从路由里拿 id，文章本体从列表那份里取 ——
/// 这样深链接/热重载都不会带着一个过期的对象走。
NewsArticle? newsArticleById(NewsFetchResult? result, String id) {
  if (result == null || id.isEmpty) return null;
  for (final article in result.articles) {
    if (article.id == id) return article;
  }
  return null;
}

/// 详情页用：从列表状态里挑出这一篇（列表没加载出来时是 null）
final newsArticleProvider = Provider.family<NewsArticle?, String>(
  (ref, id) => newsArticleById(ref.watch(newsListProvider).value?.result, id),
);
