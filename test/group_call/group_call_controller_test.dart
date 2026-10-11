import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/sfu_models.dart';
import 'package:gracelinkim/domain/chat/group_members.dart';
import 'package:gracelinkim/domain/group_call/sfu_room.dart';
import 'package:gracelinkim/features/group_call/group_call_controller.dart';

import '../support/fake_call_keep_alive.dart';
import '../support/fake_call_pip.dart';
import 'support/fake_sfu.dart';

/// 群通话控制器：名单、开关、共享屏的三步顺序、挂断。
///
/// 这些判断在真机上"错了也能跑"，但后果都很直接：共享屏取流抛 SecurityException、
/// 退出后前台服务还挂着（常驻通知）、名字对不上人。
void main() {
  late FakeSfuControl control;
  late FakeSfuLocalMedia local;
  late FakeSfuConnections connections;
  late FakeCallKeepAlive keepAlive;
  late FakeCallPip pip;
  late List<String> trace;
  late List<String> notices;

  /// 带名字的提示（`key|名字`）：谁离开了 / 谁的共享断了
  late List<String> namedNotices;
  late List<({int seconds, int participants})> records;
  late SfuRoom room;

  /// 房间里：我（u1，发了 mic）+ u2（发了 mic）；u3 是群成员但没进通话
  void snapshotWith({bool u2Screen = false}) {
    control.snapshot = SfuRoomState(
      epoch: 1,
      members: <SfuRoomMember>[
        member('u1', 'sess-publish-1', <String>['mic']),
        member('u2', 'sess-pub-u2', <String>['mic', if (u2Screen) 'screen']),
      ],
    );
  }

  GroupCallController buildController({
    Future<List<GroupMember>> Function()? loadMembers,
    bool supportsScreen = true,
    GroupCallRecordWriter? writeRecord,
    FakeCallPip? pipOverride,
    Duration? screenHealthInterval,
    Duration screenStallTimeout = const Duration(seconds: 8),
    DateTime Function()? now,
  }) {
    local = FakeSfuLocalMedia(supportsScreen: supportsScreen)..trace = trace;
    room = SfuRoom(
      roomId: '100',
      myUserId: 'u1',
      control: control,
      local: local,
      connectionFactory: connections.call,
      audioLevelPollInterval: null,
      heartbeatInterval: null,
      stateRefreshInterval: null,
      // 默认不自动采（用例自己推时钟）；要看健康检查的那条自己传个间隔
      screenHealthInterval: screenHealthInterval,
      screenStallTimeout: screenStallTimeout,
      now: now,
    );
    return GroupCallController(
      groupName: '产品群',
      room: room,
      loadMembers:
          loadMembers ??
          () async => <GroupMember>[
            const GroupMember(userId: 'u1', name: '我'),
            const GroupMember(userId: 'u2', name: '小明', avatar: 'a2.png'),
            const GroupMember(userId: 'u3', name: '小红'),
          ],
      keepAlive: keepAlive,
      pip: pipOverride ?? pip,
      notify: notices.add,
      notice: (key, name) => namedNotices.add('$key|$name'),
      writeRecord:
          writeRecord ??
          ({required int seconds, required int participants}) async {
            records.add((seconds: seconds, participants: participants));
          },
    );
  }

  setUp(() {
    control = FakeSfuControl();
    connections = FakeSfuConnections();
    keepAlive = FakeCallKeepAlive();
    pip = FakeCallPip();
    trace = <String>[];
    keepAlive.trace = trace;
    notices = <String>[];
    namedNotices = <String>[];
    records = <({int seconds, int participants})>[];
    snapshotWith();
  });

  group('进房间', () {
    test('名单拉回来：在通话的人排前面、我在最前，名字/头像对上', () async {
      final controller = buildController();
      await controller.start();

      final view = controller.view.value;
      expect(view.phase, SfuRoomPhase.joined);
      expect(view.inCallMembers.map((member) => member.userId), <String>[
        'u1',
        'u2',
      ], reason: 'u3 在群里但没进通话');
      expect(view.members.map((member) => member.userId), <String>[
        'u1',
        'u2',
        'u3',
      ]);
      final u2 = view.members.firstWhere((member) => member.userId == 'u2');
      expect(u2.name, '小明');
      expect(u2.avatar, 'a2.png');
      expect(u2.audio, isTrue);
      expect(u2.inCall, isTrue);
      final u3 = view.members.firstWhere((member) => member.userId == 'u3');
      expect(u3.inCall, isFalse);
      expect(view.members.first.isMe, isTrue);

      await controller.dispose();
    });

    test('保活：进房间起前台服务（语音类型、通知上写群名）', () async {
      final controller = buildController();
      await controller.start();

      expect(keepAlive.starts, <String>['video=false peer=产品群']);
      await controller.dispose();
      expect(keepAlive.stops, 1);
    });

    test('保活要等**采到麦克风之后**才起（Android 14 的 while-in-use 校验）', () async {
      // 首次通话时 RECORD_AUDIO 还没授权，而弹那个权限框的正是 `join()` 里的
      // getUserMedia：先起 mic 类型的前台服务会被系统直接拒掉，后果是整通电话
      // 没有常驻通知、屏幕共享也跟着一起坏。与 1:1 的 `_openMedia` 同一个口径：
      // **先拿媒体，再起服务**。
      final controller = buildController();
      await controller.start();

      expect(
        trace.indexOf('media.startMicrophone'),
        lessThan(trace.indexOf('service.start')),
        reason: '拿媒体必须排在起前台服务之前：$trace',
      );

      await controller.dispose();
    });

    test('进不去（没权限/人满）就不起前台服务：免得留一条没有通话的通知', () async {
      control.failOnce['createSession'] = FakeSfuControl.unknownOutcome();
      control.failOnce['createSession'] = FakeSfuControl.unknownOutcome();

      final controller = buildController();
      await controller.start();

      expect(controller.view.value.phase, SfuRoomPhase.failed);
      expect(keepAlive.starts, isEmpty);

      await controller.dispose();
    });

    test('拿到媒体之后把声音切到免提（不切的话安卓默认走听筒）', () async {
      final controller = buildController();
      await controller.start();

      expect(local.speakerOn, isTrue, reason: '微信群语音默认就是免提');
      // 顺序：媒体先起来，再切路由（与 1:1 那条一致）
      expect(local.micStarted, isTrue);

      await controller.dispose();
    });

    test('路由切不过去不影响这通电话（只记日志）', () async {
      local.speakerFails = true;
      final controller = buildController();
      await controller.start();

      expect(controller.view.value.phase, SfuRoomPhase.joined);

      await controller.dispose();
    });

    test('名单取不到也能通话（只是名字退化成空，界面自己兜「群成员」）', () async {
      final controller = buildController(
        loadMembers: () async => throw StateError('网络炸了'),
      );
      await controller.start();

      expect(controller.view.value.phase, SfuRoomPhase.joined);
      final u2 = controller.view.value.members.firstWhere(
        (member) => member.userId == 'u2',
      );
      expect(u2.name, '');
      expect(u2.inCall, isTrue, reason: '名字没有不影响他在通话里这件事');

      await controller.dispose();
    });
  });

  group('麦克风：意图（按钮）与事实（发出去没有）必须分开', () {
    test('发布没落地：按钮仍是我的意图、点得动；事实由 micPublished 说', () async {
      // 快照里我那一行没有 mic（上游没接受我的发布）
      control.snapshot = SfuRoomState(
        epoch: 1,
        members: <SfuRoomMember>[member('u1', 'sess-publish-1', <String>[])],
      );

      final controller = buildController();
      await controller.start();

      expect(controller.view.value.micPublished, isFalse);
      expect(
        controller.view.value.micEnabled,
        isTrue,
        reason: '按钮不能被锁死 —— 那是用户报的「点多少次都开不了麦」',
      );

      await controller.toggleMicrophone();
      expect(controller.view.value.micEnabled, isFalse, reason: '点一下就该变得了');
      await controller.toggleMicrophone();
      expect(controller.view.value.micEnabled, isTrue);

      await controller.dispose();
    });

    test('发布落地了：micPublished 为真（界面不再挂那行警告）', () async {
      final controller = buildController();
      await controller.start();

      expect(controller.view.value.micPublished, isTrue);

      await controller.dispose();
    });
  });

  group('共享屏幕（三步顺序是 Android 14 的硬要求）', () {
    test('先授权 → 再升前台服务类型 → 最后取流', () async {
      final controller = buildController();
      await controller.start();

      await controller.toggleScreenShare();

      expect(trace, <String>[
        'media.startMicrophone',
        'service.start',
        'media.permission',
        'service.sharing=true',
        'media.startScreen',
      ]);
      expect(controller.view.value.screenSharing, isTrue);
      expect(local.screenSharing, isTrue);
      // 发布出去的确实多了那条 screen
      final publish = control.calls.lastWhere(
        (call) => call.method == 'publish',
      );
      final tracks = publish.args['tracks']! as List<dynamic>;
      expect(tracks.length, 1);
      expect((tracks.single as Map<String, dynamic>)['track_name'], 'screen');

      await controller.dispose();
    });

    test('桌面上选中的那个源（整个屏幕/某个窗口）一路带到取流那一步', () async {
      // S12.38：桌面上先弹选择面板（`showScreenSharePicker`），选到的源 id 要
      // 一直传到 `getDisplayMedia` 的 `deviceId`（原生只认它）。
      final controller = buildController();
      await controller.start();

      await controller.toggleScreenShare(sourceId: 'window:4242:0');

      expect(local.screenSourceId, 'window:4242:0');
      expect(local.screenStartCalls, 1);
      expect(controller.view.value.screenSharing, isTrue);

      await controller.dispose();
    });

    test('保活没起来时点共享屏：**当场补起一个**，而不是直接跳过', () async {
      // 取 MediaProjection 的前置条件是「已经有带 mediaProjection 类型的前台服务
      // 在跑」——跳过就等于把共享屏判死。
      keepAlive.startError = '系统拒绝了';
      final controller = buildController();
      await controller.start();
      expect(keepAlive.starts, isEmpty, reason: '先起失败一次');

      keepAlive.startError = null;
      await controller.toggleScreenShare();

      expect(keepAlive.starts, hasLength(1), reason: '点共享屏时补起一个');
      expect(keepAlive.sharingChanges, <bool>[true]);
      expect(controller.view.value.screenSharing, isTrue);

      await controller.dispose();
    });

    test('停止共享：先把流放掉，再把服务类型降回来', () async {
      final controller = buildController();
      await controller.start();
      await controller.toggleScreenShare();

      await controller.toggleScreenShare();

      expect(keepAlive.sharingChanges, <bool>[true, false]);
      expect(local.screenSharing, isFalse);
      expect(controller.view.value.screenSharing, isFalse);

      await controller.dispose();
    });

    test('用户拒绝投屏授权：不取流、不升类型位，只提示', () async {
      final controller = buildController();
      await controller.start();
      local.screenPermissionGranted = false;
      final publishesBefore = control.countOf('publish');

      await controller.toggleScreenShare();

      expect(local.screenSharing, isFalse);
      expect(keepAlive.sharingChanges, isEmpty);
      expect(control.countOf('publish'), publishesBefore);
      expect(notices, <String>['call.shareRefused']);

      await controller.dispose();
    });

    test('已经有人在共享：**不许抢**，只提示（共享屏同一时刻只能一个人）', () async {
      // 两个人同时共享会互相打架：注册表里两条 screen，观看端只认其中一条，
      // 而且两边都要重协商。拦住第二个人，并告诉他是谁在共享。
      snapshotWith(u2Screen: true);
      final controller = buildController();
      await controller.start();
      expect(controller.view.value.screenSharer?.userId, 'u2');
      expect(controller.view.value.screenSharer?.name, '小明');
      final publishesBefore = control.countOf('publish');

      await controller.toggleScreenShare();

      expect(local.permissionAsked, isFalse, reason: '连系统投屏框都不该弹');
      expect(keepAlive.sharingChanges, isEmpty);
      expect(local.screenSharing, isFalse);
      expect(controller.view.value.screenSharing, isFalse);
      expect(control.countOf('publish'), publishesBefore);
      expect(notices, <String>['group.callShareTaken']);

      await controller.dispose();
    });

    test('对方停止共享之后我就能开了（拦住的是"此刻有人"，不是永久）', () async {
      snapshotWith(u2Screen: true);
      final controller = buildController();
      await controller.start();

      snapshotWith();
      await room.refreshRoomState();
      expect(controller.view.value.screenSharer, isNull);

      await controller.toggleScreenShare();

      expect(controller.view.value.screenSharing, isTrue);
      expect(notices, isEmpty);

      await controller.dispose();
    });

    test('取流失败：回滚服务类型位 + 提示（不能留在「正在共享」）', () async {
      final controller = buildController();
      await controller.start();
      local.screenStartFails = true;

      await controller.toggleScreenShare();

      expect(keepAlive.sharingChanges, <bool>[true, false]);
      expect(controller.view.value.screenSharing, isFalse);
      expect(notices, <String>['call.shareFailed']);

      await controller.dispose();
    });

    test('这台设备不支持投屏：按钮不出现，点了也不做事', () async {
      final controller = buildController(supportsScreen: false);
      await controller.start();

      expect(controller.view.value.supportsScreenShare, isFalse);
      await controller.toggleScreenShare();

      expect(local.permissionAsked, isFalse);
      expect(keepAlive.sharingChanges, isEmpty);

      await controller.dispose();
    });
  });

  group('会上的状态', () {
    test('静音开关：只改本机麦克风（人还在房间里）', () async {
      final controller = buildController();
      await controller.start();

      await controller.toggleMicrophone();

      expect(local.micEnabled, isFalse);
      expect(controller.view.value.micEnabled, isFalse);
      expect(controller.view.value.phase, SfuRoomPhase.joined);

      await controller.toggleMicrophone();
      expect(local.micEnabled, isTrue);

      await controller.dispose();
    });

    test('谁在说话：房间判定出来的人，名单上那一行标着 speaking', () async {
      final controller = buildController();
      await controller.start();

      // 接收侧把 u2 那条 mic 的能量报上来
      connections.receive.audioLevelsByMid = <String, double>{'mid-mic': 0.5};
      await room.pollAudioLevels();

      expect(controller.view.value.activeSpeakerId, 'u2');
      expect(
        controller.view.value.members
            .firstWhere((member) => member.userId == 'u2')
            .speaking,
        isTrue,
      );

      await controller.dispose();
    });

    test('收到的共享屏有人对得上 → 进界面；注册表说没人共享了就清掉', () async {
      snapshotWith(u2Screen: true);
      control.receivingMids['sess-pub-u2|screen'] = 'mid-screen-u2';
      final controller = buildController();
      await controller.start();
      expect(controller.view.value.screen, isNull);

      connections.receive.emit(
        'mid-screen-u2',
        kind: 'video',
        stream: 'screen-stream',
      );
      await Future<void>.delayed(Duration.zero); // 广播流的投递是排队的

      expect(controller.view.value.screen?.userId, 'u2');
      expect(controller.view.value.screen?.stream, 'screen-stream');

      // 对方停止共享：注册表里那条 screen 没了 → 手里这份流必须作废
      // （画面会冻在最后一帧，留着比清掉更糟）
      snapshotWith();
      await room.refreshRoomState();

      expect(controller.view.value.screen, isNull);

      await controller.dispose();
    });
  });

  group('异常收尾（对方直接挂断群通话）', () {
    // 用户 2026-10-08 报的：**电脑在共享屏幕、然后直接挂断群通话**，手机端就
    // 永远停在最后一帧，连「对方已离开」都没有。
    //
    // 那条链有两个会静默断掉的地方：注册表要等心跳/行超时（封顶 45 秒）才清
    // 推送也可能丢。所以除了注册表那条路，接收侧自己还盯了一道「那一路还在不在收」。
    test('共享那一路收不到帧：画面放下来 + 飘一条「共享中断」', () async {
      snapshotWith(u2Screen: true);
      control.receivingMids['sess-pub-u2|screen'] = 'mid-screen-u2';
      var clock = DateTime(2026, 10, 8, 22);
      final controller = buildController(
        screenHealthInterval: const Duration(milliseconds: 20),
        screenStallTimeout: const Duration(seconds: 5),
        now: () => clock,
      );
      await controller.start();
      connections.receive.emit(
        'mid-screen-u2',
        kind: 'video',
        stream: 'screen-stream',
      );
      connections.receive.videoCountersByMid = <String, int>{
        'mid-screen-u2': 40,
      };
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(controller.view.value.screen?.userId, 'u2');

      // 计数一动不动：过了 5 秒就该自己判出来（注册表一个字都没变）
      clock = clock.add(const Duration(seconds: 6));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await pumpEventQueue();

      expect(
        controller.view.value.screen,
        isNull,
        reason: '不能让用户一直盯着一张死图（对面那一路已经没了）',
      );
      expect(namedNotices, contains('group.callShareLost|小明'));

      await controller.dispose();
    });

    test('有人退出通话：飘一条带名字的「已离开通话」', () async {
      final controller = buildController();
      await controller.start();
      expect(namedNotices, isEmpty, reason: '刚进来时没人走过');

      // u2 挂了：注册表里只剩我
      control.snapshot = SfuRoomState(
        epoch: 2,
        members: <SfuRoomMember>[
          member('u1', 'sess-publish-1', <String>['mic']),
        ],
      );
      await room.refreshRoomState();
      await pumpEventQueue();

      expect(
        controller.view.value.inCallMembers.map((member) => member.userId),
        <String>['u1'],
      );
      expect(namedNotices, contains('group.callMemberLeft|小明'));

      await controller.dispose();
    });

    test('我自己挂断：不飘「谁已离开」（那不是别人走了，是这一页散了）', () async {
      final controller = buildController();
      await controller.start();

      await controller.hangup();

      expect(namedNotices, isEmpty);
      expect(controller.view.value.phase, SfuRoomPhase.idle);

      await controller.dispose();
    });
  });

  group('退出', () {
    test('挂断：关两条会话 + 停保活 + 回空闲', () async {
      final controller = buildController();
      await controller.start();

      await controller.hangup();

      expect(control.countOf('leave'), 1);
      expect(keepAlive.stops, 1);
      expect(controller.view.value.phase, SfuRoomPhase.idle);
    });

    test('dispose 幂等：连关两次不会把保活/会话重复折腾', () async {
      final controller = buildController();
      await controller.start();

      await controller.hangup();
      await controller.dispose();
      await controller.dispose();

      expect(keepAlive.stops, 1);
      expect(control.countOf('leave'), 1);
    });
  });

  group('群里的通话记录（房间空了由最后一个走的人落一条）', () {
    /// 服务端说：我这一走房间就空了，而这通的收尾由我来广播
    void lastOneOut({int seconds = 45, int participants = 3}) {
      control.leaveResult = SfuLeaveResult(
        closed: true,
        announce: true,
        durationSeconds: seconds,
        participants: participants,
      );
    }

    test('最后一个走的人落记录：时长与人数按服务端交代的原样带过去', () async {
      lastOneOut();
      final controller = buildController();
      await controller.start();

      await controller.hangup();

      expect(records, <({int seconds, int participants})>[
        (seconds: 45, participants: 3),
      ]);
    });

    test('房间里还有别人（announce=false）：不落记录', () async {
      control.leaveResult = const SfuLeaveResult(
        durationSeconds: 45,
        participants: 3,
      );
      final controller = buildController();
      await controller.start();

      await controller.hangup();

      expect(records, isEmpty);
    });

    test('只有我一个人进过房间（participants=1）：点进去又出来，不留记录', () async {
      lastOneOut(seconds: 3, participants: 1);
      final controller = buildController();
      await controller.start();

      await controller.hangup();

      expect(records, isEmpty);
    });

    test('服务器没交代（没升级补丁 / 请求失败）：不落记录，但退出照常', () async {
      control.failOnce['leave'] = FakeSfuControl.unknownOutcome();
      final controller = buildController();
      await controller.start();

      await controller.hangup();

      expect(records, isEmpty);
      expect(keepAlive.stops, 1);
      expect(controller.view.value.phase, SfuRoomPhase.idle);
    });

    test('直接退出页面（没点挂断）：dispose 兜底那次照样落', () async {
      lastOneOut(seconds: 12, participants: 2);
      final controller = buildController();
      await controller.start();

      await controller.dispose();

      expect(records, <({int seconds, int participants})>[
        (seconds: 12, participants: 2),
      ]);
    });

    test('只落一条：hangup 之后再 dispose 不会再发一次', () async {
      lastOneOut();
      final controller = buildController();
      await controller.start();

      await controller.hangup();
      await controller.dispose();

      expect(records.length, 1);
      expect(
        control.countOf('leave'),
        1,
        reason: 'dispose 时已经离过房，不会再发一次 leave',
      );
    });

    test('记录发失败（网络丢包、被禁言）不能影响挂断收尾', () async {
      lastOneOut();
      final controller = buildController(
        writeRecord: ({required int seconds, required int participants}) async {
          throw StateError('接口炸了');
        },
      );
      await controller.start();

      await controller.hangup();
      await controller.dispose();

      expect(keepAlive.stops, 1);
      expect(controller.view.value.phase, SfuRoomPhase.idle);
    });
  });

  group('小窗（画中画）', () {
    test('进房间就把参数交给系统：语音那一档比例 + 群名标题，但**不**自己缩窗', () async {
      final controller = buildController();
      await controller.start();

      expect(pip.last, 'video=false title=产品群');
      expect(pip.enters, 0, reason: '用户没点那颗钮，绝不自己缩成小窗');
      expect(controller.view.value.inPip, isFalse, reason: '还没进小窗，界面照旧要画按钮');

      await controller.dispose();
    });

    test('点「缩成小窗」→ 原生进一次；原生报进了/出了，界面跟着切', () async {
      final controller = buildController();
      await controller.start();

      await controller.minimizeToPip();
      expect(pip.enters, 1);

      pip.emitMode(true);
      expect(controller.view.value.inPip, isTrue);

      // 用户从系统小窗展开了：界面恢复成有按钮的样子
      pip.emitMode(false);
      expect(controller.view.value.inPip, isFalse);

      await controller.dispose();
    });

    test('挂断：把已经打开的小窗收掉，并摘掉监听（不再推界面）', () async {
      final controller = buildController();
      await controller.start();
      await controller.minimizeToPip();
      pip.emitMode(true);

      await controller.hangup();

      expect(pip.exits, 1);
      expect(controller.view.value.inPip, isFalse);

      // 这一通已经结束了：原生再报「进小窗」，界面不该再有反应
      final settled = controller.view.value;
      pip.emitMode(true);
      expect(controller.view.value, same(settled));

      await controller.dispose();
    });

    test('还没进房间就退出：参数一次都没设过（也没缩过窗）', () async {
      final controller = buildController();
      await controller.dispose();

      expect(pip.settings, isEmpty);
      expect(pip.enters, 0);
      expect(pip.exits, 0, reason: '没进过小窗就没什么可收的');
    });

    test('系统没有画中画（iOS / 桌面）：一次通道都不打，也不影响通话', () async {
      final noPip = FakeCallPip(supported: false);
      final controller = buildController(pipOverride: noPip);
      await controller.start();

      await controller.minimizeToPip();
      await controller.hangup();

      // 不支持就是这条链路上一个通道调用都没有（连参数也不设）
      expect(noPip.enters, 0);
      expect(noPip.settings, isEmpty);
      expect(controller.view.value.phase, SfuRoomPhase.idle);
    });
  });

  test('群会话 id → 房间号：注册表里存的是数字群号', () {
    expect(groupCallRoomId('group-100'), '100');
    expect(groupCallRoomId('100'), '100');
  });
}
