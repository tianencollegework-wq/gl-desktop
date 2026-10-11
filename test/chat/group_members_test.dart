import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/domain/chat/group_members.dart';

/// 群成员与 @ 提及（S4.4c）。
///
/// 对照老端 `user-select.vue`（type 4 分支）与 `im-input.vue`（`at()` /
/// `sendTextMsg()` 里的 `edit.getLink()`）。
void main() {
  List<Map<String, dynamic>> rawList() => <Map<String, dynamic>>[
    <String, dynamic>{
      'role': 1,
      'userInfo': <String, dynamic>{
        'id': 'u1',
        'displayName': '群主',
        'avatar': 'https://a.test/1.png',
        'name_py': 'qunzhu',
      },
    },
    <String, dynamic>{
      'role': 2,
      'userInfo': <String, dynamic>{
        'id': 2,
        'displayName': '管理员',
        'name_py': 'guanliyuan',
      },
    },
    <String, dynamic>{
      'role': 3,
      'userInfo': <String, dynamic>{'id': 'u3', 'displayName': '小明'},
    },
  ];

  group('解析成员列表', () {
    test('照 userInfo 取字段，role 一起带上', () {
      final members = parseGroupMembers(rawList());
      expect(members, hasLength(3));
      expect(members[0].userId, 'u1');
      expect(members[0].name, '群主');
      expect(members[0].avatar, 'https://a.test/1.png');
      expect(members[0].namePy, 'qunzhu');
      expect(members[0].isOwner, isTrue);
      expect(members[1].userId, '2', reason: '数字 id 也要转成字符串');
      expect(members[1].isManager, isTrue);
      expect(members[2].role, 3);
    });

    test('缺 userInfo / 没有 id 的项跳过（老端这里会整张表炸掉）', () {
      final members = parseGroupMembers(<Map<String, dynamic>>[
        <String, dynamic>{'role': 3},
        <String, dynamic>{
          'role': 3,
          'userInfo': <String, dynamic>{'displayName': '没有 id'},
        },
        <String, dynamic>{
          'role': 3,
          'userInfo': <String, dynamic>{'id': 'u9', 'displayName': '正常'},
        },
      ]);
      expect(members, hasLength(1));
      expect(members.single.userId, 'u9');
    });

    test('排除自己（老端 filter 掉了「我」）', () {
      final members = parseGroupMembers(rawList(), excludeUserId: 'u1');
      expect(members.map((m) => m.userId), <String>['2', 'u3']);
    });

    test('@ 所有人的入口只有群主/管理员有', () {
      final members = parseGroupMembers(rawList());
      expect(members[0].canAtAll, isTrue);
      expect(members[1].canAtAll, isTrue);
      expect(members[2].canAtAll, isFalse);
    });
  });

  group('搜索成员', () {
    final members = parseGroupMembers(rawList());

    test('空关键词原样返回', () {
      expect(searchMembers(members, '  '), members);
    });

    test('按名字与拼音匹配（老端 searchObject 的两个字段）', () {
      expect(searchMembers(members, '小明').single.userId, 'u3');
      expect(searchMembers(members, 'guanli').single.userId, '2');
      expect(searchMembers(members, '不存在的'), isEmpty);
    });
  });

  group('发送时的 at 数组', () {
    final members = parseGroupMembers(rawList());
    final all = GroupMember(userId: atAllUserId, name: '所有人');

    test('文本里还留着的 @ 才算（老端从富文本 link 节点里抓）', () {
      expect(resolveAt('你好 @小明 ', <GroupMember>[members[2]]), <String>['u3']);
      expect(resolveAt('你好（@ 被删了）', <GroupMember>[members[2]]), isEmpty);
    });

    test('@ 所有人也按文本判断，不会自己冒出来', () {
      expect(resolveAt('@所有人 开会', <GroupMember>[all]), <String>['0']);
      expect(resolveAt('开会', <GroupMember>[all]), isEmpty);
    });

    test('同一个 id 不重复', () {
      expect(
        resolveAt('@小明 @小明 ', <GroupMember>[members[2], members[2]]),
        <String>['u3'],
      );
    });

    test('没选人就是空数组', () {
      expect(resolveAt('@小明', const <GroupMember>[]), isEmpty);
    });
  });
}
