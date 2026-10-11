import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/platform/webview_host.dart';
import 'package:gracelinkim/core/router/app_router.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/ws/ws_client.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/db/message_dao.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/features/common/link_blocked_page.dart';
import 'package:gracelinkim/features/common/link_confirm_page.dart';
import 'package:gracelinkim/features/common/webview_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 聊天里点网址。
///
/// 两批事：①用户 2026-09-25 反馈「文字消息里的链接点了没有任何反应」——
/// 根因是文字气泡只是 `Text.rich` 一串纯 span，**没有手势**；
/// ②同一晚上的新要求：官方站点直开、微信/腾讯系拦住、其它第三方先确认。
///
/// 跑整个 App（真路由 + 内存库 + 假网络），因为要验的正是**端到端那一下**：
/// 真消息 → 气泡里那截蓝字 → 手指按下去 → 落到哪个页面、建过几次 webview。
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

  Future<void> pumpApp(WidgetTester tester) async {
    // 视口放到手机大小：800×600 的默认视口会把气泡挤到屏幕外，点不到
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
        ],
        child: const GracelinkApp(),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() => disposeApp(tester));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    container
        .read(sessionStoreProvider.notifier)
        .applyLogin(const UserInfo(userId: 'u1', displayName: '我'));
    await tester.pumpAndSettle();
    container.read(appRouterProvider).push('/message/chat?id=u2');
    await tester.pumpAndSettle();
  }

  /// 造一条别人发来的文字消息（`content` 就是服务端那份原文）
  Future<void> seedText(WidgetTester tester, String content) async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await db.upsertConversation(
      Conversation(
        id: 'u2',
        displayName: '小明',
        lastSendTime: DateTime(2026, 9, 25, 10).millisecondsSinceEpoch,
        lastContent: content,
      ),
    );
    await db.upsertMessages(<Message>[
      Message(
        serverId: 1,
        msgId: 'm1',
        conversationId: 'u2',
        fromUserId: 'u2',
        fromUserName: '小明',
        type: 'text',
        content: content,
        sendTime: DateTime(2026, 9, 25, 10).millisecondsSinceEpoch,
        isGroup: 0,
        isUndo: 0,
        ext: const <String, dynamic>{},
        extra: const <String, dynamic>{},
      ),
    ]);
    await tester.pumpAndSettle();
  }

  testWidgets('点消息里的网址 → 应用内浏览器打开这个地址（标题是域名）', (tester) async {
    await pumpApp(tester);
    await seedText(tester, '官网 https://gracelink.cc/help 谢谢');

    await tester.tapOnText(
      find.textRange.ofSubstring('https://gracelink.cc/help'),
    );
    await tester.pumpAndSettle();

    expect(find.byType(WebViewPage), findsOneWidget);
    expect(host.created, <String>['https://gracelink.cc/help']);
    // 标题栏用的是域名（老端也是把标题交给页面自己填）
    expect(find.text('gracelink.cc'), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('官方站点（含子域名）不多问，直接进 webview', (tester) async {
    await pumpApp(tester);
    await seedText(tester, '看 www.gracelink.cc 和 film.gracelink.cc/m/1');

    await tester.tapOnText(find.textRange.ofSubstring('www.gracelink.cc'));
    await tester.pumpAndSettle();
    expect(find.byType(LinkConfirmPage), findsNothing);
    expect(host.created, <String>['http://www.gracelink.cc']);

    // 返回聊天页，再点那个子域名（`pageBack` 靠 tooltip 找按钮，本工程是中文界面，
    // 直接点那个返回键）
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tapOnText(find.textRange.ofSubstring('film.gracelink.cc/m/1'));
    await tester.pumpAndSettle();
    expect(find.byType(LinkConfirmPage), findsNothing);
    expect(host.created.last, 'http://film.gracelink.cc/m/1');

    await disposeApp(tester);
  });

  testWidgets('第三方网址：先到确认页，点「继续访问」才真的加载', (tester) async {
    await pumpApp(tester);
    await seedText(tester, '看 gracelinkim.com/a 谢谢');

    await tester.tapOnText(find.textRange.ofSubstring('gracelinkim.com/a'));
    await tester.pumpAndSettle();

    // 先停在确认页：webview 此时**一根都没建**
    expect(find.byType(LinkConfirmPage), findsOneWidget);
    expect(find.byType(WebViewPage), findsNothing);
    expect(host.created, isEmpty);
    // 页面上要看得见「是谁提供的」与完整地址（微信那张页就是这样）
    expect(find.text('网页由 gracelinkim.com 提供'), findsOneWidget);
    expect(find.text('http://gracelinkim.com/a'), findsOneWidget);

    await tester.tap(find.text('继续访问'));
    await tester.pumpAndSettle();

    expect(find.byType(WebViewPage), findsOneWidget);
    expect(host.created, <String>['http://gracelinkim.com/a']);
    expect(find.text('gracelinkim.com'), findsOneWidget); // 标题是域名

    // 「继续访问」是 pushReplacement：从网页返回直接回聊天页，不会又冒出确认页
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byType(LinkConfirmPage), findsNothing);
    expect(find.byType(WebViewPage), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('确认页点「取消」：什么都不加载，回到聊天页', (tester) async {
    await pumpApp(tester);
    await seedText(tester, '看 https://github.com/gracelink 谢谢');

    await tester.tapOnText(
      find.textRange.ofSubstring('https://github.com/gracelink'),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LinkConfirmPage), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.byType(LinkConfirmPage), findsNothing);
    expect(find.byType(WebViewPage), findsNothing);
    expect(host.created, isEmpty);

    await disposeApp(tester);
  });

  testWidgets('微信/腾讯系网址：拦住，跳到红圈感叹号那个页，且不建 webview', (tester) async {
    await pumpApp(tester);
    await seedText(tester, '看 https://mp.weixin.qq.com/s/abc 谢谢');

    await tester.tapOnText(
      find.textRange.ofSubstring('https://mp.weixin.qq.com/s/abc'),
    );
    await tester.pumpAndSettle();

    expect(find.byType(LinkBlockedPage), findsOneWidget);
    expect(find.byType(LinkConfirmPage), findsNothing);
    expect(find.byType(WebViewPage), findsNothing);
    expect(host.created, isEmpty);
    expect(find.text('已停止访问该网页'), findsOneWidget);
    // 红圈里那个感叹号
    expect(find.text('!'), findsOneWidget);
    // 被拦下的地址原样列出来，方便截图反馈
    expect(find.text('https://mp.weixin.qq.com/s/abc'), findsOneWidget);

    // 「返回」回到聊天页
    await tester.tap(find.text('返回'));
    await tester.pumpAndSettle();
    expect(find.byType(LinkBlockedPage), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('普通文字（没有网址）点了不该乱跳页', (tester) async {
    await pumpApp(tester);
    await seedText(tester, '报告.docx 发你了，1.5 倍速听不清');

    await tester.tapOnText(find.textRange.ofSubstring('报告.docx'));
    await tester.pumpAndSettle();

    expect(find.byType(WebViewPage), findsNothing);
    expect(host.created, isEmpty);

    await disposeApp(tester);
  });
}

/// 假的 webview（真机上是平台视图，测试里建 `WebViewController` 会直接抛）
class _FakeWebViewHost implements WebViewHost {
  final List<String> created = <String>[];

  @override
  Widget build({
    required String url,
    ValueChanged<int>? onProgress,
    ValueChanged<String>? onError,
    ValueChanged<String>? onTitle,
  }) {
    created.add(url);
    return Text('FAKE-WEBVIEW:$url', textDirection: TextDirection.ltr);
  }
}
