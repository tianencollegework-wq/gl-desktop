import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/db/message_dao.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/message.dart';

import '../support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUp(() => db = memoryDatabase());
  tearDown(() => db.close());

  Conversation conversation(
    String id, {
    int unread = 0,
    int isTop = 0,
    int lastSendTime = 1000,
    String lastContent = 'hi',
    String draft = '',
  }) => Conversation(
    id: id,
    displayName: '会话$id',
    unread: unread,
    isTop: isTop,
    lastSendTime: lastSendTime,
    lastContent: lastContent,
    draft: draft,
  );

  group('写入与读取', () {
    test('upsert 之后能查到，重复 upsert 不会产生两行', () async {
      await db.upsertConversation(conversation('u1'));
      await db.upsertConversation(conversation('u1', unread: 3));

      final all = await db.allConversations();
      expect(all.length, 1);
      expect(all.single.unread, 3);
    });

    test('读取顺序 = 老端规则（置顶在前、其余按时间倒序）', () async {
      await db.upsertConversation(conversation('old', lastSendTime: 100));
      await db.upsertConversation(conversation('new', lastSendTime: 900));
      await db.upsertConversation(
        conversation('top', lastSendTime: 50, isTop: 1),
      );

      final all = await db.allConversations();
      expect(all.map((item) => item.id), <String>['top', 'new', 'old']);
    });

    test('watch 的流会随写入更新', () async {
      final first = await db.watchConversations().first;
      expect(first, isEmpty);

      await db.upsertConversation(conversation('u1'));
      final second = await db.watchConversations().first;
      expect(second.map((item) => item.id), <String>['u1']);
    });

    test('extra（服务端多给的字段）能原样存取，不丢', () async {
      await db.upsertConversation(
        Conversation.fromServerJson(<String, dynamic>{
          'id': 'u1',
          'displayName': '小明',
          'setting': <String, dynamic>{'profile': '1'},
          'notice': '群公告',
        }),
      );
      final stored = await db.findConversation('u1');
      expect(stored!.extra['notice'], '群公告');
      expect((stored.extra['setting'] as Map)['profile'], '1');
    });
  });

  group('服务端同步（老端是整份替换）', () {
    test('服务端不再返回的会话会被删掉', () async {
      await db.upsertConversation(conversation('gone'));
      await db.upsertConversation(conversation('keep'));

      await db.syncConversations(<Conversation>[conversation('keep')]);

      final all = await db.allConversations();
      expect(all.map((item) => item.id), <String>['keep']);
    });

    test('服务端返回空列表时不清本地（新端刻意的，避免一次异常响应抹掉聊天列表）', () async {
      await db.upsertConversation(conversation('u1', lastSendTime: 100));
      await db.upsertConversation(conversation('u2', lastSendTime: 200));

      await db.syncConversations(<Conversation>[]);

      final all = await db.allConversations();
      expect(all.map((item) => item.id), <String>['u2', 'u1']);
    });

    test('同步不会覆盖本地草稿（老端的草稿是独立 storage key）', () async {
      await db.upsertConversation(conversation('u1', draft: '没写完的话'));

      await db.syncConversations(<Conversation>[
        Conversation.fromServerJson(<String, dynamic>{
          'id': 'u1',
          'displayName': '服务端改名',
        }),
      ]);

      final stored = await db.findConversation('u1');
      expect(stored!.draft, '没写完的话');
      expect(stored.displayName, '服务端改名');
    });
  });

  group('局部更新', () {
    test('patch 只改指定列', () async {
      await db.upsertConversation(
        conversation('u1', unread: 2, isTop: 1, lastContent: '原文'),
      );

      await db.patchConversation(
        'u1',
        const DbConversationsCompanion(unread: Value(0)),
      );

      final stored = await db.findConversation('u1');
      expect(stored!.unread, 0);
      expect(stored.isTop, 1);
      expect(stored.lastContent, '原文');
    });

    test('clearUnread 只清未读，**不**动 @ 角标（老端进聊天页也只清未读）', () async {
      await db.upsertConversation(conversation('u1', unread: 5));
      await db.patchConversation(
        'u1',
        const DbConversationsCompanion(isAt: Value(3)),
      );

      await db.clearUnread('u1');

      final stored = await db.findConversation('u1');
      expect(stored!.unread, 0);
      expect(stored.isAt, 3, reason: '@ 角标要等点开 @ 面板才清');
    });

    test('草稿的存与取（空字符串等于删除）', () async {
      await db.upsertConversation(conversation('u1'));

      await db.saveDraft('u1', '半句话');
      expect(await db.draftOf('u1'), '半句话');

      await db.saveDraft('u1', '');
      expect(await db.draftOf('u1'), '');
    });
  });

  test('删除会话会连本地聊天记录一起删（老端删会话不清记录）', () async {
    await db.upsertConversation(conversation('u1'));
    await db.upsertMessages(<Message>[
      Message(conversationId: 'u1', content: 'a', sendTime: 100),
      Message(conversationId: 'u1', content: 'b', sendTime: 200),
    ]);
    expect(await db.messageCount('u1'), 2);

    await db.deleteConversation('u1');

    expect(await db.findConversation('u1'), isNull);
    expect(await db.messageCount('u1'), 0);
  });
}
