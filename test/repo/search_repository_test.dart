import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/net/api_exception.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/data/api/chat_api.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
// 会话的数据库方法都是 extension，必须 import
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/db/message_dao.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/repo/conversation_repository.dart';
import 'package:gracelinkim/data/repo/search_repository.dart';
import 'package:gracelinkim/domain/chat/message_record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 搜索仓库（S5.4）：搜人、聊天记录分页、前后文、按 user_id 补会话。
///
/// 走真实的 [ChatApi] + 假 adapter——参数名（`keywords` / `toContactId` /
/// `direction`）与返回形态（`searchUser` 与 `getMessageContext` 的 `data`
/// 都是**数组**）本身就是最容易写错的，必须让真实代码跑一遍。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late SearchRepository repository;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    db = memoryDatabase();
    adapter = StubAdapter();
    final api = adapter.apiClient();
    repository = SearchRepository(
      ChatApi(api),
      ConversationRepository(db, ChatApi(api)),
    );
  });

  tearDown(() => db.close());

  Map<String, dynamic> message(
    int id, {
    String type = 'text',
  }) => <String, dynamic>{
    'id': id,
    'msg_id': 'm$id',
    'type': type,
    'content': '第 $id 条',
    'sendTime': DateTime(2026, 9, 18, 10).millisecondsSinceEpoch + id * 1000,
    'toContactId': 'g1',
    'fromUser': <String, dynamic>{'id': 'u2', 'realname': '小明'},
  };

  group('搜人', () {
    test('关键词送进去前会 trim；`data` 是数组', () async {
      adapter.ok(
        ChatPaths.searchUser,
        data: <Map<String, dynamic>>[
          <String, dynamic>{'user_id': 'u9', 'realname': '张三', 'friend': 1},
        ],
      );

      final results = await repository.searchUsers('  张三  ');

      expect(adapter.bodyOf(ChatPaths.searchUser), <String, dynamic>{
        'keywords': '张三',
      });
      expect(results.single.userId, 'u9');
      expect(results.single.isFriend, isTrue);
    });

    test('空关键词不白跑一趟接口', () async {
      expect(await repository.searchUsers('   '), isEmpty);
      expect(adapter.paths, isEmpty);
    });

    test('接口挂了给空列表，不抛异常（页面显示空态）', () async {
      adapter.fail(ChatPaths.searchUser, msg: '搜索炸了');
      expect(await repository.searchUsers('张三'), isEmpty);
    });
  });

  group('从搜索结果进聊天', () {
    test('本地已有会话：不调 getUserInfo，直接能进', () async {
      await db.upsertConversation(
        const Conversation(id: 'u9', displayName: '张三'),
      );

      expect(await repository.ensureChatWith('u9'), isTrue);
      expect(adapter.paths, isEmpty);
    });

    test('本地没有：getUserInfo 的 contactInfo 补一条会话', () async {
      adapter.ok(
        ChatPaths.userInfo,
        data: <String, dynamic>{
          'contactInfo': <String, dynamic>{
            'id': 'u9',
            'displayName': '张三',
            'avatar': 'https://cdn.test/u9.png',
            'is_group': 0,
          },
        },
      );

      expect(await repository.ensureChatWith('u9'), isTrue);
      expect(adapter.bodyOf(ChatPaths.userInfo), <String, dynamic>{
        'user_id': 'u9',
      });
      final conversation = await db.findConversation('u9');
      expect(conversation?.displayName, '张三');
    });

    test('服务端没给 contactInfo：进不去（老端这时什么都不发生）', () async {
      adapter.ok(ChatPaths.userInfo, data: <String, dynamic>{});
      expect(await repository.ensureChatWith('u9'), isFalse);
      expect(await db.findConversation('u9'), isNull);
    });

    test('getUserInfo 挂了：进不去，不抛异常', () async {
      adapter.fail(ChatPaths.userInfo, msg: '取用户信息炸了');
      expect(await repository.ensureChatWith('u9'), isFalse);
    });

    test('空 id 直接挡掉', () async {
      expect(await repository.ensureChatWith(''), isFalse);
      expect(adapter.paths, isEmpty);
    });
  });

  group('聊天记录', () {
    test(
      '参数照老端：toContactId / is_group / type / keywords / page / limit',
      () async {
        adapter.ok(
          ChatPaths.messageList,
          data: <Map<String, dynamic>>[message(2), message(1)],
          count: 25,
        );

        final page = await repository.recordPage(
          conversationId: 'g1',
          isGroup: 1,
          type: 'image',
          keyword: ' 猫 ',
          page: 2,
        );

        expect(adapter.bodyOf(ChatPaths.messageList), <String, dynamic>{
          'toContactId': 'g1',
          'is_group': 1,
          'type': 'image',
          'keywords': '猫',
          'page': 2,
          'limit': 10,
        });
        // 总数来自信封的 count（分页条用它）
        expect(page.total, 25);
        // 按时间升序（老端直接用服务端顺序，新端统一一下）
        expect(page.messages.map((item) => item.serverId), <int>[1, 2]);
        expect(page.messages.first.fromUserName, '小明');
        expect(page.messages.first.conversationId, 'g1');
      },
    );

    test('拉不到数据时给空的一份（不落库）', () async {
      adapter.ok(ChatPaths.messageList, data: null);
      final page = await repository.recordPage(
        conversationId: 'g1',
        isGroup: 0,
      );
      expect(page.messages, isEmpty);
      expect(page.total, 0);
      // 记录页刻意不写本地库
      expect(await db.messagesFor('g1'), isEmpty);
    });

    test('接口挂了会抛出去（页面自己提示并显示空）', () async {
      adapter.fail(ChatPaths.messageList, msg: '记录炸了');
      expect(
        () => repository.recordPage(conversationId: 'g1', isGroup: 0),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('前后文', () {
    test('参数是 msg_id / is_group / direction（数字），结果升序', () async {
      adapter.ok(
        ChatPaths.messageContext,
        data: <Map<String, dynamic>>[message(6), message(5)],
      );

      final messages = await repository.contextMessages(
        msgId: 'm5',
        isGroup: 1,
        direction: ContextDirection.earlier,
      );

      expect(adapter.bodyOf(ChatPaths.messageContext), <String, dynamic>{
        'msg_id': 'm5',
        'is_group': 1,
        'direction': 1,
      });
      expect(messages.map((item) => item.serverId), <int>[5, 6]);
      // 前后文接口不带 toContactId，会话 id 从消息体里推
      expect(messages.first.conversationId, 'g1');
    });

    test('direction=2（更晚）送的是 2', () async {
      adapter.ok(ChatPaths.messageContext, data: <Map<String, dynamic>>[]);
      await repository.contextMessages(
        msgId: 'm5',
        isGroup: 0,
        direction: ContextDirection.later,
      );
      expect(adapter.bodyOf(ChatPaths.messageContext)['direction'], 2);
    });
  });
}
