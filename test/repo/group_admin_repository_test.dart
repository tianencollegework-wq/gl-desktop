import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/data/api/chat_api.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/api/friend_api.dart';
import 'package:gracelinkim/data/api/group_api.dart';
import 'package:gracelinkim/data/db/app_database.dart';
// 会话/消息/通讯录的数据库方法都是 extension，必须 import
import 'package:gracelinkim/data/db/contact_dao.dart';
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/db/message_dao.dart';
import 'package:gracelinkim/data/model/contact.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/data/repo/contact_repository.dart';
import 'package:gracelinkim/data/repo/conversation_repository.dart';
import 'package:gracelinkim/data/repo/group_admin_repository.dart';
import 'package:gracelinkim/domain/chat/group_admin.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 群管理仓库（S5.3）：接口参数 + 该不该动本地库。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late GroupAdminRepository repository;

  /// 创建群聊之后被绑定的群 id（真实实现是 `bindGroup` 那次请求）
  late List<String> bound;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    db = memoryDatabase();
    adapter = StubAdapter();
    final api = adapter.apiClient();
    final conversations = ConversationRepository(db, ChatApi(api));
    final contacts = ContactRepository(db, ChatApi(api), FriendApi(api));
    bound = <String>[];
    repository = GroupAdminRepository(
      GroupApi(api),
      db,
      conversations,
      contacts,
      bindClient: (groupId) async => bound.add(groupId),
    );

    // 本地先有一条群会话 + 群联系人 + 两条消息
    await db.upsertConversation(
      const Conversation(
        id: 'g1',
        displayName: '老群名',
        isGroup: 1,
        role: 1,
        extra: <String, dynamic>{'notice': '旧公告'},
      ),
    );
    await db.upsertContacts(<Contact>[
      const Contact(id: 'g1', displayName: '老群名', isGroup: 1),
    ]);
    await db.upsertMessages(<Message>[
      const Message(
        localId: 1,
        conversationId: 'g1',
        msgId: 'm1',
        type: 'text',
        content: '第一条',
        sendTime: 1000,
      ),
    ]);
  });

  tearDown(() => db.close());

  test('成员列表：解析每项、总数取信封的 count', () async {
    adapter.ok(
      GroupPaths.userList,
      data: <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 1,
          'userInfo': <String, dynamic>{'id': 'u1', 'displayName': '我'},
        },
        <String, dynamic>{
          'role': 3,
          'userInfo': <String, dynamic>{'id': 'u2', 'displayName': '小明'},
        },
      ],
      count: 42,
    );

    final list = await repository.members('g1');

    expect(adapter.bodyOf(GroupPaths.userList), <String, dynamic>{
      'group_id': 'g1',
    });
    expect(list.members.map((member) => member.userId).toList(), <String>[
      'u1',
      'u2',
    ]);
    expect(list.count, 42);
  });

  test('信封没给 count 时退到本页条数（老端那个「N 人」不会显示成 0）', () async {
    adapter.ok(
      GroupPaths.userList,
      data: <Map<String, dynamic>>[
        <String, dynamic>{
          'role': 3,
          'userInfo': <String, dynamic>{'id': 'u2', 'displayName': '小明'},
        },
      ],
    );

    expect((await repository.members('g1')).count, 1);
  });

  test('改群名：接口参数对，本地联系人与会话的名字也改了', () async {
    adapter.ok(GroupPaths.editName, data: null);

    await repository.rename('g1', '新群名');

    expect(adapter.bodyOf(GroupPaths.editName), <String, dynamic>{
      'id': 'g1',
      'displayName': '新群名',
    });
    expect((await db.findContact('g1'))?.displayName, '新群名');
    expect((await db.findConversation('g1'))?.displayName, '新群名');
  });

  test('改公告：参数对，本地会话的 extra.notice 也覆盖', () async {
    adapter.ok(GroupPaths.setNotice, data: null);

    await repository.setNotice('g1', '新公告');

    expect(adapter.bodyOf(GroupPaths.setNotice), <String, dynamic>{
      'id': 'g1',
      'notice': '新公告',
    });
    expect((await db.findConversation('g1'))?.extra['notice'], '新公告');
  });

  test('群管理：整份 setting 一起提交（老端也是整份发）', () async {
    adapter.ok(GroupPaths.setting, data: null);

    await repository.saveSettings('g1', <String, dynamic>{
      'manage': '1',
      'invite': '0',
      'history': '1',
      'profile': '0',
      'nospeak': '2',
    });

    expect(adapter.bodyOf(GroupPaths.setting), <String, dynamic>{
      'id': 'g1',
      'setting': <String, dynamic>{
        'manage': '1',
        'invite': '0',
        'history': '1',
        'profile': '0',
        'nospeak': '2',
      },
    });
  });

  test('禁言：参数是 id / user_id / noSpeakDay / noSpeakTimer', () async {
    adapter.ok(GroupPaths.setNoSpeak, data: null);

    await repository.muteMember(
      groupId: 'g1',
      userId: 'u2',
      choice: const NoSpeakChoice.custom(7),
    );

    expect(adapter.bodyOf(GroupPaths.setNoSpeak), <String, dynamic>{
      'id': 'g1',
      'user_id': 'u2',
      'noSpeakDay': 7,
      'noSpeakTimer': 0,
    });
  });

  test('取消禁言：两个时长字段都是 0', () async {
    adapter.ok(GroupPaths.setNoSpeak, data: null);

    await repository.muteMember(groupId: 'g1', userId: 'u2');

    expect(adapter.bodyOf(GroupPaths.setNoSpeak), <String, dynamic>{
      'id': 'g1',
      'user_id': 'u2',
      'noSpeakDay': 0,
      'noSpeakTimer': 0,
    });
  });

  test('设置/取消管理员：role 2 与 3', () async {
    adapter.ok(GroupPaths.setManager, data: null);

    await repository.setManager(groupId: 'g1', userId: 'u2', role: 2);

    expect(adapter.bodyOf(GroupPaths.setManager), <String, dynamic>{
      'id': 'g1',
      'user_id': 'u2',
      'role': 2,
    });
  });

  test('移出成员：is_black 跟着开关走', () async {
    adapter.ok(GroupPaths.removeUser, data: null);

    await repository.removeMember(groupId: 'g1', userId: 'u2', isBlack: true);

    expect(adapter.bodyOf(GroupPaths.removeUser), <String, dynamic>{
      'id': 'g1',
      'user_id': 'u2',
      'is_black': 1,
    });
  });

  test('转让群主：参数是 id + user_id', () async {
    adapter.ok(GroupPaths.changeOwner, data: null);

    await repository.changeOwner(groupId: 'g1', userId: 'u2');

    expect(adapter.bodyOf(GroupPaths.changeOwner), <String, dynamic>{
      'id': 'g1',
      'user_id': 'u2',
    });
  });

  test('解散群聊：接口对 + 本地联系人与会话一起删', () async {
    adapter.ok(GroupPaths.removeGroup, data: null);

    await repository.disband('g1');

    expect(adapter.bodyOf(GroupPaths.removeGroup), <String, dynamic>{
      'id': 'g1',
    });
    expect(await db.findConversation('g1'), isNull);
    expect(await db.findContact('g1'), isNull);
  });

  test('退出群聊：走 removeUser 把自己移出，本地同样清掉', () async {
    adapter.ok(GroupPaths.removeUser, data: null);

    await repository.quit('g1', 'u1');

    expect(adapter.bodyOf(GroupPaths.removeUser), <String, dynamic>{
      'id': 'g1',
      'user_id': 'u1',
      'is_black': 0,
    });
    expect(await db.findConversation('g1'), isNull);
  });

  test('清空聊天记录：接口对 + 本地消息也清掉', () async {
    adapter.ok(GroupPaths.clearMessage, data: null);

    await repository.clearMessages('g1');

    expect(adapter.bodyOf(GroupPaths.clearMessage), <String, dynamic>{
      'id': 'g1',
    });
    expect(await db.messageCount('g1'), 0);
  });

  test('解散失败时不动本地（不然会话会凭空消失）', () async {
    adapter.fail(GroupPaths.removeGroup, code: 400, msg: '只有群主能解散');

    await expectLater(() => repository.disband('g1'), throwsA(anything));

    expect(await db.findConversation('g1'), isNotNull);
  });

  test('添加成员：一次提交多个 user_id', () async {
    adapter.ok(GroupPaths.addUser, data: null);

    await repository.addMembers(groupId: 'g1', userIds: <String>['u2', 'u3']);

    expect(adapter.bodyOf(GroupPaths.addUser), <String, dynamic>{
      'id': 'g1',
      'user_ids': <String>['u2', 'u3'],
    });
  });

  group('创建群聊（老端 addGroup + appendContacts）', () {
    test('参数只带 user_ids；新群写进通讯录与会话，并绑一次 client', () async {
      adapter.ok(
        GroupPaths.add,
        data: <String, dynamic>{'id': 'g2', 'displayName': '新群', 'is_group': 1},
      );

      final id = await repository.createGroup(userIds: <String>['u2', 'u3']);

      expect(id, 'g2');
      expect(adapter.bodyOf(GroupPaths.add), <String, dynamic>{
        'user_ids': <String>['u2', 'u3'],
      });
      expect((await db.findContact('g2'))?.isGroup, 1);
      expect(await db.findConversation('g2'), isNotNull);
      expect(bound, <String>['g2']);
    });

    test('服务端没返回 id：算失败，不写本地也不绑 client', () async {
      adapter.ok(GroupPaths.add, data: <String, dynamic>{'displayName': '空壳'});

      await expectLater(
        () => repository.createGroup(userIds: <String>['u2']),
        throwsA(anything),
      );

      expect(bound, isEmpty);
    });

    test('一个人都没选：直接拒绝，不发请求', () async {
      await expectLater(
        () => repository.createGroup(userIds: const <String>[]),
        throwsA(anything),
      );

      expect(adapter.paths, isNot(contains(GroupPaths.add)));
    });

    test('绑 client 失败不影响结果（群已经建好了）', () async {
      adapter.ok(
        GroupPaths.add,
        data: <String, dynamic>{'id': 'g3', 'is_group': 1},
      );
      final failing = GroupAdminRepository(
        GroupApi(adapter.apiClient()),
        db,
        ConversationRepository(db, ChatApi(adapter.apiClient())),
        ContactRepository(
          db,
          ChatApi(adapter.apiClient()),
          FriendApi(adapter.apiClient()),
        ),
        bindClient: (groupId) async => throw Exception('bindGroup 炸了'),
      );

      final id = await failing.createGroup(userIds: <String>['u2']);

      expect(id, 'g3');
    });
  });

  group('扫码进群（老端 pages/message/group/info.vue）', () {
    test('群资料：字段形态照老端，接口没给 id 时用传进来的兜底', () async {
      adapter.ok(
        GroupPaths.info,
        data: <String, dynamic>{
          'name': '扫码群',
          'avatar': 'https://cdn.test/g.png',
          'groupUserCount': '12',
          'isJoin': 1,
          'inviteUid': 'u9',
          // 老端是 `setting.invite == 0` 才拦：这里给 0，等于「已关闭加群」
          'setting': <String, dynamic>{'invite': 0},
          'qrUrl': 'https://gracelink.cc/q/g9',
          'qrExpire': '2026-09-26',
        },
      );

      final info = await repository.joinInfo('g9');

      expect(adapter.bodyOf(GroupPaths.info), <String, dynamic>{
        'group_id': 'g9',
      });
      expect(info.id, 'g9');
      expect(info.name, '扫码群');
      expect(info.memberCount, 12);
      expect(info.joined, isTrue);
      expect(info.inviteOpen, isFalse);
      expect(info.inviteUid, 'u9');
      expect(info.qrUrl, 'https://gracelink.cc/q/g9');
      expect(info.qrExpire, '2026-09-26');
    });

    test('加入群聊：参数带 group_id + inviteUid；本地写通讯录/会话并绑 client', () async {
      adapter.ok(GroupPaths.joinGroup, data: <String, dynamic>{'id': 'g9'});

      await repository.join(
        'g9',
        inviteUid: 'u9',
        group: <String, dynamic>{
          'id': 'g9',
          'displayName': '扫码群',
          'avatar': 'https://cdn.test/g.png',
        },
      );

      expect(adapter.bodyOf(GroupPaths.joinGroup), <String, dynamic>{
        'group_id': 'g9',
        'inviteUid': 'u9',
      });
      expect((await db.findContact('g9'))?.isGroup, 1);
      expect((await db.findConversation('g9'))?.displayName, '扫码群');
      expect(bound, <String>['g9']);
    });

    test('加群失败：不动本地、也不绑 client（分组本身没变）', () async {
      adapter.fail(GroupPaths.joinGroup, code: 400, msg: '该群聊已经关闭加群申请');

      await expectLater(() => repository.join('g9'), throwsA(anything));

      expect(await db.findContact('g9'), isNull);
      expect(bound, isEmpty);
    });
  });
}
