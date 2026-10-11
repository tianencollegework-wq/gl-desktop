import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
// 会话/消息的数据库方法是以 extension 形式提供的，必须 import
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/db/message_dao.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/domain/chat/chat_sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_web_socket.dart';
import '../support/test_database.dart';

/// 聊天链路里「补漏掉的消息」这一块。
///
/// 服务端不会重放断线期间的推送（`simple` / `group` 都是纯在线推送），
/// 所以连接恢复时要主动把有未读的会话各拉一页最新消息——不拉就是
/// 「会话列表有预览、点进去什么都没有」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late StubAdapter adapter;
  late FakeWebSocketChannel channel;
  late WsService ws;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    db = memoryDatabase();
    adapter = StubAdapter();
    channel = FakeWebSocketChannel();
    ws = await startTestWsService(channel);
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        apiClientProvider.overrideWithValue(adapter.apiClient()),
        wsServiceProvider.overrideWithValue(ws),
      ],
    );
  });

  tearDown(() async {
    ws.dispose();
    container.dispose();
    await db.close();
  });

  /// 让 async 链路（事件分发、HTTP、落库）跑完
  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Map<String, dynamic> missedMessage({int id = 7, String content = '漏掉的'}) =>
      <String, dynamic>{
        'id': id,
        'msg_id': 'm-$id',
        'content': content,
        'type': 'text',
        'sendTime': 1758163200,
        'at': <String>[],
        'is_group': 0,
        'fromUser': <String, dynamic>{'id': 'u2', 'displayName': '小明'},
        'toContactId': 'u2',
      };

  Future<void> seedConversation(String id, {int unread = 0, int isGroup = 0}) =>
      db.upsertConversation(
        Conversation(id: id, displayName: id, unread: unread, isGroup: isGroup),
      );

  test('只补「有未读」的会话，并把它落库', () async {
    adapter.ok(
      ChatPaths.messageList,
      data: <Map<String, dynamic>>[missedMessage()],
    );
    await seedConversation('u2', unread: 1);
    await seedConversation('u3'); // 没未读：不值得多打一次接口
    await seedConversation('system', unread: 5, isGroup: 2); // 系统通知不在消息表里

    await container.read(chatSyncServiceProvider).syncMissedMessages();

    expect(
      adapter.paths.where((path) => path == ChatPaths.messageList),
      hasLength(1),
    );
    expect(adapter.bodyOf(ChatPaths.messageList), <String, dynamic>{
      'is_group': 0,
      'toContactId': 'u2',
      'last_id': '',
      'page': 1,
      'limit': 20,
    });
    final stored = await db.messagesFor('u2');
    expect(stored.map((item) => item.content), <String>['漏掉的']);
  });

  test('连接恢复时自动补一次（断线期间的推送服务端不会重放）', () async {
    adapter.ok(
      ChatPaths.messageList,
      data: <Map<String, dynamic>>[missedMessage(content: '断线时发的')],
    );
    await seedConversation('u2', unread: 2);
    container
        .read(sessionStoreProvider.notifier)
        .applyLogin(const UserInfo(userId: 'u1', displayName: '我'));

    container.read(chatSyncServiceProvider).start();
    // 断线 → 重连（`restart` 就是 stop + start）
    await ws.restart();
    await settle();

    // 会话列表先对齐（新的预览与未读数都在这里回来），再补消息
    expect(adapter.paths, contains(ChatPaths.contacts));
    expect(adapter.paths, contains(ChatPaths.messageList));
    final stored = await db.messagesFor('u2');
    expect(stored.map((item) => item.content), <String>['断线时发的']);
  });

  test('没登录时连接恢复也不补（还没绑定设备，拉也拉不到）', () async {
    adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
    await seedConversation('u2', unread: 2);

    container.read(chatSyncServiceProvider).start();
    await ws.restart();
    await settle();

    expect(adapter.paths, isNot(contains(ChatPaths.messageList)));
  });
}
