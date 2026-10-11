import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/app.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/router/session_guard.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/saved_accounts.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/model/global_config.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/features/mine/accounts_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

/// 切换账号那一页（S10.1）。
///
/// 钉的是用户定的那几条规则：三个上限（满了「添加账号」那行就不画）、
/// 「当前使用」标在正在用的那个上、退出登录过的显示「已退出」、
/// 管理模式里能删（空出余位后「添加账号」自己回来）。
void main() {
  late AppDatabase db;
  late StubAdapter adapter;

  const current = UserInfo(
    userId: 'u1',
    account: '13800000000',
    displayName: '张三',
    raw: <String, dynamic>{'user_id': 'u1', 'account': '13800000000'},
  );

  Map<String, dynamic> accountJson(
    String userId, {
    String account = '',
    String name = '',
    String token = 'tok',
    int usedAt = 0,
  }) => <String, dynamic>{
    'user': <String, dynamic>{
      'user_id': userId,
      'account': account,
      'realname': name,
    },
    'authToken': token,
    'clientIds': <String>[],
    'usedAt': usedAt,
  };

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    db = memoryDatabase();
    adapter = StubAdapter();
    sessionGuard.update(ready: true, hasSession: true);
    SavedAccountsStore.instance = SavedAccountsStore()..reload();
  });

  tearDown(() async {
    sessionGuard.update(ready: false, hasSession: false);
    await db.close();
  });

  /// 拆掉整棵树，让 drift 关查询流时留下的零延迟定时器跑完
  /// （不消化掉，框架会报「Timer 未结束」）——每个用例末尾都要调一次
  Future<void> disposeApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  }

  /// 摆一份「本机存着这几个账号」的列表（最近使用在前）
  Future<void> seed(List<Map<String, dynamic>> accounts) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      SavedAccountsStore.storageKey: json.encode(accounts),
    });
    await CredentialStore.init();
    SavedAccountsStore.instance = SavedAccountsStore()..reload();
  }

  /// 起 App → 登录 → 打开切换账号页
  Future<void> pumpAccounts(
    WidgetTester tester, {
    List<Map<String, dynamic>> accounts = const <Map<String, dynamic>>[],
    bool openFromSettings = true,
  }) async {
    await seed(accounts);
    tester.view.physicalSize = const Size(1170, 3000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          apiClientProvider.overrideWithValue(adapter.apiClient()),
        ],
        child: const GracelinkApp(),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() => disposeApp(tester));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    container.read(sessionStoreProvider.notifier).applyLogin(current);
    container
        .read(sessionStoreProvider.notifier)
        .applyConfig(
          const GlobalConfig(
            sysInfo: SysInfo(name: '恩信'),
            chatInfo: ChatInfo(),
            compass: CompassConfig(),
            demonMode: false,
          ),
        );
    await tester.pumpAndSettle();

    if (!openFromSettings) return;

    await tester.tap(find.text('我'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
  }

  testWidgets('设置里「切换账号」在「退出登录」上面，样式一样（居中、没有箭头）', (tester) async {
    await pumpAccounts(
      tester,
      accounts: [accountJson('u1', account: '13800000000', name: '张三')],
    );

    final switchRow = tester.getRect(find.text('切换账号'));
    final logoutRow = tester.getRect(find.text('退出登录'));
    expect(switchRow.top, lessThan(logoutRow.top), reason: '切换账号在退出登录上面');
    expect(
      switchRow.center.dx,
      closeTo(logoutRow.center.dx, 1),
      reason: '两行都是居中文字（同一种样式）',
    );

    await tester.tap(find.text('切换账号'));
    await tester.pumpAndSettle();
    expect(find.byType(AccountsPage), findsOneWidget);

    await disposeApp(tester);
  });

  testWidgets('账号卡：昵称 + 恩信号，「当前使用」标在正在用的那个上', (tester) async {
    await pumpAccounts(
      tester,
      accounts: [
        accountJson('u1', account: '13800000000', name: '张三', usedAt: 900),
        accountJson('u2', account: '13800000002', name: '李四', usedAt: 100),
      ],
    );
    await tester.tap(find.text('切换账号'));
    await tester.pumpAndSettle();

    expect(find.text('轻触头像以切换账号'), findsOneWidget);
    expect(find.text('张三'), findsOneWidget);
    expect(find.text('李四'), findsOneWidget);
    expect(find.text('恩信号：13800000000'), findsOneWidget);
    expect(find.text('恩信号：13800000002'), findsOneWidget);

    // 「当前使用」只有一颗，且落在当前账号那一行上
    expect(find.text('当前使用'), findsOneWidget);
    final badge = tester.getRect(find.text('当前使用'));
    final currentName = tester.getRect(find.text('张三'));
    expect(
      badge.center.dy,
      closeTo(currentName.center.dy, 20),
      reason: '标在正在用的那个账号那一行（字号不同，允许十几像素的偏差）',
    );
    await disposeApp(tester);
  });

  testWidgets('存满三个：「添加账号」那一行就不画了', (tester) async {
    await pumpAccounts(
      tester,
      accounts: [
        accountJson('u1', account: '13800000000', name: '张三', usedAt: 900),
        accountJson('u2', account: '13800000002', name: '李四', usedAt: 500),
        accountJson('u3', account: '13800000003', name: '王五', usedAt: 100),
      ],
    );
    await tester.tap(find.text('切换账号'));
    await tester.pumpAndSettle();

    expect(find.text('王五'), findsOneWidget);
    expect(find.text('添加账号'), findsNothing, reason: '满了三个就不给加：要加先「管理」里删一个');

    // 管理里删掉一个（非当前账号那颗，最后一张卡） → 余位回来，「添加账号」自己出现
    await tester.tap(find.text('管理'));
    await tester.pumpAndSettle();
    expect(find.text('删除'), findsNWidgets(3));
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.text('王五'), findsNothing);
    expect(find.text('添加账号'), findsOneWidget);
    expect(SavedAccountsStore.instance.accounts.length, 2);

    await disposeApp(tester);
  });

  testWidgets('管理里删当前账号 = 退出登录（弹的是退出确认，删完回登录页）', (tester) async {
    await pumpAccounts(
      tester,
      accounts: [
        accountJson('u1', account: '13800000000', name: '张三', usedAt: 900),
        accountJson('u2', account: '13800000002', name: '李四', usedAt: 100),
      ],
    );
    await tester.tap(find.text('切换账号'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('管理'));
    await tester.pumpAndSettle();
    // 第一张卡是当前账号
    await tester.tap(find.text('删除').first);
    await tester.pumpAndSettle();
    // 弹的是「退出登录」那套确认（不是删账号的）
    expect(find.textContaining('退出后不会删除任何历史数据'), findsOneWidget);
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();

    // 会话清掉、离开切换页；但这一份仍然留在切换列表里（只清了令牌）
    expect(CredentialStore.instance.authToken, isNull);
    expect(find.byType(AccountsPage), findsNothing);
    expect(SavedAccountsStore.instance.byId('u1'), isNotNull);
    expect(SavedAccountsStore.instance.byId('u1')!.canSwitchOnline, isFalse);

    await disposeApp(tester);
  });

  testWidgets('「添加账号」抽屉：注册新账号 / 登录其他账号，后者进登录表单', (tester) async {
    await pumpAccounts(
      tester,
      accounts: [accountJson('u1', account: '13800000000', name: '张三')],
    );
    await tester.tap(find.text('切换账号'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('添加账号'));
    await tester.pumpAndSettle();
    expect(find.text('注册新账号'), findsOneWidget);
    expect(find.text('登录其他账号'), findsOneWidget);

    await tester.tap(find.text('登录其他账号'));
    await tester.pumpAndSettle();

    // 进的是那条「已登录也能进」的添加账号表单（不是 /login，那条会被守卫弹回首页）
    expect(find.text('轻触头像以切换账号'), findsNothing);
    expect(find.text('登录其他账号'), findsOneWidget);
    expect(find.text('添加账号'), findsNothing);

    await disposeApp(tester);
  });

  testWidgets('在设置里退出登录过的账号：留在列表里、标「已退出」，点它去登录表单（账号预填）', (tester) async {
    await pumpAccounts(
      tester,
      accounts: [
        accountJson('u1', account: '13800000000', name: '张三', usedAt: 900),
        accountJson(
          'u2',
          account: '13800000002',
          name: '李四',
          token: '',
          usedAt: 100,
        ),
      ],
    );
    await tester.tap(find.text('切换账号'));
    await tester.pumpAndSettle();

    expect(find.text('已退出'), findsOneWidget);

    await tester.tap(find.text('李四'));
    await tester.pumpAndSettle();

    // 落到登录表单，账号已经预填成李四那个号
    expect(find.text('登录其他账号'), findsOneWidget);
    expect(find.widgetWithText(TextField, '13800000002'), findsOneWidget);

    await disposeApp(tester);
  });
}
