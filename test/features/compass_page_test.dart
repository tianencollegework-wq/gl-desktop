import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/platform/webview_host.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/ws/ws_client.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/model/global_config.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/features/common/webview_page.dart';
import 'package:gracelinkim/domain/news/news_providers.dart';
import 'package:gracelinkim/features/compass/compass_page.dart';
import 'package:gracelinkim/features/lingting/lingting_home_page.dart';
import 'package:gracelinkim/features/news/news_list_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_news.dart';
import '../support/test_database.dart';

/// 「发现」tab + 内嵌浏览器。
///
/// 「发现」现在**是纯客户端写死的**（2026-09-27 用户要求：不看服务端
/// `globalConfig.compass` 了；2026-09-29 又加了「资讯」一栏），
/// 名字走语言包、图标随包），所以这组用例做三件事：
/// ① 那两栏**在不在、叫什么、点了去哪儿**，而且**服务端不给任何配置时也照样在**；
/// ② 「资讯」用的是假仓库（真仓库要联网，见 `support/fake_news.dart`）；
/// ③ 内嵌浏览器本身（还开着链接那道门）。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late _FakeWebViewHost host;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    db = memoryDatabase();
    adapter = StubAdapter();
    host = _FakeWebViewHost();
    sessionGuard.update(ready: true, hasSession: true);
  });

  tearDown(() async {
    sessionGuard.update(ready: false, hasSession: false);
    await db.close();
  });

  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    CompassConfig compass = const CompassConfig(),
    FakeNewsRepository? news,
  }) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(adapter.apiClient()),
          webViewHostProvider.overrideWithValue(host),
          wsStatusProvider.overrideWith(
            (ref) => Stream<WsStatus>.value(WsStatus.connected),
          ),
          if (news != null) newsRepositoryProvider.overrideWithValue(news),
        ],
        child: const GracelinkApp(),
      ),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    container
        .read(sessionStoreProvider.notifier)
        .applyLogin(const UserInfo(userId: 'u1', displayName: '我'));
    container
        .read(sessionStoreProvider.notifier)
        .applyConfig(
          GlobalConfig.fromJson(<String, dynamic>{'compass': compass.toJson()}),
        );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('服务端什么都没配：这一格照样在，里面就是「灵听」那一栏', (tester) async {
    // 注意：`CompassConfig()` 的默认值就是「status = 0 关闭、list 空」——
    // 老端这样配置时整格都不出现，现在它是自己长出来的。
    await pumpApp(tester);

    expect(find.text('发现'), findsOneWidget, reason: '底部第三格');

    await tester.tap(find.text('发现'));
    await tester.pumpAndSettle();

    expect(find.byType(CompassPage), findsOneWidget);
    expect(find.text('灵听'), findsOneWidget);
    expect(find.text('媒体号'), findsOneWidget, reason: '第二栏也是客户端自带的');

    await disposeApp(tester);
  });

  testWidgets('两栏各占一块白底，栏与栏之间的缝和「顶部栏 → 第一栏」一样宽', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('发现'));
    await tester.pumpAndSettle();

    // 每栏外包的那块白底 Container（一栏一块，不再是一块 + 一条分隔线）
    final lingting = tester.getRect(
      find.ancestor(of: find.text('灵听'), matching: find.byType(Container)),
    );
    final news = tester.getRect(
      find.ancestor(of: find.text('媒体号'), matching: find.byType(Container)),
    );
    final bodyTop = tester.getRect(find.byType(CompassPage)).top;

    final topGap = lingting.top - bodyTop;
    final betweenGap = news.top - lingting.bottom;
    expect(topGap, greaterThan(0), reason: '第一栏和顶部栏本来就有缝');
    expect(
      betweenGap,
      closeTo(topGap, 0.5),
      reason: '用户 2026-09-30：两栏之间隔开一点，就像第一栏和顶部栏那样的距离',
    );

    await disposeApp(tester);
  });

  testWidgets('点「媒体号」进媒体号列表（内容来自手机自己拉的公开源，与服务端无关）', (tester) async {
    await pumpApp(tester, news: FakeNewsRepository([]));
    await tester.tap(find.text('发现'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('媒体号'));
    await tester.pumpAndSettle();

    expect(find.byType(NewsListPage), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('服务端把 compass 配成一堆别的东西：这一页也不认（只认灵听）', (tester) async {
    await pumpApp(
      tester,
      compass: CompassConfig(
        status: 1,
        mode: 2,
        list: const <CompassItem>[
          CompassItem(name: '朋友圈', url: '/pages/compass/moments'),
        ],
      ),
    );

    await tester.tap(find.text('发现'));
    await tester.pumpAndSettle();

    expect(find.text('灵听'), findsOneWidget);
    expect(find.text('朋友圈'), findsNothing, reason: '这一页写死了，不再跟着服务端那份 list 走');

    await disposeApp(tester);
  });

  testWidgets('点「灵听」进灵听首页', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('发现'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('灵听'));
    await tester.pumpAndSettle();

    expect(find.byType(LingtingHomePage), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('那一栏的图标是随包资源（不是网络图）', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('发现'));
    await tester.pumpAndSettle();

    final image = tester.widget<Image>(
      find.descendant(
        of: find.byType(CompassPage),
        matching: find.byType(Image),
      ),
    );
    expect(
      (image.image as AssetImage).assetName,
      CompassPage.lingtingIconAsset,
    );

    await disposeApp(tester);
  });

  testWidgets('英文界面下那一栏也叫 Lingting（名字走语言包）', (tester) async {
    await AppI18n.load('en');
    addTearDown(() => AppI18n.load('zh-Hans'));
    await pumpApp(tester);
    await tester.tap(find.text('Discover'));
    await tester.pumpAndSettle();

    expect(find.text('Lingting'), findsOneWidget);
    expect(find.text('灵听'), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('内嵌浏览器：进度条跟着走，失败给重试', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(adapter.apiClient()),
          webViewHostProvider.overrideWithValue(host),
        ],
        child: const MaterialApp(
          home: WebViewPage(title: '用户协议', src: 'https://gracelink.cc/terms'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('用户协议'), findsOneWidget);
    expect(host.created, <String>['https://gracelink.cc/terms']);
    // 还没拿到进度：不画进度条（老端也没有）
    expect(find.byType(LinearProgressIndicator), findsNothing);

    // 报进度 → 画一条确定值的进度条
    host.onProgress?.call(40);
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    // 加载完就收起来
    host.onProgress?.call(100);
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);

    // 主框架失败 → 换成「加载失败 + 重试」
    host.onError?.call('net::ERR_NAME_NOT_RESOLVED');
    await tester.pumpAndSettle();
    expect(find.text('加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    // 重试：把状态清干净，重新把 webview 建起来（第二次挂载）
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('加载失败'), findsNothing);
    expect(host.created.length, 2);
    expect(
      find.text('FAKE-WEBVIEW:https://gracelink.cc/terms'),
      findsOneWidget,
    );

    await disposeApp(tester);
  });

  testWidgets('内嵌浏览器：没给地址时只显示空态，不建 webview', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(adapter.apiClient()),
          webViewHostProvider.overrideWithValue(host),
        ],
        child: const MaterialApp(
          home: WebViewPage(title: '加载中', src: ''),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(host.created, isEmpty);
    expect(find.text('暂无数据'), findsOneWidget);

    await disposeApp(tester);
  });
}

/// 假的 webview：真机上是平台视图，测试里建 `WebViewController` 会直接抛。
///
/// 它照着真实现的语义来：`created` 里的每一条都代表**真的挂载了一次**
/// （真实现是 `StatefulWidget` + `late final WebViewController`，同一位置重建
/// 不会重新加载页面），所以只在 `initState` 里记 —— 页面因为进度/失败而
/// `setState` 时这个列表不该变长。
class _FakeWebViewHost implements WebViewHost {
  final List<String> created = <String>[];
  ValueChanged<int>? onProgress;
  ValueChanged<String>? onError;

  @override
  Widget build({
    required String url,
    ValueChanged<int>? onProgress,
    ValueChanged<String>? onError,
    ValueChanged<String>? onTitle,
  }) => _FakeWebView(
    url: url,
    host: this,
    onProgress: onProgress,
    onError: onError,
  );
}

class _FakeWebView extends StatefulWidget {
  const _FakeWebView({
    required this.url,
    required this.host,
    this.onProgress,
    this.onError,
  });

  final String url;
  final _FakeWebViewHost host;
  final ValueChanged<int>? onProgress;
  final ValueChanged<String>? onError;

  @override
  State<_FakeWebView> createState() => _FakeWebViewState();
}

class _FakeWebViewState extends State<_FakeWebView> {
  @override
  void initState() {
    super.initState();
    widget.host.created.add(widget.url);
    widget.host.onProgress = widget.onProgress;
    widget.host.onError = widget.onError;
  }

  @override
  Widget build(BuildContext context) =>
      Text('FAKE-WEBVIEW:${widget.url}', textDirection: TextDirection.ltr);
}
