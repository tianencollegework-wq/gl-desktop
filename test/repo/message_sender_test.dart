import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/util/uuid.dart';
import 'package:gracelinkim/data/api/chat_api.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/db/conversation_dao.dart';
// 数据库方法都是 extension，必须 import 才会进作用域
import 'package:gracelinkim/data/db/message_dao.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/data/repo/message_sender.dart';
import 'package:gracelinkim/data/model/lingting/song.dart';
import 'package:gracelinkim/domain/chat/contact_card.dart';
import 'package:gracelinkim/domain/lingting/lingting_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 发消息（S4.4）：乐观落库 → 接口 → 合并/标红/重发。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late MessageSender sender;

  const me = UserInfo(
    userId: 'u1',
    displayName: '我',
    avatar: 'https://a.test/me.png',
    raw: <String, dynamic>{'user_id': 'u1', 'displayName': '我'},
  );

  const conversation = Conversation(
    id: 'u2',
    displayName: '小明',
    lastContent: '你好',
    lastSendTime: 1000,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    db = memoryDatabase();
    adapter = StubAdapter();
    // 固定 uuid，方便断言请求体（也顺带验证 uuid 格式）
    sender = MessageSender(db, ChatApi(adapter.apiClient()), Random(7));
    await db.upsertConversation(conversation);
  });

  tearDown(() async => db.close());

  /// 服务端回的这条消息（把我们的 uuid 放在 `id` 里，与老端行为一致）
  Map<String, dynamic> serverEcho({
    required String clientId,
    String msgId = 'm100',
    String content = '你好',
    String type = 'text',
  }) => <String, dynamic>{
    'id': clientId,
    'msg_id': msgId,
    'type': type,
    'content': content,
    'sendTime': 1700000000000,
    'is_group': 0,
    'toContactId': 'u2',
    'fromUser': <String, dynamic>{'id': 'u1', 'displayName': '我'},
  };

  test('发文本：先乐观落库（going），成功后合并成一条 sent', () async {
    // 与 sender 内部同一种子，所以第一条消息的 uuid 是确定的
    final expectedId = uuidV4(Random(7));
    adapter.ok(
      ChatPaths.sendMessage,
      data: serverEcho(clientId: expectedId, msgId: 'm100'),
    );
    final payload = sender.sendText(
      conversation: conversation,
      me: me,
      content: '你好',
    );

    // 接口还没回，库里已经有这条了（界面能立刻看到）
    final pending = await db.messagesFor('u2');
    expect(pending, hasLength(1));
    expect(pending.single.status, MessageStatus.going);
    expect(pending.single.content, '你好');
    expect(pending.single.fromUserId, 'u1');
    // 没有服务端 id / msg_id，只有本机 uuid
    expect(pending.single.serverId, isNull);
    expect(pending.single.msgId, isNull);
    expect(pending.single.clientId, expectedId);

    final result = await payload;
    expect(result.ok, isTrue);

    final stored = await db.messagesFor('u2');
    expect(stored, hasLength(1), reason: '不能出现两条');
    expect(stored.single.status, MessageStatus.sent);
    expect(stored.single.msgId, 'm100');

    // 请求体：接口路径与关键字段
    expect(adapter.paths, contains(ChatPaths.sendMessage));
    final body = adapter.bodyOf(ChatPaths.sendMessage);
    expect(body['toContactId'], 'u2');
    expect(body['from_user'], 'u1');
    expect(body['type'], 'text');
    expect(body['content'], '你好');
    expect(body['status'], 'going');
    expect(body['id'], expectedId);
  });

  test('回执是个空对象时不能把本地这条清空（老端是 Object.assign）', () async {
    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
    await sender.sendText(conversation: conversation, me: me, content: '你好');

    final stored = await db.messagesFor('u2');
    expect(stored, hasLength(1));
    expect(stored.single.content, '你好');
    expect(stored.single.fromUserId, 'u1');
    expect(stored.single.sendTime, greaterThan(0));
    expect(stored.single.status, MessageStatus.sent);
  });

  test('回执里带着我们的 uuid：按 uuid 认领（老端就是这么匹配的）', () async {
    // 与 sender 内部同一种子，所以第一条消息的 uuid 是确定的
    final expectedId = uuidV4(Random(7));
    adapter.ok(
      ChatPaths.sendMessage,
      data: serverEcho(clientId: expectedId, msgId: 'm100'),
    );

    await sender.sendText(conversation: conversation, me: me, content: '你好');

    final stored = await db.messagesFor('u2');
    expect(stored, hasLength(1));
    expect(stored.single.clientId, expectedId);
    expect(stored.single.msgId, 'm100');
    expect(stored.single.status, MessageStatus.sent);

    // "服务端把 uuid 也回传了"这件事被记下来了（`docs/protocol/*` 里的待确认项）
    expect(await db.findMessage('u2', clientId: expectedId), isNotNull);
  });

  test('失败：状态变 failed，消息还在（退出页面也还在）', () async {
    adapter.fail(ChatPaths.sendMessage, code: 500, msg: '服务器炸了');
    final result = await sender.sendText(
      conversation: conversation,
      me: me,
      content: '发不出去',
    );

    expect(result.ok, isFalse);
    final stored = await db.messagesFor('u2');
    expect(stored, hasLength(1));
    expect(stored.single.status, MessageStatus.failed);
    expect(stored.single.content, '发不出去');
  });

  test('重发：从 failed 回到 going，成功就是 sent', () async {
    adapter.fail(ChatPaths.sendMessage, code: 500);
    final failed = await sender.sendText(
      conversation: conversation,
      me: me,
      content: '重发试试',
    );

    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
    final retried = await sender.resend(
      message: failed.message,
      me: me,
      isGroup: 0,
    );

    expect(retried.ok, isTrue);
    final stored = await db.messagesFor('u2');
    expect(stored, hasLength(1), reason: '重发是更新同一条，不是再插一条');
    expect(stored.single.status, MessageStatus.sent);
    expect(
      adapter.paths.where((p) => p == ChatPaths.sendMessage),
      hasLength(2),
    );
  });

  test('服务端明确拒绝（code 401，例如被禁言）：这条直接删掉', () async {
    adapter.fail(ChatPaths.sendMessage, code: 401, msg: '群已开启禁言');
    final result = await sender.sendText(
      conversation: conversation,
      me: me,
      content: '发不出去',
    );

    expect(result.ok, isFalse);
    expect(result.removed, isTrue);
    expect(await db.messagesFor('u2'), isEmpty);
  });

  test('WS 回显自己发的消息：认领本机那条，不产生第二条', () async {
    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
    await sender.sendText(conversation: conversation, me: me, content: '你好');
    final before = await db.messagesFor('u2');
    expect(before, hasLength(1));

    // 服务端推来的那份**没有**我们的 uuid，也没有 msg_id，
    // 只有服务端自己的 id —— 三个 id 全对不上，只能靠「同内容 + 还在 going/sent」
    await db.upsertMessages(<Message>[
      Message.fromServerJson(<String, dynamic>{
        'id': 88,
        'type': 'text',
        'content': '你好',
        'sendTime': before.single.sendTime + 500,
        'is_group': 0,
        'toContactId': 'u2',
        'extends': <String, dynamic>{'isMobile': 1},
        'fromUser': <String, dynamic>{'id': 'u1', 'displayName': '我'},
      }, conversationId: 'u2'),
    ]);

    final after = await db.messagesFor('u2');
    expect(after, hasLength(1), reason: '回显不能多出一条');
    expect(after.single.serverId, 88);
    expect(after.single.clientId, before.single.clientId);
  });

  test('同内容的两条在不同时间发出去不会被认领错（相隔太久不认）', () async {
    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
    await sender.sendText(conversation: conversation, me: me, content: '在吗');
    // 隔了 5 分钟才来一条内容相同的消息（不是我发的那条）
    await db.upsertMessages(<Message>[
      Message.fromServerJson(<String, dynamic>{
        'id': 99,
        'type': 'text',
        'content': '在吗',
        'sendTime': DateTime.now().millisecondsSinceEpoch + 600 * 1000,
        'fromUser': <String, dynamic>{'id': 'u1', 'displayName': '我'},
      }, conversationId: 'u2'),
    ]);

    expect(await db.messagesFor('u2'), hasLength(2));
  });

  test('发完立刻更新会话列表的最后一条', () async {
    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
    await sender.sendText(conversation: conversation, me: me, content: '最后一条');

    final updated = await db.findConversation('u2');
    expect(updated!.lastContent, '最后一条');
    expect(updated.lastType, 'text');
    expect(updated.lastSendTime, greaterThan(conversation.lastSendTime));
    // 自己发的不加未读
    expect(updated.unread, 0);
  });

  test('收藏表情：type 是 emoji，content 是图片地址，带 file_id', () async {
    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
    await sender.sendSticker(
      conversation: conversation,
      me: me,
      url: 'https://a.test/s.png',
      fileId: 12,
    );

    final body = adapter.bodyOf(ChatPaths.sendMessage);
    expect(body['type'], 'emoji');
    expect(body['content'], 'https://a.test/s.png');
    expect(body['file_id'], 12);
    final stored = await db.messagesFor('u2');
    expect(stored.single.type, 'emoji');
  });

  test('群通话记录：type 是 webrtc，文案是「群通话 00:45」，extends 带群通话记号', () async {
    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
    const group = Conversation(id: 'group-5', displayName: '产品群', isGroup: 1);
    await db.upsertConversation(group);

    await sender.sendGroupCallRecord(
      conversation: group,
      me: me,
      seconds: 45,
      participants: 3,
      translate: (key) => key == 'group.callRecord' ? '群通话 {time}' : key,
    );

    final body = adapter.bodyOf(ChatPaths.sendMessage);
    expect(body['type'], 'webrtc', reason: '老端的 im-webrtc.vue 就是按这个类型画气泡的');
    expect(body['content'], '群通话 00:45');
    expect(body['is_group'], 1);
    expect(body['toContactId'], 'group-5');
    expect(body['extends'], <String, dynamic>{
      'type': 0,
      'group_call': 1,
      'callTime': 45,
      'participants': 3,
    });
    // 通话记录发出去就撤不回来，也不是引用消息
    expect(body.containsKey('pid'), isFalse);

    final stored = await db.messagesFor('group-5');
    expect(stored.single.type, 'webrtc');
    expect(stored.single.content, '群通话 00:45');
    expect(stored.single.isGroup, 1);
    // 会话列表跟着动（群里那条预览就是这个）
    final row = await db.findConversation('group-5');
    expect(row?.lastType, 'webrtc');
    expect(row?.lastContent, '群通话 00:45');
  });

  test('群通话记录：没给翻译函数时用 key 本身（只影响文案，不影响能不能发出去）', () async {
    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
    const group = Conversation(id: 'group-5', displayName: '产品群', isGroup: 1);
    await db.upsertConversation(group);

    await sender.sendGroupCallRecord(
      conversation: group,
      me: me,
      seconds: 3,
      participants: 2,
    );

    expect(
      adapter.bodyOf(ChatPaths.sendMessage)['content'],
      'group.callRecord 00:03',
    );
  });

  test('名片：type 是 contact，content 是「[个人名片] 名字」，extends 带三个字段', () async {
    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});

    await sender.sendContactCard(
      conversation: conversation,
      me: me,
      card: const ContactCard(
        id: 'u3',
        displayName: '小红',
        avatar: 'https://a.test/xh.png',
      ),
      translate: (key) => key == 'chat.userIDcard' ? '个人名片' : key,
    );

    final body = adapter.bodyOf(ChatPaths.sendMessage);
    expect(body['type'], 'contact');
    expect(body['content'], '[个人名片] 小红');
    expect(body['extends'], <String, dynamic>{
      'avatar': 'https://a.test/xh.png',
      'displayName': '小红',
      'id': 'u3',
    });
    // 名片不是引用消息，不能给它塞 pid
    expect(body.containsKey('pid'), isFalse);

    final stored = await db.messagesFor('u2');
    expect(stored.single.type, 'contact');
    expect(stored.single.content, '[个人名片] 小红');
    // 假适配器是立刻回的，所以这里已经是「已发送」（拆开看就是乐观 going → 合并 sent）
    expect(stored.single.status, MessageStatus.sent);
    // 会话列表跟着动（老端是等 WS 回显，新端提前一步）
    final row = await db.findConversation('u2');
    expect(row?.lastType, 'contact');
    expect(row?.lastContent, '[个人名片] 小红');
  });

  test(
    '音乐卡片：type 是 lingting，content 是「[音乐] 《歌名》- 歌手」，extends 带播放要的字段',
    () async {
      adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});

      await sender.sendMusicCard(
        conversation: conversation,
        me: me,
        card: MusicCard.fromSong(
          const LingtingSong(
            songId: 236,
            name: '一粒麦子',
            singerName: '小羊诗歌',
            singerId: 88,
            albumName: '一粒麦子',
            albumId: 4229,
            cover: 'https://x/cover.jpg',
            audioUrl: 'https://x/236.mp3',
          ),
        ),
        translate: (key) => key == 'common.music' ? '音乐' : key,
      );

      final body = adapter.bodyOf(ChatPaths.sendMessage);
      expect(body['type'], 'lingting');
      expect(body['content'], '[音乐] 《一粒麦子》- 小羊诗歌');
      // 这些字段是对方点开就能播、并且能查到歌手/专辑的全部依据（不靠联网）
      expect(body['extends'], <String, dynamic>{
        'songId': 236,
        'name': '一粒麦子',
        'singer': '小羊诗歌',
        'singerId': 88,
        'album': '一粒麦子',
        'albumId': 4229,
        'cover': 'https://x/cover.jpg',
        'audioUrl': 'https://x/236.mp3',
      });
      expect(body.containsKey('pid'), isFalse, reason: '卡片不是引用消息');

      final stored = await db.messagesFor('u2');
      expect(stored.single.type, 'lingting');
      expect(stored.single.status, MessageStatus.sent);
      final row = await db.findConversation('u2');
      expect(row?.lastType, 'lingting');
    },
  );

  test('音乐卡片：接口失败只标红，不误报成功', () async {
    adapter.fail(ChatPaths.sendMessage, code: 500, msg: '服务器炸了');

    final result = await sender.sendMusicCard(
      conversation: conversation,
      me: me,
      card: MusicCard.fromSong(const LingtingSong(songId: 1, name: '云上太阳')),
    );

    expect(result.ok, isFalse);
    expect((await db.messagesFor('u2')).single.status, MessageStatus.failed);
  });

  test('名片：接口失败只标红，不误报成功', () async {
    adapter.fail(ChatPaths.sendMessage, code: 500, msg: '服务器炸了');

    final result = await sender.sendContactCard(
      conversation: conversation,
      me: me,
      card: const ContactCard(id: 'u3', displayName: '小红', avatar: ''),
    );

    expect(result.ok, isFalse);
    expect((await db.messagesFor('u2')).single.status, MessageStatus.failed);
  });

  test('引用消息：请求体里带 pid 与 extends（引用块）', () async {
    adapter.ok(ChatPaths.sendMessage, data: <String, dynamic>{});
    final quoted = Message(
      msgId: 'm7',
      serverId: 7,
      conversationId: 'u2',
      fromUserId: 'u2',
      fromUserName: '小明',
      type: 'text',
      content: '你好',
      sendTime: 1000,
    );

    await sender.sendText(
      conversation: conversation,
      me: me,
      content: '回复你',
      quoted: quoted,
      translate: (key) => key,
    );

    final body = adapter.bodyOf(ChatPaths.sendMessage);
    expect(body['pid'], 'm7');
    expect(body['extends'], <String, dynamic>{
      'msg_id': 'm7',
      'content': '小明：你好',
      'user_id': 'u2',
      'realname': '小明',
    });
  });
}
