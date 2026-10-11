import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/ws/ws_service.dart';
import 'package:gracelinkim/data/model/sfu_models.dart';
import 'package:gracelinkim/domain/group_call/group_call_hub.dart';
import 'package:gracelinkim/domain/group_call/group_call_presence.dart';
import 'package:gracelinkim/domain/group_call/sfu_room.dart';
import 'package:gracelinkim/features/group_call/group_call_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_web_socket.dart';
import 'support/fake_sfu.dart';

/// 群通话链路：服务端推来的 `sfuRoom` → **正在进行的那个房间**重新对账。
///
/// 没接这条推送时的表现是"别人进来了要好一会儿才看见"（只能等心跳比对版本号
/// 或 5 秒一次的定期回查）；接上之后是立刻的。这一层还负责两件容易写错的事：
/// **只理自己那个房间**（别的群的推送不能把这一页搅了），以及
/// **版本号与手里那份相同就不发请求**（一次进出会 bump 一次，9 个人就是 9 条推送）。
///
/// ⚠️ 判断是“**相同**才跳过”，不是“不比手里新就跳过”：版本号是服务端缓存里的
/// 计数器，清过缓存就会**倒退**，而“比手里小就永远不刷”会让这台手机永久失联。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSfuControl control;
  late FakeSfuConnections connections;
  late GroupCallHub hub;

  /// 让异步链路（事件分发 → 对账 → 请求）跑完
  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    control = FakeSfuControl();
    connections = FakeSfuConnections();
    hub = GroupCallHub();
    control.snapshot = SfuRoomState(
      epoch: 1,
      members: <SfuRoomMember>[
        member('u1', 'sess-publish-1', <String>['mic']),
        member('u2', 'sess-pub-u2', <String>['mic']),
      ],
    );
  });

  Future<SfuRoom> joinedRoom({String roomId = '100'}) async {
    final room = SfuRoom(
      roomId: roomId,
      myUserId: 'u1',
      control: control,
      local: FakeSfuLocalMedia(),
      connectionFactory: connections.call,
      audioLevelPollInterval: null,
      heartbeatInterval: null,
      stateRefreshInterval: null,
    );
    hub.attach(room);
    await room.join();
    return room;
  }

  group('对账（枢纽那一层）', () {
    test('版本号比手里新 → 重新拉一次快照', () async {
      final room = await joinedRoom();
      final before = control.countOf('roomState');

      control.snapshot = SfuRoomState(
        epoch: 2,
        members: <SfuRoomMember>[
          member('u1', 'sess-publish-1', <String>['mic']),
          member('u2', 'sess-pub-u2', <String>['mic']),
          member('u3', 'sess-pub-u3', <String>['mic']),
        ],
      );
      await hub.onRoomChanged(roomId: '100', epoch: 2);

      expect(control.countOf('roomState'), before + 1);
      expect(room.view.value.participants.length, 3, reason: '新进来的人要出现在名单上');
      await room.dispose();
    });

    test('版本号与手里那份相同 → 不白跑（同一条推送不发两个请求）', () async {
      final room = await joinedRoom();
      final before = control.countOf('roomState');

      await hub.onRoomChanged(roomId: '100', epoch: 1);

      expect(control.countOf('roomState'), before);
      await room.dispose();
    });

    test('版本号**倒退**（服务端清了缓存 / 重启）→ 还是要拉一次，不能永久失联', () async {
      final room = await joinedRoom();
      final before = control.countOf('roomState');

      // 服务端那边已经重新从 1 开始数了，而手里这份是旧的、更大的值
      await hub.onRoomChanged(roomId: '100', epoch: 0);

      expect(control.countOf('roomState'), before + 1);
      await room.dispose();
    });

    test('别的群的推送：直接忽略（不能把这个房间搅了）', () async {
      final room = await joinedRoom();
      final before = control.countOf('roomState');

      await hub.onRoomChanged(roomId: '999', epoch: 99);

      expect(control.countOf('roomState'), before);
      await room.dispose();
    });

    test('没在通话里：什么都不做（不会凭一条推送建出房间）', () async {
      await hub.onRoomChanged(roomId: '100', epoch: 5);
      expect(control.countOf('roomState'), 0);
    });

    test('已经离开房间：推送不再把它拉回来', () async {
      final room = await joinedRoom();
      await room.leave();
      final before = control.countOf('roomState');

      await hub.onRoomChanged(roomId: '100', epoch: 5);

      expect(control.countOf('roomState'), before, reason: '离开后不该再建出接收会话');
      expect(room.receiveSessionId, isNull);
      await room.dispose();
    });

    test('长连接恢复：重新对一次账（断线期间的进出全补上）', () async {
      final room = await joinedRoom();
      hub.detach(room);
      final before = control.countOf('roomState');

      await hub.onReconnected(); // 没登记 → 空转
      expect(control.countOf('roomState'), before);

      hub.attach(room);
      await hub.onReconnected();
      expect(control.countOf('roomState'), before + 1);
      await room.dispose();
    });
  });

  group('WS 接线（真的走路由器）', () {
    late FakeWebSocketChannel channel;
    late WsService ws;

    setUp(() async {
      channel = FakeWebSocketChannel();
      ws = await startTestWsService(channel);
    });

    tearDown(() => ws.dispose());

    void pushRoomEvent({required String roomId, required int epoch}) {
      channel.emit(
        jsonEncode(<String, dynamic>{
          'type': 'sfuRoom',
          'data': <String, dynamic>{'room_id': roomId, 'epoch': epoch},
        }),
      );
    }

    test('收到 sfuRoom → 立刻对账（不再等 25 秒心跳）', () async {
      GroupCallSyncService(hub, ws).start();
      final room = await joinedRoom();
      final before = control.countOf('roomState');

      pushRoomEvent(roomId: '100', epoch: 3);
      await settle();

      expect(control.countOf('roomState'), before + 1);
      await room.dispose();
    });

    test('没有 room_id 的事件：丢掉，不炸', () async {
      GroupCallSyncService(hub, ws).start();
      final room = await joinedRoom();
      final before = control.countOf('roomState');

      channel.emit(
        jsonEncode(<String, dynamic>{
          'type': 'sfuRoom',
          'data': <String, dynamic>{'epoch': 3},
        }),
      );
      await settle();

      expect(control.countOf('roomState'), before);
      await room.dispose();
    });

    test('这条路是注册在路由器上的（别的事件不会顺手触发它）', () async {
      GroupCallSyncService(hub, ws).start();
      expect(ws.router.handles('sfuRoom'), isTrue);

      final room = await joinedRoom();
      final before = control.countOf('roomState');
      channel.emit(
        jsonEncode(<String, dynamic>{
          'type': 'simple',
          'data': <String, dynamic>{'id': 'm1'},
        }),
      );
      await settle();

      expect(control.countOf('roomState'), before);
      await room.dispose();
    });
  });

  group('在线状态（谁在开群语音，S6.15）', () {
    late FakeWebSocketChannel channel;
    late WsService ws;
    late GroupCallPresenceTracker presence;

    setUp(() async {
      channel = FakeWebSocketChannel();
      ws = await startTestWsService(channel);
      presence = GroupCallPresenceTracker(verifyInterval: null);
    });

    tearDown(() {
      presence.dispose();
      ws.dispose();
    });

    /// 服务端 `bumpEpoch` 推的那一条（`live` / `started` 是 S6.15 新加的）
    void pushPresence({
      String roomId = '100',
      int epoch = 2,
      bool live = true,
      bool started = false,
      String callId = 'c1',
      String name = '',
      String starter = '',
    }) {
      channel.emit(
        jsonEncode(<String, dynamic>{
          'type': 'sfuRoom',
          'data': <String, dynamic>{
            'room_id': roomId,
            'epoch': epoch,
            'live': live,
            'call_id': callId,
            if (started) 'started': true,
            if (name.isNotEmpty) 'name': name,
            if (starter.isNotEmpty) 'starter': starter,
          },
        }),
      );
    }

    test('「刚开」那一条：记上「这个群在开语音」，横幅等着弹', () async {
      GroupCallSyncService(hub, ws, presence).start();

      pushPresence(started: true, name: '产品群', starter: '小明');
      await settle();

      expect(presence.liveIn('group-100'), isNotNull);
      expect(presence.pendingInvite?.groupName, '产品群');
    });

    test('房间空了：列表上那条标记跟着收掉', () async {
      GroupCallSyncService(hub, ws, presence).start();

      pushPresence(started: true, name: '产品群');
      await settle();
      pushPresence(epoch: 3, live: false);
      await settle();

      expect(presence.liveIn('group-100'), isNull);
    });

    test('我正在那间屋里（群通话页开着）：不给自己弹邀请', () async {
      GroupCallSyncService(hub, ws, presence).start();
      final room = await joinedRoom();

      pushPresence(started: true, name: '产品群', starter: '小明');
      await settle();

      expect(presence.liveIn('group-100'), isNull);
      await room.dispose();
    });

    test('别人开的是别的群：照常记（只忽略我自己那一间）', () async {
      GroupCallSyncService(hub, ws, presence).start();
      final room = await joinedRoom();

      pushPresence(roomId: '200', started: true, name: '另一个群');
      await settle();

      expect(presence.liveIn('group-200'), isNotNull);
      await room.dispose();
    });

    test('重连之后回查一次：断线期间散场的语音不会挂在列表上', () async {
      presence.dispose();
      presence = GroupCallPresenceTracker(probe: (roomId) async => false);
      GroupCallSyncService(hub, ws, presence).start();
      pushPresence(started: true, name: '产品群');
      await settle();
      expect(presence.liveIn('group-100'), isNotNull);

      // 断线 → 重连（`restart` 就是 stop + start）：那条 `live = false`
      // 是断线期间推的，我们收不到，只能自己回查
      await ws.restart();
      await settle();

      expect(presence.liveIn('group-100'), isNull);
    });
  });
}
