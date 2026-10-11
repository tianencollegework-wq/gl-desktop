import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/conversation.dart';
import 'package:gracelinkim/data/model/message.dart';
import 'package:gracelinkim/domain/chat/conversation_rules.dart';

/// 用 key 当翻译，方便断言"取了哪个 key"
String _t(String key) => key;

Message _message({
  String conversationId = 'u2',
  String fromUserId = 'u2',
  String content = 'hi',
  String type = 'text',
  int sendTime = 1758163200000,
  List<String> at = const <String>[],
  int isGroup = 0,
}) => Message(
  conversationId: conversationId,
  fromUserId: fromUserId,
  fromUserName: '小明',
  fromUserAvatar: 'a.png',
  content: content,
  type: type,
  sendTime: sendTime,
  at: at,
  isGroup: isGroup,
);

Conversation _conversation({
  String id = 'u1',
  int unread = 0,
  int isAt = 0,
  int isTop = 0,
  int isNotice = 1,
  String lastContent = 'hi',
  int lastSendTime = 1000,
  String lastType = 'text',
}) => Conversation(
  id: id,
  displayName: id,
  unread: unread,
  isAt: isAt,
  isTop: isTop,
  isNotice: isNotice,
  lastContent: lastContent,
  lastSendTime: lastSendTime,
  lastType: lastType,
);

void main() {
  group('排序（对应老端 sortContacts）', () {
    test('按最后消息时间倒序', () {
      final sorted = ConversationRules.sorted(<Conversation>[
        _conversation(id: 'a', lastSendTime: 1000),
        _conversation(id: 'b', lastSendTime: 3000),
        _conversation(id: 'c', lastSendTime: 2000),
      ]);
      expect(sorted.map((item) => item.id), <String>['b', 'c', 'a']);
    });

    test('时间无效（0）的排到最后', () {
      final sorted = ConversationRules.sorted(<Conversation>[
        _conversation(id: 'none', lastSendTime: 0),
        _conversation(id: 'new', lastSendTime: 5000),
      ]);
      expect(sorted.map((item) => item.id), <String>['new', 'none']);
    });

    test('时间相同时保持原顺序（老端是稳定排序）', () {
      final sorted = ConversationRules.sorted(<Conversation>[
        _conversation(id: 'first', lastSendTime: 1000),
        _conversation(id: 'second', lastSendTime: 1000),
      ]);
      expect(sorted.map((item) => item.id), <String>['first', 'second']);
    });

    test('置顶的排前面（老端 topContacts.concat(otherContacts)）', () {
      final list = ConversationRules.topFirst(<Conversation>[
        _conversation(id: 'old-top', isTop: 1, lastSendTime: 100),
        _conversation(id: 'new', isTop: 0, lastSendTime: 900),
        _conversation(id: 'new-top', isTop: 1, lastSendTime: 800),
      ]);
      expect(list.map((item) => item.id), <String>[
        'new-top',
        'old-top',
        'new',
      ]);
    });
  });

  group('未读汇总（对应老端 initContacts，含它那两处不对称）', () {
    test('免打扰的会话不计入总未读', () {
      final totals = ConversationRules.totals(<Conversation>[
        _conversation(id: 'a', unread: 3),
        _conversation(id: 'b', unread: 5, isNotice: 0),
      ]);
      expect(totals.unread, 3);
      expect(totals.unreadIds, <String>['a']);
    });

    test('没有 lastContent 的会话不计入总未读（老端的怪条件）', () {
      final totals = ConversationRules.totals(<Conversation>[
        _conversation(id: 'a', unread: 3, lastContent: ''),
      ]);
      expect(totals.unread, 0);
      // 但红点还是会给它（unreadIds 的条件里没有 lastContent）
      expect(totals.unreadIds, <String>['a']);
    });

    test('@ 数不受免打扰影响（老端没判 is_notice）', () {
      final totals = ConversationRules.totals(<Conversation>[
        _conversation(id: 'a', isAt: 2, isNotice: 0),
      ]);
      expect(totals.at, 2);
      // 免打扰会话不给红点
      expect(totals.unreadIds, isEmpty);
    });

    test('有未读或有 @ 但开启了提醒 → 进 unreadIds', () {
      final totals = ConversationRules.totals(<Conversation>[
        _conversation(id: 'unread', unread: 1),
        _conversation(id: 'at', isAt: 1),
        _conversation(id: 'clean'),
      ]);
      expect(totals.unreadIds, <String>['unread', 'at']);
    });
  });

  group('预览文案（对应老端 getMsgType）', () {
    test('文本 / 位置 / 名片这类直接显示原文', () {
      for (final type in <String>['text', 'event', 'location', 'contact']) {
        final conversation = _conversation(lastType: type, lastContent: '原文');
        expect(
          ConversationRules.previewOf(conversation, translate: _t),
          '原文',
          reason: '$type 应显示原文',
        );
      }
    });

    test('图片/语音/视频等换成占位文案', () {
      expect(
        ConversationRules.previewOf(
          _conversation(lastType: 'image', lastContent: 'x'),
          translate: _t,
        ),
        '[common.image]',
      );
      expect(
        ConversationRules.previewOf(
          _conversation(lastType: 'voice'),
          translate: _t,
        ),
        '[common.voice]',
      );
      expect(
        ConversationRules.previewOf(
          _conversation(lastType: 'money'),
          translate: _t,
        ),
        '[common.nonsupportMsg]',
      );
    });

    test('通话类型：未知/视频/语音三种文案', () {
      expect(
        ConversationRules.preview(type: 'webrtc', translate: _t),
        '[common.webrtc]',
      );
      expect(
        ConversationRules.preview(
          type: 'webrtc',
          translate: _t,
          callVideo: true,
        ),
        '[common.videoCalling]',
      );
      expect(
        ConversationRules.preview(
          type: 'webrtc',
          translate: _t,
          callVideo: false,
        ),
        '[common.voiceCalling]',
      );
    });

    test('名片用的是正确的 i18n key（老端写的 common.IDcard 对不上语言包）', () {
      expect(
        ConversationRules.preview(type: 'contact', translate: _t),
        '[common.idcard]',
      );
    });

    test('音乐卡片（lingting）显示「[音乐]」，不把 content 里的长文字铺出来', () {
      expect(
        ConversationRules.preview(type: 'lingting', translate: _t),
        '[common.music]',
      );
      // 会话列表里也一样：lingting 不在 rawPreviewTypes 里，
      // 所以 lastContent（`[音乐] 《歌名》- 歌手`）不会直接铺到列表上
      expect(
        ConversationRules.previewOf(
          _conversation(lastType: 'lingting', lastContent: '[音乐] 《一粒麦子》- 小羊诗歌'),
          translate: _t,
        ),
        '[common.music]',
      );
    });
  });

  group('推送落会话（对应老端 appendMessage）', () {
    test('别人发来的消息：未读 +1，最后一条信息刷新', () {
      final result = ConversationRules.applyIncoming(
        existing: _conversation(id: 'u2', unread: 2, lastSendTime: 100),
        message: _message(content: '新消息', sendTime: 999),
        myUserId: 'me',
      );
      expect(result.unreadDelta, 1);
      expect(result.conversation.unread, 3);
      expect(result.conversation.lastContent, '新消息');
      expect(result.conversation.lastSendTime, 999);
    });

    test('自己发的消息：未读不变（老端 addUnread = 0）', () {
      final result = ConversationRules.applyIncoming(
        existing: _conversation(id: 'u2', unread: 5),
        message: _message(fromUserId: 'me'),
        myUserId: 'me',
      );
      expect(result.unreadDelta, 0);
      expect(result.conversation.unread, 5);
    });

    test('@ 到我就把 is_at +1', () {
      final result = ConversationRules.applyIncoming(
        existing: _conversation(id: 'g1', isAt: 1),
        message: _message(
          conversationId: 'g1',
          at: <String>['me', 'other'],
          isGroup: 1,
        ),
        myUserId: 'me',
      );
      expect(result.conversation.isAt, 2);
    });

    test('@ 的是别人则不加', () {
      final result = ConversationRules.applyIncoming(
        existing: _conversation(id: 'g1', isAt: 1),
        message: _message(conversationId: 'g1', at: <String>['other']),
        myUserId: 'me',
      );
      expect(result.conversation.isAt, 1);
    });

    test('没有会话时新建一条（用发送者信息 + 会话 id）', () {
      final result = ConversationRules.applyIncoming(
        existing: null,
        message: _message(conversationId: 'u9', fromUserId: 'u9'),
        myUserId: 'me',
      );
      expect(result.conversation.id, 'u9');
      expect(result.conversation.displayName, '小明');
      expect(result.conversation.avatar, 'a.png');
      expect(result.conversation.unread, 1);
      expect(result.conversation.isTop, 0);
      expect(result.conversation.lastType, 'text');
    });

    test('已有会话的置顶 / 免打扰 / 草稿不被推送覆盖', () {
      final existing = _conversation(
        id: 'u2',
        isTop: 1,
        isNotice: 0,
      ).copyWith(draft: '还没发完');
      final result = ConversationRules.applyIncoming(
        existing: existing,
        message: _message(conversationId: 'u2'),
        myUserId: 'me',
      );
      expect(result.conversation.isTop, 1);
      expect(result.conversation.isNotice, 0);
      expect(result.conversation.draft, '还没发完');
    });
  });

  group('会话便捷判断', () {
    test('系统会话 / 群聊 / 免打扰 / 管理权限', () {
      expect(const Conversation(id: 'system').isSystem, isTrue);
      expect(const Conversation(id: 'u1', isNotice: 0).muted, isTrue);
      expect(const Conversation(id: 'g1', role: 2).canModerate, isTrue);
      expect(const Conversation(id: 'g1', role: 3).canModerate, isFalse);
    });

    test('「我的收藏」「系统通知」的名字走语言包，其余照用服务端给的', () {
      // 这两个名字是**服务端用中文存下来的**：不翻译的话，切到英文界面时
      // 别的会话都变了，就这两行还是中文（用户 2026-09-27 指出的就是这个）。
      String en(String key) => switch (key) {
        'user.systemNotice' => 'System Notification',
        'user.myFavorites' => 'Favorites',
        _ => key,
      };

      expect(
        ConversationRules.displayNameOf(
          const Conversation(id: 'system', displayName: '系统通知'),
          translate: en,
        ),
        'System Notification',
      );
      expect(
        ConversationRules.displayNameOf(
          const Conversation(id: '-1', displayName: '我的收藏', isGroup: 3),
          translate: en,
        ),
        'Favorites',
      );
      // is_group == 2（系统通知）即使 id 不是 system 也算它 —— 老端那个字段的语义
      expect(
        ConversationRules.displayNameOf(
          const Conversation(id: 'u9', displayName: '某条公告', isGroup: 2),
          translate: en,
        ),
        'System Notification',
      );
      // is_group == 3 **但 id 不是 -1**：可能是应用号，别把人家名字换成「我的收藏」
      expect(
        ConversationRules.displayNameOf(
          const Conversation(id: 'app-1', displayName: '恩信助手', isGroup: 3),
          translate: en,
        ),
        '恩信助手',
      );
      // 普通人 / 群聊：服务端给什么用什么；没名字时退回 id
      expect(
        ConversationRules.displayNameOf(
          const Conversation(id: 'u1', displayName: '小明'),
          translate: en,
        ),
        '小明',
      );
      expect(
        ConversationRules.displayNameOf(
          const Conversation(id: 'u7'),
          translate: en,
        ),
        'u7',
      );
    });

    test('只有 is_group == 1 算群：2 系统通知、3 我的收藏都不是', () {
      // 老端 `is_group`：0 好友、1 群聊、2 系统通知、3 我的收藏/应用号。
      // 以前这里写 `!= 0`，于是「我的收藏」被当成群聊，聊天信息页上
      // 冒出了「群成员 0 人 / 群名称 我的收藏 / 群公告 暂无公告」。
      expect(const Conversation(id: 'g1', isGroup: 1).isGroupChat, isTrue);
      expect(const Conversation(id: 'u1', isGroup: 2).isGroupChat, isFalse);
      expect(const Conversation(id: '-1', isGroup: 3).isGroupChat, isFalse);
      expect(const Conversation(id: 'u1').isGroupChat, isFalse);
    });
  });
}
