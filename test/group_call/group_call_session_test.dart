import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/sfu_models.dart';
import 'package:gracelinkim/domain/chat/group_members.dart';
import 'package:gracelinkim/domain/group_call/group_call_hub.dart';
import 'package:gracelinkim/domain/group_call/group_call_presence.dart';
import 'package:gracelinkim/domain/group_call/sfu_room.dart';
import 'package:gracelinkim/features/group_call/group_call_controller.dart';
import 'package:gracelinkim/features/group_call/group_call_session.dart';

import '../support/fake_call_keep_alive.dart';
import 'support/fake_sfu.dart';

/// 常驻会话与登记处（S6.17）：**退出通话页不等于挂断**这套规矩全靠它。
///
/// 这里验的都是「只有真机上才看得出来、但逻辑上必须写死」的那几件事：
/// 同一个群再进来还是那一通（不重开会话）、换一个群会先把上一通挂干净、
/// 关掉页面会话还在、进不去又没人看着时不留僵尸。
void main() {
  late FakeSfuControl control;
  late FakeCallKeepAlive keepAlive;
  late GroupCallHub hub;
  late GroupCallPresenceTracker presence;
  late GroupCallSessionHost host;

  /// 1:1 那台控制器的「通话中」状态（真的那份是 `CallController.view`）
  late ValueNotifier<bool> oneToOne;

  /// 每个会话一个连接工厂（真机上是新的一对 PeerConnection）
  late List<FakeSfuConnections> connections;

  /// 每一次 `createSession` 都记一笔（「有没有重新加入」就看它）
  int joinCount() => control.countOf('createSession:publish');

  GroupCallController buildController({
    required String conversationId,
    required String name,
  }) {
    final media = FakeSfuLocalMedia();
    final factory = FakeSfuConnections();
    connections.add(factory);
    return GroupCallController(
      groupName: name,
      room: SfuRoom(
        roomId: conversationId.startsWith('group-')
            ? conversationId.substring('group-'.length)
            : conversationId,
        myUserId: 'u1',
        control: control,
        local: media,
        connectionFactory: factory.call,
        audioLevelPollInterval: null,
        heartbeatInterval: null,
        stateRefreshInterval: null,
      ),
      loadMembers: () async => <GroupMember>[
        const GroupMember(userId: 'u1', name: '我'),
        const GroupMember(userId: 'u2', name: '小明'),
      ],
      keepAlive: keepAlive,
      notify: (_) {},
      // 登记处要跟着挂上：页面关着的时候，对账就靠它接住 `sfuRoom` 推送
      hub: hub,
    );
  }

  /// 把「进房间」那一串（采媒体、建会话、订阅全屋）推完。
  /// 会话是后台开跑的（`unawaited`），所以这里反复让出事件循环
  Future<void> settle([int rounds = 20]) async {
    for (var i = 0; i < rounds; i += 1) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() {
    control = FakeSfuControl();
    control.snapshot = SfuRoomState(
      epoch: 1,
      members: <SfuRoomMember>[
        member('u1', 'sess-publish-1', <String>['mic']),
        member('u2', 'sess-pub-u2', <String>['mic']),
      ],
    );
    keepAlive = FakeCallKeepAlive();
    connections = <FakeSfuConnections>[];
    hub = GroupCallHub();
    presence = GroupCallPresenceTracker();
    oneToOne = ValueNotifier<bool>(false);
    host = GroupCallSessionHost(
      factory: buildController,
      hub: hub,
      presence: presence,
      oneToOne: oneToOne,
      oneToOneActive: () => oneToOne.value,
    );
  });

  tearDown(() async {
    await host.end();
    host.dispose();
    presence.dispose();
    oneToOne.dispose();
  });

  test('1:1 电话一接通，群通话自己让路（一条链路只能有一只麦克风）', () async {
    final session = await host.openPage(
      conversationId: 'group-100',
      name: '产品群',
    );
    await settle();
    expect(session.view.phase, SfuRoomPhase.joined);

    // 来电只是响铃（还没接）时不动
    oneToOne.value = false;
    await settle();
    expect(host.active, isNotNull);

    // 接通那一刻：群通话自己收尾
    oneToOne.value = true;
    await settle();

    expect(host.active, isNull);
    expect(hub.active, isNull, reason: '对账登记也要跟着脱钩');
    expect(keepAlive.stops, 1, reason: '前台服务只有一份，必须干净地让出去');
    expect(control.countOf('leave'), 1);
    expect(session.view.phase, SfuRoomPhase.idle);
  });

  test('进来就是加入：会话进房间、保活起来、登记处找到了它', () async {
    final session = await host.openPage(
      conversationId: 'group-100',
      name: '产品群',
    );
    await settle();

    expect(session.view.phase, SfuRoomPhase.joined);
    expect(host.active, same(session));
    expect(host.sessionFor('group-100'), same(session));
    expect(host.pageOpen, isTrue);
    expect(keepAlive.starts, <String>['video=false peer=产品群']);
    // 房间里的人算得出来（小窗与群聊页那条都用它）
    expect(session.memberCount, 2);
    expect(session.joinedAt, isNotNull);
    expect(session.elapsed.inMilliseconds, greaterThanOrEqualTo(0));
    // 对账登记也挂上了（页面不在也能接住推送）
    expect(hub.active, same(session.controller.room));
  });

  test('同一个群再进来：还是那一通（不重新加入、不重开会话）', () async {
    final first = await host.openPage(conversationId: 'group-100', name: '产品群');
    await settle();
    final sessionsBefore = joinCount();

    // 关掉页面（退出通话页）再进来
    host.closePage();
    expect(host.active, same(first), reason: '关掉页面不等于挂断');
    final second = await host.openPage(
      conversationId: 'group-100',
      name: '产品群',
    );
    await settle();

    expect(second, same(first));
    expect(joinCount(), sessionsBefore, reason: '不该重新建发布会话');
    expect(keepAlive.starts.length, 1, reason: '不该再起一次前台服务');
  });

  test('关掉页面：会话照旧在跑（声音、对账、计时都不受影响）', () async {
    final session = await host.openPage(
      conversationId: 'group-100',
      name: '产品群',
    );
    await settle();
    expect(session.view.phase, SfuRoomPhase.joined);

    host.closePage();

    expect(host.pageOpen, isFalse);
    expect(host.active, same(session));
    expect(session.view.phase, SfuRoomPhase.joined);
    expect(session.controller.room.view.value.phase, SfuRoomPhase.joined);
    // 一条 leave 都没发过：这通还在
    expect(control.countOf('leave'), 0);
    expect(keepAlive.stops, 0);
  });

  test('挂断：会话没了、房间关干净、登记处也清空', () async {
    final session = await host.openPage(
      conversationId: 'group-100',
      name: '产品群',
    );
    await settle();

    await host.end();

    expect(host.active, isNull);
    expect(host.sessionFor('group-100'), isNull);
    expect(host.pageOpen, isFalse);
    expect(control.countOf('leave'), 1);
    expect(keepAlive.stops, 1);
    expect(hub.active, isNull, reason: '对账登记也要摘掉');
    // 会话已经收尾：视图不该再被谁推着变（再挂一次是空转）
    expect(session.joinedAt, isNotNull);
    await host.end();
    expect(control.countOf('leave'), 1);
  });

  test('换一个群进去：先把上一通挂干净（一次只有一通）', () async {
    final first = await host.openPage(conversationId: 'group-100', name: '产品群');
    await settle();

    final second = await host.openPage(
      conversationId: 'group-200',
      name: '另一个群',
    );
    await settle();

    expect(second, isNot(same(first)));
    expect(host.active, same(second));
    expect(host.sessionFor('group-100'), isNull);
    expect(control.countOf('leave'), 1, reason: '上一通要挂干净');
    // 前一个群那间屋子已经不在对账名单上了（推来的事件不会把它拉回来）
    expect(hub.active, same(second.controller.room));
    expect(second.controller.room.roomId, '200');
  });

  test('进不去的会话：页面关掉之后不留僵尸（自己收掉）', () async {
    // 发布会话失败 → 这是一个「进不去」的会话
    control.failOnce['createSession'] = FakeSfuControl.unknownOutcome();
    final session = await host.openPage(
      conversationId: 'group-100',
      name: '产品群',
    );
    await settle();

    expect(session.view.phase, SfuRoomPhase.failed);
    expect(host.active, same(session), reason: '页面还看着它，先留着（能重试）');

    host.closePage();
    await settle();

    expect(host.active, isNull, reason: '没人看着的「进不去」没有留下的理由');
    expect(host.pageOpen, isFalse);
  });

  test('登录态变了就整段清掉（reset）', () async {
    await host.openPage(conversationId: 'group-100', name: '产品群');
    await settle();

    await host.reset();

    expect(host.active, isNull);
    expect(control.countOf('leave'), 1);
  });
}
