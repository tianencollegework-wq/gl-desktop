import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/contact.dart';
import 'package:gracelinkim/domain/contacts/group_list.dart';

/// 群聊列表页（S5.1）的筛选、搜索、排序。
///
/// 过滤口径逐条对照老端 `pages/contacts/group.vue` 的 `filterGroup()`。
void main() {
  Contact grp(
    String id, {
    String name = '产品群',
    String index = 'C',
    String py = '',
    int role = 0,
    String ownerId = '',
    String account = '',
  }) => Contact(
    id: id,
    displayName: name,
    indexLetter: index,
    namePy: py,
    account: account,
    isGroup: 1,
    role: role,
    ownerId: ownerId,
  );

  final List<Contact> all = <Contact>[
    grp('g1', name: '我建的群', index: 'W', role: 1, ownerId: 'u1'),
    grp('g2', name: '我管的群', index: 'W', role: 2),
    grp('g3', name: '我加的群', index: 'W', role: 3),
    grp('g4', name: '别人类似群', index: 'B', role: 3),
  ];

  test('全部：一条不少', () {
    expect(
      filterGroups(all, GroupTab.all, myUserId: 'u1').map((g) => g.id),
      <String>['g1', 'g2', 'g3', 'g4'],
    );
  });

  test('我创建的看 owner_id（老端就是这一条，跟 role 无关）', () {
    // 一个 role 是 3 但我确实是 owner 的群，也应该出现
    final tricky = grp('g9', ownerId: 'u1', role: 3);
    expect(
      filterGroups(
        <Contact>[...all, tricky],
        GroupTab.created,
        myUserId: 'u1',
      ).map((g) => g.id),
      <String>['g1', 'g9'],
    );
  });

  test('我管理的看 role == 2；我加入的看 role == 3', () {
    expect(
      filterGroups(all, GroupTab.managed, myUserId: 'u1').map((g) => g.id),
      <String>['g2'],
    );
    expect(
      filterGroups(all, GroupTab.joined, myUserId: 'u1').map((g) => g.id),
      <String>['g3', 'g4'],
    );
  });

  test('role 认不出来（0）的群只在「全部」里出现', () {
    final unknown = grp('g5');
    expect(
      filterGroups(<Contact>[unknown], GroupTab.managed, myUserId: 'u1'),
      isEmpty,
    );
    expect(
      filterGroups(<Contact>[unknown], GroupTab.joined, myUserId: 'u1'),
      isEmpty,
    );
    expect(
      filterGroups(<Contact>[unknown], GroupTab.all, myUserId: 'u1').length,
      1,
    );
  });

  test('分段枚举的 id 与文案 key 照老端', () {
    expect(GroupTab.all.id, 'all');
    expect(GroupTab.created.id, '1');
    expect(GroupTab.managed.id, '2');
    expect(GroupTab.joined.id, '3');
    expect(GroupTab.values.map((tab) => tab.labelKey), <String>[
      'common.all',
      'group.iCreated',
      'group.iManaged',
      'group.iJoined',
    ]);
  });

  group('排序', () {
    test('按首字母升序，# 最后', () {
      final sorted = sortGroups(<Contact>[
        grp('a', index: 'B'),
        grp('b', index: '#'),
        grp('c', index: 'A'),
      ]);
      expect(sorted.map((g) => g.indexLetter).toList(), <String>[
        'A',
        'B',
        '#',
      ]);
    });

    test('同一字母保持接口给的顺序（Dart 的 sort 不保证稳定，这里自己钉）', () {
      final sorted = sortGroups(<Contact>[
        grp('a', index: 'C', name: '一'),
        grp('b', index: 'C', name: '二'),
        grp('c', index: 'C', name: '三'),
      ]);
      expect(sorted.map((g) => g.id).toList(), <String>['a', 'b', 'c']);
    });

    test('没有 index 时按拼音 / 英文名兜底，都认不出才归 # 排最后', () {
      final sorted = sortGroups(<Contact>[
        // 中文名 + 没给拼音 → 认不出字母，归 #
        grp('zh', name: '产品群', index: ''),
        // 英文名 → 名字首字母 B
        grp('en', name: 'Beta Group', index: ''),
        // 中文名但服务端给了拼音 → C
        grp('py', name: '中文名', index: '', py: 'chanpin'),
      ]);
      expect(sorted.map((g) => g.id).toList(), <String>['en', 'py', 'zh']);
    });
  });

  group('visibleGroups', () {
    test('没搜索词时按分段筛选', () {
      final visible = visibleGroups(all, tab: GroupTab.managed, myUserId: 'u1');
      expect(visible.map((g) => g.id).toList(), <String>['g2']);
    });

    test('有搜索词时忽略分段（老端把 type 归零，搜的是全部）', () {
      final visible = visibleGroups(
        all,
        tab: GroupTab.managed,
        myUserId: 'u1',
        keyword: '我加的',
      );
      expect(visible.map((g) => g.id).toList(), <String>['g3']);
    });

    test('搜索匹配名字 / 拼音 / 账号', () {
      final list = <Contact>[
        grp('g1', name: '公司大群', py: 'gongsidaqun', account: 'corp'),
        grp('g2', name: '同事群', py: 'tongshiqun', account: 'mates'),
      ];
      expect(
        visibleGroups(
          list,
          tab: GroupTab.all,
          myUserId: 'u1',
          keyword: '公司',
        ).map((g) => g.id),
        <String>['g1'],
      );
      expect(
        visibleGroups(
          list,
          tab: GroupTab.all,
          myUserId: 'u1',
          keyword: 'tongshi',
        ).map((g) => g.id),
        <String>['g2'],
      );
      expect(
        visibleGroups(
          list,
          tab: GroupTab.all,
          myUserId: 'u1',
          keyword: 'MATES',
        ).map((g) => g.id),
        <String>['g2'],
      );
    });

    test('搜索词只有空格时当没搜（不会筛成空）', () {
      expect(
        visibleGroups(
          all,
          tab: GroupTab.all,
          myUserId: 'u1',
          keyword: '   ',
        ).length,
        4,
      );
    });

    test('结果一律是排好序的', () {
      final visible = visibleGroups(
        <Contact>[grp('z', index: '#'), grp('a', index: 'A')],
        tab: GroupTab.all,
        myUserId: 'u1',
      );
      expect(visible.map((g) => g.id).toList(), <String>['a', 'z']);
    });
  });
}
