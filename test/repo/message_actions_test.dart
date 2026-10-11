import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/net/api_exception.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/data/api/chat_api.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/db/message_dao.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/data/repo/message_repository.dart';
import 'package:gracelinkim/data/repo/message_sender.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 撤回 / 删除 / 转发 / @我（S4.5）的仓库层。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late MessageRepository repository;

  const me = UserInfo(
    userId: 'u1',
    displayName: '我',
    raw: <String, dynamic>{'user_id': 'u1', 'displayName': '我'},
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    db = memoryDatabase();
    adapter = StubAdapter();
    repository = MessageRepository(db, ChatApi(adapter.apiClient()));
    await db.upsertConversation(
      const Conversation(id: 'g1', displayName: '同学群', isGroup: 1),
    );
  });

  tearDown(() async {
    await db.close();
  });

  final baseTime = DateTime(2026, 9, 18, 10).millisecondsSinceEpoch;

  Message message(
    int serverId, {
    String type = 'text',
    String content = '你好',
    String fromUserId = 'u1',
    List<String> at = const <String>[],
  }) => Message(
    serverId: serverId,
    msgId: 'm$serverId',
    conversationId: 'g1',
    fromUserId: fromUserId,
    fromUserName: fromUserId == 'u1' ? '我' : '小明',
    type: type,
    content: content,
    sendTime: baseTime + serverId * 1000,
    at: at,
  );

  test('删除：调 delMessage 并把本地那条真的删掉', () async {
    adapter.ok(ChatPaths.delMessage, data: null);
    await repository.save(<Message>[message(1), message(2)]);
    expect(await db.messagesFor('g1'), hasLength(2));

    await repository.delete(conversationId: 'g1', serverId: 1, msgId: 'm1');

    final body = adapter.bodyOf(ChatPaths.delMessage);
    expect(body['id'], 1);
    expect(body['msg_id'], 'm1');
    final left = await db.messagesFor('g1');
    expect(left, hasLength(1));
    expect(left.single.serverId, 2);
  });

  test('删除失败：服务端报错时本地那条不能先删掉', () async {
    adapter.fail(ChatPaths.delMessage, code: 500, msg: '炸了');
    await repository.save(<Message>[message(1)]);

    await expectLater(
      repository.delete(conversationId: 'g1', serverId: 1, msgId: 'm1'),
      throwsA(isA<ApiException>()),
    );
    expect(await db.messagesFor('g1'), hasLength(1), reason: '本地这条要留着');
  });

  test('转发：forwardMessage 带 user_ids 与 msg_id（老端一次请求搞定）', () async {
    adapter.ok(ChatPaths.forwardMessage, data: null);
    await repository.forward(userIds: <String>['u2', 'g1'], msgId: 'm7');

    final body = adapter.bodyOf(ChatPaths.forwardMessage);
    expect(body['user_ids'], <String>['u2', 'g1']);
    expect(body['msg_id'], 'm7');
  });

  test('撤回：服务端确认之后本地才标 is_undo（老端是在 .then 里才 updateMessage）', () async {
    adapter.ok(ChatPaths.undoMessage, data: null);
    await repository.save(<Message>[message(1)]);

    final ok = await repository.undo(
      conversationId: 'g1',
      serverId: 1,
      msgId: 'm1',
    );

    expect(ok, isTrue);
    expect(adapter.bodyOf(ChatPaths.undoMessage)['id'], 1);
    final stored = (await db.messagesFor('g1')).single;
    expect(stored.isUndo, 1);
    expect(stored.content, '你好', reason: '原文要留着，撤回后还能重新编辑');
  });

  test('撤回失败：本地一个字段都不动（不能写「你撤回了一条消息」）', () async {
    adapter.fail(ChatPaths.undoMessage, code: 500, msg: '服务器繁忙，请稍后再试');
    await repository.save(<Message>[message(1)]);

    final ok = await repository.undo(
      conversationId: 'g1',
      serverId: 1,
      msgId: 'm1',
    );

    expect(ok, isFalse);
    expect((await db.messagesFor('g1')).single.isUndo, 0);
  });

  test('撤回刚发出去那条：没有数字 id 时把本机 uuid 当 id 发出去', () async {
    adapter.ok(ChatPaths.undoMessage, data: null);
    // 服务端回执把本机 uuid 原样放在 `id` 里（见 `Message.fromServerJson`），
    // 所以这条只有 `clientId`、没有 `serverId` —— 旧代码这时只发了一个
    // `msg_id`，服务端 `Im.php::undo()` 取 `id` 取不到直接 500（用户 2026-09-30 报的）
    await repository.save(<Message>[
      Message.fromServerJson(<String, dynamic>{
        'id': 'uuid-1',
        'msg_id': 'm100',
        'type': 'text',
        'content': '你好',
        'sendTime': baseTime,
        'toContactId': 'g1',
        'is_group': 1,
        'fromUser': <String, dynamic>{'id': 'u1', 'displayName': '我'},
      }, conversationId: 'g1'),
    ]);

    await repository.undo(conversationId: 'g1', msgId: 'm100');

    final body = adapter.bodyOf(ChatPaths.undoMessage);
    expect(body['id'], 'uuid-1', reason: '老端发的就是手里这个 id');
    expect(body['msg_id'], 'm100');
  });

  test('@我的消息：只挑 at 里带我的，新 → 旧', () async {
    await repository.save(<Message>[
      message(1, at: <String>['u1']),
      message(2, at: <String>['u9']),
      message(3, fromUserId: 'u2', at: <String>['u1', 'u9']),
      message(4),
    ]);

    final mentions = await repository.mentioning('g1', 'u1');
    expect(mentions.map((m) => m.serverId), <int>[3, 1]);
    expect(mentions.first.fromUserName, '小明');
  });

  test('@我：空 id 直接返回空，不查库', () async {
    await repository.save(<Message>[
      message(1, at: <String>['u1']),
    ]);
    expect(await repository.mentioning('g1', ''), isEmpty);
  });

  test('已读上报：setMsgIsRead 的三个参数与老端一致', () async {
    adapter.ok(ChatPaths.setMsgIsRead, data: null);
    await repository.reportRead(
      conversationId: 'g1',
      isGroup: 1,
      fromUserId: 'u2',
    );
    final body = adapter.bodyOf(ChatPaths.setMsgIsRead);
    expect(body['toContactId'], 'g1');
    expect(body['is_group'], 1);
    expect(body['fromUser'], 'u2');
  });

  test('发文本带 at：本地也存下来（会话列表的 @ 标记要用）', () async {
    await db.upsertConversation(
      const Conversation(id: 'g2', displayName: '群', isGroup: 1),
    );
    final sender = MessageSender(db, ChatApi(adapter.apiClient()), Random(1));
    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});

    await sender.sendText(
      conversation: const Conversation(id: 'g2', displayName: '群', isGroup: 1),
      me: me,
      content: '@小明 你好',
      at: <String>['u2'],
    );

    final stored = (await db.messagesFor('g2')).single;
    expect(stored.at, <String>['u2']);
    expect(adapter.bodyOf(ChatPaths.sendMessage)['at'], <String>['u2']);
  });
}
