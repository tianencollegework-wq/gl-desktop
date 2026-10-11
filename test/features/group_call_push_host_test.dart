import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/notify/message_notification_presenter.dart';
import 'package:gracelinkim/core/router/app_router.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/domain/chat/message_notification.dart';
import 'package:gracelinkim/domain/group_call/group_call_push.dart';
import 'package:gracelinkim/features/group_call/group_call_push_host.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「推送来的群通话邀请」怎么进到群通话页（S6.14）。
///
/// 这是整条链里最绕的一段：后台 isolate 只能响个铃、把整条报文留在通知里，
/// 而**真正进那个群**得在主 isolate 做（要路由、要登录态），App 当时很可能是死的
/// （用户点通知才把进程拉起来）。
///
/// 这里刻意**不挂真的群通话页**（那要 SfuRoom、媒体、成员接口一整套，属于
/// `group_call_page_test` 的地盘）：用一张最小的路由表，验的是「点通知之后
/// 有没有带着对的那个群与群名跳到 GroupCallPage 那条路由上」。
void main() {
  late _FakePresenter presenter;

  /// 服务端那条推送的 payload = 整条群通话报文（通知里存的就是它）
  String invitePayload({
    String conversationId = 'group-100',
    String groupName = '产品群',
    String starter = '小明',
    String callId = 'gc-1',
    DateTime? sentAt,
  }) => json.encode(<String, dynamic>{
    'id': callId,
    'type': groupCallPushType,
    'toContactId': conversationId,
    'fromUser': <String, dynamic>{'id': 'u2', 'displayName': starter},
    'sendTime': (sentAt ?? DateTime.now()).millisecondsSinceEpoch,
    'extends': <String, dynamic>{
      'event': GroupCallPushEvent.ringing,
      'call_id': callId,
      'group_id': '100',
      'name': groupName,
      'type': 0,
    },
  });

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // 冷启动的真实形态：登录态已经在本地（进程是被通知拉起来的，没人重新登录）
    SharedPreferences.setMockInitialValues(<String, Object>{
      'authToken': 'token-1',
      'userInfo': json.encode(<String, dynamic>{
        'user_id': 'u1',
        'displayName': '我',
      }),
    });
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    presenter = _FakePresenter();
  });

  /// 挂上宿主（只用一张最小的路由表：真正的群通话页在这里没有意义）
  Future<GoRouter> pumpHost(WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: <RouteBase>[
        GoRoute(
          path: '/',
          builder: (context, state) => const Scaffold(body: Text('home')),
        ),
        GoRoute(
          path: AppRoutes.groupCall,
          builder: (context, state) => Scaffold(
            body: Text(
              'call ${state.uri.queryParameters['id']} '
              '@${state.uri.queryParameters['name']}',
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appRouterProvider.overrideWithValue(router),
          messageNotificationPresenterProvider.overrideWithValue(presenter),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (context, child) =>
              GroupCallPushHost(child: child ?? const SizedBox.shrink()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('App 被这条邀请拉起来（冷启动）：进那个群的群通话页', (tester) async {
    presenter.launchGroup = invitePayload();
    await pumpHost(tester);

    expect(find.text('call group-100 @产品群'), findsOneWidget);
    // 人已经进来了，那条通知不该还挂着
    expect(presenter.cancelledGroupRings, 1);
  });

  testWidgets('点通知（App 还活着）：一样进群通话页', (tester) async {
    await pumpHost(tester);

    presenter.openGroup?.call(invitePayload(callId: 'gc-2'));
    await tester.pumpAndSettle();

    expect(find.text('call group-100 @产品群'), findsOneWidget);
  });

  testWidgets('同一条邀请只处理一次（冷启动 + 再点一次不该叠一页）', (tester) async {
    final payload = invitePayload(callId: 'gc-3');
    presenter.launchGroup = payload;
    await pumpHost(tester);

    presenter.openGroup?.call(payload);
    await tester.pumpAndSettle();

    expect(find.text('call group-100 @产品群'), findsOneWidget);
  });

  testWidgets('群名里有空格与 & 也能带着走（路由参数要编码）', (tester) async {
    presenter.launchGroup = invitePayload(groupName: '产品 群&测试');
    await pumpHost(tester);

    expect(find.text('call group-100 @产品 群&测试'), findsOneWidget);
  });

  testWidgets('邀请里没有群会话 id：不跳（宁可什么都不做，也别进错群）', (tester) async {
    presenter.launchGroup = invitePayload(conversationId: '');
    await pumpHost(tester);

    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('超龄的邀请不进（群里那通可能早就散了）', (tester) async {
    presenter.launchGroup = invitePayload(
      sentAt: DateTime.now().subtract(const Duration(minutes: 5)),
    );
    await pumpHost(tester);

    expect(find.text('home'), findsOneWidget);
    expect(presenter.cancelledGroupRings, 0);
  });

  testWidgets('payload 不是群通话邀请（比如一条普通消息）：什么也不做', (tester) async {
    presenter.launchGroup = json.encode(<String, dynamic>{
      'id': 'm1',
      'type': 'text',
      'content': '在吗',
      'extends': <String, dynamic>{'event': 'simple'},
    });
    await pumpHost(tester);

    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('坏掉的 payload：不崩，也不跳', (tester) async {
    presenter.launchGroup = '{不是 json';
    await pumpHost(tester);

    expect(find.text('home'), findsOneWidget);
  });
}

/// 通知层的替身：只负责「通知栏里放着哪条邀请报文」和「点通知的回调」
class _FakePresenter implements MessageNotificationPresenter {
  /// 「App 是被这条邀请拉起来的」——就是那份整条报文
  String? launchGroup;

  /// 点通知（App 还活着）时 `GroupCallPushHost` 注册进来的那个 handler
  ValueChanged<String>? openGroup;

  int cancelledGroupRings = 0;

  @override
  Future<String?> takeLaunchGroupCall() async {
    final payload = launchGroup;
    launchGroup = null; // 只能取一次（进程当时已经没了）
    return payload;
  }

  @override
  void onGroupCallOpen(ValueChanged<String> handler) => openGroup = handler;

  @override
  Future<void> cancelGroupCallRing() async => cancelledGroupRings += 1;

  @override
  Future<void> showGroupCallRing(IncomingCallNotification invite) async {}

  @override
  Future<String?> initialize({required ValueChanged<String> onOpen}) async =>
      null;

  @override
  Future<bool> enabled() async => true;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> show(MessageNotification notification) async {}

  @override
  Future<void> cancel(String conversationId) async {}

  @override
  Future<void> cancelAll() async {}

  // 1:1 来电那几条本文件用不到（CallPushHost 才是它们的宿主）
  @override
  Future<void> showIncomingCall(IncomingCallNotification call) async {}

  @override
  Future<void> cancelIncomingCall() async {}

  @override
  void onIncomingCallOpen(ValueChanged<String> handler) {}

  @override
  Future<String?> takeLaunchIncomingCall() async => null;
}
