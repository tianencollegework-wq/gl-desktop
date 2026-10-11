import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/domain/call/call_signal.dart';

/// 信令报文层（S6.1）：事件/码常量、收到时的解析、发出去时的十个字段。
void main() {
  group('常量', () {
    test('客户端真的会发的事件就那七个（turndown 老端从没发过）', () {
      expect(CallEvent.sent, <String>[
        'calling',
        'acceptRtc',
        'offer',
        'answer',
        'iceCandidate',
        'hangup',
        'busy',
      ]);
      expect(CallEvent.sent, isNot(contains(CallEvent.turndown)));
      expect(CallEvent.sent, isNot(contains(CallEvent.otherOpt)));
      expect(CallEvent.sent, isNot(contains(CallEvent.mediaDevices)));
    });

    test('解锁列表照抄老端 [902,903,905,906,907]', () {
      expect(CallCode.unlockCodes, <int>[902, 903, 905, 906, 907]);
      expect(CallCode.unlockCodes, isNot(contains(CallCode.dialing)));
      expect(CallCode.unlockCodes, isNot(contains(CallCode.accept)));
    });
  });

  group('收到信令（extends）', () {
    test('全部字段都能读出来', () {
      final signal = CallSignal.fromExtends(
        <String, dynamic>{
          'event': 'hangup',
          'code': 906,
          'status': 2,
          'type': 1,
          'sdp': 'sdp-text',
          'callTime': 42,
          'isbtn': true,
          'isMobile': 1,
        },
        messageId: 'uuid-1',
        serverId: 'srv-9',
        fromUserId: 'u2',
        fromUserName: '老B',
        fromUserAvatar: 'https://a.test/b.png',
      );

      expect(signal.event, 'hangup');
      expect(signal.code, 906);
      expect(signal.status, CallStatus.talking);
      expect(signal.type, CallType.video);
      expect(signal.sdp, 'sdp-text');
      expect(signal.callTime, 42);
      expect(signal.byButton, isTrue);
      expect(signal.isMobile, isTrue);
      expect(signal.messageId, 'uuid-1');
      expect(signal.serverId, 'srv-9');
      expect(signal.fromUserId, 'u2');
      expect(signal.fromUserName, '老B');
      expect(signal.isVideo, isTrue);
    });

    test('宽松取值：code 是字符串、缺字段都按老端的松散比较来', () {
      final signal = CallSignal.fromExtends(<String, dynamic>{
        'event': 'acceptRtc',
        'code': '904',
      });

      expect(signal.code, 904);
      expect(signal.status, 0);
      expect(signal.type, 0);
      expect(signal.sdp, '');
      expect(signal.callTime, 0);
      expect(signal.byButton, isFalse);
      expect(signal.iceCandidate, isEmpty);
      expect(signal.isVideo, isFalse);
    });

    test('extends 是 null / 不是对象都退化成空信令，不抛异常', () {
      expect(CallSignal.fromExtends(null).event, '');
      expect(CallSignal.fromExtends('炸了').code, 0);
      expect(CallSignal.fromExtends(<String, dynamic>{}).status, 0);
    });

    test('ICE 候选是 JSON 字符串（我们就是这么发的）', () {
      final signal = CallSignal.fromExtends(<String, dynamic>{
        'event': 'iceCandidate',
        'iceCandidate':
            '{"candidate":"cand-1","sdpMLineIndex":0,"sdpMid":"audio"}',
      });

      expect(signal.iceCandidate['candidate'], 'cand-1');
      expect(signal.iceCandidate['sdpMid'], 'audio');
    });

    test('ICE 候选是对象也认（老端 WebView 两种都处理了）', () {
      final signal = CallSignal.fromExtends(<String, dynamic>{
        'event': 'iceCandidate',
        'iceCandidate': <String, dynamic>{'candidate': 'cand-2', 'sdpMid': '0'},
      });

      expect(signal.iceCandidate['candidate'], 'cand-2');
    });

    test('ICE 候选是坏字符串 / 空串 → 空 map（别让一条脏报文崩掉整通话）', () {
      expect(decodeIceCandidate('{不是 json'), isEmpty);
      expect(decodeIceCandidate(''), isEmpty);
      expect(decodeIceCandidate(null), isEmpty);
      expect(decodeIceCandidate(<String, dynamic>{}), isEmpty);
    });

    test('是不是自己发的（老端那一堆 isMobile / fromUser.id 判断靠它）', () {
      final mine = CallSignal.fromExtends(<String, dynamic>{
        'event': 'calling',
      }, fromUserId: 'u1');

      expect(mine.isEchoOf('u1'), isTrue);
      expect(mine.isEchoOf('u2'), isFalse);
      expect(mine.isEchoOf(null), isFalse);
      expect(mine.isEchoOf(''), isFalse);
    });
  });

  group('发出去的信令（sendToMsg 的十个字段）', () {
    test('主叫那条 calling：status 3、code 901、缺的字段写空串', () {
      final request = buildSignalRequest(
        toContactId: 'u2',
        type: CallType.video,
        event: CallEvent.calling,
        id: 'uuid-1',
        status: CallStatus.ringing,
        code: CallCode.dialing,
      );

      expect(request, <String, dynamic>{
        'id': 'uuid-1',
        'msg_id': '',
        'toContactId': 'u2',
        'type': 1,
        'event': 'calling',
        'status': 3,
        'code': 901,
        'callTime': '',
        'sdp': '',
        'iceCandidate': '',
      });
    });

    test('打的就是这十个键（多一个少一个都不行）', () {
      final request = buildSignalRequest(
        toContactId: 'u2',
        type: CallType.voice,
        event: CallEvent.hangup,
        id: 'uuid-1',
        serverId: 'srv-1',
        code: CallCode.hangupInCall,
        callTime: 61,
      );

      expect(request.keys.toSet(), <String>{
        'id',
        'msg_id',
        'toContactId',
        'type',
        'event',
        'status',
        'code',
        'callTime',
        'sdp',
        'iceCandidate',
      });
      expect(request['msg_id'], 'srv-1');
      expect(request['callTime'], 61);
      expect(request['status'], '');
    });

    test('ICE 候选只发三个键、而且是 JSON 字符串（老端 JSON.stringify）', () {
      final request = buildSignalRequest(
        toContactId: 'u2',
        type: CallType.voice,
        event: CallEvent.iceCandidate,
        id: 'uuid-1',
        iceCandidate: <String, dynamic>{
          'candidate': 'cand-1',
          'sdpMLineIndex': 0,
          'sdpMid': 'audio',
          'address': '192.168.1.5', // 浏览器会给，老端发之前筛掉了
          'toJSON': 'x',
        },
      );

      final raw = request['iceCandidate'] as String;
      expect(json.decode(raw), <String, dynamic>{
        'candidate': 'cand-1',
        'sdpMLineIndex': 0,
        'sdpMid': 'audio',
      });
    });

    test('没有 ICE 候选的事件也带一个空串（老端十个字段一个不少）', () {
      final request = buildSignalRequest(
        toContactId: 'u2',
        type: CallType.voice,
        event: CallEvent.offer,
        id: 'uuid-1',
        sdp: 'v=0...',
      );

      expect(request['iceCandidate'], '');
      expect(request['sdp'], 'v=0...');
      expect(request['code'], '');
    });

    test('encodeIceCandidate 与 decodeIceCandidate 能互相还原', () {
      final candidate = <String, dynamic>{
        'candidate': 'cand-1',
        'sdpMLineIndex': 1,
        'sdpMid': 'video',
      };

      expect(decodeIceCandidate(encodeIceCandidate(candidate)), candidate);
    });
  });
}
