import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/net/api_exception.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/domain/news/news_article.dart';
import 'package:gracelinkim/domain/news/news_feed.dart';
import 'package:gracelinkim/domain/news/news_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 资讯仓库：并发抓取、**单源容错**、断网回读缓存、已读标记、上限裁剪。
///
/// 走真实的 [NewsRepository] + 假 adapter（只换掉网络那层），所以这里验的就是
/// 线上那套逻辑：一个源挂掉不能让整页没内容，**全部**源都挂才轮到缓存。
///
/// 用例尽量不写死「几个源」（2026-09-30 从 4 个扩到 11 个时，写死数量的就得
/// 全部改一遍）—— 要几个源就看 `kNewsFeeds`。
void main() {
  late CredentialStore store;
  late _FakeAdapter adapter;
  late Dio dio;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    store = await CredentialStore.init();
    adapter = _FakeAdapter();
    dio = Dio()
      ..options = BaseOptions(responseType: ResponseType.plain)
      ..httpClientAdapter = adapter;
  });

  NewsRepository build() => NewsRepository(dio: dio, store: store);

  /// 一个只带一条新闻的最小 RSS
  String feedXml({
    required String title,
    required String link,
    String date = 'Tue, 29 Sep 2026 23:25:25 +0800',
  }) =>
      '<rss version="2.0"><channel><title>x</title><item>'
      '<title>$title</title><link>$link</link><pubDate>$date</pubDate>'
      '</item></channel></rss>';

  /// 造一个「源里有 N 条」的报文（时间递减：第 0 条最新）
  String many(String prefix, int count) {
    final items = StringBuffer();
    for (var index = 0; index < count; index++) {
      final hour = (22 - index).toString().padLeft(2, '0');
      items
        ..write('<item><title>$prefix-$index</title>')
        ..write('<link>https://a.test/$prefix/$index</link>')
        ..write('<pubDate>Tue, 29 Sep 2026 $hour:00:00 +0800</pubDate>')
        ..write('</item>');
    }
    return '<rss version="2.0"><channel><title>x</title>$items</channel></rss>';
  }

  /// 按 URL 分别回答（源 key → 报文）；返回 null 的源＝超时
  void serve(Map<String, String?> byUrl) {
    adapter.handler = (options) async {
      final payload = byUrl[options.uri.toString()];
      if (payload == null) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionTimeout,
        );
      }
      return ResponseBody.fromString(
        payload,
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['application/xml; charset=utf-8'],
        },
      );
    };
  }

  String urlOf(String key) =>
      kNewsFeeds.firstWhere((feed) => feed.key == key).url;

  test('所有源都成功：合并成一份，源间轮转，没有失败的源', () async {
    // 每个源各给一条（时间是乱的，反正源间轮转时**不看时间**）
    serve(<String, String?>{
      for (final feed in kNewsFeeds)
        feed.url: feedXml(
          title: '${feed.key} 的新闻',
          link: 'https://a.test/${feed.key}/1',
          date:
              'Tue, 29 Sep 2026 ${(20 - kNewsFeeds.indexOf(feed)).toString().padLeft(2, '0')}:00:00 +0800',
        ),
    });

    final result = await build().fetch();

    expect(result.failedFeeds, isEmpty);
    expect(result.fromCache, isFalse);
    expect(
      result.articles.map((article) => article.title),
      kNewsFeeds.map((feed) => '${feed.key} 的新闻'),
      reason: '每个源各一条时，顺序就是源在 kNewsFeeds 里的顺序（源间轮转）',
    );
    expect(result.articles.first.sourceKey, kNewsFeeds.first.key);
    expect(
      adapter.requested,
      hasLength(kNewsFeeds.length),
      reason: '每个源并发各拉一次',
    );
  });

  test('一个源超时、一个源返回 WAF 拦截页：别的源照常出内容', () async {
    serve(<String, String?>{
      urlOf('ithome'): feedXml(title: '活着的源', link: 'https://a.test/i1'),
      urlOf('sspai'): '<html><body><p>为保障您的访问安全，系统正在检测当前网络环境</p></body></html>',
      // 其余源都不在表里 → 超时
    });

    final result = await build().fetch();

    expect(result.articles.map((a) => a.title), <String>['活着的源']);
    expect(
      result.failedFeeds,
      containsAll(<String>['sspai', 'ifanr', 'solidot']),
      reason: 'HTTP 200 但解析出 0 条（拦截页）也算这个源这次没拉到',
    );
    expect(
      result.failedFeeds,
      hasLength(kNewsFeeds.length - 1),
      reason: '除了成功的那个，其余全是「这次没拉到」',
    );
  });

  test('全部源都挂：回读上次抓到的缓存，并标成 fromCache', () async {
    // 先成功抓一次，把缓存写进去
    serve(<String, String?>{
      urlOf('ithome'): feedXml(title: '第一次抓到的', link: 'https://a.test/i1'),
    });
    final first = await build().fetch();
    expect(first.articles, hasLength(1));

    // 现在全断网
    serve(<String, String?>{});
    final second = await build().fetch();

    expect(second.fromCache, isTrue);
    expect(second.articles.map((a) => a.title), <String>['第一次抓到的']);
    expect(second.failedFeeds, hasLength(kNewsFeeds.length));
  });

  test('全部源都挂且没有缓存：抛「网络不可用」，页面才有得提示', () async {
    serve(<String, String?>{});

    await expectLater(
      build().fetch(),
      throwsA(isA<NetworkUnavailableException>()),
    );
  });

  /// 分层加载（S12.2，用户 2026-09-30：「哪个源先回来先铺哪几条，不再等最慢的那个」）。
  ///
  /// 验的是「吐的节奏」：老做法 `fetch()` 等 12 个源全回来才有一份，最慢的那个
  /// （超时 12 秒）把整页拖在转圈上。
  group('一块一块地吐', () {
    /// 等到手上攒够 [count] 帧（多让几个事件循环转一圈）
    Future<void> waitFrames(List<NewsFetchResult> frames, int count) async {
      for (var turn = 0; turn < 500 && frames.length < count; turn++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    /// 让某个源回答之前先卡住（真网络里就是它慢）
    void hold(
      String holdKey,
      Map<String, String?> byUrl,
      Completer<void> gate,
    ) {
      adapter.handler = (options) async {
        final url = options.uri.toString();
        if (url == urlOf(holdKey)) await gate.future;
        final payload = byUrl[url];
        if (payload == null) {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionTimeout,
          );
        }
        return ResponseBody.fromString(
          payload,
          200,
          headers: <String, List<String>>{
            Headers.contentTypeHeader: <String>[
              'application/xml; charset=utf-8',
            ],
          },
        );
      };
    }

    test('慢的还挂着，快的已经吐了一帧', () async {
      final gate = Completer<void>();
      hold('sspai', <String, String?>{
        urlOf('ithome'): feedXml(title: '快的源', link: 'https://a.test/i1'),
        // sspai 卡着；其余源都不在表里 → 立刻超时
      }, gate);

      final frames = <NewsFetchResult>[];
      final done = build().fetchStream().listen(frames.add).asFuture<void>();
      await waitFrames(frames, 1);

      expect(frames, hasLength(1), reason: '快的那个源已经到手，而 sspai 还挂着');
      expect(frames.single.articles.map((a) => a.title), <String>['快的源']);
      expect(
        frames.single.failedFeeds,
        isNot(contains('sspai')),
        reason: '还在路上的源不算失败（空手回来的源也不会多吐一帧）',
      );

      gate.complete();
      await done;

      expect(
        frames.last.articles.map((a) => a.title),
        <String>['快的源'],
        reason: 'sspai 回来后是空的（没给它报文），所以最后一份里也只有快的那条',
      );
    });

    test('中间那几帧不落盘：磁盘上始终是一份完整的快照', () async {
      final gate = Completer<void>();
      hold('sspai', <String, String?>{
        urlOf('ithome'): feedXml(title: '快的源', link: 'https://a.test/i1'),
      }, gate);

      final repository = build();
      final frames = <NewsFetchResult>[];
      final done = repository.fetchStream().listen(frames.add).asFuture<void>();
      await waitFrames(frames, 1);

      expect(frames, hasLength(1));
      expect(
        repository.cachedAt(),
        0,
        reason: '第一帧就写盘的话，缓存会被一个只回了 3 条的源盖成一页残废的列表',
      );

      gate.complete();
      await done;

      expect(repository.cachedAt(), greaterThan(0), reason: '整轮跑完才写');
      expect(repository.cachedArticles().map((a) => a.title), <String>['快的源']);
    });

    test('还没回来的源先拿缓存顶上：列表不会在第一帧到达时突然变少', () async {
      // 第一轮：两个源各一条，进缓存
      serve(<String, String?>{
        urlOf('ithome'): feedXml(title: '旧的 IT', link: 'https://a.test/i/old'),
        urlOf('sspai'): feedXml(title: '旧的派', link: 'https://a.test/p/old'),
      });
      await build().fetch();

      // 第二轮：ithome 换了新内容，sspai 卡着不回
      final gate = Completer<void>();
      hold('sspai', <String, String?>{
        urlOf('ithome'): feedXml(title: '新的 IT', link: 'https://a.test/i/new'),
      }, gate);

      final frames = <NewsFetchResult>[];
      final done = build().fetchStream().listen(frames.add).asFuture<void>();
      await waitFrames(frames, 1);

      expect(
        frames.single.articles.map((a) => a.title),
        <String>['新的 IT', '旧的派'],
        reason: 'sspai 还没回答 → 先拿缓存那条顶着；不然页面会从「两条」缩成「一条」',
      );
      expect(
        frames.single.articles.map((a) => a.title),
        isNot(contains('旧的 IT')),
        reason: '已经用新内容回答过的源，它缓存里那几行不再顶位',
      );

      gate.complete();
      await done;

      expect(
        frames.last.articles.map((a) => a.title),
        <String>['新的 IT', '旧的派'],
        reason:
            'sspai 这一轮空手回来（超时/拦截页都算）→ 它缓存那一条继续顶着，'
            '不会因为「这个源今天挂了」就突然空一块',
      );
    });

    test('已读的小圆点在每一帧上都在（不闪一下又回来）', () async {
      serve(<String, String?>{
        urlOf('ithome'): feedXml(title: '读过的', link: 'https://a.test/i/read'),
      });
      final repository = build();
      final first = await repository.fetch();
      expect(await repository.markRead(first.articles.single.id), isTrue);

      // 第二轮：ithome 卡着（它那一条只能用缓存顶位），sspai 先回来
      final gate = Completer<void>();
      hold('ithome', <String, String?>{
        urlOf('sspai'): feedXml(title: '新来的', link: 'https://a.test/p/new'),
      }, gate);

      final frames = <NewsFetchResult>[];
      final done = repository.fetchStream().listen(frames.add).asFuture<void>();
      await waitFrames(frames, 1);

      final read = frames.single.articles.firstWhere(
        (article) => article.title == '读过的',
      );
      expect(read.read, isTrue, reason: '中间那几帧也得贴已读状态，不然列表里的小圆点会闪一下又回来');

      gate.complete();
      await done;
    });
  });

  test('updatedAt 用的是抓取时间（缓存没写过就是 0）', () async {
    final repository = build();
    expect(repository.cachedAt(), 0);

    serve(<String, String?>{
      urlOf('ithome'): feedXml(title: '一条', link: 'https://a.test/i1'),
    });
    final before = DateTime.now().millisecondsSinceEpoch;
    await repository.fetch();

    expect(repository.cachedAt(), greaterThanOrEqualTo(before));
  });

  test('封面：feed 没图时才去原文页挖，而且标记了「不要页内封面」的源连请求都不发', () async {
    final repository = build();
    // 用户自己那个协会通知网：site123 把 og:image 写成全站同一张头图，
    // 抓回来会变成「这个号的每篇文章贴着同一张图」
    final feed = kNewsFeeds.firstWhere((item) => !item.pageCovers);
    final article = NewsArticle(
      id: 'x1',
      title: '一条通知',
      link: 'https://notice.test/1',
      sourceKey: feed.key,
      summary: '',
    );

    expect(await repository.resolveCover(article), isEmpty);
    expect(adapter.requested, isEmpty, reason: '连页面都不该去拉');
  });

  test('已读：标过之后缓存里那一条也是已读，重复标不再写盘', () async {
    serve(<String, String?>{
      urlOf('ithome'): feedXml(title: '一条', link: 'https://a.test/i1'),
    });
    final repository = build();
    final result = await repository.fetch();
    final id = result.articles.single.id;

    expect(result.articles.single.read, isFalse, reason: '新拉的默认未读');
    expect(await repository.markRead(id), isTrue);
    expect(await repository.markRead(id), isFalse, reason: '本来就已读，不用再写一次');
    expect(repository.cachedArticles().single.read, isTrue);
    expect(repository.readIds(), contains(id));
  });

  test('按源轮转：IT之家发得再多也不会连着刷屏（用户 2026-09-30 的要求）', () async {
    // IT之家 6 条、少数派 2 条，纯按时间排的话前 6 条全是 IT之家
    serve(<String, String?>{
      urlOf('ithome'): many('IT', 6),
      urlOf('sspai'): many('派', 2),
    });

    final result = await build().fetch();
    final sources = result.articles.map((a) => a.sourceKey).toList();

    expect(sources.take(4).toList(), <String>[
      'ithome',
      'sspai',
      'ithome',
      'sspai',
    ], reason: '源之间轮流取一条');
    expect(
      sources.where((key) => key == 'ithome').length,
      6,
      reason: 'IT之家这 6 条一条都不丢，只是被别的源隔开了',
    );
    // 源内部仍然按时间倒序
    final ithome = result.articles
        .where((a) => a.sourceKey == 'ithome')
        .toList();
    expect(ithome.first.title, 'IT-0');
  });

  test('源自己的顺序稳定：同样的内容刷新两次排出来一样', () async {
    serve(<String, String?>{
      urlOf('ithome'): many('IT', 3),
      urlOf('ifanr'): many('范', 3),
      urlOf('sspai'): many('派', 3),
    });

    final first = await build().fetch();
    final second = await build().fetch();

    expect(
      first.articles.map((a) => a.title),
      second.articles.map((a) => a.title),
    );
  });

  test('缓存里的坏数据不会让整页崩（上一版 App 写的 / 手改过的）', () async {
    await store.setJson(NewsRepository.keyCache, <String, dynamic>{
      'fetchedAt': 1,
      'items': <dynamic>[
        <String, dynamic>{'id': 'a', 'title': '好的', 'link': 'https://a.test/1'},
        <String, dynamic>{'id': 'b', 'title': ''}, // 没标题
        'not-a-map',
      ],
    });

    final cached = build().cachedArticles();

    expect(cached.map((article) => article.title), <String>['好的']);
  });

  test('已读 id 只留最近 300 条（键值不会无限长）', () async {
    final repository = build();
    for (var index = 0; index < NewsRepository.maxReadIds + 20; index++) {
      await repository.markRead('id-$index');
    }

    final read = repository.readIds();
    expect(read, hasLength(NewsRepository.maxReadIds));
    expect(read, contains('id-${NewsRepository.maxReadIds + 19}'));
    expect(read, isNot(contains('id-0')), reason: '最早的那批被挤掉');
  });
}

/// 假的 HTTP 层：只换掉「发请求」这一步，其余（Dio 的解码、重定向之外的行为）
/// 还是真的 —— 这样测的是真实代码路径。
class _FakeAdapter implements HttpClientAdapter {
  Future<ResponseBody> Function(RequestOptions options) handler = (_) async =>
      throw UnimplementedError('用例没给 handler');

  /// 请求过的地址，用来验「每个源都拉了一遍」
  final List<String> requested = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    requested.add(options.uri.toString());
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}
