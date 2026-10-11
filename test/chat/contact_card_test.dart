import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/contact.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/domain/chat/contact_card.dart';

/// 名片消息的纯逻辑（S4.6 补漏）：发出去的那三个字段与点它跳谁。
void main() {
  const friend = Contact(
    id: 'u3',
    displayName: '小红',
    avatar: 'https://cdn.test/xiaohong.png',
    isGroup: 0,
    account: '13800000003',
  );

  String translate(String key) => key == 'chat.userIDcard' ? '个人名片' : key;

  Message cardMessage({required String id, String displayName = '小红'}) =>
      Message(
        conversationId: 'u2',
        fromUserId: 'u1',
        type: 'contact',
        content: '[个人名片] $displayName',
        ext: <String, dynamic>{
          'avatar': 'https://cdn.test/xiaohong.png',
          'displayName': displayName,
          if (id.isNotEmpty) 'id': id,
        },
      );

  test('fromContact：只带 id / displayName / avatar 三个字段', () {
    final card = ContactCard.fromContact(friend);

    expect(card.id, 'u3');
    expect(card.displayName, '小红');
    expect(card.avatar, 'https://cdn.test/xiaohong.png');
    expect(card.isEmpty, isFalse);
  });

  test('extends 就是老端那三个键（这样老端收到也能画出来）', () {
    expect(ContactCard.fromContact(friend).toExt(), <String, dynamic>{
      'avatar': 'https://cdn.test/xiaohong.png',
      'displayName': '小红',
      'id': 'u3',
    });
  });

  test('content：「[个人名片] 名字」——会话列表与通知里显示的就是它', () {
    expect(ContactCard.fromContact(friend).content(translate), '[个人名片] 小红');
  });

  test('没有显示名也不炸（老端会拼出 "[个人名片] undefined"）', () {
    const anonymous = Contact(id: 'u9');
    expect(anonymous.displayName.isEmpty, isTrue);
    expect(ContactCard.fromContact(anonymous).content(translate), '[个人名片] ');
  });

  test('点名片：从 extends 里读对方的 user_id', () {
    expect(contactCardTargetId(cardMessage(id: 'u3')), 'u3');
  });

  test('名片没带 id：读出来是空串（调用处就不跳资料页）', () {
    expect(contactCardTargetId(cardMessage(id: '')), '');
  });

  test('老端那种只有 realname 没有 displayName 的名片也认得出来', () {
    final message = Message(
      conversationId: 'u2',
      type: 'contact',
      content: '[个人名片] 小明',
      ext: <String, dynamic>{'realname': '小明', 'id': 'u7'},
    );

    expect(contactCardTargetId(message), 'u7');
  });
}
