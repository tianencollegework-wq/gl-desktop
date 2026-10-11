import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/media/media_picker.dart';
import 'package:gracelinkim/core/media/media_saver.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/platform/desktop_shell.dart';
import 'package:gracelinkim/core/platform/webview_host.dart';
import 'package:gracelinkim/core/router/app_router.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/lingting_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/theme/app_colors.dart';
import 'package:gracelinkim/core/theme/app_theme.dart';
import 'package:gracelinkim/core/ui/hover_highlight.dart';
import 'package:gracelinkim/core/ws/ws_client.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/db/contact_dao.dart';
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/db/message_dao.dart';
import 'package:gracelinkim/data/model/contact.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/features/chat/chat_info_page.dart';
import 'package:gracelinkim/features/chat/widgets/chat_info_panel.dart';
import 'package:gracelinkim/features/chat/widgets/chat_input.dart';
import 'package:gracelinkim/features/chat/widgets/media/news_card_bubble.dart';
import 'package:gracelinkim/features/chat/chat_page.dart';
import 'package:gracelinkim/features/contacts/user_detail_page.dart';
import 'package:gracelinkim/domain/news/news_card.dart';
import 'package:gracelinkim/features/desktop_window/desktop_window_service.dart';
import 'package:gracelinkim/features/home/desktop_frame.dart';
import 'package:gracelinkim/features/home/shell_menu.dart';
import 'package:gracelinkim/features/lingting/lingting_home_page.dart';
import 'package:gracelinkim/features/news/news_detail_page.dart';
import 'package:gracelinkim/features/news/news_list_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 桌面适配（2026-10-03，Windows）。
///
/// 「桌面独立窗口」那两条**不验窗口本身**（那是另一颗引擎里的事，见
/// `desktop_child_window_test.dart`），只验**入口有没有把这件事交出去**：
/// 换成一个记事的假服务，看点了灵听 / 点了资讯卡片之后它收到的是什么。
///
/// 这一套钉的是「**在 Windows 上跑也一样过**」：`flutter test` 的宿主就是
/// Windows，`isDesktopRuntime` 在那里是真的，所以凡是**已改行为**的地方都必须
/// 能显式指定桌面形态（[desktopFeaturesProvider]），否则要么测试变味、
/// 要么桌面上那半套代码永远没人验。
///
/// 覆盖的范围（不含通话/视频/音乐那三块，见规划书 S12.11）：
/// * 桌面壳：内容封顶 500 居中，窗口本来就窄时原样透传；
/// * 读二维码：桌面那条纯 Dart 的解码路（`desktop_qr_scanner.dart`）；
/// * 外链两条路：Windows 上是真 webview（WebView2），其它桌面 / 起不来时
///   才是「系统浏览器」那页降级；
/// * 存图提示语、拍照入口、回车发送 / Shift+回车换行。
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
  });

  /// 把 [DesktopShell] 单独摆起来：给定的窗口尺寸就是它看到的 `MediaQuery`。
  /// 子节点把自己看到的宽度印出来 —— `rpx` 那一套读的就是这个宽度。
  Future<void> pumpShell(
    WidgetTester tester, {
    required bool desktop,
    required Size windowSize,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [desktopShellProvider.overrideWithValue(desktop)],
        child: MediaQuery(
          data: MediaQueryData(size: windowSize),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: DesktopShell(
              child: Builder(
                builder: (context) => Text(
                  'w=${MediaQuery.sizeOf(context).width.toStringAsFixed(0)}',
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  test('测试里桌面行为默认关着（不然那 1900 多条手机用例会集体变味）', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(desktopFeaturesEnabled, isFalse, reason: 'FLUTTER_TEST 下必须是关的');
    expect(container.read(desktopFeaturesProvider), isFalse);
    expect(container.read(desktopShellProvider), isFalse);
  });

  testWidgets('桌面壳：窗口拉宽 → 内容封顶 500 居中（两侧留灰）', (tester) async {
    await pumpShell(tester, desktop: true, windowSize: const Size(1280, 800));

    // 子树看到的宽度被换成 500：`rpx` 与直接读宽度的写法都跟着归位
    expect(find.text('w=500'), findsOneWidget);
    // 封顶那一列居中、两侧那层灰底在
    expect(find.byType(Center), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is ColoredBox && widget.color == DesktopShell.backdrop,
      ),
      findsOneWidget,
    );
    // 高度没有被夹（整站是竖版布局，只夹宽度）
    expect(MediaQuery.sizeOf(tester.element(find.text('w=500'))).height, 800);
  });

  testWidgets('桌面壳：窗口本来就窄（360）→ 原样透传，与手机一致', (tester) async {
    await pumpShell(tester, desktop: true, windowSize: const Size(360, 640));

    expect(find.text('w=360'), findsOneWidget);
    expect(find.byType(Center), findsNothing);
    expect(find.byType(ColoredBox), findsNothing);
  });

  testWidgets('桌面壳：开关关着时一个字都不改（测试里的默认形态）', (tester) async {
    await pumpShell(tester, desktop: false, windowSize: const Size(1280, 800));

    expect(find.text('w=1280'), findsOneWidget);
    expect(find.byType(Center), findsNothing);
  });

  test('存图提示语跟着平台换：手机「已保存到相册」，桌面「已保存到下载目录」', () {
    expect(savedMediaToastKey(desktop: false), 'common.savedToGallery');
    expect(savedMediaToastKey(desktop: true), 'common.savedToDownloads');
  });

  test('桌面上「拍摄」直接返回 null，不去碰相机插件', () async {
    // `image_picker_windows` 对 `ImageSource.camera` 是直接抛 `StateError` 的，
    // 所以这一步必须自己拦下来（界面上那一格在桌面也不显示）
    final picker = SystemMediaPicker(null, true);
    expect(await picker.pickCamera(), isNull);
  });

  // 「桌面从图片里读二维码」那两条用例跟着功能一起删了（2026-10-08）。
  // 用户原话：「电脑扫一扫这功能有点多此一举吧，直接把这功能删了吧，扫一扫在
  // 电脑端没用」—— 桌面少了这颗入口与那条路由（见 `shell_menu.dart` /
  // `app_router.dart`），`desktop_qr_scanner.dart` 与 `zxing2` 依赖也一并去掉
  // （`image` 留着：它还被 `.dart_tool/shottool` 那套截图脚本用着）。
  // 手机的扫一扫（相机 + 相册 analyzeImage）一点没动。

  test('「＋」菜单的清单本身没动：手机仍摆着扫一扫（挡的是桌面那一次渲染）', () {
    // 删的是「电脑端摆不摆」，不是把这个动作从菜单里拿掉 ——
    // 两条清单（消息 / 通讯录）里它都还在，桌面那一道是 `ShellAddMenu` 里
    // `!(desktop && action == ShellAddAction.scan)` 那句过滤。
    expect(messageAddActions, contains(ShellAddAction.scan));
    expect(contactsAddActions, contains(ShellAddAction.scan));
  });

  testWidgets('电脑端「＋」菜单里没有「扫一扫」：手机那套不动，桌面只是少摆一项', (tester) async {
    // 宽窗才是桌面那套版式（≥900，见 `desktopWideLayout`），「＋」这时在会话列顶上
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = memoryDatabase();
    addTearDown(db.close);
    final adapter = StubAdapter();
    sessionGuard.update(ready: true, hasSession: true);
    addTearDown(() => sessionGuard.update(ready: false, hasSession: false));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(adapter.apiClient()),
          desktopFeaturesProvider.overrideWithValue(true),
          wsStatusProvider.overrideWith(
            (ref) => Stream<WsStatus>.value(WsStatus.connected),
          ),
        ],
        child: const GracelinkApp(),
      ),
    );
    await tester.pumpAndSettle();
    ProviderScope.containerOf(tester.element(find.byType(MaterialApp)))
        .read(sessionStoreProvider.notifier)
        .applyLogin(const UserInfo(userId: 'u1', displayName: '我'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ShellAddMenu).first);
    await tester.pumpAndSettle();

    // 那一条的语言包文案是带空格的「扫 一 扫」（跟着老端），别写成紧凑的
    expect(find.text('扫 一 扫'), findsNothing, reason: '电脑上没有相机，这一项不摆');
    // 同菜单里其它几项照旧摆着（少的是扫一扫，不是整个菜单没了）；
    // 「创建群聊」摆不摆看服务端配置，这里不碰它
    expect(find.text('更新消息'), findsOneWidget);
    expect(find.text('添加朋友'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('桌面外链页：说明 + 地址 + 「在浏览器中打开」，进度直接报 100', (tester) async {
    var progress = -1;
    // 分流按**平台**走（不是按那个开关）：Windows 上给真 webview（WebView2），
    // 别的桌面才是降级页。用例宿主就是 Windows，所以这一条同时钉着
    // 「Windows 不再走浏览器」。
    final desktop = ProviderContainer(
      overrides: [desktopFeaturesProvider.overrideWithValue(true)],
    );
    addTearDown(desktop.dispose);
    final mobile = ProviderContainer();
    addTearDown(mobile.dispose);
    expect(
      desktop.read(webViewHostProvider),
      Platform.isWindows
          ? isA<WindowsWebViewHost>()
          : isA<DesktopWebViewHost>(),
    );
    expect(
      mobile.read(webViewHostProvider),
      Platform.isWindows ? isA<WindowsWebViewHost>() : isA<SystemWebViewHost>(),
      reason: '手机那支只长在手机上（宿主是 Windows 时两处拿到的是同一份）',
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: DesktopWebViewHost().build(
              url: 'https://gracelink.cc/privacy',
              onProgress: (value) => progress = value,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 页面根本不在我们这里加载 → 那条进度线直接收掉，不能一直挂着
    expect(progress, 100);
    expect(find.text('此页面由系统浏览器打开'), findsOneWidget);
    expect(find.text('https://gracelink.cc/privacy'), findsOneWidget);
    expect(find.text('在浏览器中打开'), findsOneWidget);
  });

  group('聊天输入栏（桌面：回车发送 / Shift+回车换行 / 没有「拍摄」）', () {
    late AppDatabase db;
    late StubAdapter adapter;

    setUp(() async {
      db = memoryDatabase();
      adapter = StubAdapter();
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

    /// 跑整个 App（用 `chat_send_test` 那套：真路由 + 内存库 + 假网络），
    /// 只是把桌面开关打开。
    Future<ProviderContainer> pumpApp(WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            apiClientProvider.overrideWithValue(adapter.apiClient()),
            desktopFeaturesProvider.overrideWithValue(true),
            wsStatusProvider.overrideWith(
              (ref) => Stream<WsStatus>.value(WsStatus.connected),
            ),
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
      await tester.pumpAndSettle();
      container.read(appRouterProvider).push('/message/chat?id=u2');
      await tester.pumpAndSettle();
      addTearDown(() => disposeApp(tester));
      return container;
    }

    Future<void> seedConversation() => db.upsertConversation(
      Conversation(
        id: 'u2',
        displayName: '小明',
        isGroup: 0,
        role: 3,
        lastSendTime: DateTime(2026, 10, 3, 10).millisecondsSinceEpoch,
        lastContent: '你好',
      ),
    );

    Future<void> type(WidgetTester tester, String text) async {
      final field = find.descendant(
        of: find.byType(ChatInput),
        matching: find.byType(TextField),
      );
      await tester.tap(field);
      await tester.pumpAndSettle();
      await tester.enterText(field, text);
      await tester.pumpAndSettle();
    }

    String fieldText(WidgetTester tester) => tester
        .widget<TextField>(
          find.descendant(
            of: find.byType(ChatInput),
            matching: find.byType(TextField),
          ),
        )
        .controller!
        .text;

    testWidgets('回车 = 发送（桌面上文本输入框的 action 是 newline，靠快捷键拦）', (tester) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
      await seedConversation();
      await pumpApp(tester);

      await type(tester, '回车发出去');

      // 桌面：输入框是 newline（引擎才会自己插换行，见 _field 的注释），
      // 所以「发送」这件事只能由我们自己的 Shortcuts 干
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byType(ChatInput),
                matching: find.byType(TextField),
              ),
            )
            .textInputAction,
        TextInputAction.newline,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      final body = adapter.bodyOf(ChatPaths.sendMessage);
      expect(body['content'], '回车发出去');
      expect(find.text('回车发出去'), findsOneWidget, reason: '气泡出来了');
      expect(fieldText(tester), isEmpty, reason: '发完清空');

      await disposeApp(tester);
    });

    testWidgets('Shift+回车 = 换行，不发送', (tester) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
      await seedConversation();
      await pumpApp(tester);

      await type(tester, '第一行');
      // 按住 Shift 再回车（`sendKeyEvent` 没有修饰键参数，得自己按住）
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();

      expect(fieldText(tester), '第一行\n', reason: '自己插一个 \\n');
      expect(
        adapter.paths,
        isNot(contains(ChatPaths.sendMessage)),
        reason: '换行不该发出去',
      );
      expect(find.text('发送'), findsOneWidget, reason: '内容还在，发送键还在');

      await disposeApp(tester);
    });

    testWidgets('「＋」面板没有「拍摄」那一格（桌面没有相机）', (tester) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      await seedConversation();
      await pumpApp(tester);

      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pumpAndSettle();

      expect(find.text('相册'), findsOneWidget);
      expect(find.text('拍摄'), findsNothing);

      await disposeApp(tester);
    });
  });

  group('桌面横屏三栏（窗口 ≥900）', () {
    late AppDatabase db;
    late StubAdapter adapter;

    setUp(() async {
      db = memoryDatabase();
      adapter = StubAdapter();
      sessionGuard.update(ready: true, hasSession: true);
    });

    tearDown(() async {
      sessionGuard.update(ready: false, hasSession: false);
      await db.close();
    });

    /// 收尾：卸载整棵树，再把 drift 关流时排下的零延迟定时器推完。
    ///
    /// **必须在用例体最后显式调一次**（不能只靠 `addTearDown`）：框架那道
    /// 「不能有 Timer 挂着」的断言跑在 test body 结束、teardown 之前。
    /// 三栏用例体内会关掉一批 drift 流（会话列表换版式、`pumpAndSettle` 之后再
    /// 卸载整棵树），那些流排下的零延迟定时器得在这里消化掉，
    /// 否则报「A Timer is still pending」。
    Future<void> disposeApp(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 1));
    }

    /// 跑整个 App 并停在主界面（不 push 聊天页），窗口尺寸由用例给。
    ///
    /// [desktopShellProvider] 跟着一起打开 —— **这是重点**：壳在宽窗下会把子树
    /// 看到的宽度覆写成 500，而三栏判据必须能穿过这层覆写看到真实窗口宽度。
    /// 早先这一条没开壳，于是判据读到的永远是真实值，那个
    /// 「登录之后还是手机版式」的 bug 在测试里一个都抓不到。
    Future<ProviderContainer> pumpHome(
      WidgetTester tester, {
      required Size windowSize,
      bool desktop = true,

      /// 把「去开系统级窗口」这件事换成假的（见 [_RecordingWindowService]）
      DesktopWindowService? windowService,
    }) async {
      tester.view.physicalSize = windowSize;
      // dpr = 1：下面断言的宽度就是逻辑宽度，与窗口尺寸一个口径
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            apiClientProvider.overrideWithValue(adapter.apiClient()),
            desktopFeaturesProvider.overrideWithValue(desktop),
            desktopShellProvider.overrideWithValue(desktop),
            wsStatusProvider.overrideWith(
              (ref) => Stream<WsStatus>.value(WsStatus.connected),
            ),
            if (windowService != null)
              desktopWindowServiceProvider.overrideWithValue(windowService),
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
      await tester.pumpAndSettle();
      addTearDown(() => disposeApp(tester));
      return container;
    }

    Future<void> seedConversation() => db.upsertConversation(
      Conversation(
        id: 'u2',
        displayName: '小明',
        isGroup: 0,
        role: 3,
        lastSendTime: DateTime(2026, 10, 3, 10).millisecondsSinceEpoch,
        lastContent: '你好',
      ),
    );

    /// 往本地库塞一个好友（通讯录那两栏的用例用；`_sync` 拿服务端空列表时
    /// 刻意**不清空**本地缓存，所以这套种子数据能一直留着）
    Future<void> seedContact() => db.upsertContacts(<Contact>[
      const Contact(
        id: 'u2',
        displayName: '小明',
        indexLetter: 'X',
        namePy: 'xiaoming',
      ),
    ]);

    testWidgets('宽窗：左图标条 + 会话列（搜索/＋）+ 右栏空态', (tester) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      await seedConversation();

      await pumpHome(tester, windowSize: const Size(1200, 800));

      // 这一条就是那个 bug 的钉子：**壳是开着的**（生产就是这个形态），它在宽窗下
      // 会把子树看到的 `MediaQuery` 宽度覆写成 500。判据要是读 `MediaQuery`，这里
      // 根本不会有 `DesktopFrame` —— 2026-10-03 晚上用户登录后看到的还是手机版式，
      // 就是这里。修法是判据改读**真实窗口宽度**（`realWindowWidth`）。
      expect(find.byType(DesktopFrame), findsOneWidget, reason: '≥900 要走三栏');
      // 框架一接手，壳那条封顶就不再夹：它看到的宽度是整窗
      expect(
        MediaQuery.sizeOf(tester.element(find.byType(DesktopFrame))).width,
        1200,
        reason: '框架看到的宽度是整窗（不再是 500）',
      );
      // 中栏：搜索框 + 会话列
      expect(find.text('搜索'), findsOneWidget);
      expect(find.text('小明'), findsWidgets);
      // 右栏：还没选会话 → 空态那句
      expect(find.text('选择左侧的聊天开始'), findsOneWidget);
      // 手机那套（底部 tab 栏）不该同时存在
      expect(find.text('通讯录'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('chatInputBar')),
        findsNothing,
        reason: '没选会话时右栏不该有输入框',
      );

      // 三栏的**实际位置**（用户这一条要的就是「按钮摆哪儿」）：
      // 图标条 60 宽在最左，会话列紧贴在它右边、宽 300，聊天区吃掉剩下的。
      final rail = tester.getRect(find.byTooltip('通讯录'));
      expect(
        rail.left,
        lessThan(DesktopFrame.railWidth),
        reason: '图标条贴左边（那一格自己还有一圈内边距）',
      );
      expect(rail.right, lessThanOrEqualTo(DesktopFrame.railWidth));
      final tile = tester.getRect(find.text('小明').first);
      expect(tile.left, greaterThanOrEqualTo(DesktopFrame.railWidth));
      expect(
        tile.left,
        lessThan(DesktopFrame.railWidth + DesktopFrame.listWidth),
        reason: '会话行落在中间那一栏里',
      );
      final searchBox = tester.getRect(find.text('搜索'));
      expect(
        searchBox.left,
        greaterThanOrEqualTo(DesktopFrame.railWidth),
        reason: '搜索框在中栏，不在图标条里',
      );
      // （断言写在 expect 上而不是 matcher 里：matcher 没有 reason 参数）
      expect(
        searchBox.right,
        lessThan(DesktopFrame.railWidth + DesktopFrame.listWidth),
      );

      // 图标条也能切分区：点「通讯录」→ 中栏整块换成好友列（搜索 / ＋ 照旧在，
      // 会话列没了），右栏换成好友资料的空态
      await tester.tap(find.byTooltip('通讯录'));
      await tester.pumpAndSettle();
      expect(find.byType(DesktopFrame), findsOneWidget);
      expect(find.text('小明'), findsNothing, reason: '会话列已经整块换掉了');
      expect(find.text('搜索'), findsOneWidget, reason: '通讯录中栏顶上也是「搜索框 + ＋」');
      expect(find.text('选择左侧的联系人'), findsOneWidget, reason: '右栏是好友资料的空态');

      await disposeApp(tester);
    });

    testWidgets('点会话 = 选中到右栏（不跳页），发送键常驻右下', (tester) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
      await seedConversation();

      await pumpHome(tester, windowSize: const Size(1200, 800));
      await tester.tap(find.text('小明').first);
      await tester.pumpAndSettle();

      // 还在主界面上（没有被 push 一个整页聊天盖掉）
      expect(find.byType(DesktopFrame), findsOneWidget);
      expect(find.text('搜索'), findsOneWidget, reason: '左边那一列还在');
      // 右栏是聊天页：输入栏在，且「发送」**空内容时也摆着**（微信 PC 就是这样）
      expect(
        find.byKey(const ValueKey<String>('chatInputBar')),
        findsOneWidget,
      );
      expect(find.text('发送'), findsOneWidget, reason: '桌面这颗钮常驻');
      // 输入框铺满右栏（不是又缩回一个手机宽的窄条）
      final bar = tester.getRect(
        find.byKey(const ValueKey<String>('chatInputBar')),
      );
      expect(
        bar.left,
        greaterThanOrEqualTo(DesktopFrame.railWidth + DesktopFrame.listWidth),
        reason: '右栏从「图标条 + 会话列」右边开始',
      );
      expect(bar.right, greaterThan(1000), reason: '右栏一直铺到窗口右边');
      // 工具排（表情 / ＋面板 / 语音）在输入框里
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('chatInputBar')),
          matching: find.byIcon(Icons.emoji_emotions_outlined),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('chatInputBar')),
          matching: find.byIcon(Icons.mic_none_outlined),
        ),
        findsOneWidget,
      );

      await disposeApp(tester);
    });

    testWidgets('右栏右上角：查找聊天记录 / 通话 / ⋯，⋯ 抻出右侧信息面板', (tester) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      await seedConversation();

      await pumpHome(tester, windowSize: const Size(1200, 800));
      await tester.tap(find.text('小明').first);
      await tester.pumpAndSettle();

      // 微信 PC 那三颗在右栏右上角（单聊 + webrtc 开着 → 通话那颗也在）
      expect(
        find.byKey(const ValueKey<String>('chatNavRecord')),
        findsOneWidget,
        reason: '查找聊天记录',
      );
      expect(
        find.byKey(const ValueKey<String>('chatNavCall')),
        findsOneWidget,
        reason: '通话（canCall 时才有）',
      );
      expect(find.byKey(const ValueKey<String>('chatNavMore')), findsOneWidget);

      // 没开面板时聊天区铺到右边
      final wide = tester.getRect(
        find.byKey(const ValueKey<String>('chatInputBar')),
      );
      expect(wide.right, greaterThan(1000));

      // 点「⋯」→ 右侧信息面板挤出来（不是整页跳转）
      await tester.tap(find.byKey(const ValueKey<String>('chatNavMore')));
      await tester.pumpAndSettle();

      expect(find.byType(ChatInfoPanel), findsOneWidget);
      expect(find.byType(DesktopFrame), findsOneWidget, reason: '还在三栏里');
      // 面板里那几行（对照微信 PC 截图）：查找 / 免打扰 / 置顶 / 清空
      expect(find.text('查找聊天记录'), findsOneWidget);
      expect(find.text('消息免打扰'), findsOneWidget);
      expect(find.text('置顶聊天'), findsOneWidget);
      expect(find.text('清空聊天记录'), findsOneWidget);
      // 聊天区被挤窄：输入栏右边不再到窗口边
      final narrow = tester.getRect(
        find.byKey(const ValueKey<String>('chatInputBar')),
      );
      expect(narrow.right, lessThan(wide.right));
      expect(
        narrow.right,
        lessThanOrEqualTo(1200 - ChatInfoPanel.panelWidth + 1),
        reason: '面板宽 300，右侧让出来',
      );

      // 再点一下收回去
      await tester.tap(find.byKey(const ValueKey<String>('chatNavMore')));
      await tester.pumpAndSettle();
      expect(find.byType(ChatInfoPanel), findsNothing);
      expect(
        tester
            .getRect(find.byKey(const ValueKey<String>('chatInputBar')))
            .right,
        wide.right,
      );

      await disposeApp(tester);
    });

    testWidgets('右栏面板 = 聊天信息正文（不再推手机整页）：单聊有虚线「＋」，收藏 / 群不给', (tester) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      adapter.ok(
        GroupPaths.userList,
        data: <String, dynamic>{'list': <Map<String, dynamic>>[], 'count': 0},
      );
      await seedConversation();
      // 「我的收藏」：`is_group == 3`，它不是一个「人」，拉人开群这件事不成立
      await db.upsertConversation(
        Conversation(
          id: 'favorite',
          displayName: '我的收藏',
          isGroup: 3,
          role: 3,
          lastSendTime: DateTime(2026, 10, 3, 11).millisecondsSinceEpoch,
          lastContent: '收藏的文件',
        ),
      );
      await db.upsertConversation(
        Conversation(
          id: 'group-9',
          displayName: '测试群',
          isGroup: 1,
          role: 1,
          lastSendTime: DateTime(2026, 10, 3, 12).millisecondsSinceEpoch,
          lastContent: '群里的话',
        ),
      );

      await pumpHome(tester, windowSize: const Size(1200, 800));

      // 单聊：面板里嵌的就是聊天信息正文，那颗虚线「＋」（发起群聊）在
      await tester.tap(find.text('小明').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('chatNavMore')));
      await tester.pumpAndSettle();
      expect(find.byType(ChatInfoPanel), findsOneWidget);
      expect(
        find.byType(ChatInfoPage),
        findsOneWidget,
        reason: '桌面面板就是聊天信息那份内容，不是另一套行',
      );
      expect(
        find.byKey(const ValueKey<String>('chatInfo-createGroup')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey<String>('chatNavMore')));
      await tester.pumpAndSettle();

      // 群：面板里直接是群资料（成员 / 群名称 / 群公告…），没有「聊天信息」那一层入口
      await tester.tap(find.text('测试群').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('chatNavMore')));
      await tester.pumpAndSettle();
      expect(find.textContaining('查看全部群成员'), findsOneWidget);
      expect(find.text('群聊名称'), findsOneWidget);
      expect(find.text('群公告'), findsOneWidget);
      expect(
        find.text('聊天信息'),
        findsNothing,
        reason: '面板自己不再挂「聊天信息」入口（以前点它又推一页手机版）',
      );
      expect(
        find.byKey(const ValueKey<String>('chatInfo-createGroup')),
        findsNothing,
        reason: '单聊那颗「＋」不该出现在群里',
      );
      await tester.tap(find.byKey(const ValueKey<String>('chatNavMore')));
      await tester.pumpAndSettle();

      // 我的收藏：面板照旧能开，但没有「＋」（用户 2026-10-04 报的那条）
      await tester.tap(find.text('我的收藏').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('chatNavMore')));
      await tester.pumpAndSettle();
      expect(find.byType(ChatInfoPanel), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('chatInfo-createGroup')),
        findsNothing,
        reason: '收藏里不该有「添加成员」那颗＋',
      );
      expect(
        find.byKey(const ValueKey<String>('chatInfo-addMember')),
        findsNothing,
        reason: '收藏更没有群成员那颗「＋」',
      );

      await disposeApp(tester);
    });

    testWidgets('窄窗（800）进聊天：没有桌面那三颗，仍是整页那套', (tester) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      await seedConversation();

      await pumpHome(tester, windowSize: const Size(800, 600));
      await tester.tap(find.text('小明').first);
      await tester.pumpAndSettle();

      // 手机形态（窄窗）走的是整页聊天：有返回箭头，右上角还是原来那颗「更多」
      expect(find.byIcon(Icons.arrow_back_ios_new), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('chatNavRecord')), findsNothing);
      expect(find.byKey(const ValueKey<String>('chatNavMore')), findsNothing);
      expect(find.byType(ChatInfoPanel), findsNothing);

      await disposeApp(tester);
    });

    testWidgets('窄窗（800）退回手机壳：没有三栏，底部 tab 栏在', (tester) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      await seedConversation();

      await pumpHome(tester, windowSize: const Size(800, 600));

      expect(
        find.byType(DesktopFrame),
        findsNothing,
        reason: '800 < 900，还没到三栏那一档',
      );
      // 手机壳的分区名在底部 tab 栏上
      expect(find.text('通讯录'), findsWidgets);

      await disposeApp(tester);
    });

    testWidgets('手机（桌面开关关着）哪怕窗口 1200 宽也还是手机那套', (tester) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      await seedConversation();

      // 手机上跑的就是这一支：`desktopFeaturesEnabled` 是
      // `isDesktopRuntime && !FLUTTER_TEST`，安卓 / iOS 上 isDesktopRuntime 就是假，
      // 与这里 override 成 false 等价。
      await pumpHome(tester, windowSize: const Size(1200, 800), desktop: false);

      expect(find.byType(DesktopFrame), findsNothing, reason: '一个桌面框架都不该有');
      expect(find.byType(DesktopPageFrame), findsNothing);
      expect(find.byType(DesktopPanel), findsNothing);
      // 手机那套的标记：底部 tab 栏那几个分区名
      expect(find.text('通讯录'), findsWidgets);
      expect(find.text('发现'), findsWidgets);

      await disposeApp(tester);
    });

    testWidgets('宽窗通讯录：中栏好友列（搜索/＋）+ 右栏资料空态', (tester) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
      await seedContact();

      await pumpHome(tester, windowSize: const Size(1200, 800));
      await tester.tap(find.byTooltip('通讯录'));
      await tester.pumpAndSettle();

      expect(find.byType(DesktopFrame), findsOneWidget);
      // 中栏：搜索框 + ＋ + 好友行
      expect(find.text('搜索'), findsOneWidget);
      final row = tester.getRect(find.text('小明').first);
      expect(row.left, greaterThanOrEqualTo(DesktopFrame.railWidth));
      expect(
        row.left,
        lessThan(DesktopFrame.railWidth + DesktopFrame.listWidth),
        reason: '好友行落在中栏里',
      );
      // 右栏：还没点好友 → 空态那句
      expect(find.text('选择左侧的联系人'), findsOneWidget);

      await disposeApp(tester);
    });

    testWidgets('宽窗通讯录：点好友 = 右栏出资料（不跳页），删好友那颗 ⋯ 还在', (tester) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
      adapter.ok(
        ChatPaths.userInfo,
        data: <String, dynamic>{
          'user_id': 'u2',
          'displayName': '小明',
          'account': 'xiaoming',
          // 有 friend 块才算「已经是好友」：底部那块动作栏与删除好友才会出来
          'friend': <String, dynamic>{'id': 'u2'},
        },
      );
      await seedContact();

      await pumpHome(tester, windowSize: const Size(1200, 800));
      await tester.tap(find.byTooltip('通讯录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('小明').first);
      await tester.pumpAndSettle();

      // 还在框架里、左边好友列还在（不是 push 了一页整页资料盖上来）
      expect(find.byType(DesktopFrame), findsOneWidget);
      expect(find.text('搜索'), findsOneWidget, reason: '左边好友列还在');
      // 右栏是资料：恩信号那行落在中栏右边
      final accountLine = find.text('恩信号：xiaoming');
      expect(accountLine, findsOneWidget);
      expect(
        tester.getRect(accountLine).left,
        greaterThanOrEqualTo(DesktopFrame.railWidth + DesktopFrame.listWidth),
        reason: '资料摆在右栏',
      );
      // 右栏就是复用的那份用户详情（同一页，只是 `embedded`）
      expect(find.byType(UserDetailPage), findsOneWidget);
      expect(
        tester.widget<UserDetailPage>(find.byType(UserDetailPage)).embedded,
        isTrue,
      );
      // 右栏形态没有手机那套自己的顶栏（返回箭头 / AppBar）
      expect(find.byType(AppBar), findsNothing);
      expect(find.byIcon(Icons.arrow_back_ios_new), findsNothing);
      // 但「⋯ → 删除好友」那颗钮不能因为换了摆法就没了
      expect(find.byIcon(Icons.more_horiz), findsOneWidget);

      await disposeApp(tester);
    });

    testWidgets('宽窗通讯录：右栏资料里点「发消息」→ 三栏切到消息、右栏换成聊天', (tester) async {
      // 用户 2026-10-08 报的：「点发消息会返回上一层」—— 在右栏那份好友资料里点
      // 「发消息」，资料没了、聊天也没出来，看着像退了一页。
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
      adapter.ok(
        ChatPaths.userInfo,
        data: <String, dynamic>{
          'user_id': 'u2',
          'displayName': '小明',
          'account': 'xiaoming',
          'friend': <String, dynamic>{'id': 'u2'},
        },
      );
      await seedContact();

      await pumpHome(tester, windowSize: const Size(1200, 800));
      await tester.tap(find.byTooltip('通讯录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('小明').first);
      await tester.pumpAndSettle();
      expect(find.text('发消息'), findsOneWidget);

      await tester.tap(find.text('发消息'));
      await tester.pumpAndSettle();

      // 还在三栏里（不是变成手机那种竖版整页）
      expect(find.byType(DesktopFrame), findsOneWidget);
      // 右栏换成聊天、资料让位：这两条就是 bug 的钉子
      expect(find.byType(ChatPage), findsOneWidget, reason: '右栏该是聊天');
      expect(find.byType(UserDetailPage), findsNothing, reason: '资料得让位');
      // 中栏也换成会话列（消息分区）：左边好友列不该还占着中间
      expect(find.text('搜索'), findsOneWidget);

      await disposeApp(tester);
    });

    testWidgets('宽窗：从「我」分区被拉进聊天（点通知那条路）→ 也落在消息分区', (tester) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      await seedConversation();

      final container = await pumpHome(
        tester,
        windowSize: const Size(1200, 800),
      );
      await tester.tap(find.byTooltip('我'));
      await tester.pumpAndSettle();
      expect(
        find.byType(DesktopPanel),
        findsOneWidget,
        reason: '「我」这个分区本身就是一栏面板',
      );

      // 通知拉会话走的就是这一句（`NotificationHost` 里 push `/message/chat`）
      container.read(appRouterProvider).push('${AppRoutes.chat}?id=u2');
      await tester.pumpAndSettle();

      expect(find.byType(ChatPage), findsOneWidget);
      expect(
        find.byType(DesktopPanel),
        findsNothing,
        reason: '「我」那一栏得让位给会话列 + 聊天',
      );

      await disposeApp(tester);
    });

    /// 面板右边那片灰底（页面底色）的矩形。
    ///
    /// 必须用**矩形**而不是「找得到那个 widget」来断言：没有 child 的 `ColoredBox`
    /// 只占 `constraints.smallest`，而 Row 里交叉轴是松约束 —— 它是 0 高、什么都不画，
    /// 但 widget 还在树上（2026-10-03 实机右边一片白，用例绿着）。
    Rect pageBackdropRightOf(WidgetTester tester, double left) {
      final boxes = find.byWidgetPredicate(
        (widget) =>
            (widget is ColoredBox && widget.color == AppColors.page) ||
            (widget is Container && widget.color == AppColors.page),
      );
      for (var i = 0; i < boxes.evaluate().length; i++) {
        final rect = tester.getRect(boxes.at(i));
        if (rect.left >= left - 1 && rect.height > 700) return rect;
      }
      fail('面板右边没有铺到页面底色的灰底（0 高的 ColoredBox 是抓不到的）');
    }

    testWidgets('宽窗发现 / 我：一栏面板（定宽 500）+ 右侧留灰', (tester) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);

      await pumpHome(tester, windowSize: const Size(1200, 800));

      // 发现：灵听 / 媒体号两栏入口摆在一栏面板里
      await tester.tap(find.byTooltip('发现'));
      await tester.pumpAndSettle();
      expect(find.byType(DesktopFrame), findsOneWidget);
      expect(find.byType(DesktopPanel), findsOneWidget);
      expect(find.text('灵听'), findsOneWidget);
      expect(find.text('媒体号'), findsOneWidget);
      final panel = tester.getRect(find.byType(DesktopPanel));
      expect(panel.left, closeTo(DesktopFrame.railWidth + 0.5, 1));
      expect(panel.width, DesktopFrame.panelWidth);
      expect(panel.right, lessThan(1000), reason: '面板没铺满整窗（右边那片灰底还在）');

      // 我：资料卡 + 设置行也在同一栏里
      await tester.tap(find.byTooltip('我'));
      await tester.pumpAndSettle();
      expect(find.byType(DesktopPanel), findsOneWidget);
      // 面板右边那片灰底（页面底色）真的铺在那里、有高度
      final backdrop = pageBackdropRightOf(tester, panel.right);
      expect(backdrop.left, closeTo(panel.right, 1));
      expect(backdrop.right, 1200, reason: '灰底一直铺到窗口右边');
      final card = tester.getRect(
        find.byKey(const ValueKey<String>('mineProfileCard')),
      );
      expect(card.left, greaterThanOrEqualTo(panel.left - 0.5));
      expect(card.right, lessThanOrEqualTo(panel.right + 0.5));
      expect(find.text('设置'), findsWidgets, reason: '「我」里那一行设置');

      await disposeApp(tester);
    });

    testWidgets('宽窗二级页：设置进**右栏**，中栏还是「我」那一栏（右边不再留灰）', (tester) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);

      await pumpHome(tester, windowSize: const Size(1200, 800));
      // 图标条底下那颗「≡」→ 设置
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();

      expect(find.byType(DesktopPageFrame), findsOneWidget);
      // 图标条还在（二级页不是整屏页面）
      expect(find.byTooltip('通讯录'), findsOneWidget);
      // 中栏还是「我」那一栏（定宽 500 的面板）
      final panel = tester.getRect(find.byType(DesktopPanel));
      expect(panel.width, DesktopFrame.panelWidth);
      expect(panel.left, greaterThanOrEqualTo(DesktopFrame.railWidth));
      // 设置那一页摆在**右栏**：从面板右边一直铺到窗口右边（不再留一片灰）
      final pane = tester.getRect(
        find.byKey(const ValueKey<String>('desktopPane')),
      );
      expect(pane.left, closeTo(panel.right, 1));
      expect(pane.right, 1200, reason: '右栏铺到窗口右边');
      // 右栏顶上那条「设置」（桌面形态）也跟着铺满右栏（不是手机那种居中窄条）
      final header = tester.getRect(
        find.byKey(const ValueKey<String>('settingPaneHeader')),
      );
      expect(header.left, greaterThanOrEqualTo(pane.left - 0.5));
      expect(header.right, lessThanOrEqualTo(pane.right + 0.5));
      expect(find.byType(AppBar), findsNothing, reason: '右栏里不用手机那条居中 AppBar');
      expect(find.text('个人资料'), findsOneWidget);
      expect(find.text('退出登录'), findsOneWidget);

      // 点图标条上的分区 → 回到主界面（不是又叠一页）
      await tester.tap(find.byTooltip('通讯录'));
      await tester.pumpAndSettle();
      expect(find.byType(DesktopPageFrame), findsNothing);
      expect(find.byType(DesktopFrame), findsOneWidget);

      await disposeApp(tester);
    });

    testWidgets('宽窗设置：左列分类 + 右列那一类的内容（不再是一列竖排）', (tester) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);

      await pumpHome(tester, windowSize: const Size(1200, 800));
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();

      // 左列：四个分类竖着排在同一档 x 上
      final account = tester.getRect(find.text('账号'));
      final general = tester.getRect(find.text('通用'));
      expect(general.top, greaterThan(account.bottom), reason: '分类竖着排');
      expect(general.left, closeTo(account.left, 1), reason: '同一列');

      // 右列：默认选中「账号」→ 就是账号那一类的行
      final profile = tester.getRect(find.text('个人资料'));
      expect(profile.left, greaterThan(account.right), reason: '内容在分类右边');
      expect(
        profile.left,
        greaterThanOrEqualTo(DesktopFrame.railWidth + DesktopFrame.panelWidth),
        reason: '内容在右栏里（中栏是「我」那一栏）',
      );
      expect(find.text('账号与安全'), findsOneWidget);
      // 手机版最底下那两块并进「账号」这一类
      expect(find.text('切换账号'), findsOneWidget);
      expect(find.text('退出登录'), findsOneWidget);
      expect(find.text('通知'), findsNothing, reason: '别的类不一起铺出来');

      // 点「通用」→ 右列换成通用那一类（还在同一个 x 上）
      await tester.tap(find.byKey(const ValueKey<String>('settingCategory1')));
      await tester.pumpAndSettle();
      expect(find.text('通知'), findsOneWidget);
      expect(find.text('界面与显示'), findsOneWidget);
      expect(find.text('个人资料'), findsNothing, reason: '账号那一类收起来了');
      expect(
        tester.getRect(find.text('通知')).left,
        closeTo(profile.left, 1),
        reason: '右列的位置不变，只是换了内容',
      );
      // 界面上仍只有一个「退出登录」（它在账号那一类里，没被复制一份）
      expect(find.text('退出登录'), findsNothing);

      await disposeApp(tester);
    });

    testWidgets('宽窗：设置 › 音视频通话 点开不是白纸（用户 2026-10-10 报的）', (tester) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);

      await pumpHome(tester, windowSize: const Size(1200, 800));
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();

      // 「功能」那一类里就是「音视频通话」
      await tester.tap(find.byKey(const ValueKey<String>('settingCategory2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('音视频通话'));
      await tester.pumpAndSettle();

      // 用户原话：「电脑端设置的音视频通话点开是啥都没有的这体验很不好，要么有东西，
      // 要么就不要有这一栏」。原来那三行（保活通知 / 全屏显示 / debug 自检）在桌面上
      // 一个都不画，点进来就是一张白纸。
      expect(find.text('通话线路'), findsOneWidget);
      expect(find.text('仅 STUN'), findsOneWidget);
      expect(find.text('通话保活通知'), findsNothing);
      expect(find.text('来电全屏显示'), findsNothing);

      // 点开是明细（桌面上是居中那张弹层窗口，见 `showAppSheet`）
      await tester.tap(find.text('通话线路'));
      await tester.pumpAndSettle();
      expect(find.text('公共 STUN（客户端固定）'), findsOneWidget);
      expect(find.text('stun:stun.xten.com'), findsOneWidget);

      await disposeApp(tester);
    });

    testWidgets('顶栏那颗通话：菜单挂在钮**下面**（不是飘到窗口右下角）', (tester) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      await seedConversation();

      await pumpHome(tester, windowSize: const Size(1200, 800));
      await tester.tap(find.text('小明').first);
      await tester.pumpAndSettle();

      final call = find.byKey(const ValueKey<String>('chatNavCall'));
      final button = tester.getRect(call);
      await tester.tap(call);
      await tester.pumpAndSettle();

      // 2026-10-04 用户截图那个 bug：锚错成了**整页**那块 RenderBox，
      // 菜单于是飘到窗口右下角（离那颗摄像头图标十万八千里）。
      // 钉的就是「菜单顶边贴着钮底边」这一条。
      final voice = tester.getRect(find.text('语音通话'));
      final video = tester.getRect(find.text('视频通话'));
      expect(
        voice.top,
        inInclusiveRange(button.bottom, button.bottom + 48),
        reason: '菜单从钮下面展开',
      );
      expect(video.top, greaterThan(voice.top), reason: '两项竖着排');
      expect(voice.left, lessThanOrEqualTo(button.right), reason: '横向上贴着钮');
      expect(voice.left, greaterThan(button.left - 220), reason: '没飘到窗口另一头');

      await disposeApp(tester);
    });

    testWidgets('宽窗通讯录：点「新的朋友」→ 那一页就在右半部分，好友列留在左边', (tester) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.friendList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);
      adapter.ok(FriendPaths.applyList, data: <Map<String, dynamic>>[]);
      await seedContact();

      await pumpHome(tester, windowSize: const Size(1200, 800));
      await tester.tap(find.byTooltip('通讯录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新的朋友').first);
      await tester.pumpAndSettle();

      // 这就是用户 2026-10-04 那条：「点击新的朋友之后把新的朋友页面显示在右半部分」
      expect(find.byType(DesktopPageFrame), findsOneWidget);
      expect(find.byType(DesktopFrame), findsOneWidget);
      // 左边那栏还在：搜索框、群聊入口、好友行
      expect(find.text('搜索'), findsOneWidget);
      expect(find.text('群聊'), findsOneWidget);
      expect(find.text('小明'), findsWidgets);
      // 右栏从「图标条 + 好友列」右边开始，一直铺到窗口右边
      final pane = tester.getRect(
        find.byKey(const ValueKey<String>('desktopPane')),
      );
      expect(
        pane.left,
        closeTo(DesktopFrame.railWidth + DesktopFrame.listWidth, 1),
      );
      expect(pane.right, 1200);
      // 那一页自己的内容（好友申请列表那块）也在右栏里
      expect(
        tester.getRect(find.byType(AppBar)).left,
        greaterThanOrEqualTo(pane.left - 0.5),
      );

      await disposeApp(tester);
    });

    testWidgets('宽窗消息：二级页**把聊天区换掉**，不再加成第 4 栏（用户 2026-10-04 报的套娃）', (
      tester,
    ) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.messageContext, data: <Map<String, dynamic>>[]);
      adapter.ok(ChatPaths.userInfo, data: <String, dynamic>{'user_id': 'u2'});
      await seedConversation();

      final container = await pumpHome(
        tester,
        windowSize: const Size(1200, 800),
      );
      await tester.tap(find.text('小明').first);
      await tester.pumpAndSettle();
      // 「会话信息」这一页（`/message/detail?id=`）—— 从右栏面板里那个入口
      // 进去同一条路，这里直接推那条路由，与入口无关
      container.read(appRouterProvider).push('/message/detail?id=u2');
      await tester.pumpAndSettle();

      expect(find.byType(DesktopPageFrame), findsOneWidget);
      final pane = tester.getRect(
        find.byKey(const ValueKey<String>('desktopPane')),
      );
      // 二级页从「图标条 + 会话列」右边一直铺到窗口右边 —— 里面**不再**塞着
      // 聊天区和信息面板（那是 1200 窗口下的第 3、4 层，聊天只剩 120 宽）
      expect(
        pane.left,
        closeTo(DesktopFrame.railWidth + DesktopFrame.listWidth, 1),
      );
      expect(pane.right, 1200, reason: '二级页铺满右栏');
      expect(
        find.byKey(const ValueKey<String>('chatInputBar')),
        findsNothing,
        reason: '聊天区已经被这一页换掉，不该还挤在旁边',
      );
      expect(find.byType(ChatInfoPanel), findsNothing);
      // 中栏（会话列）还在
      expect(find.text('搜索'), findsOneWidget);

      await disposeApp(tester);
    });

    testWidgets('桌面独立窗口：点「发现」里的灵听 → 交给开窗服务（主窗口原地不动）', (tester) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      await seedConversation();
      // 灵听自己那本账（`main()` 里初始化；测试里补上，与 lingting_pages_test 同一套）
      await LingtingStore.init();

      final service = _RecordingWindowService();
      await pumpHome(
        tester,
        windowSize: const Size(1200, 800),
        windowService: service,
      );
      await tester.tap(find.byTooltip('发现'));
      await tester.pumpAndSettle();
      expect(find.text('灵听'), findsOneWidget);

      await tester.tap(find.text('灵听'));
      await tester.pumpAndSettle();

      // 交给开窗服务（真正的窗口在另一颗引擎里，主窗口这边一点没动）
      expect(service.calls, <String>['lingting:灵听']);
      expect(
        find.byType(LingtingHomePage),
        findsNothing,
        reason: '独立窗口是另一颗引擎，主窗口不该再推这一页',
      );
      expect(find.text('媒体号'), findsOneWidget, reason: '主窗口还是「发现」那一栏（媒体号那一行）');

      await disposeApp(tester);
    });

    testWidgets('桌面独立窗口：点「发现」里的媒体号 → 也交给开窗服务（不再开在主窗口右栏）', (tester) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      await seedConversation();
      await LingtingStore.init();

      final service = _RecordingWindowService();
      await pumpHome(
        tester,
        windowSize: const Size(1200, 800),
        windowService: service,
      );
      await tester.tap(find.byTooltip('发现'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('媒体号'));
      await tester.pumpAndSettle();

      // 用户 2026-10-04：「为啥我这看到的媒体号还是这样的不是独立窗口？」
      expect(service.calls, <String>['news:媒体号']);
      expect(
        find.byType(NewsListPage),
        findsNothing,
        reason: '媒体号那张列表开在独立窗口（另一颗引擎）里，主窗口不该再摆一份',
      );

      await disposeApp(tester);
    });

    testWidgets('桌面独立窗口：聊天里的资讯卡片 → 交给开窗服务（带上卡片本体，主窗口不换页）', (tester) async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      await seedConversation();
      await db.upsertMessages(<Message>[
        Message(
          serverId: 1,
          msgId: 'm1',
          conversationId: 'u2',
          fromUserId: 'u2',
          fromUserName: '小明',
          type: 'news',
          content: '[资讯] 朋友分享来的新闻',
          sendTime: DateTime(2026, 10, 3, 10, 1).millisecondsSinceEpoch,
          isGroup: 0,
          ext: <String, dynamic>{
            'id': 'n-1',
            'title': '朋友分享来的新闻',
            'source': 'sspai',
            'summary': '卡片里带的摘要。',
            'link': 'https://sspai.com/post/1',
          },
        ),
      ]);

      final service = _RecordingWindowService();
      await pumpHome(
        tester,
        windowSize: const Size(1200, 800),
        windowService: service,
      );

      // 三栏：点会话 → 右栏就是聊天，卡片在那儿
      await tester.tap(find.text('小明'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(NewsCardBubble));
      await tester.pumpAndSettle();

      expect(service.calls, <String>['article:n-1:朋友分享来的新闻:n-1']);
      expect(
        find.byType(NewsDetailPage),
        findsNothing,
        reason: '文章开在独立窗口里，主窗口不换页',
      );
      expect(find.text('小明'), findsWidgets, reason: '主窗口（会话列）原地不动');

      await disposeApp(tester);
    });
  });

  group('鼠标悬停反馈（桌面）', () {
    /// 取 `RepaintBoundary` 正中心那个像素；测试里 dpr = 1，所以就是逻辑像素。
    Future<List<int>> centerPixel(WidgetTester tester, GlobalKey key) async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final List<int>? rgb = await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = (await image.toByteData())!;
        final int w = image.width;
        final int i = ((image.height ~/ 2) * w + w ~/ 2) * 4;
        return <int>[
          data.getUint8(i),
          data.getUint8(i + 1),
          data.getUint8(i + 2),
        ];
      });
      return rgb!;
    }

    testWidgets('HoverHighlight：悬停压一层蒙版，移开立刻撤掉', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: HoverHighlight(
              borderRadius: BorderRadius.all(Radius.circular(8)),
              child: SizedBox(width: 120, height: 40),
            ),
          ),
        ),
      );
      Color? mask() {
        final box = tester.widget<Container>(
          find.descendant(
            of: find.byType(HoverHighlight),
            matching: find.byType(Container),
          ),
        );
        return (box.foregroundDecoration as BoxDecoration?)?.color;
      }

      expect(mask(), isNull, reason: '鼠标没进来时不该有蒙版');

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      final center = tester.getCenter(find.byType(HoverHighlight));
      await gesture.addPointer(location: center);
      await gesture.moveTo(center);
      await tester.pump();
      expect(
        mask(),
        const Color(0x14000000),
        reason: '与主题 hoverColor 同一档（8% 黑）',
      );

      await gesture.moveTo(const Offset(1, 1));
      await tester.pump();
      expect(mask(), isNull, reason: '移开要撤掉，不然像还能点');
    });

    testWidgets('主题 hoverColor：InkWell 那一族（会话行 / 底部 tab / 设置行）真的会变暗', (
      tester,
    ) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Center(
            child: RepaintBoundary(
              key: key,
              child: Material(
                child: SizedBox(
                  width: 200,
                  height: 60,
                  child: InkWell(onTap: () {}, child: const SizedBox.expand()),
                ),
              ),
            ),
          ),
        ),
      );
      final before = await centerPixel(tester, key);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(gesture.removePointer);
      final center = tester.getCenter(find.byType(InkWell));
      await gesture.addPointer(location: center);
      await gesture.moveTo(center);
      await tester.pumpAndSettle();
      final after = await centerPixel(tester, key);

      expect(after, isNot(before), reason: '悬停必须看得见，否则鼠标划过像一块死图');
      for (var channel = 0; channel < 3; channel++) {
        expect(
          after[channel],
          lessThan(before[channel]),
          reason: '主题给的是「压暗」那一档，第 $channel 个通道应比原来暗',
        );
      }
    });
  });
}

/// 「去开系统级窗口」这件事的替身：只记谁被点过（真开窗是另一颗引擎，
/// 那些在 `desktop_child_window_test.dart` 里验）。
class _RecordingWindowService implements DesktopWindowService {
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
