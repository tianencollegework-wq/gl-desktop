import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/net/api_exception.dart';
import '../../core/platform/desktop_shell.dart';
import '../../core/router/app_router.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/ui/retry_view.dart';
import '../../core/util/time_format.dart';
import '../../domain/news/news_article.dart';
import '../../domain/news/news_feed.dart';
import '../../domain/news/news_providers.dart';
import '../desktop_window/desktop_window_service.dart';
import 'widgets/news_skeleton.dart';
import 'widgets/news_source_card.dart';

/// 「媒体号」列表（「发现」里那一栏进去的第一页）。
///
/// 版式照**公众号**：一屏一张一张的**号卡**，卡头是号（头像 + 号名 + 号里最新那篇
/// 的相对时间），第一篇文章的封面压在标题下面（图在上），后面几篇是「左标题 +
/// 右缩略图」的小行，没露完的收在「余下N篇」后面（见 `NewsSourceCard`）。
///
/// 用户 2026-09-30 定下来的三件事都在这儿：
/// * **越像公众号越好**：卡间留白、卡片圆角、白底、相对时间、封面压标题；
/// * **不要一次性铺一大堆**：每个号先露 3 条，点「余下N篇」再露 10 条
///   （上一版是全局 10 条一页的平铺，滚起来没个头，也不像公众号）；
/// * **右上角那颗搜索**（截图里最右边那颗）能做就做：这里是对**已经拉到的**
///   文章做标题/号名过滤，不发新请求 —— 所以是即时出结果，也搜不到还没拉到的东西。
///
/// 抓取是**一块一块出画**的（见 `NewsListController`）：本机缓存先铺，哪个源先回来
/// 先铺哪几条，不等最慢的那个。
///
/// 三种「不太顺」的情况都画得出来，不留白屏：
/// * 第一块还没回来但本机缓存还在 → **先画缓存**（顶上是「正在更新…」，不再解释）；
/// * 第一块还没回来且没缓存 → **摆号卡骨架屏**（S12.3，不再是居中的转圈：
///   一眼能看出这一页长什么样、内容会落在哪儿）；
/// * 一个源都没拉到且没缓存 → 加载失败 + 重试（和灵听详情页同一颗 `RetryView`）。
///
/// 这两种之外的细节（哪个源这次没拉到、这份是不是缓存）**界面上一律不提**
/// （用户 2026-09-30：「把顶部『网络连接失败』和底部的『这次没拉到…』文案去掉」）——
/// 数据还在 `NewsFetchResult.failedFeeds` 里，只是不再拿出来给用户看。
///
/// **没有下拉刷新**（用户 2026-09-30：「把下拉刷新功能去掉，就改成每半个小时自动
/// 刷新一次（也不用提示更新于什么时间）」）。顶上那条时间没了；更新是自动的：
/// 进页面时如果手上这份已经超过 [NewsListController.autoRefreshInterval] 就刷一次，
/// 页面开着时每 [NewsListController.staleCheckInterval] 再问一次该不该更新。
class NewsListPage extends ConsumerStatefulWidget {
  const NewsListPage({super.key});

  @override
  ConsumerState<NewsListPage> createState() => _NewsListPageState();
}

class _NewsListPageState extends ConsumerState<NewsListPage> {
  final TextEditingController _query = TextEditingController();
  bool _searching = false;
  Timer? _staleCheck;

  @override
  void initState() {
    super.initState();
    // 边打边筛：输入框每变一次就重画一次（**不发请求**，筛的是已经拉到的那批）
    _query.addListener(() => setState(() {}));
    // 第一次进页面时 `build` 本来就会抓一遍；这一路是为了**再进来时**（provider
    // 还活着、内容还是上次那份）如果已经过期了，自己悄悄更新掉。
    // 放到第一帧之后：不在 build 里改 provider。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(newsListProvider.notifier).refreshIfStale();
    });
    // 页面开着的时候每 5 分钟问一次「该更新了吗」（只是比时间戳，没到点不发请求）
    _staleCheck = Timer.periodic(NewsListController.staleCheckInterval, (_) {
      if (!mounted) return;
      ref.read(newsListProvider.notifier).refreshIfStale();
    });
  }

  @override
  void dispose() {
    _staleCheck?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _openSearch() => setState(() => _searching = true);

  void _closeSearch() {
    _query.clear();
    setState(() => _searching = false);
  }

  @override
  Widget build(BuildContext context) {
    final i18n = ref.watch(appI18nProvider);
    final async = ref.watch(newsListProvider);
    // 本机缓存是**同步**读的，不用等网络：第一块还没到手时先把它画出来，别闪白屏
    //（第一块一到就换成那份 —— 那份里**没回来的源也拿缓存顶着**，所以列表不会
    // 在这一刻突然变少，见仓库里的 `_frame`）
    final cached = ref.watch(newsRepositoryProvider).cachedArticles();
    final state =
        async.value ??
        (cached.isEmpty
            ? null
            : NewsListState(
                result: NewsFetchResult(articles: cached, fromCache: true),
                // 还在等第一块：顶上那条「正在更新…」说的就是这件事；
                // 已经抓挂了（`AsyncError`）就别再顶这句
                updating: async.isLoading,
              ));

    return Scaffold(
      backgroundColor: AppColors.page,
      appBar: AppBar(
        backgroundColor: AppColors.page,
        title: _searching
            ? _SearchField(controller: _query, hint: i18n.t('news.searchHint'))
            : Text(i18n.t('news.title')),
        actions: <Widget>[
          if (_searching)
            IconButton(
              tooltip: i18n.t('common.cancel'),
              icon: const Icon(Icons.close),
              onPressed: _closeSearch,
            )
          else
            IconButton(
              tooltip: i18n.t('news.search'),
              icon: const Icon(Icons.search),
              onPressed: _openSearch,
            ),
        ],
      ),
      body: state == null
          ? (async.isLoading
                // 连缓存都没有才轮到这里：摆一屏号卡骨架（不用转圈 —— 它说不出
                // 「马上会有什么」，还会让整页先空一下再跳）
                ? const NewsListSkeleton()
                : RetryView(
                    message: _errorMessage(async.error, i18n),
                    retryLabel: i18n.t('common.retry'),
                    onRetry: () =>
                        ref.read(newsListProvider.notifier).refresh(),
                  ))
          // 搜索时画的是**过滤后的平铺结果**（不是号卡）：
          // 搜索要的是「这一条在哪」，不该再让用户在一张张卡里翻
          : _searching && _query.text.trim().isNotEmpty
          ? _SearchResults(
              articles: _match(state, _query.text.trim()),
              empty: i18n.t('news.searchEmpty'),
              onOpen: _open,
            )
          : _Feed(state: state, onOpen: _open),
    );
  }

  void _open(NewsArticle article) {
    // 桌面宽窗：文章开在**系统级独立窗口**里（用户 2026-10-04：像微信 PC 点
    // 公众号文章那样），主窗口里这份列表原地不动；手机 / 窄窗照旧整页推。
    if (desktopWideLayout(context, ref)) {
      unawaited(
        ref
            .read(desktopWindowServiceProvider)
            .openArticle(id: article.id, title: article.title),
      );
      return;
    }
    context.push(
      '${AppRoutes.newsDetail}?id=${Uri.encodeComponent(article.id)}',
    );
  }

  /// 已经拉到的那批里筛一遍：标题命中、或者号名命中（搜「IT之家」进来的）
  List<NewsArticle> _match(NewsListState state, String query) {
    final i18n = ref.read(appI18nProvider);
    final needle = query.toLowerCase();
    return state.all
        .where((article) {
          if (article.title.toLowerCase().contains(needle)) return true;
          final feed = newsFeedByKey(article.sourceKey);
          return feed != null &&
              i18n.t(feed.nameKey).toLowerCase().contains(needle);
        })
        .toList(growable: false);
  }

  /// 接口自己的话（比如「请求超时」）比一句笼统的「加载失败」有用
  String _errorMessage(Object? error, AppI18n i18n) {
    if (error is ApiException && error.message.isNotEmpty) return error.message;
    return i18n.t('common.loadFailed');
  }
}

/// 号卡那一屏：顶上一条抓取状态，然后一卡一个号（谁没拉到**不画**，数据留着）
class _Feed extends ConsumerWidget {
  const _Feed({required this.state, required this.onOpen});

  final NewsListState state;
  final void Function(NewsArticle article) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);
    final groups = state.groups;
    // 一个号都没有（比如所有源全解析不出东西）：只留一句话，不留空白页
    if (groups.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: <Widget>[
          SizedBox(height: context.rpx(160)),
          Center(
            child: Text(
              i18n.t('common.noData'),
              style: TextStyle(
                fontSize: context.rpx(27),
                color: AppColors.text999,
              ),
            ),
          ),
        ],
      );
    }
    return ListView(
      padding: EdgeInsets.only(top: context.rpx(12), bottom: context.rpx(40)),
      physics: const AlwaysScrollableScrollPhysics(),
      children: <Widget>[
        _StatusBar(state: state),
        for (final group in groups)
          NewsSourceCard(group: group, onOpen: onOpen),
      ],
    );
  }
}

/// 搜索：输入框（放进 AppBar 的标题位，就是微信那颗搜索点开的样子）
class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.hint});

  final TextEditingController controller;
  final String hint;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    autofocus: true,
    textInputAction: TextInputAction.search,
    style: TextStyle(fontSize: context.rpx(31), color: AppColors.text000),
    decoration: InputDecoration(
      isDense: true,
      border: InputBorder.none,
      hintText: hint,
      hintStyle: TextStyle(fontSize: context.rpx(31), color: AppColors.text999),
    ),
  );
}

/// 搜索结果：平铺，一条一行 —— 搜索要的是「这一条在哪」，不该再让人在卡里翻
class _SearchResults extends ConsumerWidget {
  const _SearchResults({
    required this.articles,
    required this.empty,
    required this.onOpen,
  });

  final List<NewsArticle> articles;
  final String empty;
  final void Function(NewsArticle article) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final i18n = ref.watch(appI18nProvider);
    if (articles.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: <Widget>[
          SizedBox(height: context.rpx(160)),
          Center(
            child: Text(
              empty,
              style: TextStyle(
                fontSize: context.rpx(27),
                color: AppColors.text999,
              ),
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.only(top: context.rpx(12)),
      itemCount: articles.length,
      itemBuilder: (context, index) {
        final article = articles[index];
        final feed = newsFeedByKey(article.sourceKey);
        final meta = <String>[
          if (feed != null) i18n.t(feed.nameKey),
          if (article.publishedAt != null)
            feedTime(
              article.publishedAt!.millisecondsSinceEpoch,
              translate: i18n.t,
            ),
        ].join(' · ');
        return Container(
          color: AppColors.white,
          margin: EdgeInsets.fromLTRB(
            context.rpx(20),
            0,
            context.rpx(20),
            context.rpx(12),
          ),
          child: InkWell(
            onTap: () => onOpen(article),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                context.rpx(28),
                context.rpx(26),
                context.rpx(28),
                context.rpx(26),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    article.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: context.rpx(33),
                      height: 1.4,
                      color: article.read
                          ? AppColors.text666
                          : AppColors.text000,
                    ),
                  ),
                  if (meta.isNotEmpty) ...<Widget>[
                    SizedBox(height: context.rpx(10)),
                    Text(
                      meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: context.rpx(24),
                        color: AppColors.text999,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 顶上那条：**只在正在抓的时候**出现（一个转圈 + 「正在更新…」）。
///
/// 用户 2026-09-30 把这种提示砍到只剩这一条了：
/// * 「更新于 14:20」——不要（更新是自动的，用户不需要知道上次是几点抓的）；
/// * 「网络不可用，显示的是上次拉到的内容」——也不要（用户原话是「把顶部『网络连接失败』
///   的文案去掉」）。**看不到就当作没发生**：缓存内容照常画，只是不再解释了。
///
/// 不更新时**整条不占位置**（公众号顶部本来也是干净的）。
class _StatusBar extends ConsumerWidget {
  const _StatusBar({required this.state});

  final NewsListState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!state.updating) return const SizedBox.shrink();
    final i18n = ref.watch(appI18nProvider);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.rpx(40),
        context.rpx(8),
        context.rpx(40),
        context.rpx(20),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: context.rpx(24),
            height: context.rpx(24),
            child: const CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.wechatGreen,
            ),
          ),
          SizedBox(width: context.rpx(12)),
          Flexible(
            child: Text(
              i18n.t('news.updating'),
              maxLines: 2,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.rpx(23),
                color: AppColors.text999,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
