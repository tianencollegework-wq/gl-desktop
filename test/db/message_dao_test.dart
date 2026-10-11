import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/db/message_dao.dart';
import 'package:gracelinkim/data/model/message.dart';

import '../support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() => db = memoryDatabase());
  tearDown(() => db.close());

  Message message({
    int? serverId,
    String? msgId,
    String conversationId = 'u1',
    String content = 'hi',
    int sendTime = 1000,
    int isMobile = 0,
  }) => Message(
    serverId: serverId,
    msgId: msgId,
    conversationId: conversationId,
    fromUserId: 'u2',
    fromUserName: '小明',
    content: content,
    sendTime: sendTime,
    isMobile: isMobile,
  );

  group('去重写入（老端 checkMsg 只按 id 判重）', () {
    test('同一服务端 id 重复写入不会变成两条', () async {
      await db.upsertMessages(<Message>[message(serverId: 7, content: '第一次')]);
      await db.upsertMessages(<Message>[message(serverId: 7, content: '第二次')]);

      final list = await db.messagesFor('u1');
      expect(list.length, 1);
      expect(list.single.content, '第二次');
    });

    test('没有服务端 id 时按 msg_id 去重（本地乐观消息的路径）', () async {
      await db.upsertMessages(<Message>[
        message(msgId: 'local-1', content: '发送中'),
      ]);
      await db.upsertMessages(<Message>[
        message(msgId: 'local-1', serverId: 9, content: '已发送'),
      ]);

      final list = await db.messagesFor('u1');
      expect(list.length, 1);
      expect(list.single.serverId, 9);
      expect(list.single.content, '已发送');
    });

    test('两个都没有就不去重（服务端也可能缺字段）', () async {
      await db.upsertMessages(<Message>[message(content: 'a')]);
      await db.upsertMessages(<Message>[message(content: 'b')]);
      expect((await db.messagesFor('u1')).length, 2);
    });

    test('返回值是"新插入"的条数', () async {
      expect(await db.upsertMessages(<Message>[message(serverId: 1)]), 1);
      expect(await db.upsertMessages(<Message>[message(serverId: 1)]), 0);
    });

    test('hasMessage 按 id / msg_id 判重（老端 checkMsg 的等价物）', () async {
      await db.upsertMessages(<Message>[message(serverId: 5, msgId: 'm-5')]);

      expect(await db.hasMessage(conversationId: 'u1', serverId: 5), isTrue);
      expect(await db.hasMessage(conversationId: 'u1', msgId: 'm-5'), isTrue);
      expect(await db.hasMessage(conversationId: 'u1', serverId: 6), isFalse);
      expect(await db.hasMessage(conversationId: 'u2', serverId: 5), isFalse);
    });
  });

  group('读取顺序与游标', () {
    test('读出来是升序（早 → 晚），直接铺进聊天列表', () async {
      await db.upsertMessages(<Message>[
        message(serverId: 3, content: '第三', sendTime: 3000),
        message(serverId: 1, content: '第一', sendTime: 1000),
        message(serverId: 2, content: '第二', sendTime: 2000),
      ]);

      final list = await db.messagesFor('u1');
      expect(list.map((item) => item.content), <String>['第一', '第二', '第三']);
      expect(
        (await db.watchConversation('u1').first).map((item) => item.content),
        <String>['第一', '第二', '第三'],
      );
    });

    test('oldestMessage 给出最旧一条（老端 getMessageList 的 last_id 游标）', () async {
      await db.upsertMessages(<Message>[
        message(serverId: 1, msgId: 'm-1', sendTime: 1000),
        message(serverId: 2, msgId: 'm-2', sendTime: 2000),
      ]);

      final oldest = await db.oldestMessage('u1');
      expect(oldest!.msgId, 'm-1');
    });

    test('limit 生效，取的是最新的 N 条', () async {
      for (var index = 1; index <= 5; index++) {
        await db.upsertMessages(<Message>[
          message(serverId: index, sendTime: index * 1000),
        ]);
      }

      final list = await db.messagesFor('u1', limit: 2);
      expect(list.length, 2);
      expect(list.map((item) => item.sendTime), <int>[4000, 5000]);
    });
  });

  group('已读与撤回', () {
    test('未读数只算本地没标已读的', () async {
      await db.upsertMessages(<Message>[
        message(serverId: 1, sendTime: 1000),
        message(serverId: 2, sendTime: 2000),
      ]);
      expect(await db.unreadCount('u1'), 2);

      await db.markConversationRead('u1');
      expect(await db.unreadCount('u1'), 0);
    });

    test('标记已读不影响别的会话', () async {
      await db.upsertMessages(<Message>[
        message(serverId: 1, conversationId: 'u1'),
        message(serverId: 2, conversationId: 'u2'),
      ]);

      await db.markConversationRead('u1');
      expect(await db.unreadCount('u1'), 0);
      expect(await db.unreadCount('u2'), 1);
    });

    test('patchMessage 标记撤回', () async {
      await db.upsertMessages(<Message>[message(serverId: 4, content: '原话')]);
      final target = await db.findMessage('u1', serverId: 4);

      await db.patchMessage(
        target!.localId!,
        const DbMessagesCompanion(isUndo: Value(1)),
      );

      final updated = await db.findMessage('u1', serverId: 4);
      expect(updated!.isUndo, 1);
      expect(updated.content, '原话');
    });

    test('findMessage 服务端 id 与 msg_id 都能查到同一条', () async {
      await db.upsertMessages(<Message>[message(serverId: 8, msgId: 'm-8')]);

      final byServer = await db.findMessage('u1', serverId: 8);
      final byMsgId = await db.findMessage('u1', msgId: 'm-8');
      expect(byServer!.localId, byMsgId!.localId);
      expect(await db.findMessage('u1'), isNull);
    });
  });

  test('消息里的 at / extends / extra 是 JSON 往返，脏数据不炸', () async {
    await db.upsertMessages(<Message>[
      Message(
        conversationId: 'u1',
        serverId: 1,
        sendTime: 1000,
        at: <String>['me', 'other'],
        ext: <String, dynamic>{'event': 'calling', 'code': 901},
        extra: <String, dynamic>{'is_group': 1},
      ),
    ]);

    final stored = (await db.messagesFor('u1')).single;
    expect(stored.at, <String>['me', 'other']);
    expect(stored.webrtcEvent, 'calling');
    expect(stored.webrtcCode, 901);
    expect(stored.extra['is_group'], 1);
  });

  group('unreadSenders（进聊天页上报已读要按发送人）', () {
    Future<void> put(
      int serverId, {
      required String from,
      int isRead = 0,
      int sendTime = 1000,
    }) => db.upsertMessages(<Message>[
      Message(
        serverId: serverId,
        conversationId: 'g1',
        fromUserId: from,
        content: 'm$serverId',
        sendTime: sendTime,
        isRead: isRead,
      ),
    ]);

    test('只算未读的、别人发的，按最近发消息去重', () async {
      await put(1, from: 'u2', sendTime: 1000);
      await put(2, from: 'u3', sendTime: 2000);
      await put(3, from: 'u2', sendTime: 3000); // u2 又发了一条（更近）
      await put(4, from: 'u9', isRead: 1, sendTime: 4000); // 已经读过
      await put(5, from: 'me', sendTime: 5000); // 自己发的

      expect(await db.unreadSenders('g1', myUserId: 'me'), <String>[
        'u2',
        'u3',
      ]);
    });

    test('没有未读时是空列表（不会白发一次已读上报）', () async {
      await put(1, from: 'u2', isRead: 1);
      expect(await db.unreadSenders('g1', myUserId: 'me'), isEmpty);
    });

    test('limit 限制人数（群里几十个人同时发消息时不要刷屏）', () async {
      for (var i = 1; i <= 8; i++) {
        await put(i, from: 'u$i', sendTime: 1000 * i);
      }
      expect(await db.unreadSenders('g1', myUserId: 'me', limit: 3), <String>[
        'u8',
        'u7',
        'u6',
      ]);
    });
  });

  test('deleteMessages 只清一个会话', () async {
    await db.upsertMessages(<Message>[
      message(serverId: 1, conversationId: 'u1'),
      message(serverId: 2, conversationId: 'u2'),
    ]);

    await db.deleteMessages('u1');
    expect(await db.messageCount('u1'), 0);
    expect(await db.messageCount('u2'), 1);
  });
}
