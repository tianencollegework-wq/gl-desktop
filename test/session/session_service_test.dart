import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/config/app_config.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/net/api_exception.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/store/session_store.dart';
import 'package:gracelinkim/core/ui/notice_bus.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/db/app_database.dart';
// 会话/消息的数据库方法都是 extension，必须 import
import 'package:gracelinkim/data/db/conversation_dao.dart';
import 'package:gracelinkim/data/db/message_dao.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/global_config.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/domain/session/session_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_web_socket.dart';
import '../support/test_database.dart';

const AppConfig _config = AppConfig(
  env: AppEnv.dev,
  scheme: 'https',
  host: 'example.test',
  hostToken: 'sha-hidden-bi',
);

/// 按路径返回预设报文，并记录每个请求的完整参数
class _StubAdapter implements HttpClientAdapter {
  final Map<String, String> responses = <String, String>{};
  final List<RequestOptions> requests = <RequestOptions>[];

  List<String> get paths => requests.map((r) => r.path).toList();

  Map<String, dynamic> bodyOf(String path) {
    final request = requests.firstWhere((r) => r.path == path);
    final data = request.data;
    if (data is Map) return data.cast<String, dynamic>();
    if (data is String) return json.decode(data) as Map<String, dynamic>;
    return <String, dynamic>{};
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final body =
        responses[options.path] ??
        json.encode(<String, dynamic>{'code': 0, 'msg': 'ok', 'data': null});
    return ResponseBody.fromString(
      body,
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

String _envelope(int code, {Map<String, dynamic>? data, String msg = ''}) =>
    json.encode(<String, dynamic>{'code': code, 'msg': msg, 'data': data});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _StubAdapter adapter;
  late FakeWebSocketChannel channel;
  late WsService ws;
  late ProviderContainer container;
  late SessionService session;

  Future<void> setUpContainer({
    Map<String, Object> prefs = const {},
    AppDatabase? database,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    await CredentialStore.init();

    adapter = _StubAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final apiClient = ApiClient(
      config: _config,
      credentials: CredentialStore.instance,
      dio: dio,
    );

    channel = FakeWebSocketChannel();
    ws = await startTestWsService(channel);

    container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(apiClient),
        wsServiceProvider.overrideWithValue(ws),
        if (database != null) appDatabaseProvider.overrideWithValue(database),
      ],
    );
    session = container.read(sessionServiceProvider);
    await session.bootstrap();
  }

  setUp(() async {
    await setUpContainer();
  });

  /// 让 async 链路（事件分发、HTTP、落盘）跑完
  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  /// 客户端发出去的帧，解码成 map
  List<Map<String, dynamic>> sentFrames() => channel.sent
      .map((frame) => json.decode(frame as String))
      .cast<Map<String, dynamic>>()
      .toList();

  tearDown(() async {
    container.dispose();
    ws.dispose();
  });

  group('登录', () {
    test('成功后：存 token、存用户、发 bindUid（参数与老端一致）', () async {
      adapter.responses['/common/Pub/login'] = _envelope(
        0,
        data: <String, dynamic>{
          'authToken': 'tok-9',
          'userInfo': <String, dynamic>{'user_id': '9', 'realname': '阿明'},
        },
      );

      await session.login(
        account: '13800000009',
        password: '123456',
        rememberMe: true,
      );
      await settle();

      final state = container.read(sessionStoreProvider);
      expect(state.isLoggedIn, isTrue);
      expect(state.userId, '9');
      expect(state.user!.name, '阿明');
      expect(CredentialStore.instance.authToken, 'tok-9');

      // 请求体：老端 loginForm 的字段名原样带过去
      final body = adapter.bodyOf('/common/Pub/login');
      expect(body['account'], '13800000009');
      expect(body['password'], '123456');
      expect(body['code'], '');
      expect(body['client_id'], '');
      expect(body['rememberMe'], isTrue);

      // 登录后立刻发 bindUid（老端 pages/login/index.vue 就是这一步）
      expect(
        sentFrames(),
        containsAll(<Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'bindUid',
            'user_id': '9',
            'token': 'tok-9',
          },
        ]),
      );
    });

    test('换账号登录：把本机的会话与消息清掉（收藏这种固定 id 的会话不再串号）', () async {
      final db = memoryDatabase();
      addTearDown(db.close);
      container.dispose();
      ws.dispose();
      // 上一个登录过的账号是 a，本机留着它的会话与消息
      await setUpContainer(
        prefs: <String, Object>{CredentialStore.keyLastUserId: 'a'},
        database: db,
      );
      await db.upsertConversation(
        const Conversation(
          id: '-1',
          displayName: '我的收藏',
          isGroup: 3,
          lastSendTime: 1,
        ),
      );
      await db.upsertConversation(
        const Conversation(id: 'u7', displayName: '老王', lastSendTime: 2),
      );
      await db.upsertMessages(<Message>[
        Message(
          conversationId: '-1',
          type: 'text',
          content: 'a 存的',
          sendTime: 3,
        ),
        Message(conversationId: 'u7', type: 'text', content: '你好', sendTime: 4),
      ]);
      // 聊天背景是按会话 id 存的本机偏好，也要跟着清
      await CredentialStore.instance.saveChatBackground(
        'u7',
        image: '/tmp/u7.png',
        filter: false,
      );

      adapter.responses['/common/Pub/login'] = _envelope(
        0,
        data: <String, dynamic>{
          'authToken': 'tok-9',
          'userInfo': <String, dynamic>{'user_id': '9', 'realname': '阿明'},
        },
      );
      await session.login(account: 'b@test.com', password: '123456');
      await settle();

      // 本机这一份是「上一个账号」的，不能留给新账号（尤其「我的收藏」的会话 id
      // 固定是 -1，两个账号会落在同一条会话里，看起来像两个人在一个群里说话）
      expect(await db.allConversations(), isEmpty);
      expect(await db.messageCount('-1'), 0);
      expect(await db.messageCount('u7'), 0);
      // 上个账号设的聊天背景也不能留给新账号（和同一个人聊会看到那张图）
      expect(CredentialStore.instance.chatBackground('u7').image, isEmpty);
      // 记住这次登录的账号，下次换回来还要靠它判断
      expect(CredentialStore.instance.lastUserId, '9');
    });

    test('同一个账号重新登录：本机那份留着（不白清一遍缓存）', () async {
      final db = memoryDatabase();
      addTearDown(db.close);
      container.dispose();
      ws.dispose();
      await setUpContainer(
        prefs: <String, Object>{CredentialStore.keyLastUserId: '9'},
        database: db,
      );
      await db.upsertConversation(
        const Conversation(
          id: '-1',
          displayName: '我的收藏',
          isGroup: 3,
          lastSendTime: 1,
        ),
      );
      await db.upsertMessages(<Message>[
        Message(
          conversationId: '-1',
          type: 'text',
          content: '我存的',
          sendTime: 3,
        ),
      ]);
      await CredentialStore.instance.saveChatBackground(
        '-1',
        image: '/tmp/favor.png',
        filter: false,
      );

      adapter.responses['/common/Pub/login'] = _envelope(
        0,
        data: <String, dynamic>{
          'authToken': 'tok-9',
          'userInfo': <String, dynamic>{'user_id': '9', 'realname': '阿明'},
        },
      );
      await session.login(account: 'a@test.com', password: '123456');
      await settle();

      expect(await db.allConversations(), hasLength(1));
      expect(await db.messageCount('-1'), 1);
      expect(
        CredentialStore.instance.chatBackground('-1').image,
        '/tmp/favor.png',
      );
    });

    test('响应里缺 authToken / userInfo → 明确报错，且不留下半个登录态', () async {
      adapter.responses['/common/Pub/login'] = _envelope(
        0,
        data: <String, dynamic>{'authToken': ''},
      );

      await expectLater(
        session.login(account: 'a', password: 'b'),
        throwsA(isA<UnknownApiException>()),
      );
      expect(container.read(sessionStoreProvider).isLoggedIn, isFalse);
    });
  });

  group('注册 / 验证码', () {
    test('注册参数用的是老端 regForm 的字段名', () async {
      await session.register(
        account: 'a@b.com',
        realName: '阿明',
        password: '123456',
        repass: '123456',
        code: '8888',
      );

      final body = adapter.bodyOf('/common/pub/register');
      expect(body['account'], 'a@b.com');
      expect(body['realname'], '阿明');
      expect(body['password'], '123456');
      expect(body['repass'], '123456');
      expect(body['code'], '8888');
    });

    test('验证码带 type（1 登录、2 注册）', () async {
      await session.sendCode(account: 'a', type: 1);
      await session.sendCode(account: 'a', type: 2);

      final sends = adapter.requests
          .where((request) => request.path == '/common/pub/sendCode')
          .toList();
      expect(sends.length, 2);
      expect(sends[0].data, <String, dynamic>{'account': 'a', 'type': 1});
      expect(sends[1].data, <String, dynamic>{'account': 'a', 'type': 2});
    });
  });

  group('连接就绪（init）自动绑定设备', () {
    test('本地已登录时：先发 WS bindUid，再登记 HTTP bindUid', () async {
      // 换成"本地已有登录态"的场景：先把 setUp 里那份容器收掉
      container.dispose();
      ws.dispose();
      await setUpContainer(
        prefs: <String, Object>{
          CredentialStore.keyAuthToken: 'tok-7',
          CredentialStore.keyUserInfo: '{"user_id":"7","realname":"小林"}',
        },
      );

      channel.emit('{"type":"init","client_id":"c-777"}');
      await settle();

      expect(adapter.bodyOf('/common/Pub/bindUid'), <String, dynamic>{
        'client_id': 'c-777',
        'user_id': '7',
        'cid': '',
      });
      expect(CredentialStore.instance.clientId, 'c-777');
      expect(
        sentFrames(),
        containsAll(<Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'bindUid',
            'user_id': '7',
            'token': 'tok-7',
          },
        ]),
      );
    });

    test('HTTP bindUid 失败也不影响实时消息：WS bindUid 照样发出，而且会重试', () async {
      // 2026-09-26 的坑：老顺序是「HTTP 成功才发 WS bindUid」，HTTP 一失败
      // （网络刚切换、服务端清缓存后第一个请求报错……）WS 就永远不绑，
      // 结果是「连着但收不到任何推送」，界面还显示已连接。
      container.dispose();
      ws.dispose();
      await setUpContainer(
        prefs: <String, Object>{
          CredentialStore.keyAuthToken: 'tok-8',
          CredentialStore.keyUserInfo: '{"user_id":"8","realname":"小陈"}',
        },
      );
      adapter.responses['/common/Pub/bindUid'] = _envelope(-1, msg: '请先登录系统');

      channel.emit('{"type":"init","client_id":"c-888"}');
      await settle();

      // 关键：HTTP 报错了，但 WS 绑定已经发出去了
      expect(
        sentFrames(),
        containsAll(<Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'bindUid',
            'user_id': '8',
            'token': 'tok-8',
          },
        ]),
      );

      // 而且 HTTP 那边会重试（第 1 次失败后等 2s 再试一次）
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      expect(
        adapter.requests
            .where((request) => request.path == '/common/Pub/bindUid')
            .length,
        greaterThanOrEqualTo(2),
      );
    });

    test('未登录时只存 client_id，不调 bindUid', () async {
      channel.emit('{"type":"init","client_id":"c-1"}');
      await settle();

      expect(CredentialStore.instance.clientId, 'c-1');
      expect(adapter.paths, isNot(contains('/common/Pub/bindUid')));
    });
  });

  group('offline：被顶下线', () {
    Future<void> loginAndReady() async {
      adapter.responses['/common/Pub/login'] = _envelope(
        0,
        data: <String, dynamic>{
          'authToken': 'tok-9',
          'userInfo': <String, dynamic>{'user_id': '9', 'realname': '阿明'},
        },
      );
      await session.login(account: '13800000009', password: '123456');
      channel.emit('{"type":"init","client_id":"c-local"}');
      await settle();
    }

    Future<void> setMultiDeviceLogin(int value) async {
      adapter.responses['/common/pub/getSystemInfo'] = _envelope(
        0,
        data: <String, dynamic>{
          'sysInfo': <String, dynamic>{'multipleLogin': value},
        },
      );
      await session.refreshGlobalConfig();
      await settle();
    }

    test('三条都命中时清会话（id 相同 + client_id 不同 + isMobile）', () async {
      await loginAndReady();

      AppNotice? notice;
      final subscription = noticeBus.stream.listen((value) => notice = value);

      channel.emit(
        '{"type":"offline","data":{"id":"9","client_id":"c-remote","isMobile":true}}',
      );
      await settle();

      expect(container.read(sessionStoreProvider).isLoggedIn, isFalse);
      expect(CredentialStore.instance.authToken, isNull);
      expect(notice, isA<ToastNotice>());

      await subscription.cancel();
    });

    test('开启了多端登录 → 直接忽略', () async {
      await loginAndReady();
      await setMultiDeviceLogin(1);

      channel.emit(
        '{"type":"offline","data":{"id":"9","client_id":"c-remote","isMobile":true}}',
      );
      await settle();

      expect(container.read(sessionStoreProvider).isLoggedIn, isTrue);
    });

    test('client_id 相同（本端自己的回声）→ 不踢', () async {
      await loginAndReady();

      channel.emit(
        '{"type":"offline","data":{"id":"9","client_id":"c-local","isMobile":true}}',
      );
      await settle();

      expect(container.read(sessionStoreProvider).isLoggedIn, isTrue);
    });

    test('isMobile 为假 → 按老端行为不踢（这条是协议盲区，先按老端实现）', () async {
      await loginAndReady();

      channel.emit(
        '{"type":"offline","data":{"id":"9","client_id":"c-remote","isMobile":false}}',
      );
      await settle();

      expect(container.read(sessionStoreProvider).isLoggedIn, isTrue);
    });

    test('不是自己的 id → 不踢', () async {
      await loginAndReady();

      channel.emit(
        '{"type":"offline","data":{"id":"999","client_id":"c-remote","isMobile":true}}',
      );
      await settle();

      expect(container.read(sessionStoreProvider).isLoggedIn, isTrue);
    });
  });

  group('updateConfig：全局配置热更新', () {
    test('data 里带整份配置 → 覆盖本地', () async {
      channel.emit(
        '{"type":"updateConfig","data":{"sysInfo":{"name":"新站点","multipleLogin":1},'
        '"compass":{"status":1}}}',
      );
      await settle();

      final config = container.read(sessionStoreProvider).config;
      expect(config.sysInfo.name, '新站点');
      expect(config.multiDeviceLogin, isTrue);
      expect(config.compassEnabled, isTrue);
    });

    test('data 为空（字段平铺在顶层）也能吃下', () async {
      channel.emit('{"type":"updateConfig","sysInfo":{"name":"顶层站点"}}');
      await settle();

      expect(container.read(sessionStoreProvider).config.sysInfo.name, '顶层站点');
    });
  });

  group('登出', () {
    test('调接口 + 清本地会话 + 断连接', () async {
      adapter.responses['/common/Pub/login'] = _envelope(
        0,
        data: <String, dynamic>{
          'authToken': 'tok-9',
          'userInfo': <String, dynamic>{'user_id': '9'},
        },
      );
      await session.login(account: 'a', password: 'b');
      channel.emit('{"type":"init","client_id":"c-local"}');
      await settle();

      await session.logout();
      await settle();

      expect(adapter.bodyOf('/common/Pub/logout'), <String, dynamic>{
        'client_id': 'c-local',
      });
      expect(container.read(sessionStoreProvider).isLoggedIn, isFalse);
      expect(ws.isStarted, isFalse);
    });

    test('登出接口失败也照样清本地（老端这里会把人卡住）', () async {
      adapter.responses['/common/Pub/login'] = _envelope(
        0,
        data: <String, dynamic>{
          'authToken': 'tok-9',
          'userInfo': <String, dynamic>{'user_id': '9'},
        },
      );
      await session.login(account: 'a', password: 'b');
      adapter.responses['/common/Pub/logout'] = _envelope(500, msg: '炸了');

      await session.logout();
      await settle();

      expect(container.read(sessionStoreProvider).isLoggedIn, isFalse);
    });
  });

  group('扫码登录（S12.17）', () {
    test('服务端推来的登录态照样落盘：存 token / 存用户 / 发 bindUid', () async {
      await session.applyQrLogin(<String, dynamic>{
        'sessionId': 'sid-1',
        'authToken': 'tok-qr',
        'userInfo': <String, dynamic>{'user_id': '7', 'realname': '扫码进来的'},
      });
      await settle();

      final state = container.read(sessionStoreProvider);
      expect(state.isLoggedIn, isTrue);
      expect(state.userId, '7');
      expect(state.user!.name, '扫码进来的');
      expect(CredentialStore.instance.authToken, 'tok-qr');
      // 与密码登录同一条后半段：立刻发 bindUid（老端网页端刷新后就是这一步）
      expect(
        sentFrames(),
        containsAll(<Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'bindUid',
            'user_id': '7',
            'token': 'tok-qr',
          },
        ]),
      );
    });

    test('推送里缺 authToken / userInfo：明确报错，不落半个登录态', () async {
      await expectLater(
        session.applyQrLogin(<String, dynamic>{'sessionId': 'sid-1'}),
        throwsA(isA<UnknownApiException>()),
      );
      await settle();

      expect(container.read(sessionStoreProvider).isLoggedIn, isFalse);
      expect(CredentialStore.instance.authToken, isNull);
    });
  });

  group('启动', () {
    test('bootstrap 后本地会话就绪，且全局配置是后台拉取（不阻塞）', () async {
      adapter.responses['/common/pub/getSystemInfo'] = _envelope(
        0,
        data: <String, dynamic>{
          'sysInfo': <String, dynamic>{'name': '站点'},
        },
      );

      expect(container.read(sessionStoreProvider).ready, isTrue);
      expect(ws.isStarted, isTrue);

      await settle();
      expect(container.read(sessionStoreProvider).config.sysInfo.name, '站点');
    });

    test('配置拉取失败不影响启动（用缓存/默认值）', () async {
      adapter.responses['/common/pub/getSystemInfo'] = '<html>502</html>';
      await settle();

      expect(container.read(sessionStoreProvider).ready, isTrue);
      expect(
        container.read(sessionStoreProvider).config.sysInfo.name,
        GlobalConfig.defaults.sysInfo.name,
      );
    });
  });
}
