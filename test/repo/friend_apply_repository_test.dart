import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/net/api_exception.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/api/friend_api.dart';
import 'package:gracelinkim/data/repo/friend_apply_repository.dart';
import 'package:gracelinkim/domain/contacts/friend_apply.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 好友申请仓库（S5.1）。
///
/// 走真实的 [FriendApi] + 假 adapter：参数名（`is_mine` / `friend_id` / `status`）
/// 与「`data` 是数组、`count` 在信封里」这两件事都让真实代码跑一遍。
void main() {
  late StubAdapter adapter;
  late FriendApplyRepository repository;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    adapter = StubAdapter();
    repository = FriendApplyRepository(FriendApi(adapter.apiClient()));
  });

  /// 服务端真实那一行：主键叫 `friend_id`，**没有 `id`**（`Friend::index()` 给的就是表行）
  Map<String, dynamic> apply({
    Object friendId = 3,
    Object status = 2,
    String remark = '加个好友',
  }) => <String, dynamic>{
    'friend_id': friendId,
    'status': status,
    'remark': remark,
    'create_user_info': <String, dynamic>{
      'user_id': 'u3',
      'realname': '老王',
      'avatar': 'https://cdn.test/u3.png',
    },
  };

  test('我收到的：第一页参数与老端一致（page/limit/is_mine）', () async {
    adapter.ok(FriendPaths.applyList, data: <Map<String, dynamic>>[apply()]);

    await repository.page(tab: ApplyTab.received);

    expect(adapter.bodyOf(FriendPaths.applyList), <String, dynamic>{
      'page': 1,
      'limit': 10,
      'is_mine': 0,
    });
  });

  test('我发起的：is_mine 是 1，翻页时 page 跟着走', () async {
    adapter.ok(FriendPaths.applyList, data: <Map<String, dynamic>>[]);

    await repository.page(tab: ApplyTab.sent, page: 3);

    expect(adapter.bodyOf(FriendPaths.applyList), <String, dynamic>{
      'page': 3,
      'limit': 10,
      'is_mine': 1,
    });
  });

  test('数组形态的 data 能解析，总数取信封里的 count', () async {
    adapter.ok(
      FriendPaths.applyList,
      data: <Map<String, dynamic>>[
        apply(friendId: 1),
        apply(friendId: 2, status: 1),
        apply(friendId: 3, status: 0),
      ],
      count: 25,
    );

    final result = await repository.page(tab: ApplyTab.received);

    expect(result.items.map((item) => item.id).toList(), <String>[
      '1',
      '2',
      '3',
    ]);
    expect(result.total, 25);
    expect(result.page, 1);
  });

  test('同意：status 是 1，friend_id 原样发数字', () async {
    adapter.ok(FriendPaths.acceptApply, data: null);

    final message = await repository.respond(friendId: '3', agree: true);

    expect(adapter.bodyOf(FriendPaths.acceptApply), <String, dynamic>{
      'friend_id': 3,
      'status': 1,
    });
    // 老端弹的是服务端回执的 msg（这里假 adapter 给的是 'ok'）
    expect(message, 'ok');
  });

  test('拒绝：status 是 0', () async {
    adapter.ok(FriendPaths.acceptApply, data: null);

    await repository.respond(friendId: '7', agree: false);

    expect(adapter.bodyOf(FriendPaths.acceptApply), <String, dynamic>{
      'friend_id': 7,
      'status': 0,
    });
  });

  test('friend_id 不是数字时按字符串发（服务端给什么就发什么）', () async {
    adapter.ok(FriendPaths.acceptApply, data: null);

    await repository.respond(friendId: 'u3', agree: true);

    expect(adapter.bodyOf(FriendPaths.acceptApply), <String, dynamic>{
      'friend_id': 'u3',
      'status': 1,
    });
  });

  test('没有 friend_id 时不发请求，直接抛错（老端会静默发个 undefined）', () async {
    await expectLater(
      () => repository.respond(friendId: '', agree: true),
      throwsA(isA<UnknownApiException>()),
    );
    expect(adapter.requests, isEmpty);
  });

  test('业务码非 0 抛异常，且不会发出「同意」（列表页据此提示失败）', () async {
    adapter.fail(FriendPaths.acceptApply, code: 400, msg: '该申请已处理');

    await expectLater(
      () => repository.respond(friendId: '3', agree: true),
      throwsA(
        isA<BusinessException>().having(
          (error) => error.message,
          'message',
          '该申请已处理',
        ),
      ),
    );
  });
}
