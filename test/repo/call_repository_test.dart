import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/data/api/chat_api.dart';
import 'package:gracelinkim/data/api/endpoints.dart';
import 'package:gracelinkim/data/repo/call_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 通话信令的通道（S6.1）：就是把十个字段 POST 到老端那个接口。
void main() {
  late StubAdapter adapter;
  late CallRepository repository;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    adapter = StubAdapter();
    repository = CallRepository(ChatApi(adapter.apiClient()));
  });

  test('打到老端那个接口，请求体原样过去', () async {
    adapter.ok(ChatPaths.sendToMsg, data: <String, dynamic>{'msg_id': 'srv-1'});

    final request = <String, dynamic>{
      'id': 'uuid-1',
      'msg_id': '',
      'toContactId': 'u2',
      'type': 0,
      'event': 'calling',
      'status': 3,
      'code': 901,
      'callTime': '',
      'sdp': '',
      'iceCandidate': '',
    };

    await repository.sendSignal(request);

    expect(adapter.paths, <String>[ChatPaths.sendToMsg]);
    expect(adapter.bodyOf(ChatPaths.sendToMsg), request);
  });

  test('把信封里的 data 交回上层（主叫要拿 msg_id、还要看 extends.code 907）', () async {
    adapter.ok(
      ChatPaths.sendToMsg,
      data: <String, dynamic>{
        'msg_id': 'srv-9',
        'extends': <String, dynamic>{'code': 907},
      },
    );

    final result = await repository.sendSignal(<String, dynamic>{
      'event': 'calling',
    });

    expect(result['msg_id'], 'srv-9');
    expect((result['extends'] as Map<String, dynamic>)['code'], 907);
  });

  test('data 是 null 时给空 map（别让状态机拿到 null）', () async {
    adapter.ok(ChatPaths.sendToMsg, data: null);

    expect(await repository.sendSignal(<String, dynamic>{}), isEmpty);
  });

  test('接口挂了照样抛（服务端没开音视频 / 对方不存在都得让上层知道）', () async {
    adapter.fail(ChatPaths.sendToMsg, code: 400, msg: '对方不在线');

    await expectLater(
      () => repository.sendSignal(<String, dynamic>{'event': 'calling'}),
      throwsA(anything),
    );
  });
}
