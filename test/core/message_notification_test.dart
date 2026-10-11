import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/domain/chat/message_notification.dart';

/// 系统通知的「该不该弹 / 弹什么」。对照老端 `App.vue::createPushMsg` 那段：
/// `if(!appStatus && data.fromUser.id!=userInfo.user_id && contact.is_notice==1)`。
void main() {
  const myId = 'u1';

  /// 一个假翻译器：直接把 key 换成可读文案，断言里好看清
  String t(String key) => key;

  Message message({
    String conversationId = 'u2',
    String fromUserId = 'u2',
    String fromUserName = '李四',
    String type = 'text',
    String content = '你好',
    int isGroup = 0,
    Map<String, dynamic> ext = const <String, dynamic>{},
  }) => Message(
    conversationId: conversationId,
    msgId: 'm1',
    fromUserId: fromUserId,
    fromUserName: fromUserName,
    type: type,
    content: content,
    isGroup: isGroup,
    ext: ext,
  );

  Conversation conversation({
    String id = 'u2',
    String displayName = '李四',
    int isNotice = 1,
    int isGroup = 0,
  }) => Conversation(
    id: id,
    displayName: displayName,
    isNotice: isNotice,
    isGroup: isGroup,
  );

  MessageNotification? build({
    Message? msg,
    Conversation? conv,
    bool appInForeground = false,
  }) => messageNotificationOf(
    message: msg ?? message(),
    conversation: conv ?? conversation(),
    myUserId: myId,
    appInForeground: appInForeground,
    translate: t,
  );

  group('该不该弹', () {
    test('后台 + 对方发的 + 会话没免打扰 → 弹', () {
      final notification = build();

      expect(notification, isNotNull);
      expect(notification!.conversationId, 'u2');
      expect(notification.title, '李四');
      expect(notification.body, '你好');
    });

    test('App 在前台 → 不弹（前台有应用内提示音）', () {
      expect(build(appInForeground: true), isNull);
    });

    test('自己发的 → 不弹', () {
      expect(build(msg: message(fromUserId: myId)), isNull);
    });

    test('会话免打扰（is_notice=0）→ 不弹', () {
      expect(build(conv: conversation(isNotice: 0)), isNull);
    });

    test('没有会话对象时也能弹（陌生会话先建会话再落消息）', () {
      final notification = messageNotificationOf(
        message: message(),
        conversation: null,
        myUserId: myId,
        appInForeground: false,
        translate: t,
      );

      expect(notification!.title, '李四', reason: '标题退回发信人昵称');
    });

    test('会话名和发信人昵称都空 → 不弹（不要画一条没标题的通知）', () {
      expect(
        build(
          msg: message(fromUserName: ''),
          conv: conversation(displayName: '   '),
        ),
        isNull,
      );
    });

    test('系统消息没有会话、也没有发信人 → 标题用「系统通知」兜底', () {
      final notification = messageNotificationOf(
        message: message(conversationId: 'system', fromUserName: ''),
        conversation: null,
        myUserId: myId,
        appInForeground: false,
        translate: t,
      );

      expect(notification, isNotNull);
      expect(notification!.title, 'user.systemNotice');
      expect(notification.conversationId, 'system');
    });
  });

  group('通知内容', () {
    test('群消息带上发送者', () {
      final notification = build(
        msg: message(isGroup: 1, fromUserName: '王五', content: '在吗'),
        conv: conversation(displayName: '项目群', isGroup: 1),
      );

      expect(notification!.title, '项目群');
      expect(notification.body, '王五: 在吗');
    });

    test('文本消息：正文剥掉 HTML，表情 token 变成系统表情（与列表预览同一套）', () {
      final notification = build(
        msg: message(
          content: '<p><span class="chat-grid-input">你好</span></p>[!1f600]',
        ),
      );

      // `<p>` 剥成一行时会留一个空格（`richToSingleLine` 的规矩）
      expect(notification!.body, '你好 😀');
    });

    test('图片 / 语音 / 文件这类：显示类型占位', () {
      expect(
        build(
          msg: message(type: 'image', content: 'x.png'),
        )!.body,
        '[common.image]',
      );
      expect(
        build(
          msg: message(type: 'voice', content: 'a.amr'),
        )!.body,
        '[common.voice]',
      );
      expect(
        build(
          msg: message(type: 'file', content: 'a.pdf'),
        )!.body,
        '[common.file]',
      );
      expect(
        build(
          msg: message(type: 'what', content: '?'),
        )!.body,
        '[common.nonsupportMsg]',
      );
    });

    test('通话消息：extends.type=1 是视频，0 是语音，缺了就是「音视频通话」', () {
      expect(
        build(
          msg: message(type: 'webrtc', ext: {'type': 1}),
        )!.body,
        '[common.videoCalling]',
      );
      expect(
        build(
          msg: message(type: 'webrtc', ext: {'type': 0}),
        )!.body,
        '[common.voiceCalling]',
      );
      expect(build(msg: message(type: 'webrtc'))!.body, '[common.webrtc]');
    });

    test('整条就是一个表情：通知里也显示那个表情（不是空白）', () {
      final notification = build(msg: message(content: '[!1f600]'));

      expect(notification!.body, '😀');
    });
  });

  group('推送（FCM 数据消息）', () {
    /// 服务端 `PushMessage::dataPayload()` 那份契约：字段名改这里就要同步改
    Map<String, String> push({
      String payload = '',
      String title = '张三',
      String content = '在吗',
      String contactId = 'u2',
    }) => <String, String>{
      'title': title,
      'content': content,
      'type': 'simple',
      'event': '',
      'contact_id': contactId,
      'msg_id': 'm1',
      'payload': payload,
    };

    /// 整条消息的 JSON（与 WS 那份同构）。接收方是 `u1`、发送方是 `u2`：
    /// 服务端给接收方那条会把 `toContactId` 设成发送者（会话 = 发送者）。
    String payload({
      String type = 'text',
      String content = '在吗',
      String fromId = 'u2',
      String fromName = '张三',
      int isGroup = 0,
      String conversationName = '',
    }) => json.encode(<String, dynamic>{
      'id': 5,
      'msg_id': 'm1',
      'type': type,
      'content': content,
      'sendTime': 1700000000000,
      'fromUser': <String, dynamic>{'id': fromId, 'displayName': fromName},
      'toContactId': 'u2',
      'toUser': 'u1',
      'is_group': isGroup,
      'contactInfo': conversationName.isEmpty
          ? <String, dynamic>{}
          : <String, dynamic>{'id': 'u2', 'displayName': conversationName},
    });

    MessageNotification? fromPush(
      Map<String, String> data, {
      String myUserId = myId,
    }) => messageNotificationFromPush(
      data: data,
      myUserId: myUserId,
      translate: t,
    );

    test('带整条消息的推送：正文走与 WS 同一套规则', () {
      final notification = fromPush(push(payload: payload()));

      expect(notification!.conversationId, 'u2', reason: '会话 = 发送者');
      expect(notification.title, '张三');
      expect(notification.body, '在吗');
    });

    test('标题优先用会话名（payload 里的 contactInfo），不是发送人昵称', () {
      final notification = fromPush(
        push(
          payload: payload(isGroup: 1, fromName: '王五', conversationName: '项目群'),
        ),
      );

      expect(notification!.title, '项目群');
      expect(notification.body, '王五: 在吗', reason: '群消息要带发送者');
    });

    test('图片/语音这类：类型占位（与列表、WS 通知同一套文案）', () {
      expect(
        fromPush(
          push(
            payload: payload(type: 'image', content: 'x.png'),
          ),
        )!.body,
        '[common.image]',
      );
    });

    test('payload 被服务端丢掉（太长）：用服务端给的标题与预览', () {
      final notification = fromPush(
        push(payload: '', title: '张三', content: '在吗（很长的消息被截断了）'),
      );

      expect(notification!.conversationId, 'u2', reason: '用 contact_id 兜底');
      expect(notification.title, '张三');
      expect(notification.body, '在吗（很长的消息被截断了）');
    });

    test('payload 是坏的 JSON：不炸，退回服务端给的预览', () {
      final notification = fromPush(push(payload: '{不是 json'));

      expect(notification!.body, '在吗');
    });

    test('自己发的推送不弹（服务端排过一次，这里是双保险）', () {
      expect(fromPush(push(payload: payload(fromId: myId))), isNull);
    });

    test('既没有 payload 也没有 contact_id：没法跳转，不弹', () {
      expect(fromPush(push(payload: '', contactId: '')), isNull);
    });

    test('标题全空：不弹（不要画一条没标题的通知）', () {
      expect(fromPush(push(payload: '', title: '', content: '在吗')), isNull);
    });
  });
}
