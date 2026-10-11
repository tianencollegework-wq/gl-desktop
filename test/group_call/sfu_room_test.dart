import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/sfu_models.dart';
import 'package:gracelinkim/domain/group_call/sfu_failure.dart';
import 'package:gracelinkim/domain/group_call/sfu_room.dart';

import 'support/fake_sfu.dart';

void main() {
  late FakeSfuControl control;
  late FakeSfuLocalMedia local;
  late FakeSfuConnections connections;
  late SfuRoom room;

  /// 房间里有：我（u1，正在发布 mic）+ u2（发 mic）+ u3（只听）
  SfuRoomState twoPublishers({int epoch = 1, bool withScreen = false}) =>
      SfuRoomState(
        epoch: epoch,
        members: <SfuRoomMember>[
          member('u1', 'sess-publish-1', <String>['mic']),
          member('u2', 'sess-pub-u2', <String>[
            'mic',
            if (withScreen) 'screen',
          ]),
          member('u3', '', <String>[]),
        ],
      );

  setUp(() {
    control = FakeSfuControl();
    local = FakeSfuLocalMedia();
    connections = FakeSfuConnections();
    room = SfuRoom(
      roomId: 'g-100',
      myUserId: 'u1',
      control: control,
      local: local,
      connectionFactory: connections.call,
    );
    control.snapshot = twoPublishers();
  });

  tearDown(() => room.dispose());

  group('进房间', () {
    test('采麦克风 → 建发布会话并发布 mic → 拉到快照', () async {
      await room.join();

      expect(local.micStarted, isTrue);
      expect(control.log.first, 'createSession:publish');
      final publish = control.calls.firstWhere((c) => c.method == 'publish');
      expect(publish.args['tracks'], <dynamic>[
        <String, dynamic>{'track_name': 'mic', 'mid': 'mid-mic-1'},
      ]);
      // 两趟快照：一趟在进房间那段（**与发布并行** —— 2026-09-27 起进房间不再等
      // 发布谈成，真机上那一趟要好几秒），一趟是**发布落地之后**的回读
      // （`micPublished` 的唯一来源是注册表，发布回包说了不算 —— 见 sfu_room.dart）。
      expect(control.countOf('roomState'), 2);
      expect(
        control.log.lastIndexOf('roomState'),
        greaterThan(control.log.indexOf('publish')),
        reason: '发布落地之后那一趟必须排在发布后面（不然读到的还是没写进去的旧注册表）',
      );
      expect(room.view.value.phase, SfuRoomPhase.joined);
      expect(room.view.value.participants.length, 3);
      // CF 的硬要求：应用完 answer 要等到 ICE 连上才算这一步做完
      expect(connections.publish.waitConnectedCalls, greaterThan(0));
      expect(connections.receive.waitConnectedCalls, greaterThan(0));
    });

    test('推送没来、版本号也没变：定期回查自己把界面纠正（最多 5 秒）', () async {
      // 真机上"对方停了共享我还卡在画面上 / 人都走了三分钟还挂在那儿"就是这条：
      // 注册表变了但没有任何东西告诉这台手机（额推丢了、或者服务端自己也不
      // 知道 —— 掉的都是要靠行超时清的人）。所以界面不能只信推送。
      final polling = SfuRoom(
        roomId: 'g-100',
        myUserId: 'u1',
        control: control,
        local: local,
        connectionFactory: connections.call,
        heartbeatInterval: null,
        audioLevelPollInterval: null,
        stateRefreshInterval: const Duration(milliseconds: 20),
      );
      addTearDown(polling.dispose);
      await polling.join();
      expect(polling.view.value.participants.length, 3);

      // 对方走了：注册表变了，但**没人推**、版本号也没变（epoch 还是 1）
      control.snapshot = SfuRoomState(
        epoch: 1,
        members: <SfuRoomMember>[
          member('u1', 'sess-publish-1', <String>['mic']),
        ],
      );

      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(polling.view.value.participants.length, 1, reason: '回查应该已经跑过几轮');
    });

    test('服务端慢：定期回查自己退避，不再每 5 秒往里压一条', () async {
      // 2026-10-06 在源站上量到的：连 `/common/pub/checkVersion` 都要 1.7~6.3s、
      // `sfu/room` 2.7~30s。那种时候还按固定间隔轮询，等于往火上浇油
      // （请求自己在排队，界面反而更不准）。健康了就该退回配置的间隔。
      final polling = SfuRoom(
        roomId: 'g-100',
        myUserId: 'u1',
        control: control,
        local: local,
        connectionFactory: connections.call,
        heartbeatInterval: null,
        audioLevelPollInterval: null,
        stateRefreshInterval: const Duration(milliseconds: 20),
        slowPollThreshold: const Duration(milliseconds: 1),
      );
      addTearDown(polling.dispose);
      control.roomStateDelay = const Duration(milliseconds: 10);
      await polling.join();

      final beforeSlow = control.countOf('roomState');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final slowPolls = control.countOf('roomState') - beforeSlow;

      // 服务端恢复（快得很）
      control.roomStateDelay = null;
      final beforeFast = control.countOf('roomState');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final fastPolls = control.countOf('roomState') - beforeFast;

      expect(
        slowPolls,
        lessThanOrEqualTo(4),
        reason: '慢的时候 150ms 里不该还压 7 条（间隔该已经拉长了）',
      );
      expect(fastPolls, greaterThan(slowPolls), reason: '健康了就退回配置的间隔');
    });

    test('版本号倒退（服务端重启/清了缓存）不会让这台手机永久收不到更新', () async {
      // 版本号是服务端缓存里的一个计数器：缓存清过就会从 1 重新数。
      // 以前判断是"不比手里这份新就不刷"→ 那种时候**永远**刷不动
      // （真机上是"别人进出我都看不见"，直到自己重进房间）。
      control.snapshot = SfuRoomState(
        epoch: 9,
        members: <SfuRoomMember>[
          member('u1', 'sess-publish-1', <String>['mic']),
          member('u2', 'sess-pub-u2', <String>['mic']),
        ],
      );
      await room.join();
      expect(room.view.value.participants.length, 2);

      // 服务端那边已经是新的一轮计数（epoch 2），而且 u2 走了
      control.snapshot = SfuRoomState(
        epoch: 2,
        members: <SfuRoomMember>[
          member('u1', 'sess-publish-1', <String>['mic']),
        ],
      );
      await room.refreshRoomState(epoch: 2);

      expect(room.view.value.participants.length, 1);
    });

    test('发布还没谈成，房间就已经可用了（听见别人不等我的发布）', () async {
      // 真机上"加入要 3~5 秒"主要就等在这一跳：候选收集 + 与 Cloudflare 建连。
      // 而**听见别人根本不需要它**（两条会话互不相干），所以发布不能再堵在进房间的路上。
      control.publishBlocker = Completer<void>();

      final joining = room.join();
      await pumpEventQueue();

      expect(room.view.value.phase, SfuRoomPhase.joined, reason: '已经听得到了');
      expect(room.subscriptionKeys, <String>{'u2|mic'});
      expect(room.view.value.micPublishPending, isTrue, reason: '我的发布还在飞');
      expect(
        room.view.value.micPublished || room.view.value.micPublishPending,
        isTrue,
        reason:
            '通话页那行红字的条件正好是"两个都为假" —— 发布还在飞时绝不能挂它，'
            '否则每次进房间都要先红几秒',
      );

      control.releasePublish();
      await joining;

      expect(room.view.value.micPublishPending, isFalse);
      expect(room.view.value.micPublished, isTrue);
    });

    test('订阅：**不带本地 offer**，一次把该订的全订上，且不订自己', () async {
      await room.join();

      final subscribe = control.calls.singleWhere(
        (call) => call.method == 'subscribe',
      );
      expect(subscribe.args.containsKey('sdp_offer'), isFalse);
      expect(subscribe.args['tracks'], <dynamic>[
        <String, dynamic>{'session_id': 'sess-pub-u2', 'track_name': 'mic'},
      ]);
      expect(room.subscriptionKeys, <String>{'u2|mic'});
      // 订阅是 SFU 回 offer → 端点作答 → renegotiate 交回去
      expect(control.countOf('renegotiate'), 1);
      expect(
        control.calls.lastWhere((c) => c.method == 'renegotiate').args,
        <String, dynamic>{
          'session_id': room.receiveSessionId,
          'sdp_answer': 'local-answer-2',
        },
      );
    });

    test('发布失败（明确被拒）→ 阶段是 failed，不会假装进房间成功', () async {
      control.failOnce['publish'] = FakeSfuControl.rejected();

      await expectLater(room.join(), throwsA(isA<SfuFailure>()));
      expect(room.view.value.phase, SfuRoomPhase.failed);
      expect(room.view.value.error, '并发提交被拒');
    });

    test('拉快照失败（服务端抖）→ 只记一笔，不把这一通判死', () async {
      // 真机上抓到的原话：`进房间失败：NetworkUnavailableException(请求超时)` ——
      // 而那时发布正在谈。读快照是**读**：读不到只是界面停在上一次的样子，
      // 推送与定期回查马上会补上；真正决定进不进得去的是发布。
      control.failOnce['roomState'] = FakeSfuControl.unknownOutcome();

      await room.join();

      expect(room.view.value.phase, SfuRoomPhase.joined);
      expect(
        room.view.value.micPublished,
        isTrue,
        reason: '发布落地后那次回读（这一次没失败）把注册表读回来了',
      );
      expect(
        room.trace.entries.any(
          (entry) => entry.failure && entry.text.contains('拉快照失败'),
        ),
        isTrue,
        reason: '失败要留在时间线上（诊断面板看得见），但不能吞掉整通电话',
      );
    });
  });

  group('发布：CF 回 offer / 逐条被拒（真机上长出来的那两坑）', () {
    test('CF 回的是 offer → 作答并交回，不是把这一步当没看见', () async {
      // 真机症状：进房间、能看见别人、按钮写「麦克风已开」，别人一个字都听不到
      control.publishOffer = 'offer-from-sfu';

      await room.join();

      expect(connections.publish.log, contains('answerSfuOffer'));
      // 订阅那条路也是"SFU 回 offer → 作答"，两条 renegotiate 的先后**不由这里约定**
      // （发布与接收是并行的：2026-09-27 起进房间不再等发布谈成），
      // 所以按会话 id 认那一条，而不是取第一条。
      final first = control.calls.firstWhere(
        (c) =>
            c.method == 'renegotiate' &&
            c.args['session_id'] == 'sess-publish-1',
      );
      expect(first.args['sdp_answer'], 'local-answer-1');
      expect(
        connections.publish.lastAnswer,
        isEmpty,
        reason: '回的是 offer 时本地没有 answer',
      );
      expect(room.view.value.phase, SfuRoomPhase.joined);
    });

    test('一条都没被上游接受 → 报错，不假装进房间成功', () async {
      control.failingPublications['mic'] = 'mid-does-not-exist';

      await expectLater(room.join(), throwsA(isA<SfuFailure>()));

      expect(room.view.value.phase, SfuRoomPhase.failed);
      expect(control.log, contains('publish'), reason: '请求发出去了，是被上游逐条拒的');
    });

    test('发布成功且注册表里有我的 mic → micPublished 为真', () async {
      await room.join();

      expect(room.view.value.micPublished, isTrue);
    });

    test('注册表里我那一行没有 mic → micPublished 为假（按钮不撒谎）', () async {
      // 服务端那条发布会话登记了，但 tracks 是空的
      control.snapshot = SfuRoomState(
        epoch: 2,
        members: <SfuRoomMember>[
          member('u2', 'sess-pub-u2', <String>['mic']),
          member('u1', 'sess-publish-1', <String>[]),
        ],
      );

      await room.join();

      expect(room.view.value.micPublished, isFalse);
    });
  });

  group('房间快照变化（epoch 收敛）', () {
    test('有人加入并发布：只补差集，已订好的不重订', () async {
      await room.join();
      expect(control.countOf('subscribe'), 1);

      control.snapshot = SfuRoomState(
        epoch: 2,
        members: <SfuRoomMember>[
          member('u1', 'sess-publish-1', <String>['mic']),
          member('u2', 'sess-pub-u2', <String>['mic']),
          member('u4', 'sess-pub-u4', <String>['mic']),
        ],
      );
      await room.refreshRoomState();

      expect(control.countOf('subscribe'), 2);
      final second = control.calls.lastWhere((c) => c.method == 'subscribe');
      expect(second.args['tracks'], <dynamic>[
        <String, dynamic>{'session_id': 'sess-pub-u4', 'track_name': 'mic'},
      ]);
      expect(room.subscriptionKeys, <String>{'u2|mic', 'u4|mic'});
    });

    test('有人离开：只关那一条，别的订阅不动', () async {
      await room.join();

      control.snapshot = SfuRoomState(
        epoch: 2,
        members: <SfuRoomMember>[
          member('u1', 'sess-publish-1', <String>['mic']),
          member('u4', 'sess-pub-u4', <String>['mic']),
        ],
      );
      await room.refreshRoomState();

      final close = control.calls.singleWhere((c) => c.method == 'closeTracks');
      expect(close.args['mids'], <dynamic>['mid-mic']);
      expect(close.args['force'], isFalse, reason: '先出 offer 再关（带协商）');
      expect(room.subscriptionKeys, <String>{'u4|mic'});
    });

    test('没有差集就不发请求（快照没变时是空转）', () async {
      await room.join();
      final before = control.countOf('subscribe');

      await room.refreshRoomState();

      expect(control.countOf('subscribe'), before);
      expect(control.countOf('closeTracks'), 0);
    });

    test('发布者换了会话 id（掉线重建）→ 订阅按新会话重订', () async {
      await room.join();

      control.snapshot = SfuRoomState(
        epoch: 3,
        members: <SfuRoomMember>[
          member('u1', 'sess-publish-1', <String>['mic']),
          member('u2', 'sess-pub-u2-new', <String>['mic']),
        ],
      );
      await room.refreshRoomState();

      expect(control.countOf('closeTracks'), 1, reason: '旧会话那条先关掉');
      final subscribe = control.calls.lastWhere((c) => c.method == 'subscribe');
      expect(subscribe.args['tracks'], <dynamic>[
        <String, dynamic>{'session_id': 'sess-pub-u2-new', 'track_name': 'mic'},
      ]);
    });

    test('逐条失败的订阅不记名（下次刷新会自动再试）', () async {
      control.failingSubscriptions['mic'] = 'track_error';

      await room.join();
      expect(room.subscriptionKeys, isEmpty, reason: '没订上就不该记成已订');

      // 服务端修好了 → 再来一次刷新就订上
      control.failingSubscriptions.clear();
      await room.refreshRoomState();
      expect(room.subscriptionKeys, <String>{'u2|mic'});
    });

    test('刷新是合并的：一瞬间来几条推送只跑一次', () async {
      await room.join();
      final before = control.countOf('roomState');

      final futures = <Future<void>>[
        room.refreshRoomState(),
        room.refreshRoomState(),
        room.refreshRoomState(),
      ];
      await Future.wait(futures);
      // 第一条在跑，后两条被合并成"跑完再来一次"
      expect(control.countOf('roomState'), before + 2);
    });
  });

  group('收到远端媒体（认回"谁的哪条 track"）', () {
    test('按接收侧 mid 认人：麦克风与共享屏都认得出', () async {
      control.snapshot = twoPublishers(withScreen: true);
      await room.join();

      final got = <SfuIncomingMedia>[];
      final subscription = room.incomingMedia.listen(got.add);

      connections.receive.emit('mid-mic');
      connections.receive.emit('mid-screen', kind: 'video');
      await pumpEventQueue();

      expect(got.map((media) => '${media.userId}/${media.trackName}'), <String>[
        'u2/mic',
        'u2/screen',
      ]);
      expect(got.first.kind, 'audio');
      expect(got.last.kind, 'video');
      await subscription.cancel();
    });

    test('不认识的 mid 丢掉，不往别人身上乱挂', () async {
      await room.join();

      final got = <SfuIncomingMedia>[];
      final subscription = room.incomingMedia.listen(got.add);

      // 重建之后旧会话上的 mid 就作废了：收到也不认
      connections.receive.emit('mid-from-a-dead-session');
      await pumpEventQueue();

      expect(got, isEmpty);
      await subscription.cancel();
    });

    test('发布会话上推来的 track 不认（订阅只发生在接收会话上）', () async {
      await room.join();

      final got = <SfuIncomingMedia>[];
      final subscription = room.incomingMedia.listen(got.add);

      connections.publish.emit('mid-mic');
      await pumpEventQueue();

      expect(got, isEmpty);
      await subscription.cancel();
    });
  });

  group('会话被判死 → 换新会话重建（不重试）', () {
    test('发布会话结果未知：换新会话 + 新连接，把该发布的重新发布', () async {
      await room.join();
      final oldSession = room.publishSessionId;

      control.failOnce['publish'] = FakeSfuControl.unknownOutcome();
      await room.startScreenShare();

      expect(room.publishSessionId, isNot(oldSession));
      expect(connections.created.length, 3, reason: '发布、接收、重建各一条新连接');
      final republish = control.calls.lastWhere((c) => c.method == 'publish');
      expect(republish.args['session_id'], room.publishSessionId);
      expect(republish.args['tracks'], <dynamic>[
        <String, dynamic>{'track_name': 'mic', 'mid': 'mid-mic-3'},
        <String, dynamic>{'track_name': 'screen', 'mid': 'mid-screen-3'},
      ], reason: '重建要把"该发布的 track"整体重发');
      expect(room.view.value.phase, SfuRoomPhase.joined);
    });

    test('接收会话结果未知：换新会话并把全屋子的订阅全部订回来', () async {
      await room.join();
      final oldReceive = room.receiveSessionId;

      control.failOnce['subscribe'] = FakeSfuControl.unknownOutcome();
      control.snapshot = SfuRoomState(
        epoch: 2,
        members: <SfuRoomMember>[
          member('u1', 'sess-publish-1', <String>['mic']),
          member('u2', 'sess-pub-u2', <String>['mic']),
          member('u4', 'sess-pub-u4', <String>['mic']),
        ],
      );
      await room.refreshRoomState();

      expect(room.receiveSessionId, isNot(oldReceive));
      expect(room.subscriptionKeys, <String>{
        'u2|mic',
        'u4|mic',
      }, reason: '重建清空了订阅表，重试要把该订的全订回来（不是只补差集）');
      final subscribe = control.calls.lastWhere((c) => c.method == 'subscribe');
      expect((subscribe.args['tracks'] as List<dynamic>).length, 2);
      expect(room.view.value.phase, SfuRoomPhase.joined, reason: '重建完要放回"已加入"');
      expect(control.countOf('createSession:receive'), 2, reason: '换了一条新接收会话');
    });

    test('发布后 ICE 一直没通 → 也按"结果未知"处理，换新发布会话重建', () async {
      // 第一条连接（发布会话那条）连不上（等超时）；重建出来的那条正常
      connections.connects.add(false);

      await room.join();

      expect(
        connections.publish.waitConnectedCalls,
        greaterThan(0),
        reason: '问过才知道没通',
      );
      expect(
        control.countOf('createSession:publish'),
        2,
        reason: '会话被判死：换一条新的，而不是在同一条上重试',
      );
      final first = control.calls.firstWhere((c) => c.method == 'publish');
      final last = control.calls.lastWhere((c) => c.method == 'publish');
      expect(last.args['session_id'], isNot(first.args['session_id']));
      expect(room.view.value.phase, SfuRoomPhase.joined);
    });

    test('重建那条也失败 → 停在 failed，不假装进房间成功', () async {
      connections.connects.add(false); // 第一条发布会话连不上 → 触发重建
      // 重建时那次重发被拒（"明确被拒"不会毒化会话，所以阶段停在 failed）
      control.failOnCall['publish'] = <int, SfuFailure>{
        2: FakeSfuControl.rejected(),
      };

      await room.join();

      expect(room.view.value.phase, SfuRoomPhase.failed);
      expect(room.view.value.error, '并发提交被拒');
    });

    test('同时触发两次毒化只重建一次（去重）', () async {
      await room.join();
      final oldSession = room.publishSessionId;

      control.failOnce['publish'] = FakeSfuControl.unknownOutcome();
      final first = room.startScreenShare();
      final second = room.startScreenShare();
      await Future.wait(<Future<void>>[first, second]);

      // 只允许建一条新发布会话（旧的那条被丢掉）
      expect(
        control.calls
            .where((call) => call.method == 'createSession:publish')
            .length,
        2,
        reason: '进房间一次 + 重建一次',
      );
      expect(room.publishSessionId, isNot(oldSession));
      expect(room.view.value.phase, SfuRoomPhase.joined);
    });
  });

  group('共享屏幕', () {
    test('开始共享：在发布会话上追加一路 video，并整体带上 track 名', () async {
      await room.join();
      await room.startScreenShare();

      expect(room.view.value.screenSharing, isTrue);
      final publish = control.calls.lastWhere((c) => c.method == 'publish');
      expect(publish.args['tracks'], <dynamic>[
        <String, dynamic>{'track_name': 'screen', 'mid': 'mid-screen-1'},
      ], reason: '只报**新增**的那条给 CF');
      expect(publish.args['session_id'], room.publishSessionId);
    });

    test('停止共享：先放掉采集，再关那条 track（带协商）', () async {
      await room.join();
      await room.startScreenShare();
      await room.stopScreenShare();

      expect(room.view.value.screenSharing, isFalse);
      expect(local.screenSharing, isFalse);
      final close = control.calls.singleWhere((c) => c.method == 'closeTracks');
      expect(close.args['mids'], <dynamic>['mid-screen-1']);
      expect(close.args['sdp_offer'], 'close-offer-1');
    });

    test('拿不到关闭用的 offer 时退回 force（不做 SDP 交换）', () async {
      await room.join();
      await room.startScreenShare();
      connections.publish.closeWithoutOffer.add('mid-screen-1');

      await room.stopScreenShare();

      final close = control.calls.lastWhere((c) => c.method == 'closeTracks');
      expect(close.args['force'], isTrue);
      expect(close.args['sdp_offer'], isNull);
    });

    test('设备不支持屏幕采集：不会把界面留在"正在共享"上', () async {
      final noScreen = FakeSfuLocalMedia(supportsScreen: false);
      final other = SfuRoom(
        roomId: 'g-100',
        myUserId: 'u1',
        control: control,
        local: noScreen,
        connectionFactory: connections.call,
      );
      await other.join();

      await expectLater(other.startScreenShare(), throwsA(isA<StateError>()));
      expect(other.view.value.screenSharing, isFalse);
      await other.dispose();
    });

    test('别人在共享屏：房间快照里看得出来', () async {
      control.snapshot = twoPublishers(withScreen: true);
      await room.join();

      final u2 = room.view.value.participants.firstWhere(
        (p) => p.userId == 'u2',
      );
      expect(u2.screen, isTrue);
      expect(u2.audio, isTrue);
      expect(room.subscriptionKeys, <String>{
        'u2|mic',
        'u2|screen',
      }, reason: '共享屏那一路也要订阅');
    });
  });

  group('离开房间', () {
    test('关两条会话 + 释放采集 + 回到 idle', () async {
      await room.join();
      await room.leave();

      final leave = control.calls.lastWhere((c) => c.method == 'leave');
      expect((leave.args['session_ids'] as List<dynamic>).length, 2);
      expect(connections.created.every((pc) => pc.closed), isTrue);
      expect(local.disposed, isTrue);
      expect(room.view.value.phase, SfuRoomPhase.idle);
    });

    test('关会话失败不影响退出（死会话关不掉是正常的）', () async {
      await room.join();
      control.failOnce['leave'] = FakeSfuControl.unknownOutcome();

      await room.leave();

      expect(room.view.value.phase, SfuRoomPhase.idle);
      expect(room.leaveResult, isNull, reason: '没拿到回包就没有「结束」的交代');
    });

    test('退出这一走是 closing（重建时丢坏会话那份不算）', () async {
      await room.join();
      await room.leave();

      expect(
        control.calls.lastWhere((c) => c.method == 'leave').args['closing'],
        isTrue,
      );
    });

    test('服务端说「房间空了、由我收尾」：回包存下来给控制器', () async {
      control.leaveResult = const SfuLeaveResult(
        closed: true,
        announce: true,
        durationSeconds: 45,
        participants: 3,
      );
      await room.join();

      await room.leave();

      expect(room.leaveResult?.announce, isTrue);
      expect(room.leaveResult?.durationSeconds, 45);
      expect(room.leaveResult?.participants, 3);
      expect(
        room.trace.entries.any((e) => e.text.contains('记录由我落')),
        isTrue,
        reason: '诊断面板里要能看出这一通是谁收的尾',
      );
    });

    test('dispose 兜底那次再走一遍 leave：不能把已经拿到的「结束」冲掉', () async {
      control.leaveResult = const SfuLeaveResult(
        closed: true,
        announce: true,
        durationSeconds: 45,
        participants: 2,
      );
      await room.join();
      await room.leave();

      // 第二次（dispose 兜底）服务端已经没底账了，回的是一份“什么都没发生”
      control.leaveResult = const SfuLeaveResult();
      await room.dispose();

      expect(room.leaveResult?.announce, isTrue);
      expect(room.leaveResult?.durationSeconds, 45);
    });
  });

  group('心跳（注册表靠它续命）', () {
    /// 一个带短心跳间隔的房间（默认 25 秒在测试里等不到）
    SfuRoom beatRoom() => SfuRoom(
      roomId: 'g-100',
      myUserId: 'u1',
      control: control,
      local: local,
      connectionFactory: connections.call,
      heartbeatInterval: const Duration(milliseconds: 20),
    );

    test('按间隔发心跳，带上房间号', () async {
      final beat = beatRoom();
      await beat.join();
      control.snapshot = twoPublishers(epoch: 2);
      control.heartbeatEpoch = 2;

      await Future<void>.delayed(const Duration(milliseconds: 70));

      expect(control.countOf('heartbeat'), greaterThan(0));
      expect(
        control.calls
            .firstWhere((c) => c.method == 'heartbeat')
            .args['room_id'],
        'g-100',
      );
      await beat.dispose();
    });

    test('版本号对不上就重新对账（相当于那条 WS 推送丢了也能自愈）', () async {
      final beat = beatRoom();
      await beat.join();
      final before = control.countOf('roomState');

      // 服务端那边房间变过（epoch=9），而客户端手里还是 1
      control.snapshot = twoPublishers(epoch: 9);
      control.heartbeatEpoch = 9;
      await Future<void>.delayed(const Duration(milliseconds: 70));

      expect(control.countOf('roomState'), greaterThan(before));
      expect(beat.view.value.epoch, 9, reason: '对完账手里就是新版本了');
      await beat.dispose();
    });

    test('服务端慢：一拍没回就不再叠下一拍', () async {
      // 20 秒一拍是给注册表续命的，不是给自己加压的：服务端回不过来时
      // 叠着发只会让它更慢。
      control.heartbeatDelay = const Duration(milliseconds: 50);
      final beat = beatRoom();
      await beat.join();

      final before = control.countOf('heartbeat');
      await Future<void>.delayed(const Duration(milliseconds: 130));
      final beats = control.countOf('heartbeat') - before;

      expect(
        beats,
        lessThanOrEqualTo(3),
        reason: '130ms / 50ms 一拍：不叠飞就该是两三拍，不是六拍',
      );
      await beat.dispose();
    });

    test('心跳失败不改变任何状态（下一次操作会自己发现并重建）', () async {
      final beat = beatRoom();
      await beat.join();
      control.failOnce['heartbeat'] = FakeSfuControl.unknownOutcome();

      await Future<void>.delayed(const Duration(milliseconds: 70));

      expect(beat.view.value.phase, SfuRoomPhase.joined);
      expect(beat.receiveSessionId, isNotNull, reason: '不会因为心跳失败去重建会话');
      await beat.dispose();
    });

    test('离开房间之后不再发心跳', () async {
      final beat = beatRoom();
      await beat.join();
      await beat.leave();
      final after = control.countOf('heartbeat');

      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(control.countOf('heartbeat'), after);
      await beat.dispose();
    });
  });

  group('静音状态同步（只报一个显示态，发布关系不动）', () {
    test('静音 / 开麦都报到服务端，参数对得上', () async {
      await room.join();

      await room.setMicrophoneEnabled(false);
      expect(control.countOf('setMuted'), 1);
      expect(control.calls.last.args['room_id'], 'g-100');
      expect(control.calls.last.args['muted'], isTrue);

      await room.setMicrophoneEnabled(true);
      expect(control.countOf('setMuted'), 2);
      expect(control.calls.last.args['muted'], isFalse);
    });

    test('静音**不动发布关系**：不重发布、不关 track、不退订别人', () async {
      await room.join();
      final publishes = control.countOf('publish');
      final closes = control.countOf('closeTracks');

      await room.setMicrophoneEnabled(false);

      // 这三条是这一版的**核心取舍**：摘掉 `mic` 虽然能让注册表自己变对，但对方会
      // 退订 —— 取消静音时重发布一旦失败，对方就再也听不到我（「说话没声」）。
      expect(control.countOf('publish'), publishes, reason: '静音不该重新发布');
      expect(control.countOf('closeTracks'), closes, reason: '静音不该关任何 track');
      expect(
        room.subscriptionKeys,
        contains('u2|mic'),
        reason: '别人听不听得到我，跟我的静音标记是两件事',
      );
    });

    test('上报失败不影响本机静音（也不往外抛）', () async {
      await room.join();
      control.failOnce['setMuted'] = FakeSfuControl.unknownOutcome();

      await room.setMicrophoneEnabled(false);

      expect(local.micEnabled, isFalse, reason: '按了静音就必须真的静了');
    });

    test('上报失败后，下一拍心跳补报一次', () async {
      final beat = SfuRoom(
        roomId: 'g-100',
        myUserId: 'u1',
        control: control,
        local: local,
        connectionFactory: connections.call,
        heartbeatInterval: const Duration(milliseconds: 20),
      );
      await beat.join();
      control.failOnce['setMuted'] = FakeSfuControl.unknownOutcome();
      await beat.setMicrophoneEnabled(false);
      expect(control.countOf('setMuted'), 1, reason: '第一次报了但没成');

      await Future<void>.delayed(const Duration(milliseconds: 70));

      expect(control.countOf('setMuted'), greaterThan(1), reason: '心跳把它补上');
      expect(
        control.calls
            .lastWhere((call) => call.method == 'setMuted')
            .args['muted'],
        isTrue,
      );
      await beat.dispose();
    });
  });

  group('别人静音了，我这边看得到（2026-10-07 真机那个 bug）', () {
    test('注册表说他 muted → 那一条算作没有声音（哪怕 tracks 里 mic 还在）', () async {
      await room.join();

      control.snapshot = SfuRoomState(
        epoch: 2,
        members: <SfuRoomMember>[
          member('u1', 'sess-publish-1', <String>['mic']),
          member('u2', 'sess-pub-u2', <String>['mic'], muted: true),
          member('u3', '', <String>[]),
        ],
      );
      await room.refreshRoomState();

      final u2 = room.view.value.participants.firstWhere(
        (participant) => participant.userId == 'u2',
      );
      expect(u2.audio, isFalse, reason: '他按了静音，界面不能写「麦克风已开」');
      expect(
        room.subscriptionKeys,
        contains('u2|mic'),
        reason: '静音**不是**退订：他的发布还在，取消静音要立即恢复',
      );
    });

    test('他取消静音 → 又算作有声音，而且没有引起重订', () async {
      await room.join();

      SfuRoomState withU2({required bool muted, required int epoch}) =>
          SfuRoomState(
            epoch: epoch,
            members: <SfuRoomMember>[
              member('u1', 'sess-publish-1', <String>['mic']),
              member('u2', 'sess-pub-u2', <String>['mic'], muted: muted),
              member('u3', '', <String>[]),
            ],
          );

      control.snapshot = withU2(muted: true, epoch: 2);
      await room.refreshRoomState();
      final subscribes = control.countOf('subscribe');

      control.snapshot = withU2(muted: false, epoch: 3);
      await room.refreshRoomState();

      final u2 = room.view.value.participants.firstWhere(
        (participant) => participant.userId == 'u2',
      );
      expect(u2.audio, isTrue);
      expect(control.countOf('subscribe'), subscribes, reason: '开关静音不该引起任何重订');
    });

    test('服务端没返回 muted（老服务端）→ 行为与从前完全一样', () async {
      await room.join();

      final u2 = room.view.value.participants.firstWhere(
        (participant) => participant.userId == 'u2',
      );
      expect(u2.audio, isTrue, reason: '没有 muted 字段时只看 tracks，不误报');
    });
  });

  group('共享屏的声音（S12.39：默认不发，要的人自己开）', () {
    /// 最近一次 publish 请求里发了哪几路
    List<String> publishedNames() {
      final tracks =
          control.calls
                  .lastWhere((call) => call.method == 'publish')
                  .args['tracks']
              as List<dynamic>;
      return <String>[
        for (final track in tracks)
          (track as Map<dynamic, dynamic>)['track_name'] as String,
      ];
    }

    test('没开「连电脑的声音」：只发布 screen 一路', () async {
      await room.join();

      await room.startScreenShare(sourceId: 'screen:0:0');

      expect(local.screenWithAudio, isFalse, reason: '开关没开，底层就不该去抓声音');
      expect(publishedNames(), <String>['screen']);
    });

    test('开了：画面 + 声音两路一起发（SFU 每条轨都要有自己的名字）', () async {
      await room.join();

      await room.startScreenShare(sourceId: 'screen:0:0', withAudio: true);

      expect(local.screenWithAudio, isTrue, reason: '开关要一路传到采集层');
      expect(publishedNames(), <String>['screen', 'screen-audio']);
    });

    test('勾了但选中的源没有声音 → 不凭空造一条空轨', () async {
      // 比如选了一个静音的窗口：`withAudio: true` 传下去了，但拿不到音频轨。
      // 这时如果仍然发一条 `screen-audio`，别人就会订阅到一条**永远没数据**的流，
      // 界面上看着像"他共享着声音"，其实一点声都没有。
      local.screenCaptureDropsAudio = true;
      await room.join();

      await room.startScreenShare(sourceId: 'screen:0:0', withAudio: true);

      expect(publishedNames(), <String>['screen']);
    });

    test('停止共享：两路一起关', () async {
      await room.join();
      await room.startScreenShare(sourceId: 'screen:0:0', withAudio: true);

      await room.stopScreenShare();

      final close = control.calls.lastWhere(
        (call) => call.method == 'closeTracks',
      );
      expect(
        (close.args['mids'] as List<dynamic>).length,
        2,
        reason: '少关一路就会在注册表里留一条没人管的轨（别人一直订阅着一路死流）',
      );
    });
  });

  group('共享的窗口最小化又回来（本机重建采集 → 新轨挂回同一个 mid）', () {
    // 真机现象（2026-10-08 用户报的）：**共享某个窗口 → 最小化 → 再点开**，
    // 对方画面永远停在最小化前最后一秒（声音一直正常）。采集器本体改不了
    // （插件预编译 libwebrtc，没开 WGC），修法是窗口回来时**重建一次采集**，
    // 再把这批新轨挂回**原来的 mid** 上 —— 不重新发布、不重新协商、服务端一行不改。
    test('按名字换轨：不重新发布、不重新协商', () async {
      await room.join();
      await room.startScreenShare(sourceId: '459138', withAudio: true);
      expect(
        local.screenTrackListeners,
        isNotEmpty,
        reason: '共享期间房间得能被本机叫一声（采集重建了）',
      );
      final publishes = control.countOf('publish');
      final renegotiates = room.trace.renegotiates;

      local.simulateScreenTrackReplaced();
      await pumpEventQueue();

      expect(connections.publish.replacedTracks, <String>[
        'screen',
        'screen-audio',
      ]);
      expect(control.countOf('publish'), publishes, reason: '换轨不是重新发布');
      expect(
        room.trace.renegotiates,
        renegotiates,
        reason: '挂了别的东西重新出 offer 会让对方黑一下（这里连一条 SDP 都不该动）',
      );
      expect(
        room.trace.entries.any((entry) => entry.text.contains('screen 已换到新轨')),
        isTrue,
      );
    });

    test('重建后取不到电脑声音：发布过的那一路要关掉', () async {
      // 重建那一次是按原来的口径再取一次（窗口 + 电脑声音），但系统/设备可能
      // 这次给不出来 —— 这时必须把已经发布出去的 `screen-audio` 关掉，"只换画面、
      // 不管声音"会让别人永远订阅着一路没数据的流。
      await room.join();
      await room.startScreenShare(sourceId: '459138', withAudio: true);
      local.screenCaptureDropsAudio = true;

      local.simulateScreenTrackReplaced();
      await pumpEventQueue();

      final close = control.calls.lastWhere(
        (call) => call.method == 'closeTracks',
      );
      expect(close.args['mids'], <dynamic>['mid-screen-audio-1']);
      expect(connections.publish.replacedTracks, <String>['screen']);
    });

    test('重建失败（本机采集没了）：界面回到未共享 + 关掉那几路发布', () async {
      // 重建那一次本机是**先把旧采集放掉、再取新的**（硬顺序，见
      // desktop_screen_capture.dart）：取不回来的话本机就没有屏幕采集了。
      // 这时如果不收尾，别人会一直订阅着两路永远没数据的轨，而用户那颗
      // 「停止共享」按下去也没反应（`local.screenSharing` 已经是 false）。
      await room.join();
      await room.startScreenShare(sourceId: '459138', withAudio: true);
      local.screenSharing = false; // 采集已经没了

      local.simulateScreenTrackReplaced();
      await pumpEventQueue();

      expect(room.view.value.screenSharing, isFalse);
      final close = control.calls.lastWhere(
        (call) => call.method == 'closeTracks',
      );
      expect((close.args['mids'] as List<dynamic>).length, 2);
      expect(local.screenTrackListeners, isEmpty);
      expect(connections.publish.replacedTracks, isEmpty);
    });

    test('停共享之后本机再叫一声：什么都不做（监听已经摘掉）', () async {
      await room.join();
      await room.startScreenShare(sourceId: '459138');
      await room.stopScreenShare();
      expect(local.screenTrackListeners, isEmpty);

      local.simulateScreenTrackReplaced();
      await pumpEventQueue();

      expect(connections.publish.replacedTracks, isEmpty);
    });
  });

  group('别人那一路共享断了（本机健康检查，不等注册表）', () {
    // 真机现象（2026-10-08 用户报的）：**电脑在共享屏幕、然后直接挂断群通话**，
    // 手机端就永远停在最后一帧 —— 注册表要等心跳/行超时（封顶 45 秒）才清，
    // 推送也可能丢。所以接收侧自己盯着「那一路还在不在收」。
    late DateTime clock;

    /// 造一个只驱动健康检查的房间（定时器关掉，用例自己调 `pollScreenHealth()`）
    SfuRoom watchRoom({Duration timeout = const Duration(seconds: 5)}) {
      final watched = SfuRoom(
        roomId: 'g-100',
        myUserId: 'u1',
        control: control,
        local: local,
        connectionFactory: connections.call,
        heartbeatInterval: null,
        stateRefreshInterval: null,
        audioLevelPollInterval: null,
        screenHealthInterval: null,
        screenStallTimeout: timeout,
        now: () => clock,
      );
      addTearDown(watched.dispose);
      return watched;
    }

    test('那一路不再出帧 → droppedMedia（把画面放下来）', () async {
      clock = DateTime(2026, 10, 8, 21);
      final watched = watchRoom();
      final dropped = <SfuIncomingMedia>[];
      final subscription = watched.droppedMedia.listen(dropped.add);
      addTearDown(subscription.cancel);

      control.snapshot = twoPublishers(withScreen: true);
      await watched.join();
      // 对方那一路画面到了（界面手里有图）
      connections.receive.videoCountersByMid = <String, int>{'mid-screen': 100};
      connections.receive.emit('mid-screen', kind: 'video');
      await pumpEventQueue();

      await watched.pollScreenHealth();
      expect(dropped, isEmpty, reason: '第一次见到就记下来，不能当场判死');

      // 计数一动不动过了宽限：本机就该自己判出来
      clock = clock.add(const Duration(seconds: 6));
      await watched.pollScreenHealth();
      await pumpEventQueue();

      expect(dropped.length, 1);
      expect(dropped.single.userId, 'u2');
      expect(dropped.single.trackName, 'screen');
      expect(dropped.single.kind, 'video');
      expect(
        watched.trace.entries.any((entry) => entry.text.contains('共享屏卡死')),
        isTrue,
        reason: '诊断面板上要能看出「这一路是自己判死的」',
      );
    });

    test('画面一直在动：不判死', () async {
      clock = DateTime(2026, 10, 8, 21);
      final watched = watchRoom();
      final dropped = <SfuIncomingMedia>[];
      final subscription = watched.droppedMedia.listen(dropped.add);
      addTearDown(subscription.cancel);

      control.snapshot = twoPublishers(withScreen: true);
      await watched.join();
      connections.receive.emit('mid-screen', kind: 'video');
      await pumpEventQueue();

      for (var frames = 100; frames < 400; frames += 100) {
        clock = clock.add(const Duration(seconds: 6));
        connections.receive.videoCountersByMid = <String, int>{
          'mid-screen': frames,
        };
        await watched.pollScreenHealth();
      }
      await pumpEventQueue();
      expect(dropped, isEmpty);
    });

    test('误判之后又出帧：把画面接回来（订阅一直没动）', () async {
      clock = DateTime(2026, 10, 8, 21);
      final watched = watchRoom();
      final got = <SfuIncomingMedia>[];
      final subscription = watched.incomingMedia.listen(got.add);
      addTearDown(subscription.cancel);

      control.snapshot = twoPublishers(withScreen: true);
      await watched.join();
      connections.receive.emit('mid-screen', kind: 'video');
      await pumpEventQueue();
      expect(got.length, 1);

      // 先判死一次（计数一动不动）
      connections.receive.videoCountersByMid = <String, int>{'mid-screen': 100};
      await watched.pollScreenHealth();
      clock = clock.add(const Duration(seconds: 6));
      await watched.pollScreenHealth();

      // 那一路其实还活着（静态画面被误判）：又涨了
      connections.receive.videoCountersByMid = <String, int>{'mid-screen': 260};
      await watched.pollScreenHealth();
      await pumpEventQueue();

      expect(got.length, 2, reason: '同一份流再交一次，界面就重新挂回去');
      expect(identical(got.first.stream, got.last.stream), isTrue);
      expect(control.countOf('subscribe'), 1, reason: '接回来不该重新订阅');
    });

    test('没人在共享：一条统计都不问（省掉没必要的 getStats）', () async {
      clock = DateTime(2026, 10, 8, 21);
      final watched = watchRoom();

      await watched.join(); // 快照里没人共享
      await watched.pollScreenHealth();
      expect(connections.receive.videoCounterCalls, 0);

      // 有人开始共享了：才该盯上
      control.snapshot = twoPublishers(withScreen: true);
      await watched.refreshRoomState();
      await watched.pollScreenHealth();
      expect(connections.receive.videoCounterCalls, greaterThan(0));
    });
  });

  group('诊断（面板读这份快照）', () {
    test('进房间这一串都记上了：发布 / 快照 / 订阅，计数对得上', () async {
      await room.join();

      final trace = room.trace;
      expect(trace.publishes, 1);
      expect(trace.subscribes, 1);
      expect(trace.renegotiates, 1);
      expect(trace.rebuilds, 0);
      expect(trace.failures, 0);
      expect(trace.entries.first.text, contains('进房间'));
      expect(
        trace.entries.any((entry) => entry.text.contains('快照：3 人')),
        isTrue,
      );
      expect(
        trace.entries.any(
          (entry) => entry.text.contains('订阅 u2/mic → mid-mic'),
        ),
        isTrue,
      );
    });

    test('发布失败→重建：失败计数 + 重建计数都涨，且写成失败条目', () async {
      control.failOnce['publish'] = FakeSfuControl.unknownOutcome();

      await room.join();

      expect(room.trace.rebuilds, 1);
      expect(room.trace.failures, greaterThanOrEqualTo(1));
      expect(
        room.trace.entries.any(
          (entry) => entry.failure && entry.text.contains('重建发布会话'),
        ),
        isTrue,
      );
      expect(room.view.value.phase, SfuRoomPhase.joined, reason: '重建之后应该能用');
    });

    test('快照里的订阅与已发布的 track 都能在面板里看到', () async {
      control.snapshot = twoPublishers(withScreen: true);
      await room.join();

      final diagnostics = room.diagnostics;
      expect(diagnostics.roomId, 'g-100');
      expect(diagnostics.subscriptions, hasLength(2));
      expect(diagnostics.publishedTracks, <String>['mic → mid-mic-1']);
      // 复制/导出的那段文本要能看出“订阅建上了没有”
      expect(diagnostics.summary, contains('房间：g-100'));
      expect(diagnostics.summary, contains('订阅：'));
      expect(diagnostics.summary, contains('时间线：'));
    });
  });

  group('谁在说话（能量按 mid 归位到人）', () {
    /// 不自动采样：测试自己调 `pollAudioLevels()`，避免跟真实时钟赛跑
    SfuRoom manualRoom() => SfuRoom(
      roomId: 'g-100',
      myUserId: 'u1',
      control: control,
      local: local,
      connectionFactory: connections.call,
      audioLevelPollInterval: null,
    );

    test('能量落在 u2 的接收 mid 上 → 说话人就是他', () async {
      final manual = manualRoom();
      await manual.join();

      // 接收侧给 u2 的 mic 分配的 mid 就是订阅时服务端回的那个
      connections.receive.audioLevelsByMid = <String, double>{'mid-mic': 0.42};
      await manual.pollAudioLevels();

      expect(manual.view.value.activeSpeaker, 'u2');
      await manual.dispose();
    });

    test('归不了位的 mid 丢掉（不认识的流不能变成一个人名）', () async {
      final manual = manualRoom();
      await manual.join();

      connections.receive.audioLevelsByMid = <String, double>{
        'mid-unknown': 0.9,
        '': 0.8,
      };
      await manual.pollAudioLevels();

      expect(manual.view.value.activeSpeaker, isNull);
      await manual.dispose();
    });

    test('离开房间后说话人清空、也不再采样', () async {
      final manual = manualRoom();
      await manual.join();
      connections.receive.audioLevelsByMid = <String, double>{'mid-mic': 0.5};
      await manual.pollAudioLevels();
      expect(manual.view.value.activeSpeaker, 'u2');

      await manual.leave();
      // 离开后即使还有能量表，也不该再往界面上写
      connections.receive.audioLevelsByMid = <String, double>{'mid-mic': 0.5};
      await manual.pollAudioLevels();

      expect(manual.view.value.activeSpeaker, isNull);
      await manual.dispose();
    });
  });

  group('补订阅的快速重试（2026-10-08 真机：服务端调 CF 超时之后两分钟什么都没有）', () {
    /// 把苝底回查**关掉**：能补上就只可能是那条快速重试。
    SfuRoom retryRoom() => SfuRoom(
      roomId: 'g-100',
      myUserId: 'u1',
      control: control,
      local: local,
      connectionFactory: connections.call,
      heartbeatInterval: null,
      audioLevelPollInterval: null,
      stateRefreshInterval: null,
      reconcileRetryInterval: const Duration(milliseconds: 20),
      reconcileRetryMaxInterval: const Duration(milliseconds: 20),
    );

    test('订阅被拒：不等回查，20 毫秒后自己再来一次', () async {
      final retrying = retryRoom();
      addTearDown(retrying.dispose);
      await retrying.join();
      expect(retrying.subscriptionKeys, <String>{'u2|mic'});

      // 对方开始共享（注册表变了；推送这条这里不喂，靠我们自己那趟对账发现），
      // 而这一趟订阅被服务端明确拒了（被拒 = 什么都没发生，不是结果未知）
      control.snapshot = twoPublishers(withScreen: true);
      control.failOnce['subscribe'] = const SfuFailure(
        kind: SfuFailureKind.rejected,
        message: '先拒一次',
        code: 4001,
      );
      await expectLater(
        retrying.refreshRoomState(),
        throwsA(isA<SfuFailure>()),
      );
      expect(
        retrying.subscriptionKeys,
        isNot(contains('u2|screen')),
        reason: '这一趟没订上',
      );

      // 回查是关着的：下面这一条能补上，就只能是快速重试干的
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(retrying.subscriptionKeys, contains('u2|screen'));
    });

    test('只订上一部分（逐条失败）也算没齐：退避里接着补，上游一好就订上', () async {
      final retrying = retryRoom();
      addTearDown(retrying.dispose);
      await retrying.join();

      control.snapshot = twoPublishers(withScreen: true);
      // HTTP 200，但那一条 track 带着错误回来（逐条失败）
      control.failingSubscriptions['screen'] = 'track_error';
      await retrying.refreshRoomState();
      expect(retrying.subscriptionKeys, isNot(contains('u2|screen')));

      final attempts = control.countOf('subscribe');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(
        control.countOf('subscribe'),
        greaterThan(attempts),
        reason: '差集还在就一直在快速重试',
      );

      control.failingSubscriptions.clear();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(
        retrying.subscriptionKeys,
        contains('u2|screen'),
        reason: '上游一好，下一拍就自己订上了',
      );
    });
  });
}
