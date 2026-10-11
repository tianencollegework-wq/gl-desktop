import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/domain/chat/user_group_manage.dart';

/// 用户详情页「群内管理」块的显示条件（老端 `pages/contacts/detail.vue`）。
void main() {
  Map<String, dynamic> groupInfo({
    Object? manageRole = 1,
    String ownerId = 'u1',
    Object? targetRole = 3,
    Object? noSpeakTime = 0,
    Object? noSpeakDay = 0,
    String name = '产品群',
  }) => <String, dynamic>{
    'name': name,
    'owner_id': ownerId,
    'manageRole': manageRole,
    'userInfo': <String, dynamic>{
      'role': targetRole,
      'no_speak_time': noSpeakTime,
      'no_speak_day': noSpeakDay,
    },
  };

  test('我是群主、对方是普通成员：整块都在，能设管理员', () {
    final block = userGroupManageBlockOf(
      groupInfo: groupInfo(),
      targetUserId: 'u2',
      myUserId: 'u1',
    );
    expect(block, isNotNull);
    expect(block!.groupName, '产品群');
    expect(block.roleLabelKeyOrEmpty, 'group.user');
    expect(block.targetIsManager, isFalse);
    expect(block.canToggleManager, isTrue);
    expect(block.mutedUntil, '');
  });

  test('我是管理员（manageRole=2）：块在，但没有「设为管理员」那行', () {
    final block = userGroupManageBlockOf(
      groupInfo: groupInfo(manageRole: 2, ownerId: 'u9'),
      targetUserId: 'u2',
      myUserId: 'u1',
    );
    expect(block, isNotNull);
    expect(block!.canToggleManager, isFalse);
  });

  test('我是普通成员（manageRole=3）：不显示整块', () {
    expect(
      userGroupManageBlockOf(
        groupInfo: groupInfo(manageRole: 3),
        targetUserId: 'u2',
        myUserId: 'u1',
      ),
      isNull,
    );
  });

  test('服务端没给 manageRole：不显示（老端 undefined < 3 也是假）', () {
    expect(
      userGroupManageBlockOf(
        groupInfo: groupInfo(manageRole: null),
        targetUserId: 'u2',
        myUserId: 'u1',
      ),
      isNull,
    );
  });

  test('对方就是群主：不显示（群主不能被禁言 / 移出）', () {
    expect(
      userGroupManageBlockOf(
        groupInfo: groupInfo(ownerId: 'u2', targetRole: 1),
        targetUserId: 'u2',
        myUserId: 'u1',
      ),
      isNull,
    );
  });

  test('不是从群成员点进来的（没有 groupInfo）：不显示', () {
    expect(
      userGroupManageBlockOf(
        groupInfo: const <String, dynamic>{},
        targetUserId: 'u2',
        myUserId: 'u1',
      ),
      isNull,
    );
  });

  test('对方是管理员：角色文案与「取消管理员」按钮', () {
    final block = userGroupManageBlockOf(
      groupInfo: groupInfo(targetRole: 2),
      targetUserId: 'u2',
      myUserId: 'u1',
    );
    expect(block!.roleLabelKeyOrEmpty, 'group.manage');
    expect(block.targetIsManager, isTrue);
  });

  test('认不出来的角色：角色那一行留空（老端三个 v-if 都不命中）', () {
    final block = userGroupManageBlockOf(
      groupInfo: groupInfo(targetRole: 0),
      targetUserId: 'u2',
      myUserId: 'u1',
    );
    expect(block!.roleLabelKeyOrEmpty, isEmpty);
  });

  test('正被禁言：「禁言至」按秒级时间戳算出来', () {
    final now = DateTime(2026, 9, 19, 12);
    final block = userGroupManageBlockOf(
      groupInfo: groupInfo(
        noSpeakTime:
            now.add(const Duration(hours: 2)).millisecondsSinceEpoch ~/ 1000,
      ),
      targetUserId: 'u2',
      myUserId: 'u1',
      now: now,
    );
    expect(block!.mutedUntil, '09-19 14:00');
  });

  test('禁言已过期：不算禁言中', () {
    final now = DateTime(2026, 9, 19, 12);
    final block = userGroupManageBlockOf(
      groupInfo: groupInfo(
        noSpeakTime:
            now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch ~/
            1000,
      ),
      targetUserId: 'u2',
      myUserId: 'u1',
      now: now,
    );
    expect(block!.mutedUntil, isEmpty);
  });

  test('服务端把角色发成字符串（"2"）也认', () {
    final block = userGroupManageBlockOf(
      groupInfo: groupInfo(manageRole: '2', targetRole: '2', ownerId: 'u9'),
      targetUserId: 'u2',
      myUserId: 'u1',
    );
    expect(block!.targetIsManager, isTrue);
  });
}
