import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/ws/ws_client.dart';
import 'package:gracelinkim/core/ws/ws_event.dart';
import 'package:gracelinkim/core/ws/ws_handlers.dart';
import 'package:gracelinkim/core/ws/ws_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_web_socket.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('服务端心跳要回 pong（老端 socket.js 的行为）', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await CredentialStore.init();
    });

    test('收到 {"type":"ping"} 就回 {"type":"pong"}', () async {
      final channel = FakeWebSocketChannel();
      final ws = await startTestWsService(channel);
      addTearDown(ws.dispose);

      channel.emit('{"type":"ping"}');
      await Future<void>.delayed(Duration.zero);

      expect(
        channel.sent.map((frame) => json.decode(frame as String)).toList(),
        <Object>[
          <String, dynamic>{'type': 'pong'},
        ],
      );
    });

    test('收到 pong 不回任何东西（否则会和客户端自己的心跳回响成环）', () async {
      final channel = FakeWebSocketChannel();
      final ws = await startTestWsService(channel);
      addTearDown(ws.dispose);

      channel.emit('{"type":"pong","multiport":false}');
      await Future<void>.delayed(Duration.zero);

      expect(channel.sent, isEmpty);
    });
  });

  group('连接状态流会补当前这一帧（广播流不会重放）', () {
    test('连上之后再订阅：第一帧就是当前状态，不是空的', () async {
      final channel = FakeWebSocketChannel();
      final ws = await startTestWsService(channel);
      addTearDown(ws.dispose);

      // 会话页正是在首帧渲染之后才建的（`bootstrap()` 在 `runApp` 之前已经把 WS 连上）——
      // 不补这一帧的话它会一直停在 `AsyncLoading`，界面上就是那条挂着的「连接中…」
      // （用户 2026-09-30 报的）。
      expect(ws.status, WsStatus.connected);
      expect(await ws.statusChanges.first, WsStatus.connected);
    });

    test('之后的每一次状态变化照旧转发', () async {
      final channel = FakeWebSocketChannel();
      final ws = await startTestWsService(channel);
      addTearDown(ws.dispose);

      final seen = <WsStatus>[];
      final subscription = ws.statusChanges.listen(seen.add);
      await Future<void>.delayed(Duration.zero);

      // 服务端把连接掰了：客户端要自己判定断开（这里 `autoReconnect: false`，
      // 所以停在 `reconnecting` 上，不会又排一个重连定时器）
      await channel.closeIncoming();
      await Future<void>.delayed(Duration.zero);

      expect(seen.first, WsStatus.connected, reason: '先补当前状态');
      expect(seen.last, WsStatus.reconnecting, reason: '断开也要传下来');
      await subscription.cancel();
    });
  });

  group('重连退避（replace 老端那两套 15 秒定时器）', () {
    test('1s → 2s → 4s → 8s → 16s，上限 30s', () {
      expect(WsClient.backoffFor(1).inMilliseconds, 1000);
      expect(WsClient.backoffFor(2).inMilliseconds, 2000);
      expect(WsClient.backoffFor(3).inMilliseconds, 4000);
      expect(WsClient.backoffFor(4).inMilliseconds, 8000);
      expect(WsClient.backoffFor(5).inMilliseconds, 16000);
      expect(WsClient.backoffFor(6).inMilliseconds, 30000);
      expect(WsClient.backoffFor(100).inMilliseconds, 30000);
    });

    test('不会溢出（老端没有上限，长时间断网会算出荒谬的间隔）', () {
      expect(WsClient.backoffFor(1000).inMilliseconds, 30000);
    });
  });

  group('WsEvent 解析', () {
    test('解析 type 与 data', () {
      final event = WsEvent.tryParse('{"type":"simple","data":{"id":3}}')!;
      expect(event.type, 'simple');
      expect(event.intValue('id'), 3);
    });

    test('能取顶层字段（init 的 client_id、pong 的 multiport）', () {
      final init = WsEvent.tryParse(
        '{"type":"init","client_id":"c-1","data":{}}',
      )!;
      expect(init.top('client_id'), 'c-1');

      final pong = WsEvent.tryParse('{"type":"pong","multiport":1,"data":{}}')!;
      expect(pong.top('multiport'), 1);
    });

    test('非法 / 空 / 没有 type 的报文返回 null，不抛异常', () {
      expect(WsEvent.tryParse('not json'), isNull);
      expect(WsEvent.tryParse(''), isNull);
      expect(WsEvent.tryParse('{"data":{}}'), isNull);
      expect(WsEvent.tryParse(123), isNull);
      expect(WsEvent.tryParse(null), isNull);
    });

    test('data 不是对象时退化成空 map', () {
      final event = WsEvent.tryParse('{"type":"ping","data":[]}')!;
      expect(event.data, isEmpty);
    });

    test('字符串形式的数字/布尔值也能读', () {
      final event = WsEvent.tryParse(
        '{"type":"pong","data":{"is_online":"1"}}',
      )!;
      expect(event.boolValue('is_online'), isTrue);
      expect(event.intValue('nope'), isNull);
      expect(event.str('nope'), isNull);
    });
  });

  group('事件路由', () {
    test('注册的事件能被分发', () async {
      final hits = <String>[];
      final router = WsRouter()
        ..register('ping', (event) => hits.add(event.type));
      await router.dispatch(WsEvent.tryParse('{"type":"ping","data":{}}')!);
      expect(hits, <String>['ping']);
    });

    test('未注册的事件被记录下来，而不是静默丢掉', () async {
      final router = WsRouter();
      await router.dispatch(WsEvent.tryParse('{"type":"webrtc","data":{}}')!);
      await router.dispatch(WsEvent.tryParse('{"type":"webrtc","data":{}}')!);
      // 同一个事件只记一次
      expect(router.unknownTypes, <String>['webrtc']);
      expect(router.handles('webrtc'), isFalse);
    });

    test('一个处理器抛异常不影响后续事件', () async {
      var secondCalled = false;
      final router = WsRouter()
        ..register('webrtc', (_) => throw StateError('炸了'))
        ..register('simple', (_) => secondCalled = true);

      await router.dispatch(WsEvent.tryParse('{"type":"webrtc","data":{}}')!);
      await router.dispatch(WsEvent.tryParse('{"type":"simple","data":{}}')!);
      expect(secondCalled, isTrue);
    });
  });

  group('协议层处理器', () {
    late CredentialStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      store = await CredentialStore.init();
    });

    test('覆盖 ping / pong / init', () {
      final client = WsClient(
        url: 'ws://example.test/wss',
        autoReconnect: false,
      );
      final handlers = protocolWsHandlers(client: client, store: store);
      expect(handlers.keys, containsAll(<String>['ping', 'pong', 'init']));
    });

    test('init 事件会把 client_id 存进本地（bindUid 要用）', () async {
      final client = WsClient(
        url: 'ws://example.test/wss',
        autoReconnect: false,
      );
      String? notified;
      final handlers = protocolWsHandlers(
        client: client,
        store: store,
        onClientId: (id) => notified = id,
      );

      // 用线上实测的真实形状：没有 data 层
      await handlers['init']!(
        WsEvent.tryParse('{"type":"init","client_id":"c-9"}')!,
      );

      expect(store.clientId, 'c-9');
      expect(notified, 'c-9');
    });

    test('pong 事件能带出多端在线标记', () async {
      final client = WsClient(
        url: 'ws://example.test/wss',
        autoReconnect: false,
      );
      bool? multiport;
      final handlers = protocolWsHandlers(
        client: client,
        store: store,
        onMultiport: (value) => multiport = value,
      );

      // 线上实测：multiport 是布尔值
      await handlers['pong']!(
        WsEvent.tryParse('{"type":"pong","multiport":true}')!,
      );
      expect(multiport, isTrue);

      await handlers['pong']!(
        WsEvent.tryParse('{"type":"pong","multiport":false}')!,
      );
      expect(multiport, isFalse);

      // 老端那种 parseInt 写法也不该被报错：数字 1 同样当 true
      await handlers['pong']!(
        WsEvent.tryParse('{"type":"pong","multiport":1}')!,
      );
      expect(multiport, isTrue);
    });

    test('未连接时回 pong 不会抛异常（老端这里是静默失败）', () async {
      final client = WsClient(
        url: 'ws://example.test/wss',
        autoReconnect: false,
      );
      final handlers = protocolWsHandlers(client: client, store: store);
      await handlers['ping']!(WsEvent.tryParse('{"type":"ping","data":{}}')!);
    });
  });

  group('线上真实报文（2026-09-18 探测，见 docs/protocol/samples/）', () {
    test('init 不带 data 层，client_id 在顶层', () {
      final event = WsEvent.tryParse(
        '{"type":"init","client_id":"7f00000108fc00000009"}',
      )!;
      expect(event.type, 'init');
      expect(event.data, isEmpty);
      expect(event.top('client_id'), '7f00000108fc00000009');
    });

    test('pong 的 multiport 是布尔值', () {
      final event = WsEvent.tryParse('{"type":"pong","multiport":false}')!;
      expect(event.data, isEmpty);
      expect(event.top('multiport'), isFalse);
    });

    test('只观测到 type / client_id / multiport 三个顶层字段', () {
      final init = WsEvent.tryParse('{"type":"init","client_id":"x"}')!;
      final pong = WsEvent.tryParse('{"type":"pong","multiport":false}')!;
      expect(init.raw.keys, <String>['type', 'client_id']);
      expect(pong.raw.keys, <String>['type', 'multiport']);
    });
  });

  group('事件清单', () {
    test('已接入的事件（M1 协议层 + M2 会话层 + M4 聊天层 + M5 通讯录 + M6 通话 + S9 群通话）', () {
      expect(WsEvents.handledEvents, <String>[
        'ping',
        'pong',
        'init',
        'bindUid',
        'offline',
        'updateConfig',
        'simple',
        'group',
        'isOnline',
        'setChatTop',
        'setIsNotice',
        'undoMessage',
        'appendContact',
        'addGroup',
        'editGroupName',
        'removeGroup',
        'removeUser',
        'webrtc',
        // S9：群通话的房间变化（有人进来/走了/换了会话）→ 立刻重新对账
        'sfuRoom',
      ]);
    });

    test('待接入的业务事件与 docs/protocol/ws-events.md 对齐', () {
      expect(
        WsEvents.pendingBusinessEvents,
        containsAll(<String>['setNotice', 'setManager']),
      );
      // 已接掉的不要留在待接入清单里（M5/ M6 接掉的都要从清单里出去）
      for (final done in <String>[
        'webrtc',
        'offline',
        'updateConfig',
        'simple',
        'group',
        'isOnline',
        'setChatTop',
        'setIsNotice',
        'undoMessage',
        'appendContact',
        'addGroup',
        'editGroupName',
        'removeGroup',
        'removeUser',
      ]) {
        expect(WsEvents.pendingBusinessEvents, isNot(contains(done)));
      }
      // 两个清单不能有交集（否则状态就是说不清的）
      expect(
        WsEvents.pendingBusinessEvents.toSet().intersection(
          WsEvents.handledEvents.toSet(),
        ),
        isEmpty,
      );
      // 剩下的待接入：群成员 / 群设置那四个
      expect(WsEvents.pendingBusinessEvents.length, 4);
    });

    test('M2 注册的两个事件真的被路由认领（不是只写在清单里）', () async {
      final store = CredentialStore.instance;
      final client = WsClient(
        url: 'ws://example.test/wss',
        autoReconnect: false,
      );
      final router = WsRouter()
        ..registerAll(protocolWsHandlers(client: client, store: store))
        ..registerAll(<String, WsHandler>{
          WsEvents.offline: (_) {},
          WsEvents.updateConfig: (_) {},
        });

      expect(router.handles(WsEvents.offline), isTrue);
      expect(router.handles(WsEvents.updateConfig), isTrue);

      await router.dispatch(WsEvent.tryParse('{"type":"offline","data":{}}')!);
      expect(router.unknownTypes, isEmpty);
    });
  });
}
