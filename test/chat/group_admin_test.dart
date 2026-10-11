import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/domain/chat/group_admin.dart';
import 'package:gracelinkim/domain/chat/group_members.dart';

/// 群管理（S5.3）：角色、权限、成员操作能不能点、禁言时长与到期文案。
void main() {
  GroupMember member(
    String id, {
    int role = groupRoleMember,
    int noSpeakTime = 0,
    int noSpeakDays = 0,
  }) => GroupMember(
    userId: id,
    name: id,
    role: role,
    noSpeakTime: noSpeakTime,
    noSpeakDays: noSpeakDays,
  );

  test('角色文案：群主 / 管理员 / 成员', () {
    expect(roleLabelKey(groupRoleOwner), 'group.owner');
    expect(roleLabelKey(groupRoleManager), 'group.manage');
    expect(roleLabelKey(groupRoleMember), 'group.user');
    expect(roleLabelKey(0), 'group.user');
  });

  group('权限判定', () {
    test('我是群主', () {
      final permissions = groupPermissionsOf(<GroupMember>[
        member('u1', role: groupRoleOwner),
        member('u2'),
      ], 'u1');

      expect(permissions.isOwner, isTrue);
      expect(permissions.isManager, isFalse);
      expect(permissions.isAuth, isTrue);
    });

    test('我是管理员', () {
      final permissions = groupPermissionsOf(<GroupMember>[
        member('u2', role: groupRoleOwner),
        member('u1', role: groupRoleManager),
      ], 'u1');

      expect(permissions.isOwner, isFalse);
      expect(permissions.isManager, isTrue);
      expect(permissions.isAuth, isTrue);
    });

    test('普通成员 / 不在群里 / 不知道我是谁 → 没有权限', () {
      expect(
        groupPermissionsOf(<GroupMember>[member('u1')], 'u1').isAuth,
        isFalse,
      );
      expect(
        groupPermissionsOf(<GroupMember>[member('u2')], 'u1').isAuth,
        isFalse,
      );
      expect(
        groupPermissionsOf(<GroupMember>[
          member('u1', role: groupRoleOwner),
        ], '').isAuth,
        isFalse,
      );
    });
  });

  group('成员操作入口', () {
    final owner = GroupPermissions(isOwner: true);
    final manager = GroupPermissions(isManager: true);

    test('群主可以操作普通成员与管理员，但不能动自己', () {
      expect(
        canOpenMemberOptions(
          member: member('u2'),
          myUserId: 'u1',
          permissions: owner,
        ),
        isTrue,
      );
      expect(
        canOpenMemberOptions(
          member: member('u2', role: groupRoleManager),
          myUserId: 'u1',
          permissions: owner,
        ),
        isTrue,
      );
      expect(
        canOpenMemberOptions(
          member: member('u1', role: groupRoleOwner),
          myUserId: 'u1',
          permissions: owner,
        ),
        isFalse,
      );
    });

    test('管理员能操作普通成员，但动不了群主、也不动自己（刻意与老端不同）', () {
      expect(
        canOpenMemberOptions(
          member: member('u3'),
          myUserId: 'u1',
          permissions: manager,
        ),
        isTrue,
      );
      expect(
        canOpenMemberOptions(
          member: member('u2', role: groupRoleOwner),
          myUserId: 'u1',
          permissions: manager,
        ),
        isFalse,
      );
      expect(
        canOpenMemberOptions(
          member: member('u1', role: groupRoleManager),
          myUserId: 'u1',
          permissions: manager,
        ),
        isFalse,
      );
    });

    test('普通成员一个入口都没有', () {
      expect(
        canOpenMemberOptions(
          member: member('u2'),
          myUserId: 'u1',
          permissions: const GroupPermissions(),
        ),
        isFalse,
      );
    });

    test('role 认不出来（0）的成员不给操作', () {
      expect(
        canOpenMemberOptions(
          member: member('u2', role: 0),
          myUserId: 'u1',
          permissions: owner,
        ),
        isFalse,
      );
    });

    test('转让/管理员/禁言只有群主有；移出看能不能打开菜单', () {
      final forOwner = memberActionsOf(
        member: member('u2'),
        myUserId: 'u1',
        permissions: owner,
      );
      expect(forOwner.changeOwner, isTrue);
      expect(forOwner.toggleManager, isTrue);
      expect(forOwner.noSpeak, isTrue);
      expect(forOwner.remove, isTrue);

      final forManager = memberActionsOf(
        member: member('u2'),
        myUserId: 'u1',
        permissions: manager,
      );
      expect(forManager.changeOwner, isFalse);
      expect(forManager.toggleManager, isFalse);
      expect(forManager.noSpeak, isFalse);
      expect(forManager.remove, isTrue);
    });
  });

  group('禁言参数', () {
    test('选预设：noSpeakTimer 是预设号，noSpeakDay 是 1', () {
      expect(
        noSpeakPayload(
          groupId: 'g1',
          userId: 'u2',
          choice: const NoSpeakChoice.preset(3),
        ),
        <String, Object>{
          'id': 'g1',
          'user_id': 'u2',
          'noSpeakDay': 1,
          'noSpeakTimer': 3,
        },
      );
    });

    test('自定义天数：noSpeakTimer 是 0', () {
      final payload = noSpeakPayload(
        groupId: 'g1',
        userId: 'u2',
        choice: const NoSpeakChoice.custom(30),
      );

      expect(payload['noSpeakTimer'], 0);
      expect(payload['noSpeakDay'], 30);
    });

    test('天数会被夹在老端那个数字框的范围里（1..365）', () {
      expect(const NoSpeakChoice.custom(0).clampedDays, 1);
      expect(const NoSpeakChoice.custom(999).clampedDays, 365);
    });

    test('取消禁言：两个字段都是 0', () {
      expect(noSpeakPayload(groupId: 'g1', userId: 'u2'), <String, Object>{
        'id': 'g1',
        'user_id': 'u2',
        'noSpeakDay': 0,
        'noSpeakTimer': 0,
      });
    });

    test('四个预设的 id 与文案键照老端', () {
      expect(noSpeakPresets.map((preset) => preset.id).toList(), <int>[
        1,
        2,
        3,
        4,
      ]);
      expect(noSpeakPresets.map((preset) => preset.labelKey).toList(), <String>[
        'common.tenM',
        'common.oneHour',
        'common.threeHour',
        'common.oneDay',
      ]);
    });
  });

  group('禁言到期文案', () {
    final now = DateTime(2026, 9, 19, 12, 0);

    test('还没到期 → m-d H:i', () {
      final expiry =
          DateTime(2026, 9, 20, 8, 30).millisecondsSinceEpoch ~/ 1000;
      expect(noSpeakExpiryLabel(expiry, now: now), '09-20 08:30');
    });

    test('已经过期 → 空串（老端返回 false，界面上什么都不显示）', () {
      final past = DateTime(2026, 9, 18, 8, 30).millisecondsSinceEpoch ~/ 1000;
      expect(noSpeakExpiryLabel(past, now: now), '');
    });

    test('0 / 负数 → 空串', () {
      expect(noSpeakExpiryLabel(0, now: now), '');
      expect(noSpeakExpiryLabel(-1, now: now), '');
    });

    test('服务端要是某天改成毫秒也不会算成 1970 年', () {
      final expiry = DateTime(2026, 9, 20, 8, 30).millisecondsSinceEpoch;
      expect(noSpeakExpiryLabel(expiry, now: now), '09-20 08:30');
    });
  });
}
