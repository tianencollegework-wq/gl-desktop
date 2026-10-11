import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/store/cleared_chats.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/data/api/chat_api.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/data/repo/conversation_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StubAdapter adapter;
  late AppDatabase db;
  late ConversationRepository repository;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    // 「清空聊天记录」的名单是单例，每个用例换一份干净的
    ClearedChatsStore.instance = ClearedChatsStore();
    adapter = StubAdapter();
    db = memoryDatabase();
    repository = ConversationRepository(db, ChatApi(adapter.apiClient()));
  });

  tearDown(() => db.close());

  Message incoming({
    String conversationId = 'u2',
    String fromUserId = 'u2',
    String content = '你好',
    int sendTime = 1758163200, // 秒（服务端给的是秒）
    List<String> at = const <String>[],
  }) => Message.fromServerJson(<String, dynamic>{
    'id': 11,
    'msg_id': 'm-11',
    'content': content,
    'sendTime': sendTime,
    'type': 'text',
    'at': at,
    'is_group': 0,
    'fromUser': <String, dynamic>{
      'id': fromUserId,
      'displayName': '小明',
      'avatar': 'a.png',
    },
    'toContactId': 'me',
    'toUser': conversationId,
  }, conversationId: conversationId);

  group('服务端同步', () {
    test('数组响应能吃下（老端 getContacts 返回数组）', () async {
      adapter.ok(
        ChatPaths.contacts,
        data: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'u1',
            'displayName': '小红',
            'lastContent': '在吗',
            'lastSendTime': 1758163200,
            'unread': 2,
            'is_top': 1,
            'is_group': 0,
          },
          <String, dynamic>{'id': 'g1', 'displayName': '群一', 'is_group': 1},
        ],
      );

      final synced = await repository.syncFromServer();

      expect(synced.length, 2);
      final stored = await db.allConversations();
      final u1 = stored.firstWhere((item) => item.id == 'u1');
      expect(u1.displayName, '小红');
      expect(u1.unread, 2);
      expect(u1.isTop, 1);
      // 服务端给的是秒 → 入库是毫秒
      expect(u1.lastSendTime, 1758163200000);
      // 置顶的排前面
      expect(stored.first.id, 'u1');
    });

    test('脏数据（没有 id）被跳过，不污染列表', () async {
      adapter.ok(
        ChatPaths.contacts,
        data: <Map<String, dynamic>>[
          <String, dynamic>{'displayName': '没有 id'},
          <String, dynamic>{'id': 'ok', 'displayName': '正常'},
        ],
      );

      await repository.syncFromServer();
      expect((await db.allConversations()).map((item) => item.id), <String>[
        'ok',
      ]);
    });

    test('同步会删掉服务端不再返回的会话（老端整份替换）', () async {
      adapter.ok(
        ChatPaths.contacts,
        data: <Map<String, dynamic>>[
          <String, dynamic>{'id': 'a'},
          <String, dynamic>{'id': 'b'},
        ],
      );
      await repository.syncFromServer();

      adapter.ok(
        ChatPaths.contacts,
        data: <Map<String, dynamic>>[
          <String, dynamic>{'id': 'b'},
        ],
      );
      await repository.syncFromServer();

      expect((await db.allConversations()).map((item) => item.id), <String>[
        'b',
      ]);
    });
  });

  group('推送消息落地', () {
    test('新会话：用发送者信息建一条，未读 1', () async {
      await repository.applyIncomingMessage(incoming(), myUserId: 'me');

      final stored = await db.findConversation('u2');
      expect(stored, isNotNull);
      expect(stored!.displayName, '小明');
      expect(stored.unread, 1);
      expect(stored.lastContent, '你好');
      expect(stored.lastSendTime, 1758163200000);
    });

    test('已有会话：未读累加、最后一条刷新，草稿与置顶不被覆盖', () async {
      adapter.ok(
        ChatPaths.contacts,
        data: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'u2',
            'is_top': 1,
            'unread': 4,
            'is_notice': 0,
          },
        ],
      );
      await repository.syncFromServer();
      await repository.saveDraft('u2', '没写完');

      await repository.applyIncomingMessage(incoming(), myUserId: 'me');

      final stored = await db.findConversation('u2');
      expect(stored!.unread, 5);
      expect(stored.isTop, 1);
      expect(stored.isNotice, 0);
      expect(stored.draft, '没写完');
      expect(stored.lastContent, '你好');
    });

    test('自己发的消息不增加未读', () async {
      await repository.applyIncomingMessage(
        incoming(fromUserId: 'me', conversationId: 'u3'),
        myUserId: 'me',
      );

      final stored = await db.findConversation('u3');
      expect(stored!.unread, 0);
      expect(stored.lastContent, '你好');
    });

    test('系统消息不建会话（老端只把 sysUnread 加一）', () async {
      final result = await repository.applyIncomingMessage(
        incoming(conversationId: 'system'),
        myUserId: 'me',
      );
      expect(result, isNull);
      expect(await db.allConversations(), isEmpty);
    });

    test('@ 到我时 is_at 增加', () async {
      await repository.applyIncomingMessage(
        incoming(conversationId: 'g1', at: <String>['me']),
        myUserId: 'me',
      );

      final stored = await db.findConversation('g1');
      expect(stored!.isAt, 1);
    });
  });

  group('本地状态操作', () {
    setUp(() async {
      adapter.ok(
        ChatPaths.contacts,
        data: <Map<String, dynamic>>[
          <String, dynamic>{'id': 'u1', 'unread': 3, 'is_at': 2},
        ],
      );
      await repository.syncFromServer();
    });

    test('置顶：本地先改，接口参数与老端一致（含 is_group）', () async {
      await repository.setTop('u1', 1, isGroup: 0);

      expect((await db.findConversation('u1'))!.isTop, 1);
      expect(adapter.bodyOf(ChatPaths.setChatTop), <String, dynamic>{
        'id': 'u1',
        'is_top': 1,
        'is_group': 0,
      });
    });

    test('免打扰：参数 {id, is_notice, is_group}（老端 isNotice 接口）', () async {
      await repository.setNotice('u1', 0, isGroup: 1);

      expect((await db.findConversation('u1'))!.isNotice, 0);
      expect(adapter.bodyOf(ChatPaths.isNotice), <String, dynamic>{
        'id': 'u1',
        'is_notice': 0,
        'is_group': 1,
      });
    });

    test('接口失败不影响本地状态（老端是等接口成功才改）', () async {
      adapter.fail(ChatPaths.setChatTop);

      await repository.setTop('u1', 1, isGroup: 0);
      expect((await db.findConversation('u1'))!.isTop, 1);
    });

    test('清未读：不调接口（老端进聊天页只改本地），且不动 @ 角标', () async {
      await repository.markReadLocally('u1');

      final stored = await db.findConversation('u1');
      expect(stored!.unread, 0);
      expect(stored.isAt, 2, reason: '@ 角标要等点开 @ 面板才清（clearAt）');
      expect(adapter.paths.contains(ChatPaths.setMsgIsRead), isFalse);
    });

    test('清 @：调 readAtMsg 并把 is_at 归零', () async {
      await repository.clearAt('u1');

      expect((await db.findConversation('u1'))!.isAt, 0);
      expect(adapter.bodyOf(ChatPaths.readAtMsg), <String, dynamic>{
        'toContactId': 'u1',
      });
    });

    test('在线状态只改本地', () async {
      await repository.setOnline('u1', 1);
      expect((await db.findConversation('u1'))!.isOnline, 1);
    });

    test('删除会话：本地删除 + 调 delChat', () async {
      await repository.remove('u1', isGroup: 0);

      expect(await db.findConversation('u1'), isNull);
      expect(adapter.bodyOf(ChatPaths.delChat), <String, dynamic>{
        'id': 'u1',
        'is_group': 0,
      });
    });

    test('陌生会话的 contactInfo 能补成一条会话', () async {
      await repository.ensureFromContactInfo(<String, dynamic>{
        'id': 'stranger',
        'displayName': '陌生人',
      });

      expect((await db.findConversation('stranger'))!.displayName, '陌生人');
      // 已经存在时不再重复写
      adapter.requests.clear();
      await repository.ensureFromContactInfo(<String, dynamic>{
        'id': 'stranger',
        'displayName': '改了名',
      });
      expect((await db.findConversation('stranger'))!.displayName, '陌生人');
    });
  });

  group('未读汇总与草稿', () {
    test('watchTotals 按老端口径汇总', () async {
      adapter.ok(
        ChatPaths.contacts,
        data: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'a',
            'unread': 3,
            'is_notice': 1,
            'lastContent': 'x',
          },
          <String, dynamic>{
            'id': 'b',
            'unread': 9,
            'is_notice': 0,
            'lastContent': 'y',
          },
          <String, dynamic>{'id': 'c', 'is_at': 2, 'lastContent': 'z'},
        ],
      );
      await repository.syncFromServer();

      final totals = await repository.totals();
      expect(totals.unread, 3);
      expect(totals.at, 2);
      expect(totals.unreadIds, <String>['a', 'c']);
    });

    test('草稿存取', () async {
      adapter.ok(
        ChatPaths.contacts,
        data: <Map<String, dynamic>>[
          <String, dynamic>{'id': 'd'},
        ],
      );
      await repository.syncFromServer();

      await repository.saveDraft('d', '半句');
      expect(await repository.draft('d'), '半句');
    });
  });

  group('清空聊天记录：会话列表那行预览', () {
    void stubContacts({required int lastSendTime, String content = '在吗'}) {
      adapter.ok(
        ChatPaths.contacts,
        data: <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'u9',
            'displayName': '小明',
            'lastContent': content,
            'lastSendTime': lastSendTime,
            'unread': 3,
            'is_at': 1,
            'is_group': 0,
          },
        ],
      );
    }

    // 服务端那条最后一条的 sendTime（秒）→ 本地毫秒，和消息上的 `sendTime` 对齐
    const int lastSendTime = 1758163200000;

    test('服务端最后一条正好是被清掉的那条 → 预览抹掉（红点也一起清）', () async {
      stubContacts(lastSendTime: 1758163200);
      await repository.syncFromServer();
      expect((await repository.find('u9'))!.lastContent, '在吗');

      await ClearedChatsStore.instance.mark(
        'u9',
        ids: <String>{'m-1'},
        lastSendTime: lastSendTime,
      );
      await repository.syncFromServer();

      final conversation = (await repository.find('u9'))!;
      expect(conversation.lastContent, isEmpty);
      expect(conversation.unread, 0);
      expect(conversation.isAt, 0);
    });

    test('之后来了新消息（时间戳变了）→ 预览照常显示', () async {
      await ClearedChatsStore.instance.mark(
        'u9',
        ids: <String>{'m-1'},
        lastSendTime: lastSendTime,
      );
      stubContacts(lastSendTime: 1758163300, content: '新消息');
      await repository.syncFromServer();

      final conversation = (await repository.find('u9'))!;
      expect(conversation.lastContent, '新消息');
      expect(conversation.unread, 3);
    });
  });

  test('仓库的 provider 用注入的容器也不炸（内存库覆盖）', () async {
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);

    final repo = container.read(conversationRepositoryProvider);
    expect(await repo.all(), isEmpty);
  });
}
