import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/router/app_router.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/theme/app_colors.dart';
import 'package:gracelinkim/core/ui/retry_view.dart';
import 'package:gracelinkim/domain/news/news_article.dart';
import 'package:gracelinkim/domain/news/news_card.dart';
import 'package:gracelinkim/domain/news/news_providers.dart';
import 'package:gracelinkim/features/common/link_confirm_page.dart';
import 'package:gracelinkim/features/news/news_detail_page.dart';
import 'package:gracelinkim/features/news/news_list_page.dart';
import 'package:gracelinkim/features/news/widgets/news_skeleton.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_news.dart';

/// 媒体号的两个页面。
///
/// 仓库那层（抓取/缓存/已读）已经被 `test/news/news_repository_test.dart` 盯住了，
/// 这里只验页面自己的事：**号卡画成什么样（图压标题、余下N篇）、点进去是不是
/// 同一篇、没网/部分源挂掉时给不给得出话、以及「阅读原文」是不是走聊天那套外链闸门**。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
  });

  tearDown(() => AppI18n.load('zh-Hans'));

  /// 页面只跟仓库打交道，所以这里换掉仓库就行
  Future<ProviderContainer> pumpNews(
    WidgetTester tester,
    FakeNewsRepository repository, {
    String location = AppRoutes.newsList,
    bool asRouter = true,
    NewsCard? shared,

    /// 屏幕尺寸（物理像素；默认 1170x2532 就是一台典型的 3x 手机）
    Size size = const Size(1170, 2532),

    /// 要不要等页面完全静下来。
    ///
    /// 分层加载那几条要传 false：抓取还没完时顶上转着圈（`_StatusBar` 里的
    /// `CircularProgressIndicator` 一直在动），`pumpAndSettle` 会一直等下去。
    bool settle = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final router = GoRouter(
      initialLocation: location,
      routes: <RouteBase>[
        GoRoute(
          path: AppRoutes.newsList,
          builder: (context, state) => const NewsListPage(),
        ),
        GoRoute(
          path: AppRoutes.newsDetail,
          builder: (context, state) => NewsDetailPage(
            id: state.uri.queryParameters['id'] ?? '',
            // 与真实路由表一样：卡片从 `extra` 带进来
            shared: state.extra is NewsCard ? state.extra! as NewsCard : shared,
          ),
        ),
        // 「阅读原文」会推到这两个页面（真实路由表里也是这两个）
        GoRoute(
          path: AppRoutes.linkConfirm,
          builder: (context, state) =>
              LinkConfirmPage(url: state.uri.queryParameters['url'] ?? ''),
        ),
        GoRoute(
          path: AppRoutes.webview,
          builder: (context, state) => const Scaffold(body: Text('WEBVIEW')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [newsRepositoryProvider.overrideWithValue(repository)],
        child: asRouter
            ? MaterialApp.router(routerConfig: router)
            : MaterialApp(
                home: location == AppRoutes.newsList
                    ? const NewsListPage()
                    : NewsDetailPage(id: shared?.id ?? 'a1', shared: shared),
              ),
      ),
    );
    if (!settle) {
      await tester.pump();
      return ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
      );
    }
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
  }

  testWidgets('号卡：卡头是号名 + 相对时间，第一篇压在大图上，没图时退成大标题', (tester) async {
    final repository = FakeNewsRepository(<NewsArticle>[
      fakeArticle(id: 'a1', title: '第一条资讯', source: 'sspai'),
      fakeArticle(id: 'a2', title: '第二条资讯', source: 'ifanr'),
    ]);
    final container = await pumpNews(tester, repository);

    // 两个号 → 两张卡；标题都在（一个是大标题，一个是小行）
    expect(find.text('第一条资讯'), findsOneWidget);
    expect(find.text('第二条资讯'), findsOneWidget);
    // 卡头是**号名**（公众号那张图里卡头就是号，不是文章），走语言包
    expect(find.text('少数派'), findsOneWidget);
    expect(find.text('爱范儿'), findsOneWidget);
    // 顶上**没有**「更新于 …」了（用户 2026-09-30 明确不要）：更新是自动的，
    // 用户不需要知道上次是几点抓的，所以那条状态栏没话说时整条不占位置
    expect(find.textContaining('更新于'), findsNothing);
    expect(find.text('正在更新…'), findsNothing);
    expect(
      container.read(newsListProvider).value!.groups,
      hasLength(2),
      reason: '一个号一张卡',
    );
    // 列表里只有号卡，**没有摘要**（公众号的卡片也不放摘要，摘要留给详情页）
    expect(find.text('这里是摘要。'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('封面上屏就行 —— feed 没给图、本机补到的那张也画出来', (tester) async {
    final repository = FakeNewsRepository(<NewsArticle>[
      fakeArticle(id: 'a1', title: '带封面那条'),
    ]);
    // 模拟「上一轮已经补好封面了」：provider 初始就读到这张图
    repository.covers = <String, String>{'a1': 'https://cdn.test/cover.jpg'};
    await pumpNews(tester, repository);

    expect(_loadedUrls(tester), contains('https://cdn.test/cover.jpg'));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('点一条进详情：标题/来源/摘要/阅读原文都在，返回后红点消失（标记已读）', (tester) async {
    final repository = FakeNewsRepository(<NewsArticle>[
      fakeArticle(id: 'a1', title: '第一条资讯'),
    ]);
    final container = await pumpNews(tester, repository);

    await tester.tap(find.text('第一条资讯'));
    await tester.pumpAndSettle();

    expect(find.byType(NewsDetailPage), findsOneWidget);
    expect(find.text('第一条资讯'), findsOneWidget);
    expect(find.text('这里是摘要。'), findsOneWidget);
    expect(find.text('阅读原文'), findsOneWidget);
    // 底栏只剩这一颗：分享挪到右上角了，复制链接整个去掉（用户 2026-09-30）
    expect(find.text('复制链接'), findsNothing);
    expect(find.byIcon(Icons.link), findsNothing);
    expect(find.byIcon(Icons.ios_share), findsOneWidget, reason: '分享在右上角');
    expect(repository.marked, <String>['a1']);

    // 返回列表：那一条已经变成已读了
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(container.read(newsListProvider).value!.all.single.read, isTrue);
    expect(_unreadDots(tester), 0);
    expect(find.text('第一条资讯'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('「阅读原文」走聊天那套外链闸门：先弹「第三方网址」，不直接开', (tester) async {
    final repository = FakeNewsRepository(<NewsArticle>[
      fakeArticle(id: 'a1', title: '第一条资讯'),
    ]);
    await pumpNews(
      tester,
      repository,
      location: '${AppRoutes.newsDetail}?id=a1',
    );

    await tester.tap(find.text('阅读原文'));
    await tester.pumpAndSettle();

    expect(find.byType(LinkConfirmPage), findsOneWidget);
    expect(find.text('即将打开第三方网页'), findsOneWidget);
    expect(find.text('WEBVIEW'), findsNothing, reason: '没点「继续访问」之前不该加载');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('没网但本机有缓存：画缓存，**不再顶一条字解释**', (tester) async {
    final repository = FakeNewsRepository(
      const <NewsArticle>[],
      throwOnFetch: true,
      cached: <NewsArticle>[fakeArticle(id: 'a1', title: '上次拉到的')],
    );
    await pumpNews(tester, repository);

    expect(find.text('上次拉到的'), findsOneWidget);
    expect(
      find.textContaining('网络'),
      findsNothing,
      reason: '用户 2026-09-30：顶部那种「网络…」的话全部去掉（看不到就当作没发生）',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('一个源都没拉到且没缓存：给「加载失败 + 重试」，点了能拉回来', (tester) async {
    final repository = FakeNewsRepository(
      const <NewsArticle>[],
      throwOnFetch: true,
    );
    await pumpNews(tester, repository);

    // Riverpod 3 自己会重试（200ms 起、翻倍、封顶 6.4s，最多 10 次）：重试期间
    // 状态是 `AsyncLoading(error: …, retrying)`，页面摆的还是骨架屏。把时间
    // 快进过整串重试（加起来 ~38s），它放弃了才轮到「加载失败 + 重试」。
    // 这一步顺带记下了「骨架屏不闪」的副作用：以前那是个一直转的圈，
    // `pumpAndSettle` 会被它拖着把重试跑完；现在骨架是静态的，
    // `pumpAndSettle` 立刻返回 —— 想看到失败态得自己推时间。
    await tester.pump(const Duration(seconds: 60));
    await tester.pump();

    expect(find.text('资讯加载失败，请检查网络后重试'), findsOneWidget);
    expect(
      find.byType(RetryView),
      findsOneWidget,
      reason: '和灵听详情页是同一颗（S12.3：同款重试视图）',
    );

    // 网络回来了
    repository.throwOnFetch = false;
    repository.articles = <NewsArticle>[fakeArticle(id: 'a1', title: '终于拉到了')];
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('终于拉到了'), findsOneWidget);
    expect(find.byType(RetryView), findsNothing, reason: '拉回来了就不该再摆那一屏');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('部分源没拉到：**底部不再点名**，活着的源照常出内容', (tester) async {
    final repository = FakeNewsRepository(
      <NewsArticle>[fakeArticle(id: 'a1', title: '活着的源给的')],
      failedFeeds: <String>['ithome', 'solidot'],
    );
    await pumpNews(tester, repository);

    expect(find.text('活着的源给的'), findsOneWidget);
    expect(
      find.textContaining('没拉到'),
      findsNothing,
      reason: '用户 2026-09-30：底部那句「这些来源这次没拉到…」去掉（数据还留着，只是不画）',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('详情页的 id 在列表里找不到：说清楚并给重试，不白屏', (tester) async {
    final repository = FakeNewsRepository(const <NewsArticle>[]);
    await pumpNews(
      tester,
      repository,
      location: '${AppRoutes.newsDetail}?id=old-1',
    );

    expect(find.text('这篇文章已经不在了（可能被来源更新掉了）。'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('换掉了下拉刷新：列表不再能被下拉刷新，也不再有「更新于 …」', (tester) async {
    final repository = FakeNewsRepository(<NewsArticle>[
      fakeArticle(id: 'a1', title: '第一条资讯'),
    ]);
    await pumpNews(tester, repository);

    expect(
      find.byType(RefreshIndicator),
      findsNothing,
      reason: '用户 2026-09-30：下拉刷新去掉，改成自动刷新',
    );
    expect(find.textContaining('更新于'), findsNothing);
    expect(find.text('正在更新…'), findsNothing, reason: '没事的时候顶上那条不占位置');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('自动刷新期间不闪成 loading：原来露出来的条数也不会缩回去', (tester) async {
    final repository = FakeNewsRepository(<NewsArticle>[
      for (var index = 0; index < 8; index++)
        fakeArticle(id: 'a$index', title: '第 $index 条文章'),
    ]);
    final container = await pumpNews(tester, repository);

    container.read(newsListProvider.notifier).expand('ithome');
    await tester.pumpAndSettle();
    expect(find.text('第 7 条文章'), findsOneWidget, reason: '先展开到 8 条都露出来');

    // 抓久一点，好在「正在刷新」那一刻看页面画的是什么
    repository.fetchDelay = const Duration(milliseconds: 300);
    unawaited(container.read(newsListProvider.notifier).refresh());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('正在更新…'), findsOneWidget);
    expect(
      find.text('第 7 条文章'),
      findsOneWidget,
      reason: '刷新期间画的是上一份内容，不换成 loading（否则整页会闪、卡片会缩回 3 条）',
    );
    expect(
      container.read(newsListProvider).value!.visibleOf('ithome'),
      NewsListState.defaultPerSource + NewsListState.expandStep,
    );

    await tester.pumpAndSettle();
    expect(
      container.read(newsListProvider).value!.visibleOf('ithome'),
      NewsListState.defaultPerSource + NewsListState.expandStep,
      reason: '刷新完了也不能把人家展开的收回去',
    );
    expect(find.text('正在更新…'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('哪个源先回来先铺哪几条：慢的还挂着，先回来的那几条已经画出来了', (tester) async {
    final repository = FakeNewsRepository(const <NewsArticle>[])
      ..batches = <List<NewsArticle>>[
        <NewsArticle>[fakeArticle(id: 'fast', title: '先回来的那条')],
        <NewsArticle>[fakeArticle(id: 'slow', title: '慢的源那条', source: 'sspai')],
      ]
      // 第二块（= 慢的那个源）卡住
      ..gates[1] = Completer<void>();
    await pumpNews(tester, repository, settle: false);
    await tester.pump();

    expect(find.text('先回来的那条'), findsOneWidget, reason: '不等最慢的那个：第一块到手就画出来');
    expect(find.text('慢的源那条'), findsNothing);
    expect(find.text('正在更新…'), findsOneWidget, reason: '还有源在路上');

    repository.open(1);
    await tester.pump();
    await tester.pump();

    expect(find.text('慢的源那条'), findsOneWidget, reason: '它回来之后自己补上去了');
    expect(find.text('正在更新…'), findsNothing, reason: '整轮完了就把它收掉');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('第一块还没回来：先画本机缓存，不等网络', (tester) async {
    final repository =
        FakeNewsRepository(
            const <NewsArticle>[],
            cached: <NewsArticle>[fakeArticle(id: 'c1', title: '缓存里的旧闻')],
          )
          ..batches = <List<NewsArticle>>[
            <NewsArticle>[fakeArticle(id: 'n1', title: '刚拉到的')],
          ]
          // 第一块也卡住：页面只能靠本机缓存先撑着
          ..gates[0] = Completer<void>();
    await pumpNews(tester, repository, settle: false);
    await tester.pump();

    expect(
      find.text('缓存里的旧闻'),
      findsOneWidget,
      reason: '缓存是同步读的，不用等网络 —— 这就是「本机缓存先出画」',
    );
    expect(
      find.byType(NewsListSkeleton),
      findsNothing,
      reason: '有缓存就不摆骨架屏：骨架是「连缓存都没有」时的兑底',
    );
    expect(find.text('正在更新…'), findsOneWidget, reason: '还在等第一块');

    repository.open(0);
    await tester.pump();
    await tester.pump();

    expect(find.text('刚拉到的'), findsOneWidget);
    expect(find.text('正在更新…'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('第一块还没回来且没缓存：首屏摆骨架屏（不是转圈），内容到了原地换上', (tester) async {
    final repository = FakeNewsRepository(const <NewsArticle>[])
      ..batches = <List<NewsArticle>>[
        <NewsArticle>[fakeArticle(id: 'n1', title: '第一块回来了')],
      ]
      // 第一块卡住：页面就停在「缓存也没有、网络也没回来」那一刻
      ..gates[0] = Completer<void>();
    await pumpNews(tester, repository, settle: false);
    await tester.pump();

    expect(find.byType(NewsListSkeleton), findsOneWidget);
    expect(
      find.byType(CircularProgressIndicator),
      findsNothing,
      reason: '首屏那个转圈换成骨架屏了（用户 2026-09-30）',
    );

    // 骨架是**静态**的：没有动画就挂不住 pumpAndSettle（灵听那条同理）
    await tester.pumpAndSettle();
    expect(
      find.byType(NewsListSkeleton),
      findsOneWidget,
      reason: '还卡着就在那儿摆着，不闪也不消失',
    );

    // 第一块回来 → 骨架原地换成真内容
    repository.open(0);
    await tester.pump();
    await tester.pump();

    expect(find.byType(NewsListSkeleton), findsNothing);
    expect(find.text('第一块回来了'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('窄屏（320dp）下骨架屏不溢出：两张灰卡照样铺得下', (tester) async {
    final repository = FakeNewsRepository(const <NewsArticle>[])
      // 第一块卡住：页面就停在骨架上
      ..gates[0] = Completer<void>();
    await pumpNews(
      tester,
      repository,
      settle: false,
      // 960/3 = 320dp 宽：老手机的宽度，最容易溢出
      size: const Size(960, 1707),
    );
    await tester.pump();

    // 溢出在用例里会直接报错，所以「跑完了」本身就是结果
    expect(find.byType(NewsListSkeleton), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    repository.open(0);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('英文界面下也跟着换（标题与号名都走语言包）', (tester) async {
    await AppI18n.load('en');
    final repository = FakeNewsRepository(<NewsArticle>[
      fakeArticle(id: 'a1', title: 'A story'),
    ]);
    await pumpNews(tester, repository);

    expect(find.text('Media'), findsOneWidget);
    expect(find.text('ITHome'), findsOneWidget);
    expect(find.text('媒体号'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('每个号先露 3 条，点「余下N篇」才接着露 —— 而且只展开点的那张卡', (tester) async {
    final repository = FakeNewsRepository(<NewsArticle>[
      for (var index = 0; index < 25; index++)
        fakeArticle(id: 'a$index', title: '第 $index 条文章'),
      for (var index = 0; index < 5; index++)
        fakeArticle(id: 'b$index', title: '别的号第 $index 条', source: 'solidot'),
    ]);
    final container = await pumpNews(tester, repository);

    expect(find.text('第 0 条文章'), findsOneWidget);
    expect(find.text('第 2 条文章'), findsOneWidget, reason: '卡片里第 3 条也露出来了');
    expect(find.text('第 3 条文章'), findsNothing, reason: '第 4 条还收在「余下N篇」后面');
    expect(find.text('余下 22 篇'), findsOneWidget);
    // 另一个号（5 条 → 露 3 条）自己也有一行「余下 2 篇」
    expect(find.text('余下 2 篇'), findsOneWidget);

    final before = container.read(newsListProvider).value!;
    expect(before.visibleOf('ithome'), NewsListState.defaultPerSource);
    expect(before.hiddenOf(before.groups.first), 22);

    await tester.tap(find.text('余下 22 篇'));
    await tester.pumpAndSettle();

    expect(find.text('第 12 条文章'), findsOneWidget, reason: '一次再露 10 条');
    expect(find.text('余下 12 篇'), findsOneWidget);
    final after = container.read(newsListProvider).value!;
    expect(
      after.visibleOf('ithome'),
      NewsListState.defaultPerSource + NewsListState.expandStep,
    );
    expect(
      after.visibleOf('solidot'),
      NewsListState.defaultPerSource,
      reason: '展开是按号算的：点了一张卡，别的卡不该跟着变',
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('搜索：右上角那颗点开，按标题筛已经拉到的那批，不发新请求', (tester) async {
    final repository = FakeNewsRepository(<NewsArticle>[
      fakeArticle(id: 'a1', title: '温州这家长很难办', source: 'sspai'),
      fakeArticle(id: 'a2', title: '东京连续下了 34 天雨', source: 'ifanr'),
    ]);
    await pumpNews(tester, repository);
    final fetches = repository.fetchCount;

    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '东京');
    await tester.pumpAndSettle();

    expect(find.text('东京连续下了 34 天雨'), findsOneWidget);
    expect(find.text('温州这家长很难办'), findsNothing);
    expect(repository.fetchCount, fetches, reason: '筛的是本机已有的那批，不再去拉');

    // 搜不到就给一句话，而不是空白
    await tester.enterText(find.byType(TextField), '不存在的东西');
    await tester.pumpAndSettle();
    expect(find.text('没有找到相关文章'), findsOneWidget);

    // 关掉搜索回到号卡
    await tester.tap(find.byTooltip('取消'));
    await tester.pumpAndSettle();
    expect(find.text('温州这家长很难办'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('分享进来的那一篇：本机列表里没有，也看得到摘要与「阅读原文」', (tester) async {
    // 本机列表是空的（这一篇是**发卡片那个人**机器上抓到的）
    final repository = FakeNewsRepository(const <NewsArticle>[]);
    final card = NewsCard(
      id: 'shared-1',
      title: '朋友分享来的新闻',
      sourceKey: 'sspai',
      summary: '卡片里带的摘要。',
      link: 'https://sspai.com/post/1',
    );
    await pumpNews(tester, repository);

    // 走聊天里点卡片那条路：push 详情页 + 把卡片作为 extra 带上
    GoRouter.of(
      tester.element(find.byType(NewsListPage)),
    ).push('${AppRoutes.newsDetail}?id=shared-1', extra: card);
    await tester.pumpAndSettle();

    expect(find.text('朋友分享来的新闻'), findsOneWidget);
    expect(find.text('卡片里带的摘要。'), findsOneWidget);
    expect(
      find.textContaining('少数派'),
      findsNWidgets(2),
      reason: '顶栏写号名（自己在读谁），标题下面那行再来一次（公众号也是两处）',
    );
    expect(find.text('阅读原文'), findsOneWidget);

    await tester.tap(find.text('阅读原文'));
    await tester.pumpAndSettle();
    expect(find.byType(LinkConfirmPage), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('窄屏（320dp）下详情页不溢出：底栏那颗满宽按钮也放得下', (tester) async {
    final repository = FakeNewsRepository(<NewsArticle>[
      fakeArticle(id: 'a1', title: '一个长得能把两行都占满的标题一个长得能把两行都占满的标题'),
    ]);
    await pumpNews(
      tester,
      repository,
      location: '${AppRoutes.newsDetail}?id=a1',
      size: const Size(960, 1707),
      // 960/3 = 320dp 宽：老手机的宽度，最容易溢出
    );

    // 溢出在用例里会直接报错，所以「跑完了」本身就是结果
    expect(find.text('阅读原文'), findsOneWidget);
    expect(find.byIcon(Icons.ios_share), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('详情页有「分享」入口（点了走聊天那套转发选择器）', (tester) async {
    final repository = FakeNewsRepository(<NewsArticle>[
      fakeArticle(id: 'a1', title: '第一条资讯'),
    ]);
    await pumpNews(
      tester,
      repository,
      location: '${AppRoutes.newsDetail}?id=a1',
    );

    expect(find.byTooltip('分享'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.ios_share));
    await tester.pumpAndSettle();

    expect(find.text('转发'), findsOneWidget, reason: '聊天那套转发选择器');
    expect(find.text('完成'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

/// 页面上正在加载的图片地址。
///
/// 要拆一层 `ResizeImage` —— 列表里的图都带 `cacheWidth`（按显示尺寸解码），
/// 那会把 `NetworkImage` 包起来，直接 `whereType<NetworkImage>()` 一个都取不到。
List<String> _loadedUrls(WidgetTester tester) => tester
    .widgetList<Image>(find.byType(Image))
    .map((image) => image.image)
    .map(
      (provider) => provider is ResizeImage ? provider.imageProvider : provider,
    )
    .whereType<NetworkImage>()
    .map((image) => image.url)
    .toList();

/// 数一下列表里那几个未读小红点。
///
/// 只看 `unreadRed` 的圆形 Container —— 卡头那颗**号头像也是圆的**，
/// 不按颜色分就把它一起数进来了。
int _unreadDots(WidgetTester tester) => tester
    .widgetList<Container>(find.byType(Container))
    .where(
      (container) =>
          container.decoration is BoxDecoration &&
          (container.decoration! as BoxDecoration).shape == BoxShape.circle &&
          (container.decoration! as BoxDecoration).color == AppColors.unreadRed,
    )
    .length;
