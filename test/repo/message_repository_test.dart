import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/store/cleared_chats.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/data/api/chat_api.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/data/repo/message_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StubAdapter adapter;
  late AppDatabase db;
  late MessageRepository repository;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    // 「清空聊天记录」的名单是单例，每个用例换一份干净的
    ClearedChatsStore.instance = ClearedChatsStore();
    adapter = StubAdapter();
    db = memoryDatabase();
    repository = MessageRepository(db, ChatApi(adapter.apiClient()));
  });

  tearDown(() => db.close());

  Map<String, dynamic> serverMessage({
    required int id,
    required String msgId,
    String content = 'hi',
    int sendTime = 1758163200,
    String type = 'text',
  }) => <String, dynamic>{
    'id': id,
    'msg_id': msgId,
    'content': content,
    'sendTime': sendTime,
    'type': type,
    'at': <String>[],
    'is_group': 0,
    'fromUser': <String, dynamic>{'id': 'u2', 'displayName': '小明'},
    'toContactId': 'u2',
  };

  group('loadPage（对应老端 chat.vue::queryList）', () {
    test('请求参数与老端一字不差', () async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);

      await repository.loadPage(
        conversationId: 'u2',
        isGroup: 1,
        lastId: 'm-3',
        page: 2,
        limit: 30,
      );

      expect(adapter.bodyOf(ChatPaths.messageList), <String, dynamic>{
        'is_group': 1,
        'toContactId': 'u2',
        'last_id': 'm-3',
        'page': 2,
        'limit': 30,
      });
    });

    test('没有游标时 last_id 传空串（老端首次加载就是这样）', () async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);
      await repository.loadPage(conversationId: 'u2', isGroup: 0);

      expect(adapter.bodyOf(ChatPaths.messageList)['last_id'], '');
    });

    test('refreshNewest：拉最新一页（空游标 + page 1）并落库', () async {
      // 本地已经有旧消息（进页面前先出的缓存）
      await repository.save(<Message>[
        Message(
          serverId: 1,
          msgId: 'm-1',
          conversationId: 'u2',
          content: '旧的',
          sendTime: 1000,
        ),
      ]);
      adapter.ok(
        ChatPaths.messageList,
        data: <Map<String, dynamic>>[
          // 离线期间漏了推送：只有服务端有这两条
          serverMessage(id: 8, msgId: 'm-8', content: '漏掉的文字', sendTime: 8000),
          serverMessage(
            id: 9,
            msgId: 'm-9',
            content: '漏掉的图片',
            sendTime: 9000,
            type: 'image',
          ),
        ],
      );

      await repository.refreshNewest(
        conversationId: 'u2',
        isGroup: 0,
        limit: 20,
      );

      // 与老端一致：每次进聊天页都拿空 `last_id` 拉第一页
      expect(adapter.bodyOf(ChatPaths.messageList), <String, dynamic>{
        'is_group': 0,
        'toContactId': 'u2',
        'last_id': '',
        'page': 1,
        'limit': 20,
      });
      // 漏掉的消息真的进了本地库（会话列表有预览、点进去也能看到）
      final stored = await repository.cached('u2');
      expect(stored.map((item) => item.content), <String>[
        '旧的',
        '漏掉的文字',
        '漏掉的图片',
      ]);
    });

    test('返回升序、落库、并给出下一页游标与 hasMore', () async {
      adapter.ok(
        ChatPaths.messageList,
        data: <Map<String, dynamic>>[
          serverMessage(id: 3, msgId: 'm-3', content: '第三', sendTime: 3000),
          serverMessage(id: 1, msgId: 'm-1', content: '第一', sendTime: 1000),
          serverMessage(id: 2, msgId: 'm-2', content: '第二', sendTime: 2000),
        ],
      );

      final page = await repository.loadPage(
        conversationId: 'u2',
        isGroup: 0,
        limit: 3,
      );

      expect(page.messages.map((item) => item.content), <String>[
        '第一',
        '第二',
        '第三',
      ]);
      expect(page.oldestMsgId, 'm-1');
      expect(page.hasMore, isTrue);
      expect(await repository.countIn('u2'), 3);

      // 服务端给的是秒 → 落库毫秒
      expect((await repository.cached('u2')).first.sendTime, 1000000);
    });

    test('不满一页 → hasMore 为假', () async {
      adapter.ok(
        ChatPaths.messageList,
        data: <Map<String, dynamic>>[serverMessage(id: 1, msgId: 'm-1')],
      );

      final page = await repository.loadPage(
        conversationId: 'u2',
        isGroup: 0,
        limit: 20,
      );
      expect(page.hasMore, isFalse);
    });

    test('重复拉同一页不会产生重复消息（按服务端 id 去重）', () async {
      adapter.ok(
        ChatPaths.messageList,
        data: <Map<String, dynamic>>[
          serverMessage(id: 1, msgId: 'm-1'),
          serverMessage(id: 2, msgId: 'm-2'),
        ],
      );

      await repository.loadPage(conversationId: 'u2', isGroup: 0);
      await repository.loadPage(conversationId: 'u2', isGroup: 0);

      expect(await repository.countIn('u2'), 2);
    });

    test('空数组（没有更多历史）不会报错', () async {
      adapter.ok(ChatPaths.messageList, data: <Map<String, dynamic>>[]);

      final page = await repository.loadPage(conversationId: 'u2', isGroup: 0);
      expect(page.isEmpty, isTrue);
      expect(page.hasMore, isFalse);
      expect(page.oldestMsgId, isNull);
    });
  });

  test('缓存流：先给本地，再随写入更新（聊天页首屏不用等接口）', () async {
    expect(await repository.watch('u2').first, isEmpty);

    await repository.saveOne(
      Message.fromServerJson(
        serverMessage(id: 1, msgId: 'm-1'),
        conversationId: 'u2',
      ),
    );

    expect(
      (await repository.watch('u2').first).map((item) => item.msgId),
      <String>['m-1'],
    );
  });

  test('oldest 给出游标（下一页从它往前翻）', () async {
    await repository.save(<Message>[
      Message.fromServerJson(
        serverMessage(id: 1, msgId: 'm-1', sendTime: 1000),
        conversationId: 'u2',
      ),
      Message.fromServerJson(
        serverMessage(id: 2, msgId: 'm-2', sendTime: 2000),
        conversationId: 'u2',
      ),
    ]);

    expect((await repository.oldest('u2'))!.msgId, 'm-1');
  });

  group('已读上报（老端在聊天页收到新消息时调）', () {
    test('参数 {toContactId, is_group, fromUser, messages}', () async {
      await repository.reportRead(
        conversationId: 'u2',
        isGroup: 1,
        fromUserId: 'u9',
      );

      // `messages` 一个键都不能少：服务端 `Im::setMsgIsRead()` 第一行就是
      // `is_array($param['messages'][0] ?? '')`，缺了它 → PHP notice → HTTP 500
      expect(adapter.bodyOf(ChatPaths.setMsgIsRead), <String, dynamic>{
        'toContactId': 'u2',
        'is_group': 1,
        'fromUser': 'u9',
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'fromUser': 'u9'},
        ],
      });
    });

    test('接口失败不抛异常（老端同样静默）', () async {
      adapter.fail(ChatPaths.setMsgIsRead, code: 500);
      await repository.reportRead(
        conversationId: 'u2',
        isGroup: 0,
        fromUserId: 'u9',
      );
      expect(adapter.paths.contains(ChatPaths.setMsgIsRead), isTrue);
    });
  });

  group('撤回', () {
    test('undo：本地标记 isUndo 并调接口带 id', () async {
      final message = Message.fromServerJson(
        serverMessage(id: 8, msgId: 'm-8'),
        conversationId: 'u2',
      );
      await repository.saveOne(message);

      await repository.undo(conversationId: 'u2', serverId: 8);

      expect((await repository.find('u2', serverId: 8))!.isUndo, 1);
      expect(adapter.bodyOf(ChatPaths.undoMessage), <String, dynamic>{'id': 8});
    });

    test('服务端推来的 undoMessage：本地有就标记，没有就安静跳过', () async {
      await repository.saveOne(
        Message.fromServerJson(
          serverMessage(id: 9, msgId: 'm-9'),
          conversationId: 'u2',
        ),
      );

      await repository.applyUndo(
        conversationId: 'u2',
        serverId: 9,
        content: '你撤回了一条消息',
      );

      final updated = await repository.find('u2', serverId: 9);
      expect(updated!.isUndo, 1);
      expect(updated.content, '你撤回了一条消息');

      // 本地没有这条消息：不抛异常（老端会直接改不存在的项）
      await repository.applyUndo(conversationId: 'u2', serverId: 999);
    });
  });

  test('save 的返回值是真正新插入的条数', () async {
    final message = Message.fromServerJson(
      serverMessage(id: 1, msgId: 'm-1'),
      conversationId: 'u2',
    );
    expect(await repository.save(<Message>[message]), 1);
    expect(await repository.save(<Message>[message]), 0);
  });

  group('清空聊天记录（本机那份名单）', () {
    // 服务端没有「只清我这边」的接口，历史还在它库里，所以每次进聊天页
    // 还是会把那页拉回来 —— 清完必须真的看不到，靠的就是这份名单。
    void stubList() {
      adapter.ok(
        ChatPaths.messageList,
        data: <Map<String, dynamic>>[
          serverMessage(id: 11, msgId: 'm-11', sendTime: 11000),
          serverMessage(id: 12, msgId: 'm-12', sendTime: 12000),
        ],
      );
    }

    test('清空之后重新拉回来的那批照样落不进去', () async {
      stubList();
      await repository.refreshNewest(conversationId: 'u2', isGroup: 0);
      expect(await repository.countIn('u2'), 2);

      // 界面上的「清空」：记名单（msgId 与 serverId 都记）→ 删本地
      await ClearedChatsStore.instance.mark(
        'u2',
        ids: <String>{'m-11', '12'},
        lastSendTime: 12000,
      );
      await repository.deleteFor('u2');
      expect(await repository.countIn('u2'), 0);

      // 服务端还是那两条，再拉一次
      await repository.refreshNewest(conversationId: 'u2', isGroup: 0);
      expect(await repository.countIn('u2'), 0);
    });

    test('名单外的消息（真的新消息）照常进', () async {
      await ClearedChatsStore.instance.mark(
        'u2',
        ids: <String>{'m-11'},
        lastSendTime: 11000,
      );

      final stored = await repository.save(<Message>[
        Message.fromServerJson(
          serverMessage(id: 11, msgId: 'm-11'),
          conversationId: 'u2',
        ),
        Message.fromServerJson(
          serverMessage(id: 13, msgId: 'm-13', sendTime: 13000),
          conversationId: 'u2',
        ),
      ]);

      expect(stored, 1);
      expect((await repository.cached('u2')).single.msgId, 'm-13');
    });

    test('只影响被清的那个会话（另一个会话的历史不动）', () async {
      await ClearedChatsStore.instance.mark(
        'u2',
        ids: <String>{'m-11'},
        lastSendTime: 11000,
      );

      expect(
        await repository.save(<Message>[
          Message.fromServerJson(
            serverMessage(id: 11, msgId: 'm-11'),
            conversationId: 'u2',
          ),
          Message.fromServerJson(
            serverMessage(id: 11, msgId: 'm-11'),
            conversationId: 'u3',
          ),
        ]),
        1,
      );
      expect(await repository.countIn('u3'), 1);
      expect(await repository.countIn('u2'), 0);
    });
  });
}
