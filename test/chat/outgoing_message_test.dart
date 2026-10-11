import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/data/model/user_info.dart';
import 'package:gracelinkim/domain/chat/outgoing_message.dart';

/// 发出去的消息怎么拼（S4.4）。
///
/// 字段名全部对着老端 `im-input.vue::msgItem()` + `chat.vue::sendMessage()` 抄的，
/// 所以这里逐字段断言——参数名错了服务端就收不到（老端那边不会有任何报错）。
void main() {
  const me = UserInfo(
    userId: 'u1',
    account: '13800000001',
    displayName: '我',
    realName: '张三',
    avatar: 'https://a.test/me.png',
    raw: <String, dynamic>{
      'user_id': 'u1',
      'account': '13800000001',
      'displayName': '我',
      'realname': '张三',
      'avatar': 'https://a.test/me.png',
    },
  );

  group('请求体', () {
    test('文本消息的字段与老端一一对应', () {
      final payload = buildOutgoingPayload(
        clientId: 'c-1',
        type: 'text',
        content: '你好[!1f600]',
        me: me,
        toContactId: 'u2',
        isGroup: 0,
        sendTimeMs: 1700000000000,
      );

      expect(payload['id'], 'c-1');
      expect(payload['sendTime'], 1700000000000);
      expect(payload['status'], 'going');
      expect(payload['type'], 'text');
      expect(payload['content'], '你好[!1f600]');
      expect(payload['is_read'], 0);
      expect(payload['is_group'], 0);
      expect(payload['toContactId'], 'u2');
      expect(payload['from_user'], 'u1');
      expect(payload['fileName'], '');
      expect(payload['fileSize'], 0);
      // 这四个老端永远会带上（`msgItem()` 的默认值）
      expect(payload['file_id'], 0);
      expect(payload['file_cate'], 0);
      // 没有引用的文本消息，`extends` 是 null（老端就是 null，不是 {}）
      expect(payload.containsKey('extends'), isTrue);
      expect(payload['extends'], isNull);
      // 没有 @ 就不带 at 字段
      expect(payload.containsKey('at'), isFalse);
      expect(payload.containsKey('pid'), isFalse);
    });

    test('fromUser 里是完整的用户对象，并按老端那样补上 id', () {
      final payload = buildOutgoingPayload(
        clientId: 'c-1',
        type: 'text',
        content: 'hi',
        me: me,
        toContactId: 'u2',
        isGroup: 0,
        sendTimeMs: 1,
      );

      final fromUser = payload['fromUser'] as Map<String, dynamic>;
      expect(fromUser['id'], 'u1');
      expect(fromUser['user_id'], 'u1');
      expect(fromUser['displayName'], '我');
      expect(fromUser['realname'], '张三');
      expect(fromUser['avatar'], 'https://a.test/me.png');
    });

    test('引用消息：extends 就是引用块本身，pid 是对方的 msg_id', () {
      final quote = <String, dynamic>{
        'msg_id': 'm9',
        'content': '小明：你好',
        'user_id': 'u2',
        'realname': '小明',
      };
      final payload = buildOutgoingPayload(
        clientId: 'c-2',
        type: 'text',
        content: '回复你',
        me: me,
        toContactId: 'u2',
        isGroup: 0,
        sendTimeMs: 1,
        ext: quote,
        quote: quote,
        pid: 'm9',
      );

      expect(payload['extends'], quote);
      expect(payload['pid'], 'm9');
    });

    test('群聊带上 is_group 与 at 名单', () {
      final payload = buildOutgoingPayload(
        clientId: 'c-3',
        type: 'text',
        content: '@小明 在吗',
        me: me,
        toContactId: 'g1',
        isGroup: 1,
        sendTimeMs: 1,
        at: <String>['u2', 'u3'],
      );

      expect(payload['is_group'], 1);
      expect(payload['at'], <String>['u2', 'u3']);
    });

    test('表情消息（收藏表情）：content 是图片地址，带 file_id', () {
      final payload = buildOutgoingPayload(
        clientId: 'c-4',
        type: 'emoji',
        content: 'https://a.test/sticker.png',
        me: me,
        toContactId: 'u2',
        isGroup: 0,
        sendTimeMs: 1,
        fileId: 7,
      );

      expect(payload['type'], 'emoji');
      expect(payload['content'], 'https://a.test/sticker.png');
      expect(payload['file_id'], 7);
    });
  });

  group('引用块', () {
    String t(String key) => switch (key) {
      'common.image' => '图片',
      _ => key,
    };

    Message message({
      required String type,
      required String content,
      String fromName = '小明',
      String msgId = 'm1',
    }) => Message(
      msgId: msgId,
      conversationId: 'u2',
      fromUserId: 'u2',
      fromUserName: fromName,
      type: type,
      content: content,
      sendTime: 1,
    );

    test('文本：去掉 HTML 标签，冠上发送人名字', () {
      final quote = buildQuote(
        message(type: 'text', content: '<p>你好</p>'),
        translate: t,
      );
      expect(quote['content'], '小明：你好');
      expect(quote['msg_id'], 'm1');
      expect(quote['user_id'], 'u2');
      expect(quote['realname'], '小明');
    });

    test('非文本类型换成占位（老端 getMsgType 那套）', () {
      final quote = buildQuote(
        message(type: 'image', content: 'https://a.test/1.png'),
        translate: t,
      );
      expect(quote['content'], '小明：[图片]');
    });

    test('位置/名片显示原文（老端把它们留在原样显示的那一档）', () {
      final location = buildQuote(
        message(type: 'location', content: '人民广场'),
        translate: t,
      );
      expect(location['content'], '小明：人民广场');
      final contact = buildQuote(
        message(type: 'contact', content: '[个人名片] 小红'),
        translate: t,
      );
      expect(contact['content'], '小明：[个人名片] 小红');
    });
  });

  group('能不能发言（老端 nospeak，语义是「可以发」）', () {
    Conversation group({required int nospeak, required int role}) =>
        Conversation(
          id: 'g1',
          isGroup: 1,
          role: role,
          extra: <String, dynamic>{
            'setting': <String, dynamic>{'nospeak': nospeak},
          },
        );

    test('单聊永远能发', () {
      expect(canSpeak(const Conversation(id: 'u2')), isTrue);
      expect(canSpeak(null), isTrue);
    });

    test('没开禁言：谁都能发', () {
      expect(canSpeak(group(nospeak: 0, role: 3)), isTrue);
    });

    test('全员禁言（nospeak=1）：群主/管理员能发，普通成员不能', () {
      expect(canSpeak(group(nospeak: 1, role: 1)), isTrue);
      expect(canSpeak(group(nospeak: 1, role: 2)), isTrue);
      expect(canSpeak(group(nospeak: 1, role: 3)), isFalse);
    });

    test('只禁管理员（nospeak=2）：只有群主能发（照抄老端的判断）', () {
      expect(canSpeak(group(nospeak: 2, role: 1)), isTrue);
      expect(canSpeak(group(nospeak: 2, role: 2)), isFalse);
      expect(canSpeak(group(nospeak: 2, role: 3)), isFalse);
    });
  });
}
