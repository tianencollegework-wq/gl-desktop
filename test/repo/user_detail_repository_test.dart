import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/net/api_exception.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/data/api/chat_api.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/api/friend_api.dart';
import 'package:gracelinkim/data/db/app_database.dart';
// 通讯录/会话的数据库方法都是 extension，必须 import
import 'package:gracelinkim/data/db/contact_dao.dart';
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/model/contact.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/repo/contact_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 用户详情与好友操作（S5.2）。
///
/// 走真实的 [ChatApi] / [FriendApi] + 假 adapter：参数名（`user_id` / `group_id` /
/// `remark` / `is_black` / `friend_id` / `nickname`）与「成功后要不要动本地库」
/// 都让真实代码跑一遍。
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

  Map<String, dynamic> detailJson({
    String userId = 'u2',
    String realname = '小明',
    String account = '13800000000',
    Map<String, dynamic>? friend,
  }) => <String, dynamic>{
    'user_id': userId,
    'realname': realname,
    'account': account,
    'avatar': 'https://cdn.test/$userId.png',
    'email': 'u2@example.test',
    'sex': 1,
    'friend': ?friend,
    'contactInfo': <String, dynamic>{'id': userId, 'displayName': realname},
  };

  test('取用户详情：参数只有 user_id（老端会把 undefined 的 group_id 发出去）', () async {
    adapter.ok(
      ChatPaths.userInfo,
      data: detailJson(friend: <String, dynamic>{'friend_id': 2}),
    );

    final detail = await repository.userDetail('u2');

    expect(adapter.bodyOf(ChatPaths.userInfo), <String, dynamic>{
      'user_id': 'u2',
    });
    expect(detail.userId, 'u2');
    expect(detail.isFriend, isTrue);
  });

  test('从群里点进来时带 group_id', () async {
    adapter.ok(ChatPaths.userInfo, data: detailJson());

    await repository.userDetail('u2', groupId: 'group-5');

    expect(adapter.bodyOf(ChatPaths.userInfo), <String, dynamic>{
      'user_id': 'u2',
      'group_id': 'group-5',
    });
  });

  test('不是群会话 id（`group-` 开头）就干脆不发 group_id', () async {
    // 单聊的会话 id 就是对方的 user_id（如 `5`）。老端聊天信息页点对方头像
    // 会把它当 group_id 发出来，服务端 `Im::getUserInfo` 里
    // `explode('-', $group_id)[1]` 踩 undefined offset → 500 →「服务器繁忙」。
    adapter.ok(ChatPaths.userInfo, data: detailJson());

    await repository.userDetail('u2', groupId: '5');

    expect(adapter.bodyOf(ChatPaths.userInfo), <String, dynamic>{
      'user_id': 'u2',
    });
  });

  test('加好友：参数是 user_id + remark，回执的 msg 带出来', () async {
    adapter.ok(FriendPaths.add, data: null);

    final message = await repository.addFriend(userId: 'u2', remark: '我是老王');

    expect(adapter.bodyOf(FriendPaths.add), <String, dynamic>{
      'user_id': 'u2',
      'remark': '我是老王',
    });
    expect(message, 'ok');
  });

  test('删除好友：参数是 id + is_black，成功后连本地联系人一起删', () async {
    await db.upsertContacts(<Contact>[
      const Contact(id: 'u2', displayName: '小明'),
    ]);
    adapter.ok(FriendPaths.del, data: null);

    await repository.deleteFriend('u2', isBlack: true);

    expect(adapter.bodyOf(FriendPaths.del), <String, dynamic>{
      'id': 'u2',
      'is_black': 1,
    });
    expect(await db.findContact('u2'), isNull);
  });

  test('删除好友不勾黑名单时 is_black 是 0', () async {
    adapter.ok(FriendPaths.del, data: null);

    await repository.deleteFriend('u2');

    expect(adapter.bodyOf(FriendPaths.del), <String, dynamic>{
      'id': 'u2',
      'is_black': 0,
    });
  });

  test('接口失败时不动本地（不然列表里那行会凭空消失）', () async {
    await db.upsertContacts(<Contact>[
      const Contact(id: 'u2', displayName: '小明'),
    ]);
    adapter.fail(FriendPaths.del, code: 400, msg: '删除失败');

    await expectLater(
      () => repository.deleteFriend('u2'),
      throwsA(isA<BusinessException>()),
    );

    expect((await db.findContact('u2'))?.displayName, '小明');
  });

  test('改备注：参数是 friend_id + nickname，成功后本地显示名也改掉', () async {
    await db.upsertContacts(<Contact>[
      const Contact(id: 'u2', displayName: '小明'),
    ]);
    await db.upsertConversation(
      Conversation(id: 'u2', displayName: '小明', lastSendTime: 1),
    );
    adapter.ok(FriendPaths.setNickname, data: null);

    final message = await repository.setFriendNickname(
      userId: 'u2',
      friendId: '2',
      nickname: '小明明',
    );

    expect(adapter.bodyOf(FriendPaths.setNickname), <String, dynamic>{
      'friend_id': 2,
      'nickname': '小明明',
    });
    expect((await db.findContact('u2'))?.displayName, '小明明');
    // 会话行（聊天列表与聊天页标题读它）也要跟着改，不然名字看着像没生效
    expect((await db.findConversation('u2'))?.displayName, '小明明');
    expect(message, 'ok');
  });

  test('清空备注：nickname 传空串，本地显示名回落到真名（联系人 + 会话）', () async {
    await db.upsertContacts(<Contact>[
      const Contact(id: 'u2', displayName: '小明明'),
    ]);
    await db.upsertConversation(
      Conversation(id: 'u2', displayName: '小明明', lastSendTime: 1),
    );
    adapter.ok(FriendPaths.setNickname, data: null);

    await repository.setFriendNickname(
      userId: 'u2',
      friendId: '2',
      nickname: '',
      fallbackName: '小明',
    );

    // 空串要真的发出去（服务端配套那个补丁才收）
    expect(adapter.bodyOf(FriendPaths.setNickname), <String, dynamic>{
      'friend_id': 2,
      'nickname': '',
    });
    expect((await db.findContact('u2'))?.displayName, '小明');
    expect((await db.findConversation('u2'))?.displayName, '小明');
  });

  test('清空备注但没给兜底名时，本地显示名是空串（不会留着旧备注）', () async {
    await db.upsertContacts(<Contact>[
      const Contact(id: 'u2', displayName: '小明明'),
    ]);
    adapter.ok(FriendPaths.setNickname, data: null);

    await repository.setFriendNickname(
      userId: 'u2',
      friendId: '2',
      nickname: '',
    );

    expect((await db.findContact('u2'))?.displayName, '');
  });

  test('改备注失败时本地不改（老端是等接口成功才改）', () async {
    await db.upsertContacts(<Contact>[
      const Contact(id: 'u2', displayName: '小明'),
    ]);
    adapter.fail(FriendPaths.setNickname, code: 400, msg: '改不了');

    await expectLater(
      () => repository.setFriendNickname(
        userId: 'u2',
        friendId: '2',
        nickname: '小明明',
      ),
      throwsA(isA<BusinessException>()),
    );

    expect((await db.findContact('u2'))?.displayName, '小明');
  });

  test('friend_id 不是数字时按字符串发', () async {
    adapter.ok(FriendPaths.setNickname, data: null);

    await repository.setFriendNickname(
      userId: 'u2',
      friendId: 'u2',
      nickname: '备注',
    );

    expect(adapter.bodyOf(FriendPaths.setNickname)['friend_id'], 'u2');
  });
}
