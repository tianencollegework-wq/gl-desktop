import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/platform/desktop_shell.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/lingting_store.dart';
import 'package:gracelinkim/data/repo/lingting_repository.dart';
import 'package:gracelinkim/domain/news/news_article.dart';
import 'package:gracelinkim/domain/news/news_card.dart';
import 'package:gracelinkim/domain/news/news_providers.dart';
import 'package:gracelinkim/features/desktop_window/child_window_app.dart';
import 'package:gracelinkim/features/desktop_window/window_args.dart';
import 'package:gracelinkim/features/lingting/lingting_home_page.dart';
import 'package:gracelinkim/features/news/news_detail_page.dart';
import 'package:gracelinkim/features/news/news_list_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_lingting.dart';
import '../support/fake_news.dart';

/// 桌面「系统级独立窗口」（第二颗引擎）里那套东西（2026-10-04，S12.23）。
///
/// 这颗引擎里没有主窗口那份容器，所以这一套钉的是**它自己那份最小环境**：
/// 参数怎么递进来、窗口自己的样子（标题/大小/居中/显形）谁去设、
/// 点 ✕ 之后收什么尾、以及窗口里那两张界面到底画出来没有。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await LingtingStore.init();
    await AppI18n.load('zh-Hans');
  });

  group('窗口参数（主窗口 ↔ 子引擎那根线）', () {
    test('文章参数编/解一圈还在（标题里的中文与符号都活着）', () {
      const args = DesktopWindowArgs.article(
        id: 'https://sspai.com/post/1',
        title: '朋友分享来的「新闻」· 第 2 期',
      );
      final back = DesktopWindowArgs.decode(args.encode());

      expect(back, isNotNull);
      expect(back!.kind, DesktopWindowKind.article);
      expect(back.id, 'https://sspai.com/post/1');
      expect(back.title, '朋友分享来的「新闻」· 第 2 期');
    });

    test('卡片本体跟着参数走：那边本机没这一篇也能渲染', () {
      const card = NewsCard(
        id: 'n-1',
        title: '卡片里的标题',
        sourceKey: 'sspai',
        summary: '卡片里带的摘要。',
        link: 'https://sspai.com/post/1',
      );
      final back = DesktopWindowArgs.decode(
        const DesktopWindowArgs.article(
          id: 'n-1',
          title: '卡片里的标题',
          shared: card,
        ).encode(),
      );

      expect(back!.shared, isNotNull);
      expect(back.shared!.id, 'n-1');
      expect(back.shared!.title, '卡片里的标题');
      expect(back.shared!.summary, '卡片里带的摘要。');
      expect(back.shared!.sourceKey, 'sspai');
      expect(back.shared!.link, 'https://sspai.com/post/1');
    });

    test('灵听参数：只有 kind 与标题', () {
      final back = DesktopWindowArgs.decode(
        const DesktopWindowArgs.lingting(title: '灵听').encode(),
      );

      expect(back!.kind, DesktopWindowKind.lingting);
      expect(back.title, '灵听');
      expect(back.id, isEmpty);
      expect(back.shared, isNull);
    });

    test('不是窗口进程 → null（主窗口照常启动，参数别乱认）', () {
      expect(DesktopWindowArgs.decode(''), isNull);
      expect(DesktopWindowArgs.decode('--gracelink-spike-auto'), isNull);
      expect(DesktopWindowArgs.decode('gracelink://不知道什么东西'), isNull);
      expect(DesktopWindowArgs.decode('https://message.gracelink.cc'), isNull);
    });

    test('从进程参数里挑窗口参数（子引擎拿到的是 [multi_window, id, 参数]）', () {
      final args = const DesktopWindowArgs.lingting(title: '灵听');
      final picked = windowArgsOf(<String>[
        'multi_window',
        'b6a1-窗口-id',
        args.encode(),
      ]);

      expect(picked, isNotNull);
      expect(picked!.kind, DesktopWindowKind.lingting);
      expect(windowArgsOf(<String>['multi_window']), isNull);
      expect(windowArgsOf(const <String>[]), isNull);
    });

    test('卡片参数坏了只当没有卡片，不影响这颗窗口能不能开', () {
      final back = DesktopWindowArgs.decode(
        'gracelink://article?id=n-1&title=x&card=%7Bnot-json',
      );

      expect(back, isNotNull);
      expect(back!.id, 'n-1');
      expect(back.shared, isNull);
    });
  });

  group('子窗口自己那份界面', () {
    /// native 通道（标题/大小/居中/显形）收到过什么
    Future<List<MethodCall>> pumpChild(
      WidgetTester tester,
      DesktopWindowArgs args, {
      FakeNewsRepository? news,
      FakeLingtingRepository? lingting,
      Size windowSize = const Size(520, 700),
    }) async {
      final nativeCalls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('gracelinkim/child_window'),
        (call) async {
          nativeCalls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('gracelinkim/child_window'),
          null,
        ),
      );
      // 主窗口那条 IPC 通道也得应一声：真实环境下它由插件提供，
      // 测试里没人应答的话 `setMethodCallHandler` 会一直等。
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('mixin.one/desktop_multi_window/channels'),
        (call) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('mixin.one/desktop_multi_window/channels'),
          null,
        ),
      );

      tester.view.physicalSize = windowSize;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            // 与真实现一致：窗口里按手机版式排（见 `runDesktopChildWindow`）
            desktopFeaturesProvider.overrideWithValue(false),
            // 宽度封顶那只壳也一致：它默认跟着桌面功能开关走，而那个开关
            // 在窗口里（以及测试环境）是关的
            desktopShellProvider.overrideWithValue(true),
            if (news != null) newsRepositoryProvider.overrideWithValue(news),
            if (lingting != null)
              lingtingRepositoryProvider.overrideWithValue(lingting),
          ],
          child: DesktopChildRoot(args: args),
        ),
      );
      await tester.pumpAndSettle();
      return nativeCalls;
    }

    testWidgets('文章窗：标题 / 大小 / 居中先就绪，最后才显形（不闪默认那一下）', (tester) async {
      final calls = await pumpChild(
        tester,
        const DesktopWindowArgs.article(id: 'n-1', title: '一篇文章'),
        news: FakeNewsRepository(const []),
      );

      expect(
        calls.map((call) => call.method).toList(),
        <String>['setTitle', 'setSize', 'center', 'show'],
        reason: '顺序要紧：先设好样子再显形，不能先闪一下原生的 800×600',
      );
      expect(calls.first.arguments, '一篇文章');
      expect(calls[1].arguments, <String, double>{'w': 560, 'h': 720});
    });

    testWidgets('文章窗：停在那一篇上，列表还在（返回箭头能翻回去）', (tester) async {
      final repository = FakeNewsRepository(<NewsArticle>[
        fakeArticle(id: 'n-1', title: '列表里那一条', source: 'sspai'),
        fakeArticle(id: 'n-2', title: '另一条', source: 'sspai'),
      ]);

      await pumpChild(
        tester,
        const DesktopWindowArgs.article(id: 'n-1', title: '列表里那一条'),
        news: repository,
      );

      expect(find.byType(NewsDetailPage), findsOneWidget);
      // 列表还在栈里（被详情页盖住，所以 skipOffstage: false 才找得到）：
      // 窗口里那支返嚘箭头能回到列表，而不是点一下就回不去
      expect(
        find.byType(NewsListPage, skipOffstage: false),
        findsOneWidget,
        reason: '列表在详情页下面等着返回',
      );
      expect(find.text('列表里那一条'), findsWidgets);
    });

    testWidgets('文章窗：本机没有这一篇时，用卡片里那份渲染', (tester) async {
      await pumpChild(
        tester,
        const DesktopWindowArgs.article(
          id: 'n-9',
          title: '朋友分享来的新闻',
          shared: NewsCard(
            id: 'n-9',
            title: '朋友分享来的新闻',
            sourceKey: 'sspai',
            summary: '卡片里带的摘要。',
            link: 'https://sspai.com/post/9',
          ),
        ),
        news: FakeNewsRepository(const []),
      );

      expect(find.byType(NewsDetailPage), findsOneWidget);
      expect(find.text('朋友分享来的新闻'), findsWidgets);
      expect(find.text('卡片里带的摘要。'), findsOneWidget);
      expect(find.text('阅读原文'), findsOneWidget);
    });

    testWidgets('灵听窗：整条频道就开在窗口里，标题是「灵听」', (tester) async {
      final api = FakeLingtingApi();
      final calls = await pumpChild(
        tester,
        const DesktopWindowArgs.lingting(title: '灵听'),
        lingting: FakeLingtingRepository(api),
      );

      expect(find.byType(LingtingHomePage), findsOneWidget);
      expect(calls.first.arguments, '灵听');
    });

    testWidgets('主窗口塞一篇新的进来：窗口里换掉那一页（返回不会越翻越深）', (tester) async {
      final repository = FakeNewsRepository(<NewsArticle>[
        fakeArticle(id: 'n-1', title: '第一篇', source: 'sspai'),
        fakeArticle(id: 'n-2', title: '第二篇', source: 'sspai'),
      ]);

      await pumpChild(
        tester,
        const DesktopWindowArgs.article(id: 'n-1', title: '第一篇'),
        news: repository,
      );
      expect(find.byType(NewsDetailPage), findsOneWidget);

      // 主窗口那条线递过来的就是这一个消息（见插件 window_channel.dart）：
      // `open_article` 让这颗窗口自己换成那一篇（一个 kind 只开一颗窗口）。
      // 这里**不 await** 这条注入：窗口那头要转一个 `Future.delayed(Duration.zero)`
      // （让路由先落定），而测试里的定时器要靠 pump 才走 —— await 下去就卡死。
      unawaited(
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'mixin.one/desktop_multi_window/channels',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('methodCall', <String, dynamic>{
              'channel': 'gracelink/window/article',
              'method': 'open_article',
              'arguments': <String, dynamic>{'id': 'n-2', 'title': '第二篇'},
            }),
          ),
          (_) {},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('第二篇'), findsWidgets, reason: '换成了那一篇');
      expect(
        find.byType(NewsDetailPage),
        findsOneWidget,
        reason: '是**换掉**不是又推一层：从文章返回应该回列表，不是回上一篇',
      );
      expect(
        find.byType(NewsListPage, skipOffstage: false),
        findsOneWidget,
        reason: '列表仍在栈里等着返回',
      );
    });

    testWidgets('窗口被拉到很宽（最大化）：内容封顶居中，版式不跟着胀大', (tester) async {
      final api = FakeLingtingApi();
      await pumpChild(
        tester,
        const DesktopWindowArgs.lingting(title: '灵听'),
        lingting: FakeLingtingRepository(api),
        windowSize: const Size(1600, 1000),
      );

      expect(find.byType(DesktopShell), findsOneWidget);
      final page = tester.getRect(find.byType(LingtingHomePage));
      // 封顶在这颗窗口默认那档宽度（520）：`rpx` 就是按它算的，
      // 所以字号、图标、间距都还是默认大小 —— 用户报的「全屏后变形」就是
      // 没这一道时 rpx 一路涨到 2 倍多，竖版排不下、播放键被挤出窗沿
      expect(page.width, lessThanOrEqualTo(520.5));
      expect(page.center.dx, closeTo(800, 1), reason: '封顶之后居中摆');
    });

    testWidgets('媒体号窗：列表开在窗口里，点进去的文章在这颗窗口里往下推', (tester) async {
      final repository = FakeNewsRepository(<NewsArticle>[
        fakeArticle(id: 'n-1', title: '列表里那一条', source: 'sspai'),
      ]);

      final calls = await pumpChild(
        tester,
        const DesktopWindowArgs.news(title: '媒体号'),
        news: repository,
      );

      expect(find.byType(NewsListPage), findsOneWidget);
      expect(find.text('列表里那一条'), findsWidgets);
      expect(calls.map((call) => call.method).toList(), <String>[
        'setTitle',
        'setSize',
        'center',
        'show',
      ]);
      expect(calls[1].arguments, <String, double>{'w': 560, 'h': 760});

      // 窗口里点一篇文章：就在这颗窗口里推详情（子引擎里桌面功能是关的，
      // 所以不会再去开第三颗窗口）
      await tester.tap(find.text('列表里那一条').first);
      await tester.pumpAndSettle();
      expect(find.byType(NewsDetailPage), findsOneWidget);
    });
  });
}
