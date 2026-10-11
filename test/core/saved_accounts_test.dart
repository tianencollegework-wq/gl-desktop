import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/saved_accounts.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 可切换账号那份列表（S10.1）的本地存储。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SavedAccountsStore store;

  SavedAccount accountOf(
    String id, {
    String account = '',
    String token = '',
    String name = '',
    int usedAt = 0,
  }) => SavedAccount(
    user: UserInfo(
      userId: id,
      account: account,
      realName: name.isEmpty ? '用户$id' : name,
    ),
    authToken: token,
    usedAt: usedAt,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    store = SavedAccountsStore();
    SavedAccountsStore.instance = store;
  });

  test('存一份再读回来：昵称、恩信号、令牌都还在', () async {
    await store.upsert(
      accountOf('9', account: '13800000009', token: 'tok-9', name: '阿明'),
    );

    // 重新读一份（模拟下次启动）
    final reloaded = SavedAccountsStore()..reload();
    final saved = reloaded.byId('9');
    expect(saved, isNotNull);
    expect(saved!.name, '阿明');
    expect(saved.gracelinkId, '13800000009');
    expect(saved.authToken, 'tok-9');
    expect(saved.canSwitchOnline, isTrue);
    expect(reloaded.accounts.length, 1);
  });

  test('同一个 user_id 再存一次：整份替换，不会出现两份', () async {
    await store.upsert(accountOf('9', token: 'tok-old', name: '旧的'));
    await store.upsert(accountOf('9', token: 'tok-new', name: '新的'));

    expect(store.accounts.length, 1);
    expect(store.byId('9')!.authToken, 'tok-new');
    expect(store.byId('9')!.name, '新的');
  });

  test('最多三个：第四个进来顶掉最久未用的，刚存的那份一定留着', () async {
    await store.upsert(accountOf('1', usedAt: 100));
    await store.upsert(accountOf('2', usedAt: 200));
    await store.upsert(accountOf('3', usedAt: 300));
    expect(store.isFull, isTrue);

    await store.upsert(accountOf('4', usedAt: 400));

    expect(store.accounts.length, SavedAccountsStore.maxAccounts);
    expect(store.byId('1'), isNull, reason: '最久未用的那份被顶掉');
    expect(store.accounts.map((a) => a.userId).toList(), <String>[
      '4',
      '3',
      '2',
    ], reason: '最近使用的排在最前面');
  });

  test('恩信号：没填登录账号时退回 user_id', () async {
    await store.upsert(accountOf('9'));
    expect(store.byId('9')!.gracelinkId, '9');
  });

  test('touch 之后它排到最前面（当前账号在最上面）', () async {
    await store.upsert(accountOf('1', usedAt: 100));
    await store.upsert(accountOf('2', usedAt: 500));
    expect(store.accounts.first.userId, '2');

    await store.touch('1');

    expect(store.accounts.first.userId, '1');
    expect(store.accounts.length, 2, reason: 'touch 不该多出一份');
  });

  test('client_id 记账：去重、只留最近几个，并认得出「本机自己」', () async {
    await store.upsert(accountOf('9'));

    await store.rememberClientId('9', 'c-1');
    await store.rememberClientId('9', 'c-1'); // 同一个不重复记
    await store.rememberClientId('9', 'c-2');
    await store.rememberClientId('9', ''); // 空的不记

    expect(store.byId('9')!.clientIds, <String>['c-1', 'c-2']);
    expect(store.isOwnClientId('c-1'), isTrue);
    expect(store.isOwnClientId('c-remote'), isFalse);
    expect(store.isOwnClientId(''), isFalse);

    // 超过上限就砍掉最老的几个
    for (var i = 0; i < 10; i++) {
      await store.rememberClientId('9', 'x-$i');
    }
    final ids = store.byId('9')!.clientIds;
    expect(ids.length, SavedAccountsStore.maxClientIds);
    expect(ids.last, 'x-9');
  });

  test('删除一份', () async {
    await store.upsert(accountOf('1'));
    await store.upsert(accountOf('2'));

    await store.remove('1');

    expect(store.byId('1'), isNull);
    expect(store.accounts.length, 1);
    // 没存过的删了也不炸
    await store.remove('缺德号');
  });

  test('存坏了 / 脏数据不炸（没有 user_id 的直接丢掉）', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      SavedAccountsStore.storageKey: '{不是 json',
    });
    await CredentialStore.init();
    expect((SavedAccountsStore()..reload()).accounts, isEmpty);

    SharedPreferences.setMockInitialValues(<String, Object>{
      SavedAccountsStore.storageKey: json.encode(<dynamic>[
        '字符串',
        <String, dynamic>{'user': <String, dynamic>{}},
        <String, dynamic>{
          'user': <String, dynamic>{'user_id': '9', 'realname': '阿明'},
        },
      ]),
    });
    await CredentialStore.init();
    final reloaded = SavedAccountsStore()..reload();
    expect(reloaded.accounts.length, 1);
    expect(reloaded.byId('9')!.name, '阿明');
  });
}
