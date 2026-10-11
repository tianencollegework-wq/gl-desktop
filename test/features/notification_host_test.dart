import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/notify/message_notification_presenter.dart';
import 'package:gracelinkim/core/platform/app_foreground.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/ws/ws_client.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/db/app_database.dart';
// 会话的数据库方法都是 extension，必须 import
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/domain/chat/message_notification.dart';
import 'package:gracelinkim/features/chat/chat_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 假的通知实现：记录弹过什么、把「用户点了通知」手动播回来
class _FakePresenter implements MessageNotificationPresenter {
  final List<MessageNotification> shown = <MessageNotification>[];
  final List<String> cancelled = <String>[];
  bool permissionGranted = false;
  int permissionRequests = 0;
  String? pending;

  /// 模拟「用户点了通知栏里那条」
  void tap(String conversationId) => onOpen?.call(conversationId);
  ValueChanged<String>? onOpen;

  @override
  Future<String?> initialize({required ValueChanged<String> onOpen}) async {
    this.onOpen = onOpen;
    return pending;
  }

  @override
  Future<bool> enabled() async => permissionGranted;

  @override
  Future<bool> requestPermission() async {
    permissionRequests += 1;
    permissionGranted = true;
    return true;
  }

  @override
  Future<void> show(MessageNotification notification) async =>
      shown.add(notification);

  @override
  Future<void> cancel(String conversationId) async =>
      cancelled.add(conversationId);

  @override
  Future<void> cancelAll() async {}

  // 来电那几条本文件用不到（CallPushHost 才是它们的宿主），给个空实现就行
  @override
  Future<void> showIncomingCall(IncomingCallNotification call) async {}

  @override
  Future<void> cancelIncomingCall() async {}

  @override
  void onIncomingCallOpen(ValueChanged<String> handler) {}

  @override
  Future<String?> takeLaunchIncomingCall() async => null;

  // 群通话邀请那几条本文件也用不到（GroupCallPushHost 才是它们的宿主）
  @override
  Future<void> showGroupCallRing(IncomingCallNotification invite) async {}

  @override
  Future<void> cancelGroupCallRing() async {}

  @override
  void onGroupCallOpen(ValueChanged<String> handler) {}

  @override
  Future<String?> takeLaunchGroupCall() async => null;
}

/// 通知宿主（`NotificationHost`）：前后台跟踪 + 点通知进会话 + 冷启动补跳。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late ProviderContainer container;
  late _FakePresenter presenter;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    db = memoryDatabase();
    adapter = StubAdapter();
    presenter = _FakePresenter();
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
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(adapter.apiClient()),
          messageNotificationPresenterProvider.overrideWithValue(presenter),
          wsStatusProvider.overrideWith(
            (ref) => Stream<WsStatus>.value(WsStatus.connected),
          ),
        ],
        child: const GracelinkApp(),
      ),
    );
    await tester.pumpAndSettle();
    container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    container
        .read(sessionStoreProvider.notifier)
        .applyLogin(const UserInfo(userId: 'u1', displayName: '我'));
    await tester.pumpAndSettle();
    addTearDown(() => disposeApp(tester));
  }

  testWidgets('切后台 / 回前台会更新「App 是否在前台」', (tester) async {
    await pumpApp(tester);
    // 进主界面时会要一次通知权限
    expect(presenter.permissionRequests, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(container.read(appForegroundProvider), isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(container.read(appForegroundProvider), isTrue);

    await disposeApp(tester);
  });

  testWidgets('点通知：进对应会话，并把它那条通知清掉', (tester) async {
    await db.upsertConversation(
      const Conversation(id: 'u9', displayName: '李四'),
    );
    await pumpApp(tester);

    presenter.tap('u9');
    await tester.pumpAndSettle();

    expect(find.byType(ChatPage), findsOneWidget);
    expect(presenter.cancelled, contains('u9'));

    await disposeApp(tester);
  });

  testWidgets('App 是被通知拉起来的：初始化交回的会话要自动补跳', (tester) async {
    await db.upsertConversation(
      const Conversation(id: 'u9', displayName: '李四'),
    );
    presenter.pending = 'u9';

    await pumpApp(tester);

    expect(find.byType(ChatPage), findsOneWidget);

    await disposeApp(tester);
  });
}
