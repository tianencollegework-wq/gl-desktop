import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/notify/message_notification_presenter.dart';
import 'package:gracelinkim/core/notify/push_background.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/domain/call/call_signal.dart';
import 'package:gracelinkim/domain/chat/message_notification.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假的通知实现：只记弹过什么
class _FakePresenter implements MessageNotificationPresenter {
  _FakePresenter({this.fail = false});

  final bool fail;
  final List<MessageNotification> shown = <MessageNotification>[];

  /// 弹过的**来电**通知（S8.1h）。来电与消息刻意分开记，因为它们是两条展示路径，
  /// 「有没有走错通道」正是要钉住的事。
  final List<IncomingCallNotification> calls = <IncomingCallNotification>[];

  @override
  Future<String?> initialize({required ValueChanged<String> onOpen}) async =>
      null;

  @override
  Future<bool> enabled() async => true;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> show(MessageNotification notification) async {
    if (fail) throw StateError('通知渠道被系统禁了');
    shown.add(notification);
  }

  @override
  Future<void> cancel(String conversationId) async {}

  @override
  Future<void> cancelAll() async {}

  // 来电那几条：后台 isolate 里只会用到 showIncomingCall
  @override
  Future<void> showIncomingCall(IncomingCallNotification call) async {
    if (fail) throw StateError('通知渠道被系统禁了');
    calls.add(call);
  }

  /// 收掉来电通知的次数（S8.1n：「对方取消」那条收尾帧就是干这个的）
  int cancelledCalls = 0;

  @override
  Future<void> cancelIncomingCall() async {
    cancelledCalls++;
  }

  @override
  void onIncomingCallOpen(ValueChanged<String> handler) {}

  @override
  Future<String?> takeLaunchIncomingCall() async => null;

  // ------------------------------------------------- 群通话邀请（S6.14）

  /// 弹过的**群通话邀请**：与 1:1 来电、消息通知三路分开记 ——
  /// 「有没有走错通道」正是这一块要钉住的事（群邀请占了来电那个通知位
  /// 就会把一通正在响的电话顶掉）。
  final List<IncomingCallNotification> groupRings =
      <IncomingCallNotification>[];

  /// 收掉群通话邀请的次数（房间空了那条静默推送就是干这个的）
  int cancelledGroupRings = 0;

  @override
  Future<void> showGroupCallRing(IncomingCallNotification invite) async {
    if (fail) throw StateError('通知渠道被系统禁了');
    groupRings.add(invite);
  }

  @override
  Future<void> cancelGroupCallRing() async {
    cancelledGroupRings++;
  }

  @override
  void onGroupCallOpen(ValueChanged<String> handler) {}

  @override
  Future<String?> takeLaunchGroupCall() async => null;
}

/// 后台 isolate 里的推送处理（S8.1）：App 没在跑时，是这段代码把推送画成通知。
/// 它跑在真机上不容易复现（要杀进程、要真推一条），所以规则必须在这里钉住。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePresenter presenter;

  setUp(() async {
    // 后台 isolate 里那份「准备工作」在本机也会真跑一遍（语言包、本地存储）：
    // 这里把前置条件备好，顺便盖住这条路径
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    await AppI18n.load('zh-Hans');
    // 「最后响过的那通」是进程级状态：不清的话上一条用例留下的 id 会带到下一条
    PushNotificationHandler.debugResetRingingCall();
  });

  PushNotificationHandler build({bool fail = false, String myUserId = 'u1'}) {
    presenter = _FakePresenter(fail: fail);
    return PushNotificationHandler(
      presenter: presenter,
      readMyUserId: () => myUserId,
      translate: (key, fallback) => fallback.isEmpty ? key : fallback,
    );
  }

  Map<String, dynamic> data({
    String payload = '',
    String title = '张三',
    String content = '在吗',
    String contactId = 'u2',
  }) => <String, dynamic>{
    'title': title,
    'content': content,
    'type': 'simple',
    'contact_id': contactId,
    'msg_id': 'm1',
    'payload': payload,
  };

  test('弹出一条通知：会话、标题、正文都对', () async {
    await build().handle(data());

    expect(presenter.shown, hasLength(1));
    expect(presenter.shown.single.conversationId, 'u2');
    expect(presenter.shown.single.title, '张三');
    expect(presenter.shown.single.body, '在吗');
  });

  test('FCM 的值全是字符串：数字/null 也能处理，不会因为类型崩掉', () async {
    // FCM 的数据消息里所有值都是字符串，但真机上偶尔会漏字段进来
    await build().handle(<String, dynamic>{
      'title': '张三',
      'content': '在吗',
      'contact_id': 'u2',
      'msg_id': null,
    });

    expect(presenter.shown, hasLength(1));
  });

  test('带整条消息的推送：用与 WS 同一套规则组装（群消息带发送者）', () async {
    await build().handle(
      data(
        payload: json.encode(<String, dynamic>{
          'id': 5,
          'type': 'text',
          'content': '在吗',
          'fromUser': <String, dynamic>{'id': 'u2', 'displayName': '王五'},
          'toContactId': 'u2',
          'toUser': 'u1',
          'is_group': 1,
          'contactInfo': <String, dynamic>{'id': 'u2', 'displayName': '项目群'},
        }),
      ),
    );

    expect(presenter.shown.single.title, '项目群');
    expect(presenter.shown.single.body, '王五: 在吗');
  });

  test('路由不出去的推送（没有会话）：不弹', () async {
    await build().handle(data(payload: '', contactId: ''));

    expect(presenter.shown, isEmpty);
  });

  test('弹通知失败也不能炸出去（后台 isolate 崩了就什么都没有了）', () async {
    await build(fail: true).handle(data());

    expect(presenter.shown, isEmpty);
  });

  group('离线来电（S8.1h）', () {
    /// 服务端推来的一通**来电**（`pushOffline()` 里 `webrtc + calling` 那条）
    Map<String, dynamic> callPush({
      int callType = CallType.voice,
      int sendTime = 0,
      String? payload,
    }) => <String, dynamic>{
      'type': 'webrtc',
      'event': 'calling',
      'title': '张三',
      'content': '[正在请求与您语音通话]',
      'contact_id': 'u2',
      'msg_id': 'srv-1',
      'payload':
          payload ??
          json.encode(<String, dynamic>{
            'id': 'call-1',
            'msg_id': 'srv-1',
            'fromUser': <String, dynamic>{'id': 'u2', 'realname': '张三'},
            'toContactId': 'u1',
            'type': 'webrtc',
            'sendTime': sendTime,
            'extends': <String, dynamic>{
              'event': 'calling',
              'type': callType,
              'code': 901,
            },
          }),
    };

    test('来电走来电那条通知（独立渠道 / 全屏 / 响铃），不是消息通知', () async {
      await build().handle(callPush());

      expect(presenter.calls, hasLength(1));
      expect(presenter.shown, isEmpty);
      expect(presenter.calls.single.title, '张三');
      expect(presenter.calls.single.body, '[common.voiceCalling]');
    });

    test('整条来电报文原样留在通知里 —— 冷启动要靠它重建会话', () async {
      await build().handle(callPush());

      final payload = presenter.calls.single.payload;
      expect(payload, contains('call-1'));
      expect(payload, contains('calling'));
      // 点通知 / 冷启动时，主 isolate 会用这份 payload 当 `calling` 报文
      expect(json.decode(payload), isA<Map<String, dynamic>>());
    });

    test('超龄的来电不弹也不响（主叫 60 秒就挂了）', () async {
      final old = DateTime.now().subtract(const Duration(minutes: 2));
      await build().handle(callPush(sendTime: old.millisecondsSinceEpoch));

      expect(presenter.calls, isEmpty);
      expect(presenter.shown, isEmpty);
    });

    test('自己发出去的来电磁音（服务端已排过，这是双保险）', () async {
      // 这条推送的 fromUser 就是本机用户
      await build(myUserId: 'u2').handle(callPush());

      expect(presenter.calls, isEmpty);
    });

    test('弹来电通知失败也不能炸（后台 isolate 崩了就连消息也收不到了）', () async {
      await build(fail: true).handle(callPush());

      expect(presenter.calls, isEmpty);
    });

    group('主叫取消了这通电话（S8.1n）', () {
      /// 服务端在**主叫取消/超时**（code 902）时补的那条静默推送。
      /// 它唯一的任务是让被叫把那条来电通知收掉 —— 被叫正是长连接不在线的那一端，
      /// 那句 `hangup` 他一个字都收不到（真机 2026-09-20：「通知却还一直显示」）。
      Map<String, dynamic> cancelPush({String callId = 'call-1'}) =>
          <String, dynamic>{
            'type': 'webrtc',
            'event': 'callCanceled',
            'contact_id': 'u2',
            'call_id': callId,
            'msg_id': 'srv-1',
            'payload': '',
          };

      test('收到就收掉通知，而且**一条通知都不弹**', () async {
        final handler = build();
        await handler.handle(callPush());
        expect(presenter.calls, hasLength(1));

        await handler.handle(cancelPush());

        expect(presenter.cancelledCalls, 1);
        // 它不能被当成消息通知，也不能再弹一次来电
        expect(presenter.shown, isEmpty);
        expect(presenter.calls, hasLength(1));
      });

      test('新的一通已经响起来了：上一通的收尾帧不许把正在响的收了', () async {
        final handler = build();
        await handler.handle(callPush());

        await handler.handle(cancelPush(callId: 'call-999'));

        expect(presenter.cancelledCalls, 0);
      });

      test('App 刚被杀、这是第一次唤醒（手上没有正在响的）：照样收一次，反正无害', () async {
        await build().handle(cancelPush());

        expect(presenter.cancelledCalls, 1);
      });

      test('收尾帧不是来电：别被它误导着弹一条来电通知', () async {
        await build().handle(cancelPush());

        expect(presenter.calls, isEmpty);
      });
    });
  });

  group('群通话邀请（S6.14）', () {
    /// 服务端 `Sfu.php::pushGroupCall` 推出去的那条：群里有人开语音。
    Map<String, dynamic> groupRing({
      String callId = 'gc-1',
      int sendTime = 0,
      String groupName = '产品群',
      String starter = '小明',
      String payload = '',
    }) {
      final frame = json.encode(<String, dynamic>{
        'id': callId,
        'type': 'group_call',
        'toContactId': 'group-100',
        'fromUser': <String, dynamic>{'id': 'u2', 'displayName': starter},
        'sendTime': sendTime > 0
            ? sendTime
            : DateTime.now().millisecondsSinceEpoch,
        'extends': <String, dynamic>{
          'event': 'groupCalling',
          'call_id': callId,
          'group_id': '100',
          'name': groupName,
          'type': 0,
        },
      });
      return <String, dynamic>{
        'type': 'group_call',
        'event': 'groupCalling',
        'title': groupName,
        'content': '群语音通话',
        'contact_id': 'group-100',
        'call_id': callId,
        'payload': payload.isEmpty ? frame : payload,
      };
    }

    /// 那通群语音结束了（房间空了）：静默数据，不弹任何东西
    Map<String, dynamic> groupEnded({String callId = 'gc-1'}) =>
        <String, dynamic>{
          'type': 'group_call',
          'event': 'groupCallEnded',
          'contact_id': 'group-100',
          'call_id': callId,
          'payload': '',
        };

    test('弹的是群邀请那条通知（不是消息通知，也不是 1:1 来电）', () async {
      await build().handle(groupRing());

      expect(presenter.groupRings, hasLength(1));
      expect(presenter.shown, isEmpty, reason: '它不是一条消息通知');
      expect(presenter.calls, isEmpty, reason: '它也不该占 1:1 来电那个通知位');
      expect(presenter.groupRings.single.title, '产品群');
      expect(presenter.groupRings.single.body, '小明 邀请你加入群语音');
    });

    test('整条报文原样留在通知里 —— 点它 / 冷启动要靠它进那个群', () async {
      await build().handle(groupRing());

      final payload = presenter.groupRings.single.payload;
      expect(payload, contains('group-100'));
      expect(payload, contains('groupCalling'));
      expect(json.decode(payload), isA<Map<String, dynamic>>());
    });

    test('超龄的邀请不弹也不响（群里那通可能早就散了）', () async {
      final old = DateTime.now().subtract(const Duration(minutes: 5));
      await build().handle(groupRing(sendTime: old.millisecondsSinceEpoch));

      expect(presenter.groupRings, isEmpty);
      expect(presenter.shown, isEmpty);
    });

    test('弹群邀请失败也不能炸（后台 isolate 崩了就连消息也收不到了）', () async {
      await build(fail: true).handle(groupRing());

      expect(presenter.groupRings, isEmpty);
    });

    group('这通群语音结束了（房间空了）', () {
      test('收到就收掉邀请通知，而且**一条通知都不弹**', () async {
        final handler = build();
        await handler.handle(groupRing());
        expect(presenter.groupRings, hasLength(1));

        await handler.handle(groupEnded());

        expect(presenter.cancelledGroupRings, 1);
        expect(presenter.shown, isEmpty);
        expect(presenter.calls, isEmpty);
        expect(presenter.groupRings, hasLength(1));
      });

      test('新的一通群语音已经响起来了：上一通的结束帧不许把正在响的收了', () async {
        final handler = build();
        await handler.handle(groupRing(callId: 'gc-7'));

        await handler.handle(groupEnded(callId: 'gc-1'));

        expect(presenter.cancelledGroupRings, 0);
      });

      test('App 刚被杀、这是第一次唤醒（手上没有正在响的）：照样收一次，反正无害', () async {
        await build().handle(groupEnded());

        expect(presenter.cancelledGroupRings, 1);
      });

      test('收尾帧不该把 1:1 来电那条通知一起收了（两个通知位各管各的）', () async {
        final handler = build();
        await handler.handle(cancelTestCallPush());
        expect(presenter.calls, hasLength(1));

        await handler.handle(groupEnded());

        expect(presenter.cancelledGroupRings, 1);
        expect(presenter.cancelledCalls, 0, reason: '群语音的收尾不能碰来电那条');
      });
    });
  });
}

/// 一条最小的 1:1 来电报文（只为一个用处：证明两个通知位互不干扰）
Map<String, dynamic> cancelTestCallPush() => <String, dynamic>{
  'type': 'webrtc',
  'event': 'calling',
  'title': '张三',
  'contact_id': 'u2',
  'payload': json.encode(<String, dynamic>{
    'id': 'call-1',
    'fromUser': <String, dynamic>{'id': 'u2', 'realname': '张三'},
    'toContactId': 'u1',
    'type': 'webrtc',
    'sendTime': DateTime.now().millisecondsSinceEpoch,
    'extends': <String, dynamic>{'event': 'calling', 'type': 0, 'code': 901},
  }),
};
