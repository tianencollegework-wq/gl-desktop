import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/domain/call/incoming_call_push.dart';
import 'package:gracelinkim/domain/call/call_signal.dart';

/// 一条**被离线推送送来的来电**（S8.1h）。
///
/// 这条链只有真机能走通（要杀进程、要真推一条），所以「认不认得出这是一通电话、
/// 谁在打、语音还是视频、还值不值得响铃」必须在这里钉死 ——
/// 认不出来就是对方打了没人接，判错了就是半夜响一声。
void main() {
  String callingFrame({int callType = CallType.voice, int sendTime = 0}) =>
      json.encode(<String, dynamic>{
        'id': 'call-uuid-1',
        'msg_id': 'srv-1',
        'fromUser': <String, dynamic>{
          'id': 'u2',
          'realname': '老B',
          'avatar': 'https://a.test/b.png',
        },
        'toContactId': 'u1',
        'toUser': 'u2',
        'type': 'webrtc',
        'sendTime': sendTime,
        'is_group': 0,
        'extends': <String, dynamic>{
          'event': 'calling',
          'type': callType,
          'code': 901,
          'status': CallStatus.ringing,
          'sdp': '',
          'iceCandidate': '',
        },
      });

  /// 服务端 `PushMessage::dataPayload()` 发出去的那几个字段（FCM 全是字符串）
  Map<String, String> push({
    String type = 'webrtc',
    String event = 'calling',
    String title = '老B',
    String contactId = 'u2',
    int callType = CallType.voice,
    int sendTime = 0,
    String? payload,
  }) => <String, String>{
    'type': type,
    'event': event,
    'title': title,
    'content': '[正在请求与您语音通话]',
    'contact_id': contactId,
    'msg_id': 'srv-1',
    'payload': payload ?? callingFrame(callType: callType, sendTime: sendTime),
  };

  group('认得出是不是来电', () {
    test('webrtc + calling 才算来电', () {
      expect(isIncomingCallPush(push()), isTrue);
      // 普通单聊消息不是
      expect(isIncomingCallPush(push(type: 'simple')), isFalse);
      // 通话中间那些信令（对方划掉 App 之后推送里也可能出现）不是
      expect(isIncomingCallPush(push(event: 'offer')), isFalse);
      expect(isIncomingCallPush(push(event: 'hangup')), isFalse);
    });

    test('字段全缺也不崩（FCM 里偶尔会少字段）', () {
      expect(isIncomingCallPush(const <String, String>{}), isFalse);
      expect(
        incomingCallFromPush(data: const <String, String>{}, myUserId: 'u1'),
        isNull,
      );
    });

    test('自己发出去的推送不响（服务端排过了，这是双保险）', () {
      expect(incomingCallFromPush(data: push(), myUserId: 'u2'), isNull);
    });
  });

  group('还原出一通能接的电话', () {
    test('来电人、语音/视频、整条报文都对', () {
      final call = incomingCallFromPush(data: push(), myUserId: 'u1')!;

      expect(call.peerId, 'u2');
      expect(call.callerName, '老B');
      expect(call.isVideo, isFalse);
      expect(call.canRebuildSession, isTrue);
      // 冷启动要拿它当 calling 报文用（接听要发 acceptRtc，需要 id / toContactId）
      expect(call.signal['id'], 'call-uuid-1');
      expect(call.signal['toContactId'], 'u1');
    });

    test('视频通话认得出来（extends.type == 1）', () {
      final call = incomingCallFromPush(
        data: push(callType: CallType.video),
        myUserId: 'u1',
      )!;

      expect(call.isVideo, isTrue);
      expect(call.toNotification((key) => key).body, '[common.videoCalling]');
    });

    test('payload 被服务端丢掉（超长）时只退化成一条通知，不去接', () {
      final call = incomingCallFromPush(
        data: push(payload: ''),
        myUserId: 'u1',
      )!;

      expect(call.canRebuildSession, isFalse);
      expect(call.peerId, 'u2', reason: '退回 contact_id：至少点得开那个会话');
      expect(call.callerName, '老B', reason: '退回服务端给的 title');
    });

    test('通知文案与会话列表同一套（配音/视频，不认识的来电人有通用文案）', () {
      final call = incomingCallFromPush(data: push(), myUserId: 'u1')!;
      expect(call.callerName, '老B');
      expect(call.toNotification((key) => key).body, '[common.voiceCalling]');

      // 报文里没有来电人、服务端也没给 title（都不认识）：退回通用文案
      final unknown = incomingCallFromPush(
        data: push(
          title: '',
          payload: json.encode(<String, dynamic>{
            'id': 'call-9',
            'type': 'webrtc',
            'extends': <String, dynamic>{
              'event': 'calling',
              'type': CallType.voice,
            },
          }),
        ),
        myUserId: 'u1',
      )!;
      expect(
        unknown.toNotification((key) => key).title,
        'call.incomingUnknown',
      );
    });
  });

  group('时效闸门（主叫只等 60 秒）', () {
    final now = DateTime(2026, 9, 20, 12);

    test('刚发出来的响', () {
      final call = incomingCallFromPush(
        data: push(sendTime: now.millisecondsSinceEpoch),
        myUserId: 'u1',
      )!;

      expect(call.isFresh(now), isTrue);
    });

    test('比推送 TTL（60 秒）早一截就不响了：响一秒对面已挂比不响更烦人', () {
      final call = incomingCallFromPush(
        data: push(sendTime: now.millisecondsSinceEpoch - 55000),
        myUserId: 'u1',
      )!;

      expect(call.isFresh(now), isFalse);
    });

    test('没有时间戳就当它是新的（宁可多响一次）', () {
      final call = incomingCallFromPush(
        data: push(sendTime: 0),
        myUserId: 'u1',
      )!;

      expect(call.sentAt, isNull);
      expect(call.isFresh(now), isTrue);
    });

    test('时间在未来（两端时钟不一致）也算新的 —— 不能因为手机时钟快就漏接电话', () {
      final call = incomingCallFromPush(
        data: push(sendTime: now.millisecondsSinceEpoch + 5000),
        myUserId: 'u1',
      )!;

      expect(call.isFresh(now), isTrue);
    });
  });

  group('「这通电话已经结束了」的收尾帧（S8.1n）', () {
    Map<String, String> cancel({String callId = 'call-1'}) => <String, String>{
      'type': 'webrtc',
      'event': 'callCanceled',
      'call_id': callId,
    };

    test('认得出来，并且**不是**一通来电（两条路径不能串）', () {
      expect(isCallCancelPush(cancel()), isTrue);
      expect(isIncomingCallPush(cancel()), isFalse);
      expect(incomingCallFromPush(data: cancel(), myUserId: 'u1'), isNull);
    });

    test('普通消息推送 / 来电报文都不是收尾帧', () {
      expect(
        isCallCancelPush(<String, String>{
          'type': 'simple',
          'event': 'callCanceled',
        }),
        isFalse,
      );
      expect(isCallCancelPush(push()), isFalse);
      expect(isCallCancelPush(<String, String>{}), isFalse);
    });

    test('带出那通电话的 id：主叫取消的是哪一通要认得出来', () {
      expect(callCancelIdOf(cancel(callId: 'abc')), 'abc');
      // 服务端没给就交回空串（调用方按「没有正在响的」处理）
      expect(callCancelIdOf(<String, String>{'type': 'webrtc'}), '');
    });
  });
}
