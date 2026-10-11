import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/db/app_database.dart';
// 通讯录的数据库方法是以 extension 形式提供的，必须 import
import 'package:gracelinkim/data/db/contact_dao.dart';
import 'package:gracelinkim/data/model/contact.dart';

import '../support/test_database.dart';

/// 通讯录落库（S5.1）。
///
/// 重点在**同步的删除边界**：好友与群聊来自两个接口，任何一份空响应
/// 都不该把另一份（或本地缓存）带走。
void main() {
  late AppDatabase db;

  setUp(() => db = memoryDatabase());
  tearDown(() => db.close());

  Contact friend(
    String id, {
    String name = '',
    String py = '',
    int isGroup = 0,
    int isOnline = 0,
  }) => Contact(
    id: id,
    displayName: name,
    namePy: py,
    isGroup: isGroup,
    isOnline: isOnline,
  );

  test('写入后能按 id 取回，字段不丢', () async {
    await db.upsertContact(
      Contact(
        id: 'u2',
        displayName: '小明',
        realName: '李明',
        avatar: 'https://cdn.test/a.png',
        indexLetter: 'X',
        namePy: 'xiaoming',
        account: 'xm01',
        isOnline: 1,
        extra: <String, dynamic>{'dep_id': 3},
      ),
    );

    final stored = await db.findContact('u2');
    expect(stored, isNotNull);
    expect(stored!.displayName, '小明');
    expect(stored.realName, '李明');
    expect(stored.indexLetter, 'X');
    expect(stored.account, 'xm01');
    expect(stored.isOnline, 1);
    expect(stored.extra['dep_id'], 3);
    // 空 id 不该写进去
    await db.upsertContact(friend(''));
    expect(await db.allContacts(), hasLength(1));
  });

  test('流吐出的顺序：好友 → 群聊 → 系统，同类按拼音', () async {
    await db.upsertContacts(<Contact>[
      friend('g1', name: '产品群', isGroup: 1),
      friend('u2', name: '小明', py: 'xiaoming'),
      friend('system', name: '系统通知', isGroup: 2),
      friend('u1', name: '小红', py: 'xiaohong'),
    ]);

    final list = await db.allContacts();
    expect(list.map((item) => item.id).toList(), <String>[
      'u1',
      'u2',
      'g1',
      'system',
    ]);

    expect((await db.watchFriends().first).length, 2);
    expect((await db.watchGroups().first).single.id, 'g1');
    expect((await db.watchSystems().first).single.id, 'system');
  });

  test('同步好友：补新、更新旧、删掉服务端不再返回的', () async {
    await db.upsertContacts(<Contact>[
      friend('u1', name: '旧名字'),
      friend('u2', name: '要被删的'),
      friend('g1', name: '群', isGroup: 1),
    ]);

    await db.syncContacts(
      <Contact>[friend('u1', name: '新名字'), friend('u3', name: '新加的')],
      kinds: const <int>{0, 2},
    );

    final friends = await db.watchFriends().first;
    expect(friends.map((item) => item.id).toList(), <String>['u1', 'u3']);
    expect(friends.first.displayName, '新名字');
    // 群聊不在这份同步的范围里，必须原样留着
    expect((await db.watchGroups().first).single.id, 'g1');
  });

  test('同步群聊不会碰好友；服务端不再返回的群会被删掉', () async {
    await db.upsertContacts(<Contact>[
      friend('u1', name: '小明'),
      friend('g1', name: '旧群', isGroup: 1),
      friend('g2', name: '退出的群', isGroup: 1),
    ]);

    await db.syncContacts(
      <Contact>[friend('g1', name: '改名后的群', isGroup: 1)],
      kinds: const <int>{1},
    );

    final groups = await db.watchGroups().first;
    expect(groups.map((item) => item.id).toList(), <String>['g1']);
    expect((await db.watchFriends().first).single.id, 'u1');
  });

  test('空响应保留本地（token 过期/网关抽风不该清空通讯录）', () async {
    await db.upsertContacts(<Contact>[
      friend('u1', name: '小明'),
      friend('g1', name: '群', isGroup: 1),
    ]);

    await db.syncContacts(const <Contact>[], kinds: const <int>{0, 2});

    expect(await db.allContacts(), hasLength(2));
  });

  test('同步里混进别的类型（is_group=1）的项会被忽略', () async {
    await db.syncContacts(
      <Contact>[
        friend('u1', name: '小明'),
        friend('g9', name: '混进来的群', isGroup: 1),
      ],
      kinds: const <int>{0, 2},
    );

    expect((await db.watchFriends().first).single.id, 'u1');
    expect(await db.watchGroups().first, isEmpty);
  });

  test('局部更新只改给的字段（WS 推送）', () async {
    await db.upsertContact(
      Contact(id: 'u1', displayName: '小明', namePy: 'xiaoming'),
    );

    await db.patchContact('u1', const DbContactsCompanion(isOnline: Value(1)));
    await db.patchContact(
      'u1',
      const DbContactsCompanion(displayName: Value('新的名字')),
    );

    final stored = await db.findContact('u1');
    expect(stored!.isOnline, 1);
    expect(stored.displayName, '新的名字');
    expect(stored.namePy, 'xiaoming');
  });

  test('删除与清空', () async {
    await db.upsertContacts(<Contact>[friend('u1'), friend('g1', isGroup: 1)]);

    await db.deleteContact('u1');
    expect((await db.allContacts()).single.id, 'g1');

    await db.clearContacts();
    expect(await db.allContacts(), isEmpty);
  });
}
