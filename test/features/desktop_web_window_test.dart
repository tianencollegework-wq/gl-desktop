import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/platform/desktop_shell.dart';
import 'package:gracelinkim/core/platform/webview_host.dart';
import 'package:gracelinkim/core/router/app_router.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/lingting_store.dart';
import 'package:gracelinkim/core/ui/link_opener.dart';
import 'package:gracelinkim/domain/news/news_article.dart';
import 'package:gracelinkim/domain/news/news_card.dart';
import 'package:gracelinkim/domain/news/news_providers.dart';
import 'package:gracelinkim/features/common/link_confirm_page.dart';
import 'package:gracelinkim/features/common/not_found_page.dart';
import 'package:gracelinkim/features/common/webview_page.dart';
import 'package:gracelinkim/features/desktop_window/child_window_app.dart';
import 'package:gracelinkim/features/desktop_window/desktop_link_window.dart';
import 'package:gracelinkim/features/desktop_window/desktop_window_service.dart';
import 'package:gracelinkim/features/desktop_window/web_tabs.dart';
import 'package:gracelinkim/features/desktop_window/window_args.dart';
import 'package:gracelinkim/features/news/news_detail_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_news.dart';

/// 桌面「网页窗」（2026-10-04）：外链不再丢给系统浏览器，而是开一扇自己的窗口，
/// 窗口里是真 webview（WebView2，见 `core/platform/webview_host.dart`）。
///
/// 这一套钉三件事：
/// * **参数**：地址（带 query、带中文）能原样递到子引擎；
/// * **媒体号窗里点「阅读原文」不再是 404** —— 用户 2026-10-04 报的那条：
///   那颗引擎当时只挂了资讯那两条路由，而「阅读原文」会推到外链闸门页；
/// * **「继续访问」的去处**：桌面交给网页窗（本窗那一页收掉），
///   手机 / 开关关着时还是老样子（在应用内换成内嵌浏览器那一页）。
///
/// 真窗口本身（第二颗引擎、WebView2 画没画出来）不在组件测试里验，那要实机。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await LingtingStore.init();
    await AppI18n.load('zh-Hans');
  });

  group('窗口参数', () {
    test('web 参数编/解一圈还在（地址里的 & 与中文都活着）', () {
      const url =
          'https://www.cnbeta.com.tw/articles/game/1580704.htm?from=群&x=1';
      const args = DesktopWindowArgs.web(url: url, title: 'www.cnbeta.com.tw');

      final back = DesktopWindowArgs.decode(args.encode());

      expect(back, isNotNull);
      expect(back!.kind, DesktopWindowKind.web);
      expect(back.url, url);
      expect(back.title, 'www.cnbeta.com.tw');
      // 网页窗没有文章 id / 卡片那一套
      expect(back.id, isEmpty);
      expect(back.shared, isNull);
    });

    test('网页窗顶上那行字就是域名；拿不到就给空串（别写「unknown」给用户看）', () {
      expect(webWindowTitleOf('https://a.example.com/x?y=1'), 'a.example.com');
      expect(webWindowTitleOf(''), '');
      expect(webWindowTitleOf('这不是一个网址'), '');
    });
  });

  group('媒体号窗里点「阅读原文」', () {
    /// 子引擎那份最小环境 + 假的主窗口那条线。
    ///
    /// overrides 那一串与 `runDesktopChildWindow()` 保持一致（窗口里手机版式、
    /// 但「点外链去哪儿」那条是开的）—— 不照着写，这一套就验不到真行为。
    Future<_FakeWindowService> pumpChild(
      WidgetTester tester,
      DesktopWindowArgs args, {
      required FakeNewsRepository news,
    }) async {
      final service = _FakeWindowService();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('gracelinkim/child_window'),
        (call) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('gracelinkim/child_window'),
          null,
        ),
      );
      // 主窗口那条 IPC 通道也得应一声（真机上它由插件提供）
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

      tester.view.physicalSize = const Size(560, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            desktopFeaturesProvider.overrideWithValue(false),
            desktopShellProvider.overrideWithValue(true),
            desktopLinkWindowProvider.overrideWithValue(true),
            newsRepositoryProvider.overrideWithValue(news),
            desktopWindowServiceProvider.overrideWithValue(service),
          ],
          child: DesktopChildRoot(args: args),
        ),
      );
      await tester.pumpAndSettle();
      return service;
    }

    testWidgets('外链闸门页在这颗引擎里（不再 Page Not Found），确认后交给网页窗', (tester) async {
      const link = 'https://www.cnbeta.com.tw/articles/game/1580704.htm';
      final news = FakeNewsRepository(<NewsArticle>[
        fakeArticle(id: 'n-1', title: '一条资讯', link: link),
      ]);

      final service = await pumpChild(
        tester,
        const DesktopWindowArgs.news(title: '媒体号'),
        news: news,
      );

      // 列表 → 详情 → 阅读原文（第三方站点 → 先过确认页）
      await tester.tap(find.text('一条资讯').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('阅读原文'));
      await tester.pumpAndSettle();

      expect(
        find.byType(RouteNotFoundPage),
        findsNothing,
        reason: '用户 2026-10-04 看到的那一页：子引擎里没挂外链那三页',
      );
      expect(find.byType(LinkConfirmPage), findsOneWidget);
      expect(find.text('网页由 www.cnbeta.com.tw 提供'), findsOneWidget);

      // 「继续访问」→ 开一扇**独立的网页窗**（子引擎自己也能开窗）
      await tester.tap(find.text('继续访问'));
      await tester.pumpAndSettle();

      expect(service.calls, <String>['web:$link:www.cnbeta.com.tw']);
      expect(
        find.byType(NewsDetailPage),
        findsOneWidget,
        reason: '确认页自己收掉了：网页在另一扇窗口里，这里回到那篇文章上',
      );
    });
  });

  group('确认页「继续访问」的两个去处', () {
    const link = 'https://www.cnbeta.com.tw/articles/game/1580704.htm';

    /// 单独把确认页摆起来（右边那条路由用来验「没开窗时换成了哪一页」）。
    Future<_FakeWindowService> pumpConfirm(
      WidgetTester tester, {
      required bool desktopLinkWindow,
    }) async {
      final service = _FakeWindowService();
      // 确认页比默认那个 800×600 的测试窗口高（那颗钮在最下面一块）——
      // 窗口矮了它就落在视口外面，`tap` 会打空
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final router = GoRouter(
        initialLocation:
            '${AppRoutes.linkConfirm}?url=${Uri.encodeComponent(link)}',
        routes: <RouteBase>[
          GoRoute(
            path: AppRoutes.linkConfirm,
            builder: (context, state) =>
                LinkConfirmPage(url: state.uri.queryParameters['url'] ?? ''),
          ),
          GoRoute(
            path: AppRoutes.webview,
            builder: (context, state) => WebViewPage(
              title: state.uri.queryParameters['title'] ?? '',
              src: state.uri.queryParameters['src'] ?? '',
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            desktopLinkWindowProvider.overrideWithValue(desktopLinkWindow),
            desktopWindowServiceProvider.overrideWithValue(service),
            // 真机上这块是平台视图（测试里建 WebViewController 会直接抛）
            webViewHostProvider.overrideWithValue(_FakeWebViewHost()),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      return service;
    }

    testWidgets('桌面：交给网页窗，本窗不换成网页那一页', (tester) async {
      final service = await pumpConfirm(tester, desktopLinkWindow: true);

      await tester.tap(find.text('继续访问'));
      await tester.pumpAndSettle();

      expect(service.calls, <String>['web:$link:www.cnbeta.com.tw']);
      expect(find.byType(WebViewPage), findsNothing);
    });

    testWidgets('手机 / 开关关着：还是把这一页换成内嵌浏览器那一页', (tester) async {
      final service = await pumpConfirm(tester, desktopLinkWindow: false);

      await tester.tap(find.text('继续访问'));
      await tester.pumpAndSettle();

      expect(service.calls, isEmpty, reason: '这条路不碰窗口');
      expect(find.byType(WebViewPage), findsOneWidget);
      expect(find.text('FAKE-WEBVIEW:$link'), findsOneWidget);
    });
  });

  group('内嵌浏览器那一页（/mine/webview）', () {
    /// 一页「我的」那种入口 + 内嵌浏览器那一页
    Future<_FakeWindowService> pumpWebview(
      WidgetTester tester, {
      bool desktopLinkWindow = true,
      bool insideWebWindow = false,
    }) async {
      final service = _FakeWindowService();
      final router = GoRouter(
        initialLocation: '/home',
        routes: <RouteBase>[
          GoRoute(
            path: '/home',
            builder: (context, state) => Scaffold(
              body: TextButton(
                onPressed: () => context.push(
                  '${AppRoutes.webview}'
                  '?title=gracelink.cc'
                  '&src=${Uri.encodeComponent('https://gracelink.cc/privacy')}',
                ),
                child: const Text('用户协议'),
              ),
            ),
          ),
          GoRoute(
            path: AppRoutes.webview,
            builder: (context, state) => WebViewPage(
              title: state.uri.queryParameters['title'] ?? '',
              src: state.uri.queryParameters['src'] ?? '',
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            desktopLinkWindowProvider.overrideWithValue(desktopLinkWindow),
            webWindowHostProvider.overrideWithValue(insideWebWindow),
            desktopWindowServiceProvider.overrideWithValue(service),
            webViewHostProvider.overrideWithValue(_FakeWebViewHost()),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      return service;
    }

    testWidgets('桌面：推这一页会把网址交给网页窗，自己收掉（不回退到手机那条路）', (tester) async {
      final service = await pumpWebview(tester);

      await tester.tap(find.text('用户协议'));
      await tester.pumpAndSettle();

      expect(service.calls, <String>[
        'web:https://gracelink.cc/privacy:gracelink.cc',
      ]);
      expect(
        find.byType(WebViewPage),
        findsNothing,
        reason: '这一页自己收掉了：网页在另一扇窗口里',
      );
      expect(find.text('用户协议'), findsOneWidget, reason: '回到原来那一页');
    });

    testWidgets('已经跑在网页窗里：这一页就真渲染 webview（不再套一扇窗）', (tester) async {
      final service = await pumpWebview(tester, insideWebWindow: true);

      await tester.tap(find.text('用户协议'));
      await tester.pumpAndSettle();

      expect(service.calls, isEmpty, reason: '自己不动手开窗');
      expect(find.byType(WebViewPage), findsOneWidget);
      expect(
        find.text('FAKE-WEBVIEW:https://gracelink.cc/privacy'),
        findsOneWidget,
      );
    });
  });

  testWidgets('桌面上点自己的站点链接：直接交给网页窗（不多问一句）', (tester) async {
    final service = _FakeWindowService();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          desktopFeaturesProvider.overrideWithValue(true),
          desktopLinkWindowProvider.overrideWithValue(true),
          desktopWindowServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  openChatLink(context, 'https://gracelink.cc/privacy'),
              child: const Text('点链接'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('点链接'));
    await tester.pumpAndSettle();

    expect(service.calls, <String>[
      'web:https://gracelink.cc/privacy:gracelink.cc',
    ]);
    expect(find.byType(WebViewPage), findsNothing);
  });

  group('网页窗多标签（S12.26）', () {
    // —— 标签本身的规矩（不牵扯界面，跑得快）——

    test('同一条地址点了两遍：不叠第二个，切回去', () {
      final tabs = WebTabsController(url: 'https://a.example.com/1');
      expect(tabs.tabs.length, 1);

      tabs.open(url: 'https://b.example.com/2');
      expect(tabs.tabs.length, 2);
      expect(tabs.active!.url, 'https://b.example.com/2');

      tabs.open(url: 'https://a.example.com/1');
      expect(tabs.tabs.length, 2, reason: '同一条地址不该叠出第二个标签');
      expect(tabs.active!.url, 'https://a.example.com/1', reason: '切过去就行');
    });

    test('关掉当前那个：右邻顶上来（右边没了就退回左邻）；关完一个不剩就空了', () {
      final tabs = WebTabsController(url: 'https://a.example.com/1');
      tabs.open(url: 'https://b.example.com/2');
      tabs.open(url: 'https://c.example.com/3');

      // 当前是 3，关掉中间那个 2：当前不动
      tabs.close(tabs.tabs[1].id);
      expect(tabs.active!.url, 'https://c.example.com/3');

      // 关掉当前那个 3：右边没有了，左邻 1 顶上来
      tabs.close(tabs.tabs.last.id);
      expect(tabs.active!.url, 'https://a.example.com/1');

      tabs.close(tabs.tabs.single.id);
      expect(tabs.isEmpty, isTrue);
    });

    test('网页报了标题：标签上换成它；没报就是域名', () {
      final tabs = WebTabsController(url: 'https://a.example.com/1');
      expect(tabs.active!.label, 'a.example.com');

      tabs.setPageTitle(tabs.active!.id, '  某站点首页  ');
      expect(tabs.active!.label, '某站点首页');
    });

    // —— 真把网页窗那颗引擎摆起来 ——

    /// native 通道（标题/大小/居中/显形/关窗）收到过什么
    Future<List<MethodCall>> pumpWebWindow(
      WidgetTester tester, {
      required String url,
      String title = '',
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

      tester.view.physicalSize = const Size(1000, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            // 与 `runDesktopChildWindow()` 一致：窗口里手机版式，点外链照样开窗
            desktopFeaturesProvider.overrideWithValue(false),
            desktopShellProvider.overrideWithValue(true),
            desktopLinkWindowProvider.overrideWithValue(true),
            webWindowHostProvider.overrideWithValue(true),
            webViewHostProvider.overrideWithValue(_FakeWebViewHost()),
          ],
          child: DesktopChildRoot(
            args: DesktopWindowArgs.web(url: url, title: title),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return nativeCalls;
    }

    /// 主窗口又点了一条外链（真机上就是插件的这条 IPC）。
    ///
    /// 和 `desktop_child_window_test.dart` 里那条一样**不能 await**：窗口那头
    /// 还要把结果送回去，测试里的定时器得靠 pump 才走。
    Future<void> tellOpenUrl(
      WidgetTester tester,
      String url,
      String title,
    ) async {
      unawaited(
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'mixin.one/desktop_multi_window/channels',
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('methodCall', <String, dynamic>{
              'channel': 'gracelink/window/web',
              'method': 'open_url',
              'arguments': <String, dynamic>{'url': url, 'title': title},
            }),
          ),
          (_) {},
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('开窗先一条标签；又来一条外链 → 多一个标签并切过去，上一页还留着', (tester) async {
      final calls = await pumpWebWindow(tester, url: 'https://a.example.com/1');

      expect(find.text('FAKE-WEBVIEW:https://a.example.com/1'), findsOneWidget);
      expect(find.text('a.example.com'), findsOneWidget, reason: '标签条上那行字先给域名');
      expect(calls.map((call) => call.method).toList(), <String>[
        'setTitle',
        'setSize',
        'center',
        'show',
      ]);
      expect(calls[1].arguments, <String, double>{'w': 1000, 'h': 720});

      await tellOpenUrl(tester, 'https://b.example.com/2', 'b.example.com');

      expect(
        find.text('FAKE-WEBVIEW:https://b.example.com/2'),
        findsOneWidget,
        reason: '当前标签是刚点进来的那条（可见）',
      );
      expect(
        find.text('FAKE-WEBVIEW:https://a.example.com/1', skipOffstage: false),
        findsOneWidget,
        reason: '上一条没被顶掉：还挂在树上，切回去不用重新加载',
      );
      expect(find.text('a.example.com'), findsOneWidget);
      expect(find.text('b.example.com'), findsOneWidget);
      expect(
        calls.where((call) => call.method == 'setTitle').last.arguments,
        'b.example.com',
        reason: '原生标题栏（任务栏那一项）跟着当前标签走',
      );
    });

    testWidgets('同一条地址点两遍：标签不叠，切过去就行', (tester) async {
      await pumpWebWindow(tester, url: 'https://a.example.com/1');
      await tellOpenUrl(tester, 'https://b.example.com/2', 'b.example.com');
      await tellOpenUrl(tester, 'https://b.example.com/2', 'b.example.com');

      expect(find.byIcon(Icons.close), findsNWidgets(2), reason: '还是两个标签');
      expect(find.text('a.example.com'), findsOneWidget);
      expect(find.text('b.example.com'), findsOneWidget);

      await tellOpenUrl(tester, 'https://a.example.com/1', 'a.example.com');

      expect(
        find.text('FAKE-WEBVIEW:https://a.example.com/1'),
        findsOneWidget,
        reason: '切回已有那条，而不是又开一个',
      );
      expect(find.byIcon(Icons.close), findsNWidgets(2));
    });

    testWidgets('点标签条能来回切；✕ 关掉当前这个 → 另一个顶上来，窗还开着', (tester) async {
      final calls = await pumpWebWindow(tester, url: 'https://a.example.com/1');
      await tellOpenUrl(tester, 'https://b.example.com/2', 'b.example.com');

      // 点回第一条
      await tester.tap(find.text('a.example.com'));
      await tester.pumpAndSettle();
      expect(find.text('FAKE-WEBVIEW:https://a.example.com/1'), findsOneWidget);
      expect(
        find.text('FAKE-WEBVIEW:https://b.example.com/2', skipOffstage: false),
        findsOneWidget,
      );

      // 关掉当前这条（a）→ 另一个顶上来
      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pumpAndSettle();
      expect(find.text('FAKE-WEBVIEW:https://b.example.com/2'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(
        calls.where((call) => call.method == 'close'),
        isEmpty,
        reason: '还有标签在，窗不该关',
      );
    });

    testWidgets('关掉最后一个标签 = 关掉这扇窗（和用户点 ✕ 同一条路）', (tester) async {
      final calls = await pumpWebWindow(tester, url: 'https://a.example.com/1');

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(
        calls.where((call) => call.method == 'close').length,
        1,
        reason: '一个不剩了：叫 native 把这扇窗真关掉',
      );
      expect(find.byIcon(Icons.close), findsNothing);
    });
  });
}

/// 记事儿的假服务：这一套关心的是「点了之后交给谁」，不是窗口本身
class _FakeWindowService implements DesktopWindowService {
  final List<String> calls = <String>[];

  @override
  Future<void> openArticle({
    required String id,
    required String title,
    NewsCard? shared,
  }) async {
    calls.add('article:$id:$title:${shared?.id ?? ''}');
  }

  @override
  Future<void> openLingting({required String title}) async {
    calls.add('lingting:$title');
  }

  @override
  Future<void> openNews({required String title}) async {
    calls.add('news:$title');
  }

  @override
  Future<void> openWeb({required String url, required String title}) async {
    calls.add('web:$url:$title');
  }
}

/// 假的 webview（真机上是平台视图，测试里建 `WebViewController` 会直接抛）
class _FakeWebViewHost implements WebViewHost {
  @override
  Widget build({
    required String url,
    ValueChanged<int>? onProgress,
    ValueChanged<String>? onError,
    ValueChanged<String>? onTitle,
  }) => Text('FAKE-WEBVIEW:$url', textDirection: TextDirection.ltr);
}
