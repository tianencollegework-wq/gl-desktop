import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/domain/group_call/group_call_push.dart';

/// 群通话的离线推送（S6.14）：解析、判类、新鲜度、通知文案。
///
/// 这一块只有**真机 + 真的推一条**才能看到整体效果（要杀掉 App 才走后台 isolate），
/// 所以报文那一层必须能在本机钉住：字段名写错、大小写写错，真机上就是「没有通知」
/// 或者「点进去是聊天页」这种看不出根因的症状。
void main() {
  /// 服务端 `Sfu.php::pushGroupCall` 推出去的响铃帧（FCM 里全是字符串）
  Map<String, dynamic> frame({
    String conversationId = 'group-100',
    String groupName = '产品群',
    String starter = '小明',
    String callId = 'gc-1',
    DateTime? sentAt,
    String event = GroupCallPushEvent.ringing,
  }) => <String, dynamic>{
    'id': callId,
    'type': groupCallPushType,
    'toContactId': conversationId,
    'fromUser': <String, dynamic>{'id': 'u2', 'displayName': starter},
    'sendTime': (sentAt ?? DateTime.now()).millisecondsSinceEpoch,
    'extends': <String, dynamic>{
      'event': event,
      'call_id': callId,
      'group_id': '100',
      'name': groupName,
      'type': 0,
    },
  };

  /// 那条 FCM 数据消息（`PushMessage::dataPayload()` 摊平后的那几个字段）
  Map<String, String> push({
    Map<String, dynamic>? payload,
    String contactId = 'group-100',
    String title = '产品群',
    String callId = 'gc-1',
    String event = GroupCallPushEvent.ringing,
  }) => <String, String>{
    'title': title,
    'content': '群语音通话',
    'type': groupCallPushType,
    'event': event,
    'contact_id': contactId,
    'msg_id': '',
    'call_id': callId,
    'payload': json.encode(payload ?? frame(callId: callId)),
  };

  /// 后台 isolate 里那份「取不到词就用服务端给的兜底」的翻译
  String translate(String key, String fallback) =>
      fallback.isEmpty ? key : fallback;

  group('判类', () {
    test('响铃帧：type + event 都对才算', () {
      expect(isGroupCallRingPush(push()), isTrue);
      expect(
        isGroupCallRingPush(push(event: GroupCallPushEvent.ended)),
        isFalse,
      );
    });

    test('结束帧单独认（它是收尾，不是邀请）', () {
      expect(isGroupCallEndPush(push(event: GroupCallPushEvent.ended)), isTrue);
      expect(isGroupCallEndPush(push()), isFalse);
    });

    test('1:1 来电与服务端老类型都不算群通话', () {
      expect(
        isGroupCallRingPush(<String, String>{
          'type': 'webrtc',
          'event': 'calling',
        }),
        isFalse,
      );
      expect(
        isGroupCallEndPush(<String, String>{
          'type': 'webrtc',
          'event': 'callCanceled',
        }),
        isFalse,
      );
      expect(
        isGroupCallRingPush(<String, String>{
          'type': 'simple',
          'event': GroupCallPushEvent.ringing,
        }),
        isFalse,
      );
    });

    test('结束帧也要能读出那通群语音的 id（不然会把新响的那通收掉）', () {
      expect(
        groupCallPushIdOf(
          push(event: GroupCallPushEvent.ended, callId: 'gc-9'),
        ),
        'gc-9',
      );
      expect(groupCallPushIdOf(const <String, String>{}), '');
    });
  });

  group('解析', () {
    test('整条报文：群会话 id、群名、发起人、那通电话的 id 都还原出来', () {
      final invite = groupCallFromPush(data: push());

      expect(invite, isNotNull);
      expect(invite!.conversationId, 'group-100');
      expect(invite.groupName, '产品群');
      expect(invite.starterName, '小明');
      expect(invite.callId, 'gc-1');
      expect(invite.canOpen, isTrue);
    });

    test('不是邀请（结束帧 / 普通消息）时返回 null', () {
      expect(
        groupCallFromPush(data: push(event: GroupCallPushEvent.ended)),
        isNull,
      );
      expect(
        groupCallFromPush(
          data: <String, String>{'type': 'simple', 'event': 'simple'},
        ),
        isNull,
      );
    });

    test('payload 被服务端超长丢掉：退回 contact_id / title / call_id，还能点进去', () {
      final invite = groupCallFromPush(
        data: <String, String>{
          'type': groupCallPushType,
          'event': GroupCallPushEvent.ringing,
          'contact_id': 'group-100',
          'title': '产品群',
          'call_id': 'gc-2',
          'payload': '',
        },
      );

      expect(invite, isNotNull);
      expect(invite!.conversationId, 'group-100');
      expect(invite.groupName, '产品群');
      expect(invite.starterName, '', reason: '报文没了就没有发起人，正文退回通用文案');
      expect(invite.callId, 'gc-2');
      expect(invite.sentAt, isNull, reason: '没有 sendTime 时按「新的」处理');
      expect(invite.isFresh(DateTime.now()), isTrue);
    });

    test('payload 是坏的 JSON：不崩，按退路解析', () {
      final invite = groupCallFromPush(
        data: <String, String>{
          'type': groupCallPushType,
          'event': GroupCallPushEvent.ringing,
          'contact_id': 'group-100',
          'call_id': 'gc-3',
          'payload': '{这不是 json',
        },
      );

      expect(invite?.conversationId, 'group-100');
      expect(invite?.frame, isEmpty);
    });
  });

  group('点通知那条路（整条报文还原）', () {
    test('报文就是一条群通话邀请', () {
      final invite = groupCallFromSignal(frame());

      expect(invite?.conversationId, 'group-100');
      expect(invite?.groupName, '产品群');
      expect(invite?.starterName, '小明');
      expect(invite?.callId, 'gc-1');
      // payload 要用**我们手上的这份报文**（通知里存的就是它）
      expect(
        json.decode(invite!.payload),
        containsPair('type', groupCallPushType),
      );
    });

    test('不是群通话的报文一律不认（1:1 来电 / 普通消息 / 空）', () {
      expect(
        groupCallFromSignal(<String, dynamic>{
          'type': 'webrtc',
          'extends': <String, dynamic>{'event': 'calling'},
        }),
        isNull,
      );
      expect(groupCallFromSignal(<String, dynamic>{'type': 'text'}), isNull);
      expect(groupCallFromSignal(null), isNull);
    });

    test('类型对、事件是「结束」的报文不当邀请', () {
      expect(
        groupCallFromSignal(frame(event: GroupCallPushEvent.ended)),
        isNull,
      );
    });
  });

  group('新不新鲜', () {
    test('刚推来的算新鲜', () {
      final invite = groupCallFromPush(data: push());
      expect(invite!.isFresh(DateTime.now()), isTrue);
    });

    test('迟到三分钟的不再响（群里那通可能早就散了）', () {
      final invite = groupCallFromPush(
        data: push(
          payload: frame(
            sentAt: DateTime.now().subtract(const Duration(minutes: 3)),
          ),
        ),
      );
      expect(invite!.isFresh(DateTime.now()), isFalse);
    });

    test('两端时钟差几秒（sendTime 在未来）不该被判成过期', () {
      final invite = groupCallFromPush(
        data: push(
          payload: frame(
            sentAt: DateTime.now().add(const Duration(seconds: 5)),
          ),
        ),
      );
      expect(invite!.isFresh(DateTime.now()), isTrue);
    });
  });

  group('通知文案', () {
    test('标题是群名，正文是「谁 邀请你加入群语音」', () {
      final notification = groupCallFromPush(
        data: push(),
      )!.toNotification(translate);

      expect(notification.conversationId, 'group-100');
      expect(notification.title, '产品群');
      expect(notification.body, '小明 邀请你加入群语音');
    });

    test('群名取不到时退回通用标题；发起人取不到时正文只有那句邀请', () {
      final notification = groupCallFromPush(
        data: <String, String>{
          'type': groupCallPushType,
          'event': GroupCallPushEvent.ringing,
          'contact_id': 'group-100',
          'title': '',
          'call_id': 'gc-4',
          'payload': json.encode(
            frame(groupName: '', starter: '', callId: 'gc-4'),
          ),
        },
      )!.toNotification(translate);

      expect(notification.title, '群语音通话');
      expect(notification.body, '邀请你加入群语音');
    });
  });
}
