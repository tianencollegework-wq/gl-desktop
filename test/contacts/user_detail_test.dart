import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/user_detail.dart';
import 'package:gracelinkim/domain/contacts/user_detail_actions.dart';

/// 用户详情（S5.2）：解析、性别、手机号判定、底部按钮的可见性。
///
/// 按钮那几个条件是老端 `detail.vue` 里几处 `v-if` 的合体，容易改错，全部钉一遍。
void main() {
  Map<String, dynamic> json({
    String userId = 'u2',
    String realname = '小明',
    String account = '13800000000',
    int sex = 1,
    Map<String, dynamic>? friend,
    Map<String, dynamic>? contactInfo,
    Map<String, dynamic>? groupInfo,
  }) => <String, dynamic>{
    'user_id': userId,
    'realname': realname,
    'account': account,
    'avatar': 'https://cdn.test/$userId.png',
    'email': 'u2@example.test',
    'sex': sex,
    'last_login_ip': '1.2.3.4',
    'location': '广东深圳',
    'friend': ?friend,
    'contactInfo': ?contactInfo,
    'groupInfo': ?groupInfo,
  };

  group('解析', () {
    test('好友：friend 里有 friend_id 与备注', () {
      final detail = UserDetail.fromServerJson(
        json(friend: <String, dynamic>{'friend_id': 2, 'nickname': '小明明'}),
      );

      expect(detail.userId, 'u2');
      expect(detail.realName, '小明');
      expect(detail.account, '13800000000');
      expect(detail.email, 'u2@example.test');
      expect(detail.sex, 1);
      expect(detail.lastLoginIp, '1.2.3.4');
      expect(detail.location, '广东深圳');
      expect(detail.isFriend, isTrue);
      expect(detail.friendId, '2');
      expect(detail.nickname, '小明明');
      // 会话里显示备注，详情页标题显示真名
      expect(detail.displayName, '小明明');
      expect(detail.title, '小明');
    });

    test('不是好友：friend 缺失，备注是空串、friendId 退到 user_id', () {
      final detail = UserDetail.fromServerJson(json());

      expect(detail.isFriend, isFalse);
      expect(detail.nickname, '');
      expect(detail.friendId, 'u2');
      expect(detail.displayName, '小明');
    });

    test('真名缺失时用 user_id 当标题（不会出现空白）', () {
      final detail = UserDetail.fromServerJson(json(realname: ''));
      expect(detail.title, 'u2');
    });

    test('没有 IP 信息时 hasIpInfo 是 false', () {
      final detail = UserDetail.fromServerJson(<String, dynamic>{
        'user_id': 'u2',
        'last_login_ip': '',
        'location': '',
      });
      expect(detail.hasIpInfo, isFalse);
    });
  });

  group('toContact', () {
    test('contactInfo 有值就用它的名字与头像（服务端给的会话口径）', () {
      final detail = UserDetail.fromServerJson(
        json(
          contactInfo: <String, dynamic>{
            'id': 'u2',
            'displayName': '备注优先',
            'avatar': 'https://cdn.test/other.png',
            'is_group': 0,
          },
        ),
      );

      final contact = detail.toContact();
      expect(contact.id, 'u2');
      expect(contact.displayName, '备注优先');
      expect(contact.avatar, 'https://cdn.test/other.png');
    });

    test('contactInfo 缺失也能造出联系人（id 用 user_id 兜底）', () {
      final detail = UserDetail.fromServerJson(
        json(friend: <String, dynamic>{'nickname': '小明明'}),
      );

      final contact = detail.toContact();
      expect(contact.id, 'u2');
      // 备注优先
      expect(contact.displayName, '小明明');
      expect(contact.avatar, 'https://cdn.test/u2.png');
      expect(contact.isGroup, 0);
    });
  });

  test('手机号判定照老端正则（1[3456789] 开头 11 位）', () {
    expect(isMobileAccount('13800000000'), isTrue);
    expect(isMobileAccount(' 15012345678 '), isTrue);
    expect(isMobileAccount('12800000000'), isFalse);
    expect(isMobileAccount('1380000000'), isFalse);
    expect(isMobileAccount('138000000000'), isFalse);
    expect(isMobileAccount('u3'), isFalse);
    expect(isMobileAccount(''), isFalse);
  });

  test('性别文案：0 女、1 男，其它未知', () {
    expect(sexLabelKey(0), 'common.women');
    expect(sexLabelKey(1), 'common.man');
    expect(sexLabelKey(2), 'common.unknown');
    expect(sexLabelKey(-1), 'common.unknown');
  });

  group('按钮可见性', () {
    UserDetail detail({
      bool friend = true,
      bool mobile = true,
      String userId = 'u2',
    }) => UserDetail.fromServerJson(
      json(
        userId: userId,
        account: mobile ? '13800000000' : 'u2',
        friend: friend
            ? <String, dynamic>{'friend_id': 2, 'nickname': ''}
            : null,
      ),
    );

    test('runMode 2 + 已是好友：发消息 / 打电话 / 音视频 / 删好友，没有加好友', () {
      final actions = userDetailActionsOf(
        detail: detail(),
        myUserId: 'u1',
        runMode: 2,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      expect(actions.sendMessage, isTrue);
      expect(actions.callPhone, isTrue);
      expect(actions.webrtc, isTrue);
      expect(actions.deleteFriend, isTrue);
      expect(actions.addFriend, isFalse);
      expect(actions.hasChatBlock, isTrue);
    });

    test('runMode 2 + 不是好友：只有加好友', () {
      final actions = userDetailActionsOf(
        detail: detail(friend: false),
        myUserId: 'u1',
        runMode: 2,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      expect(actions.sendMessage, isFalse);
      expect(actions.callPhone, isFalse);
      expect(actions.webrtc, isFalse);
      expect(actions.deleteFriend, isFalse);
      expect(actions.addFriend, isTrue);
    });

    test('runMode 1（无好友体系）：不是好友也能聊、能打电话，但没有加/删好友', () {
      final actions = userDetailActionsOf(
        detail: detail(friend: false),
        myUserId: 'u1',
        runMode: 1,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      expect(actions.sendMessage, isTrue);
      expect(actions.callPhone, isTrue);
      expect(actions.deleteFriend, isFalse);
      expect(actions.addFriend, isFalse);
    });

    test('账号不是手机号就没有「打电话」', () {
      final actions = userDetailActionsOf(
        detail: detail(mobile: false),
        myUserId: 'u1',
        runMode: 2,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      expect(actions.sendMessage, isTrue);
      expect(actions.callPhone, isFalse);
    });

    test('音视频要两个开关都开（老端 `webrtc && simpleChat`）', () {
      for (final on in <bool>[true, false]) {
        expect(
          userDetailActionsOf(
            detail: detail(),
            myUserId: 'u1',
            runMode: 2,
            webrtcEnabled: on,
            simpleChatEnabled: false,
          ).webrtc,
          isFalse,
        );
        expect(
          userDetailActionsOf(
            detail: detail(),
            myUserId: 'u1',
            runMode: 2,
            webrtcEnabled: false,
            simpleChatEnabled: on,
          ).webrtc,
          isFalse,
        );
      }
    });

    test('自己的详情页一个按钮都没有（老端外层那个 user_id != 判断）', () {
      final actions = userDetailActionsOf(
        detail: detail(userId: 'u1'),
        myUserId: 'u1',
        runMode: 2,
        webrtcEnabled: true,
        simpleChatEnabled: true,
      );

      expect(actions.sendMessage, isFalse);
      expect(actions.callPhone, isFalse);
      expect(actions.webrtc, isFalse);
      expect(actions.addFriend, isFalse);
      expect(actions.deleteFriend, isFalse);
      expect(actions.hasChatBlock, isFalse);
    });

    test('本地还不知道自己是谁时不误判成「自己」', () {
      final actions = userDetailActionsOf(
        detail: detail(),
        myUserId: '',
        runMode: 2,
      );

      expect(actions.sendMessage, isTrue);
    });
  });
}
