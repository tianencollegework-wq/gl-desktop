import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/data/api/chat_api.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/api/friend_api.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/repo/contact_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 通讯录仓库（S5.1）：从两个接口对齐、好友申请计数、WS 增量。
///
/// 走真实的 [ChatApi] / [FriendApi] + 假 adapter，参数名与返回形态
/// （两个接口都是**数组**）都让真实代码跑一遍。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;
  late ContactRepository repository;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    db = memoryDatabase();
    adapter = StubAdapter();
    final api = adapter.apiClient();
    repository = ContactRepository(db, ChatApi(api), FriendApi(api));
  });

  tearDown(() => db.close());

  Map<String, dynamic> friend(
    String id, {
    String name = '小明',
    String index = 'X',
    String py = 'xiaoming',
    int isGroup = 0,
    int online = 0,
  }) => <String, dynamic>{
    'id': id,
    'displayName': name,
    'realname': name,
    'avatar': 'https://cdn.test/$id.png',
    'is_group': isGroup,
    'index': index,
    'name_py': py,
    'account': id,
    'is_online': online,
  };

  test('对齐通讯录：好友接口给好友 + 系统通知，群聊接口给群聊', () async {
    adapter.ok(
      ChatPaths.friendList,
      data: <Map<String, dynamic>>[
        friend('u2', name: '小明'),
        friend('system', name: '系统通知', isGroup: 2, index: ''),
      ],
    );
    adapter.ok(
      ChatPaths.groupList,
      data: <Map<String, dynamic>>[
        friend('g1', name: '产品群', isGroup: 1, index: 'C'),
      ],
    );

    await repository.syncFromServer();

    expect((await repository.watchFriends().first).single.id, 'u2');
    expect((await repository.watchSystems().first).single.id, 'system');
    expect((await repository.watchGroups().first).single.id, 'g1');
    // 两个接口都打过了
    expect(adapter.paths, contains(ChatPaths.friendList));
    expect(adapter.paths, contains(ChatPaths.groupList));
  });

  test('脏数据（没有 id）跳过，不写进库', () async {
    adapter.ok(
      ChatPaths.friendList,
      data: <Map<String, dynamic>>[
        friend('u2'),
        <String, dynamic>{'displayName': '没有 id 的'},
      ],
    );
    adapter.ok(ChatPaths.groupList, data: <Map<String, dynamic>>[]);

    await repository.syncFromServer();

    expect((await repository.all()).map((item) => item.id).toList(), <String>[
      'u2',
    ]);
  });

  test('群聊接口挂了：好友照常落库，不抛异常', () async {
    adapter.ok(
      ChatPaths.friendList,
      data: <Map<String, dynamic>>[friend('u2')],
    );
    adapter.fail(ChatPaths.groupList, msg: '群聊列表炸了');

    await repository.syncFromServer();

    expect((await repository.watchFriends().first).single.id, 'u2');
    expect(await repository.watchGroups().first, isEmpty);
  });

  test('好友接口挂了：本地已有的好友与群聊都还在', () async {
    await repository.upsertFromServer(friend('u2', name: '小明'));
    adapter.fail(ChatPaths.friendList, msg: '好友列表炸了');
    adapter.ok(
      ChatPaths.groupList,
      data: <Map<String, dynamic>>[
        friend('g1', name: '产品群', isGroup: 1, index: 'C'),
      ],
    );

    await repository.syncFromServer();

    expect((await repository.watchFriends().first).single.id, 'u2');
    expect((await repository.watchGroups().first).single.id, 'g1');
  });

  test('待处理的好友申请数：只数 status==2 的（收到的）', () async {
    adapter.ok(
      FriendPaths.applyList,
      data: <Map<String, dynamic>>[
        <String, dynamic>{'id': 1, 'status': 2},
        <String, dynamic>{'id': 2, 'status': 2},
        <String, dynamic>{'id': 3, 'status': 1},
        <String, dynamic>{'id': 4, 'status': 0},
      ],
    );

    expect(await repository.pendingApplyCount(), 2);
    expect(adapter.bodyOf(FriendPaths.applyList), <String, dynamic>{
      'page': 1,
      'limit': 50,
      'is_mine': 0,
    });
  });

  test('申请列表接口挂了：角标算 0，不抛异常', () async {
    adapter.fail(FriendPaths.applyList, msg: '炸了');
    expect(await repository.pendingApplyCount(), 0);
  });

  test('WS 增量：新增联系人 / 在线状态 / 改名 / 删除', () async {
    await repository.upsertFromServer(friend('u2', name: '小明'));
    expect((await repository.find('u2'))!.displayName, '小明');
    // 没有 id 的推送直接忽略
    await repository.upsertFromServer(<String, dynamic>{'displayName': 'x'});
    expect(await repository.all(), hasLength(1));

    await repository.setOnline('u2', 1);
    expect((await repository.find('u2'))!.isOnline, 1);

    await repository.rename('u2', '小明的备注');
    expect((await repository.find('u2'))!.displayName, '小明的备注');

    await repository.remove('u2');
    expect(await repository.find('u2'), isNull);
  });

  test('登出清空通讯录', () async {
    await repository.upsertFromServer(friend('u2'));
    await repository.clear();
    expect(await repository.all(), isEmpty);
  });
}
