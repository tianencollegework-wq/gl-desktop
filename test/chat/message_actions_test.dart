import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/domain/chat/message_actions.dart';

/// 长按菜单的规则（S4.5），对照老端 `pages/message/chat.vue` 里
/// `add-modal` 那六个 `v-if`。
void main() {
  final now = DateTime(2026, 9, 18, 12).millisecondsSinceEpoch;
  const me = 'u1';

  Message msg({
    String type = 'text',
    String content = '你好',
    String fromUserId = me,
    int? sendTime,
    int isUndo = 0,
  }) => Message(
    serverId: 1,
    msgId: 'm1',
    conversationId: 'u2',
    fromUserId: fromUserId,
    fromUserName: fromUserId == me ? '我' : '小明',
    type: type,
    content: content,
    sendTime: sendTime ?? now - 1000,
    isUndo: isUndo,
  );

  List<MessageAction> actions(
    Message message, {
    int role = 3,
    bool isGroup = false,
    bool dbDelMsg = true,
    int redoTime = 86400,
    String? myUserId = me,
  }) => availableActions(
    message: message,
    myUserId: myUserId,
    role: role,
    isGroup: isGroup,
    redoTimeSeconds: redoTime,
    dbDelMsg: dbDelMsg,
    nowMs: now,
  );

  group('撤回', () {
    test('自己的消息、在时间窗内：能撤', () {
      expect(actions(msg()).contains(MessageAction.undo), isTrue);
    });

    test('超过 redoTime 就不能撤（老端 `redoTime*1000`）', () {
      expect(
        actions(
          msg(sendTime: now - 3 * 1000),
          redoTime: 1,
        ).contains(MessageAction.undo),
        isFalse,
      );
      // 差一点点还在窗内
      expect(
        actions(
          msg(sendTime: now - 900),
          redoTime: 1,
        ).contains(MessageAction.undo),
        isTrue,
      );
    });

    test('单聊里别人的消息撤不了（老端 role<3 在单聊是 0，靠时间窗挡）', () {
      expect(
        actions(msg(fromUserId: 'u2')).contains(MessageAction.undo),
        isFalse,
      );
    });

    test('群里群主/管理员能撤别人的（role<3）', () {
      expect(
        actions(
          msg(fromUserId: 'u2'),
          isGroup: true,
          role: 2,
        ).contains(MessageAction.undo),
        isTrue,
      );
      expect(
        actions(
          msg(fromUserId: 'u2'),
          isGroup: true,
          role: 3,
        ).contains(MessageAction.undo),
        isFalse,
      );
    });

    test('通话卡片不能撤（老端排除 webrtc）', () {
      expect(
        actions(msg(type: 'webrtc')).contains(MessageAction.undo),
        isFalse,
      );
    });

    test('已经撤回过的消息不再给撤回', () {
      expect(actions(msg(isUndo: 1)).contains(MessageAction.undo), isFalse);
    });
  });

  group('复制 / 存表情 / 转发 / 引用', () {
    test('能复制的就那四类（text/image/video/file）', () {
      for (final type in <String>['text', 'image', 'video', 'file']) {
        expect(
          actions(msg(type: type)).contains(MessageAction.copy),
          isTrue,
          reason: type,
        );
      }
      for (final type in <String>['voice', 'emoji', 'location', 'contact']) {
        expect(
          actions(msg(type: type)).contains(MessageAction.copy),
          isFalse,
          reason: type,
        );
      }
    });

    test('只有动态表情能「存表情」', () {
      expect(
        actions(msg(type: 'emoji')).contains(MessageAction.saveEmoji),
        isTrue,
      );
      expect(
        actions(msg(type: 'text')).contains(MessageAction.saveEmoji),
        isFalse,
      );
    });

    test('语音/通话/红包不能转发', () {
      for (final type in <String>['voice', 'webrtc', 'money']) {
        expect(
          actions(msg(type: type)).contains(MessageAction.forward),
          isFalse,
          reason: type,
        );
      }
      expect(
        actions(msg(type: 'image')).contains(MessageAction.forward),
        isTrue,
      );
    });

    test('语音能引用（老端只挡 webrtc/money）', () {
      expect(actions(msg(type: 'voice')).contains(MessageAction.quote), isTrue);
      expect(
        actions(msg(type: 'webrtc')).contains(MessageAction.quote),
        isFalse,
      );
    });
  });

  group('删除', () {
    test('只能删自己的', () {
      expect(actions(msg()).contains(MessageAction.delete), isTrue);
      expect(
        actions(msg(fromUserId: 'u2')).contains(MessageAction.delete),
        isFalse,
      );
    });

    test('服务端关了本地删除（dbDelMsg != 1）就没有这一项', () {
      expect(
        actions(msg(), dbDelMsg: false).contains(MessageAction.delete),
        isFalse,
      );
    });

    test('群里管理员也不能删别人的（老端只看 fromUser.id == 自己）', () {
      expect(
        actions(
          msg(fromUserId: 'u2'),
          isGroup: true,
          role: 1,
        ).contains(MessageAction.delete),
        isFalse,
      );
    });
  });

  test('顺序与老端一致：撤回 → 复制 → 存表情 → 转发 → 引用 → 删除', () {
    final list = actions(msg());
    expect(list, <MessageAction>[
      MessageAction.undo,
      MessageAction.copy,
      MessageAction.forward,
      MessageAction.quote,
      MessageAction.delete,
    ]);
  });

  group('撤回后「重新编辑」', () {
    test('自己撤的、文字、在时间窗内：能点', () {
      expect(
        canReedit(
          message: msg(content: '原文', isUndo: 1),
          myUserId: me,
          redoTimeSeconds: 86400,
          nowMs: now,
        ),
        isTrue,
      );
    });

    test('别人撤的不给点（老端这里没判所有者，是个小毛病）', () {
      expect(
        canReedit(
          message: msg(content: '原文', isUndo: 1, fromUserId: 'u2'),
          myUserId: me,
          redoTimeSeconds: 86400,
          nowMs: now,
        ),
        isFalse,
      );
    });

    test('非文字消息不给点（图片的 content 是个地址）', () {
      expect(
        canReedit(
          message: msg(
            type: 'image',
            content: 'https://a.test/1.png',
            isUndo: 1,
          ),
          myUserId: me,
          redoTimeSeconds: 86400,
          nowMs: now,
        ),
        isFalse,
      );
    });

    test('超出时间窗不给点', () {
      expect(
        canReedit(
          message: msg(isUndo: 1, sendTime: now - 2000),
          myUserId: me,
          redoTimeSeconds: 1,
          nowMs: now,
        ),
        isFalse,
      );
    });
  });

  group('复制的内容', () {
    test('文字：表情 token 变成系统表情字符（S4.4b，复制出来仍旧看得到表情）', () {
      expect(copyText(msg(content: '你好[!1f600]在吗')), '你好😀在吗');
    });

    test('图片/文件：老端复制的就是 content 本身（一个地址）', () {
      expect(
        copyText(msg(type: 'image', content: 'https://a.test/1.png')),
        'https://a.test/1.png',
      );
    });
  });
}
