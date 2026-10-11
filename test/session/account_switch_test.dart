import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/audio/voice_player.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/notify/message_notification_presenter.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/saved_accounts.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/db/app_database.dart';
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/db/message_dao.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/domain/session/session_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_web_socket.dart';
import '../support/test_database.dart';

/// 切换账号（S10.1）的会话层行为。
///
/// 这里钉的是几件**很容易做错**的事：
///
/// * 登录成功时要把**当前账号**存进列表（含令牌）——以后才能一键切回来；
/// * 切换**不调服务端登出**（调了令牌就作废，切回去得重新输密码）；
/// * 本机聊天数据照旧清掉（本地库没有账号维度，不清就会把两个人的收藏串在一起）；
/// * 退出登录后的那一份**留在列表里**，但令牌清空（再点它要走登录表单）；
/// * 「被顶下线」那条推送要认得出**本机自己用过的 client_id**（切换账号会换
///   client_id，服务端可能把「上一个连接下线」的事件发到新连接上，不挡就自己踢自己）；
/// * 上一个账号留在**界面以外**的东西也要收干净：通知栏那几条、正在播的语音。
/// 记一下「清通知栏 / 停语音」被调了几次（真实那两个会碰插件与音频子系统，
/// 测试里换成这两个替身，只数次数）
class _TraceCalls {
  int cancelAllCalls = 0;
  int voiceStopCalls = 0;
}

class _RecordingPresenter extends LocalMessageNotificationPresenter {
  _RecordingPresenter(this.traces) : super(translate: (key) => key);

  final _TraceCalls traces;

  @override
  Future<void> cancelAll() async {
    traces.cancelAllCalls += 1;
  }
}

class _RecordingVoicePlayer extends VoicePlayerNotifier {
  _RecordingVoicePlayer(this.traces);

  final _TraceCalls traces;

  @override
  Future<void> stop() async {
    traces.voiceStopCalls += 1;
    await super.stop();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StubAdapter adapter;
  late FakeWebSocketChannel channel;
  late WsService ws;
  late ProviderContainer container;
  late SessionService session;
  late AppDatabase db;

  late _TraceCalls traces;

  /// 本地存一份账号（模拟「以前登录过、还没退出」）
  Map<String, dynamic> accountJson(
    String userId, {
    String account = '',
    String token = '',
    String name = '',
    int usedAt = 0,
    List<String> clientIds = const <String>[],
  }) => <String, dynamic>{
    'user': <String, dynamic>{
      'user_id': userId,
      'account': account,
      'realname': name,
    },
    'authToken': token,
    'clientIds': clientIds,
    'usedAt': usedAt,
  };

  Future<void> setUpContainer({
    List<Map<String, dynamic>> accounts = const <Map<String, dynamic>>[],
    Map<String, Object> extraPrefs = const <String, Object>{},
    AppDatabase? database,
    bool recordTraces = false,
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ...extraPrefs,
      if (accounts.isNotEmpty)
        SavedAccountsStore.storageKey: json.encode(accounts),
    });
    await CredentialStore.init();
    // 换一个干净的列表实例（并读回上面那份 mock 值）
    SavedAccountsStore.instance = SavedAccountsStore()..reload();

    adapter = StubAdapter();
    db = database ?? memoryDatabase();
    channel = FakeWebSocketChannel();
    ws = await startTestWsService(channel);
    container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(adapter.apiClient()),
        wsServiceProvider.overrideWithValue(ws),
        appDatabaseProvider.overrideWithValue(db),
        if (recordTraces)
          messageNotificationPresenterProvider.overrideWithValue(
            _RecordingPresenter(traces),
          ),
        if (recordTraces)
          voicePlayingProvider.overrideWith(
            () => _RecordingVoicePlayer(traces),
          ),
      ],
    );
    session = container.read(sessionServiceProvider);
    await session.bootstrap();
  }

  /// 让 async 链路（事件分发、HTTP、落盘）跑完
  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  /// 客户端发出去的帧
  List<Map<String, dynamic>> sentFrames() => channel.sent
      .map((frame) => json.decode(frame as String))
      .cast<Map<String, dynamic>>()
      .toList();

  Future<void> loginAs9() async {
    adapter.ok(
      '/common/Pub/login',
      data: <String, dynamic>{
        'authToken': 'tok-9',
        'userInfo': <String, dynamic>{
          'user_id': '9',
          'account': '13800000009',
          'realname': '阿明',
        },
      },
    );
    await session.login(account: '13800000009', password: '123456');
    await settle();
  }

  setUp(() async {
    traces = _TraceCalls();
    await setUpContainer();
  });

  tearDown(() async {
    container.dispose();
    ws.dispose();
    await db.close();
  });

  test('登录成功：当前账号自动进列表（名字、恩信号、令牌都在）', () async {
    await loginAs9();

    final saved = SavedAccountsStore.instance.byId('9');
    expect(saved, isNotNull);
    expect(saved!.name, '阿明');
    expect(saved.gracelinkId, '13800000009');
    expect(saved.authToken, 'tok-9');
    expect(saved.canSwitchOnline, isTrue);
    expect(SavedAccountsStore.instance.accounts.length, 1);
  });

  test('一键切换：身份与令牌换成目标账号，上一个账号留着（能切回来）', () async {
    final freshDb = memoryDatabase();
    addTearDown(freshDb.close);
    container.dispose();
    ws.dispose();
    await setUpContainer(
      accounts: <Map<String, dynamic>>[
        accountJson(
          '8',
          account: '13800000008',
          token: 'tok-8',
          name: '老王',
          usedAt: 1,
        ),
      ],
      database: freshDb,
    );

    await loginAs9();
    // 本机现在留着 9 号的聊天数据（换账号时应当被清掉）
    await freshDb.upsertConversation(
      const Conversation(id: 'u8', displayName: '老王', lastSendTime: 1),
    );
    await freshDb.upsertMessages(<Message>[
      Message(conversationId: 'u8', type: 'text', content: '你好', sendTime: 3),
    ]);

    final result = await session.switchAccount('8');
    await settle();

    expect(result, AccountSwitchResult.switched);
    // 身份与令牌都换成 8 号
    expect(container.read(sessionStoreProvider).userId, '8');
    expect(CredentialStore.instance.authToken, 'tok-8');
    expect(CredentialStore.instance.userInfo?['user_id'], '8');
    // 9 号还在列表里、令牌也留着 —— 切回去不用重新输密码
    expect(SavedAccountsStore.instance.byId('9')?.authToken, 'tok-9');
    expect(SavedAccountsStore.instance.byId('8')?.authToken, 'tok-8');
    // 本机聊天数据清掉了（本地库没有账号维度，见 session_service 里的注释）
    expect(await freshDb.allConversations(), isEmpty);
    expect(await freshDb.messageCount('u8'), 0);
    expect(CredentialStore.instance.lastUserId, '8');

    // 重连之后服务端会下发 init：这时要用**新账号**的身份 bindUid
    expect(ws.isStarted, isTrue);
    channel.emit('{"type":"init","client_id":"c-8"}');
    await settle();
    expect(
      sentFrames(),
      containsAll(<Map<String, dynamic>>[
        <String, dynamic>{'type': 'bindUid', 'user_id': '8', 'token': 'tok-8'},
      ]),
    );
  });

  test('换人时必清本机数据：连 `lastUserId` 丢了也一样清（不能看记录，要看事实）', () async {
    final freshDb = memoryDatabase();
    addTearDown(freshDb.close);
    container.dispose();
    ws.dispose();
    // 登录态在本地（9 号），但没记过 lastUserId —— 老版本装的库、设置被清掉一半
    await setUpContainer(
      extraPrefs: <String, Object>{
        CredentialStore.keyAuthToken: 'tok-9',
        CredentialStore.keyUserInfo: json.encode(<String, dynamic>{
          'user_id': '9',
          'realname': '阿明',
        }),
      },
      accounts: <Map<String, dynamic>>[
        accountJson('8', account: '13800000008', token: 'tok-8', name: '老王'),
      ],
      database: freshDb,
    );
    expect(CredentialStore.instance.lastUserId, isEmpty);
    await freshDb.upsertConversation(
      const Conversation(id: 'u8', displayName: '老王', lastSendTime: 1),
    );

    expect(await session.switchAccount('8'), AccountSwitchResult.switched);
    await settle();

    expect(
      await freshDb.allConversations(),
      isEmpty,
      reason: '上一个账号的会话不能留给新账号（哪怕没记过 lastUserId）',
    );
  });

  test('切换时顺带清掉上一账号的通知栏与正在播的语音', () async {
    container.dispose();
    ws.dispose();
    await setUpContainer(
      accounts: <Map<String, dynamic>>[
        accountJson('8', account: '13800000008', token: 'tok-8', name: '老王'),
      ],
      recordTraces: true,
    );
    await loginAs9();

    expect(await session.switchAccount('8'), AccountSwitchResult.switched);
    await settle();

    expect(traces.cancelAllCalls, 1, reason: '通知栏里那几条属于上一个人，得清掉');
    expect(
      traces.voiceStopCalls,
      greaterThanOrEqualTo(1),
      reason: '上个账号的语音不该继续响',
    );
  });

  test('令牌被清空（在设置里退出登录过）→ 只报「要重新登录」，不动当前会话', () async {
    await setUpContainer(
      accounts: <Map<String, dynamic>>[
        accountJson('8', account: '13800000008', name: '老王'),
      ],
    );

    expect(await session.switchAccount('8'), AccountSwitchResult.needsLogin);
    expect(container.read(sessionStoreProvider).isLoggedIn, isFalse);
    expect(CredentialStore.instance.authToken, isNull);
  });

  test('没存过的账号 / 本来就是当前账号', () async {
    await loginAs9();
    expect(await session.switchAccount('8'), AccountSwitchResult.unknown);
    expect(await session.switchAccount('9'), AccountSwitchResult.alreadyActive);
    expect(container.read(sessionStoreProvider).userId, '9');
  });

  test('退出登录：条目留在列表里，但令牌清空（再点它要重新输密码）', () async {
    await loginAs9();
    channel.emit('{"type":"init","client_id":"c-local"}');
    await settle();

    await session.logout();
    await settle();

    final saved = SavedAccountsStore.instance.byId('9');
    expect(saved, isNotNull, reason: '退出登录不把这一份从列表里删掉');
    expect(saved!.authToken, isEmpty);
    expect(saved.canSwitchOnline, isFalse);
    expect(SavedAccountsStore.instance.accounts.length, 1);
  });

  test('被顶下线：本机自己用过的 client_id 不算「别的设备」（切换账号后会被服务端下发）', () async {
    await loginAs9();
    // 本机用过 c-1（换账号时的旧连接），现在这条连接叫 c-2
    channel.emit('{"type":"init","client_id":"c-1"}');
    await settle();
    channel.emit('{"type":"init","client_id":"c-2"}');
    await settle();

    channel.emit(
      '{"type":"offline","data":{"id":"9","client_id":"c-1","isMobile":true}}',
    );
    await settle();
    expect(
      container.read(sessionStoreProvider).isLoggedIn,
      isTrue,
      reason: '自己用过的旧 client_id 不该把自己踢下线',
    );

    // 真别的设备：照踢
    channel.emit(
      '{"type":"offline","data":{"id":"9","client_id":"c-remote","isMobile":true}}',
    );
    await settle();
    expect(container.read(sessionStoreProvider).isLoggedIn, isFalse);
  });
}
