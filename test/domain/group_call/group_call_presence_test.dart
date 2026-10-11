import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/domain/group_call/group_call_presence.dart';

/// 「谁在开群语音」这本账（S6.15）。
///
/// 数据只有一条来源：服务端 `Sfu.php::bumpEpoch` 推的 `sfuRoom` 事件。这里逐条钉住
/// 它对每一种载荷的反应 —— 尤其是**四种不该记账的情况**（老服务端、我人在屋里、
/// 房间空了、我不认识的形状）与**两种必须保持的情况**（拿不准、回查失败）。
void main() {
  /// 服务端推的那条事件（`data` 层）
  Map<String, dynamic> event({
    String roomId = '100',
    int epoch = 2,
    Object? live = true,
    String callId = 'c1',
    Object? started,
    String name = '',
    String starter = '',
  }) => <String, dynamic>{
    'room_id': roomId,
    'epoch': epoch,
    'live': ?live,
    'call_id': callId,
    'started': ?started,
    if (name.isNotEmpty) 'name': name,
    if (starter.isNotEmpty) 'starter': starter,
  };

  /// 「这一通刚开」那一条（服务端在 `session` 里推的就是这个形状）
  Map<String, dynamic> startEvent({
    String roomId = '100',
    String callId = 'c1',
    String name = '产品群',
    String starter = '小明',
  }) => event(
    roomId: roomId,
    callId: callId,
    started: true,
    name: name,
    starter: starter,
  );

  late GroupCallPresenceTracker tracker;

  setUp(() {
    // 回查定时器默认关掉（单测里不想等 45 秒；定时器本身另有用例）
    tracker = GroupCallPresenceTracker();
  });

  tearDown(() => tracker.dispose());

  group('记账', () {
    test('「刚开」那一次：记上标记，并且有一条横幅等着弹', () {
      tracker.onRoomEvent(startEvent());

      final call = tracker.liveIn('group-100');
      expect(call, isNotNull);
      expect(call!.groupName, '产品群');
      expect(call.starterName, '小明');
      expect(call.started, isTrue);
      expect(tracker.pendingInvite?.callId, 'c1');
    });

    test('房间号是数字（服务端那种）也能对上会话 id（group-100）', () {
      tracker.onRoomEvent(startEvent(roomId: '100'));
      expect(tracker.liveIn('group-100'), isNotNull);
      expect(tracker.liveCalls.single.roomId, '100');
    });

    test('服务端把房间号写成 group-100 时也认（两种形状都收）', () {
      tracker.onRoomEvent(startEvent(roomId: 'group-100'));
      expect(tracker.liveIn('group-100'), isNotNull);
    });

    test('中途有人进来（没有 started）：标记在，但不会因此多弹一条横幅', () {
      tracker.onRoomEvent(event(callId: 'c1', name: '产品群', starter: '小明'));

      expect(tracker.liveIn('group-100'), isNotNull);
      expect(tracker.pendingInvite, isNull, reason: '不是「刚开」的那一次，不弹横幅');
    });

    test('同一通的后续事件不会把「刚开」这个标记擦掉（横幅可能正挂着）', () {
      tracker.onRoomEvent(startEvent());
      tracker.onRoomEvent(event(callId: 'c1', epoch: 3));

      expect(tracker.liveIn('group-100')!.started, isTrue);
      expect(tracker.pendingInvite, isNotNull);
    });

    test('后续事件里没有群名/发起人时，留住已经知道的（服务端只在第一次带）', () {
      tracker.onRoomEvent(startEvent());
      tracker.onRoomEvent(event(callId: 'c1', epoch: 3));

      final call = tracker.liveIn('group-100')!;
      expect(call.groupName, '产品群');
      expect(call.starterName, '小明');
    });

    test('前后两通：换了 call_id 就按新那通算（上一通的信息不串）', () {
      tracker.onRoomEvent(startEvent(callId: 'c1'));
      tracker.onRoomEvent(startEvent(callId: 'c2', name: '项目群', starter: '小红'));

      final call = tracker.liveIn('group-100')!;
      expect(call.callId, 'c2');
      expect(call.groupName, '项目群');
      expect(call.starterName, '小红');
    });

    test('两个群同时在开语音：两条标记各记各的', () {
      tracker.onRoomEvent(startEvent(roomId: '100'));
      tracker.onRoomEvent(startEvent(roomId: '200', callId: 'c2'));

      expect(tracker.liveCalls.length, 2);
      expect(tracker.liveIn('group-100'), isNotNull);
      expect(tracker.liveIn('group-200'), isNotNull);
      // 最新的一通在前（会话列表与横幅都按这个顺序看）
      expect(tracker.pendingInvite?.conversationId, 'group-200');
    });
  });

  group('收摊', () {
    test('房间空了（live=false）：标记与横幅一起收掉', () {
      tracker.onRoomEvent(startEvent());
      tracker.onRoomEvent(event(epoch: 3, live: false));

      expect(tracker.liveIn('group-100'), isNull);
      expect(tracker.pendingInvite, isNull);
      expect(tracker.liveCalls, isEmpty);
    });

    test('空房间的收尾事件再重复几次也不会出事', () {
      tracker.onRoomEvent(event(live: false));
      tracker.onRoomEvent(event(live: false));

      expect(tracker.liveCalls, isEmpty);
    });
  });

  group('四种不该记账的情况', () {
    test('老服务端（载荷里没有 live）：只当没看见，不猜「有人在开语音」', () {
      tracker.onRoomEvent(event(live: null, started: true));

      expect(tracker.liveCalls, isEmpty);
      expect(tracker.pendingInvite, isNull);
    });

    test('我人就在那间屋里（正在通话页上）：不给自己弹邀请', () {
      tracker.onRoomEvent(startEvent(), inRoomId: '100');

      expect(tracker.liveCalls, isEmpty);
    });

    test('我所在的房间号写成 group-100 时同样能对上（两种形状）', () {
      tracker.onRoomEvent(startEvent(), inRoomId: 'group-100');

      expect(tracker.liveCalls, isEmpty);
    });

    test('我在别的房间：那个群的语音照常记（只忽略我自己那间）', () {
      tracker.onRoomEvent(startEvent(roomId: '200'), inRoomId: '100');

      expect(tracker.liveIn('group-200'), isNotNull);
    });

    test('没有 room_id 的事件：丢掉，不炸', () {
      tracker.onRoomEvent(<String, dynamic>{'epoch': 3, 'live': true});

      expect(tracker.liveCalls, isEmpty);
    });
  });

  group('点掉与进去', () {
    test('点「忽略」：横幅不再弹，但列表标记照留（语音还在开）', () {
      tracker.onRoomEvent(startEvent());
      final call = tracker.liveIn('group-100')!;

      tracker.dismiss(call);

      expect(tracker.pendingInvite, isNull);
      expect(tracker.liveIn('group-100'), isNotNull);
    });

    test('重复点「忽略」不会重复通知界面', () {
      tracker.onRoomEvent(startEvent());
      final call = tracker.liveIn('group-100')!;
      tracker.dismiss(call);

      var notified = 0;
      tracker.addListener(() => notified += 1);
      tracker.dismiss(call);

      expect(notified, 0);
    });

    test('我进去了：标记与横幅都收掉，这一通之后的推送也不再弹', () {
      tracker.onRoomEvent(startEvent());
      tracker.onJoinedRoom('group-100');

      expect(tracker.liveIn('group-100'), isNull);
      expect(tracker.pendingInvite, isNull);

      // 同一通的后续事件（我人在里面，服务端照样会推）
      tracker.onRoomEvent(event(callId: 'c1', epoch: 3));
      expect(tracker.pendingInvite, isNull);
      expect(tracker.liveIn('group-100'), isNotNull, reason: '标记本身还是会记着');
    });

    test('忽略是按「这一通」记的：下一通照样弹', () {
      tracker.onRoomEvent(startEvent(callId: 'c1'));
      tracker.dismiss(tracker.liveIn('group-100')!);
      tracker.onRoomEvent(event(epoch: 3, live: false));

      tracker.onRoomEvent(startEvent(callId: 'c2'));

      expect(tracker.pendingInvite?.callId, 'c2');
    });

    test('服务端没给 call_id 时退回用会话 id 记（也能被忽略掉）', () {
      tracker.onRoomEvent(event(callId: '', started: true, name: '产品群'));
      final call = tracker.liveIn('group-100');
      expect(call, isNotNull);

      tracker.dismiss(call!);

      expect(tracker.pendingInvite, isNull);
    });
  });

  group('回查（屋里最后一个人的 App 被杀那条路）', () {
    test('回查说没人了：收掉', () async {
      tracker = GroupCallPresenceTracker(probe: (roomId) async => false)
        ..onRoomEvent(startEvent());

      await tracker.verify();

      expect(tracker.liveIn('group-100'), isNull);
    });

    test('回查说还有人：留着', () async {
      tracker = GroupCallPresenceTracker(probe: (roomId) async => true)
        ..onRoomEvent(startEvent());

      await tracker.verify();

      expect(tracker.liveIn('group-100'), isNotNull);
    });

    test('拿不准（网络失败）：保持原状，不把正在进行的语音抹掉', () async {
      tracker = GroupCallPresenceTracker(probe: (roomId) async => null)
        ..onRoomEvent(startEvent());

      await tracker.verify();

      expect(tracker.liveIn('group-100'), isNotNull);
    });

    test('回查抛异常：不往外炸，也保持原状', () async {
      tracker = GroupCallPresenceTracker(
        probe: (roomId) async => throw StateError('断网了'),
      )..onRoomEvent(startEvent());

      await tracker.verify();

      expect(tracker.liveIn('group-100'), isNotNull);
    });

    test('手里有标记时会自己按间隔回查（不需要界面催）', () async {
      var calls = 0;
      tracker = GroupCallPresenceTracker(
        verifyInterval: const Duration(milliseconds: 15),
        probe: (roomId) async {
          calls += 1;
          return true;
        },
      )..onRoomEvent(startEvent());

      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(calls, greaterThanOrEqualTo(2), reason: '按间隔反复回查');
    });

    test('标记全没了就把定时器停掉（平时一个定时器都不占）', () async {
      var calls = 0;
      tracker = GroupCallPresenceTracker(
        verifyInterval: const Duration(milliseconds: 15),
        probe: (roomId) async {
          calls += 1;
          return true;
        },
      )..onRoomEvent(startEvent());
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final settled = calls;

      tracker.onRoomEvent(event(epoch: 9, live: false));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(calls, settled, reason: '房间空了之后不该再回查');
    });

    test('dispose 之后定时器也停掉', () async {
      var calls = 0;
      final local = GroupCallPresenceTracker(
        verifyInterval: const Duration(milliseconds: 15),
        probe: (roomId) async {
          calls += 1;
          return true;
        },
      )..onRoomEvent(startEvent());
      local.dispose();

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(calls, 0);
    });
  });

  group('整段清空', () {
    test('reset：标记与「忽略过的那几通」一起清掉（换账号用）', () {
      tracker.onRoomEvent(startEvent());
      tracker.dismiss(tracker.liveIn('group-100')!);

      tracker.reset();

      expect(tracker.liveCalls, isEmpty);
      expect(tracker.pendingInvite, isNull);
    });
  });

  group('小工具', () {
    test('房间号 ↔ 会话 id 互为反函数', () {
      expect(groupConversationIdOfRoom('100'), 'group-100');
      expect(groupConversationIdOfRoom('group-100'), 'group-100');
      expect(groupRoomIdOfConversation('group-100'), '100');
      expect(groupRoomIdOfConversation('100'), '100');
      expect(groupConversationIdOfRoom(''), '');
    });
  });
}
