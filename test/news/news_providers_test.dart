import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/domain/news/news_article.dart';
import 'package:gracelinkim/domain/news/news_providers.dart';

import '../support/fake_news.dart';

/// 媒体号列表的**自动刷新**。
///
/// 用户 2026-09-30：「把下拉刷新功能去掉，就改成每半个小时自动刷新一次」。
/// 页面只负责「进页面问一次、开着时每 5 分钟问一次」，**该不该刷**是这里说了算 ——
/// 所以这几条不用起界面（页面画出来长什么样在
/// `test/features/news_pages_test.dart` 里管）。
void main() {
  final now = DateTime.now();

  ProviderContainer containerWith(FakeNewsRepository repository) {
    final container = ProviderContainer(
      overrides: [newsRepositoryProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('刚抓过（半小时内）不该白刷一遍', () async {
    final repository = FakeNewsRepository(<NewsArticle>[
      fakeArticle(id: 'a1', title: '第一条'),
    ]);
    final container = containerWith(repository);
    await container.read(newsListProvider.future);
    expect(repository.fetchCount, 1, reason: '首次进来：build 里那次');

    await container.read(newsListProvider.notifier).refreshIfStale();

    expect(repository.fetchCount, 1, reason: '手上这份是刚拉的，不用再拉一轮（自动刷新不是「每次都刷」）');
  });

  test('超过半小时：自己刷一次', () async {
    final repository = FakeNewsRepository(
      <NewsArticle>[fakeArticle(id: 'a1', title: '第一条')],
      cachedAtMillis: now
          .subtract(const Duration(minutes: 31))
          .millisecondsSinceEpoch,
    );
    final container = containerWith(repository);
    await container.read(newsListProvider.future);

    await container.read(newsListProvider.notifier).refreshIfStale();

    expect(repository.fetchCount, 2, reason: '过期的就该更新掉');
  });
  test('`cachedAt` 是 0（真仓库里 = 从没成功抓到过）也算「该更新」', () async {
    // 真仓库里 `cachedAt` 只在**成功抓到**时写。所以 0 这个值意味着「一直没抓到」——
    // 那种情况下不能认命，每个检查点都该再试一次。
    final repository = FakeNewsRepository(<NewsArticle>[
      fakeArticle(id: 'a1', title: '第一条'),
    ], cachedAtMillis: 0);
    final container = containerWith(repository);
    await container.read(newsListProvider.future);
    expect(repository.fetchCount, 1);

    await container.read(newsListProvider.notifier).refreshIfStale();

    expect(repository.fetchCount, 2, reason: '时间戳是 0 → 下个检查点还会再试');
  });

  test('正在抓的时候不叠第二次（首次进页面本来就在抓）', () async {
    final repository = FakeNewsRepository(
      <NewsArticle>[fakeArticle(id: 'a1', title: '第一条')],
      cachedAtMillis: 0,
      fetchDelay: const Duration(milliseconds: 50),
    );
    final container = containerWith(repository);

    final pending = container.read(newsListProvider.future);
    await container.read(newsListProvider.notifier).refreshIfStale();

    expect(repository.fetchCount, 1, reason: '第一次还没回来，不该再甩一轮请求出去');
    await pending;
  });

  test('自动刷新失败：旧内容留着，并标成「显示的是上次拉到的内容」', () async {
    final repository = FakeNewsRepository(<NewsArticle>[
      fakeArticle(id: 'a1', title: '第一条'),
    ]);
    final container = containerWith(repository);
    await container.read(newsListProvider.future);

    repository.throwOnFetch = true;
    await container.read(newsListProvider.notifier).refresh();

    final state = container.read(newsListProvider).value!;
    expect(state.all.single.title, '第一条', reason: '抓挂了不能把已经看到的内容清掉');
    expect(state.fromCache, isTrue, reason: '顶上那句「网络不可用…」靠它说出来');
    expect(state.updating, isFalse, reason: '转完了要把「正在更新…」收掉');
  });

  /// 分层加载（S12.2）：**第一块回来就出画**，不再等最慢的那个源。
  ///
  /// 「本机缓存先画」（网络还没回来时画的是缓存）在
  /// `test/features/news_pages_test.dart` 里管，这里只验「一块一块地长出来」。
  group('一块一块出画', () {
    test('首屏不等最慢的那个：第一块回来就画，后面的块再补上来', () async {
      final repository = FakeNewsRepository(const <NewsArticle>[])
        ..batches = <List<NewsArticle>>[
          <NewsArticle>[fakeArticle(id: 'fast', title: '先回来的源')],
          <NewsArticle>[fakeArticle(id: 'slow', title: '慢的源', source: 'sspai')],
        ]
        // 第二块卡住：页面有时间停在「先回来的那一条」上
        ..gates[1] = Completer<void>();
      final container = containerWith(repository);

      await container.read(newsListProvider.future);

      final first = container.read(newsListProvider).value!;
      expect(first.all.map((a) => a.title), <String>[
        '先回来的源',
      ], reason: '不等最慢的那个：第一块到手就出画');
      expect(first.updating, isTrue, reason: '别的源还在路上，顶上那条「正在更新…」该在');

      repository.open(1);
      await pumpEventQueue();

      final done = container.read(newsListProvider).value!;
      expect(done.all.map((a) => a.title), <String>['先回来的源', '慢的源']);
      expect(done.updating, isFalse, reason: '整轮完了要把「正在更新…」收掉');
    });

    test('刷新也是分层的：回来一块画一块，await 完才是整轮完了', () async {
      final repository = FakeNewsRepository(<NewsArticle>[
        fakeArticle(id: 'old', title: '上一份'),
      ]);
      final container = containerWith(repository);
      await container.read(newsListProvider.future);

      repository
        ..batches = <List<NewsArticle>>[
          <NewsArticle>[fakeArticle(id: 'a1', title: '第一批')],
          <NewsArticle>[fakeArticle(id: 'a2', title: '第二批', source: 'sspai')],
        ]
        ..gates[1] = Completer<void>();

      final refreshing = container.read(newsListProvider.notifier).refresh();
      await pumpEventQueue();

      final during = container.read(newsListProvider).value!;
      expect(during.all.map((a) => a.title), <String>[
        '第一批',
      ], reason: '刷新不是「等全部回来再一起换」');
      expect(during.updating, isTrue);

      repository.open(1);
      await refreshing;

      final after = container.read(newsListProvider).value!;
      expect(after.all.map((a) => a.title), <String>['第一批', '第二批']);
      expect(after.updating, isFalse);
    });

    test('抓一半的时候「该更新了吗」不会把这一轮掐掉重来', () async {
      final repository =
          FakeNewsRepository(
              <NewsArticle>[fakeArticle(id: 'a1', title: '第一条')],
              // 时间戳是 0 = 该更新（不然这条用例自动跳过刷新）
              cachedAtMillis: 0,
            )
            ..batches = <List<NewsArticle>>[
              <NewsArticle>[fakeArticle(id: 'a1', title: '第一条')],
              <NewsArticle>[
                fakeArticle(id: 'a2', title: '第二条', source: 'sspai'),
              ],
            ]
            ..gates[1] = Completer<void>();
      final container = containerWith(repository);
      await container.read(newsListProvider.future);
      expect(repository.fetchCount, 1);

      await container.read(newsListProvider.notifier).refreshIfStale();

      expect(
        repository.fetchCount,
        1,
        reason: '第一块是回来了，但后面的源还在路上 —— 从头再拉一轮只会把剩下的源掐掉',
      );

      repository.open(1);
      await pumpEventQueue();
      expect(container.read(newsListProvider).value!.all, hasLength(2));
    });
  });

  test('刷新不动已经展开的号：点开成 13 条了，刷完还是 13 条', () async {
    final repository = FakeNewsRepository(<NewsArticle>[
      for (var index = 0; index < 20; index++)
        fakeArticle(id: 'a$index', title: '第 $index 条'),
    ]);
    final container = containerWith(repository);
    await container.read(newsListProvider.future);
    container.read(newsListProvider.notifier).expand('ithome');
    expect(
      container.read(newsListProvider).value!.visibleOf('ithome'),
      NewsListState.defaultPerSource + NewsListState.expandStep,
    );

    await container.read(newsListProvider.notifier).refresh();

    expect(
      container.read(newsListProvider).value!.visibleOf('ithome'),
      NewsListState.defaultPerSource + NewsListState.expandStep,
      reason: '每半小时自动刷一次，不该把用户点开的卡片又缩回去',
    );
  });

  test('刷新的那一刻页面拿到的还是旧内容（不切成 loading，才不闪）', () async {
    final repository = FakeNewsRepository(<NewsArticle>[
      fakeArticle(id: 'a1', title: '第一条'),
    ], fetchDelay: const Duration(milliseconds: 30));
    final container = containerWith(repository);
    await container.read(newsListProvider.future);

    final pending = container.read(newsListProvider.notifier).refresh();

    final during = container.read(newsListProvider);
    expect(during.hasValue, isTrue, reason: '刷新期间也得有内容可画');
    expect(during.value!.updating, isTrue, reason: '但要说一句「正在更新…」');
    expect(during.value!.all.single.title, '第一条');
    await pending;
    expect(container.read(newsListProvider).value!.updating, isFalse);
  });
}
