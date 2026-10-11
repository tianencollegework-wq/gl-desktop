import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/contact.dart';
import 'package:gracelinkim/domain/contacts/contact_index.dart';

/// 通讯录的分组与索引（S5.1）。
///
/// 老端完全依赖服务端给的 `index`；新端多两道兜底（`name_py` → 名字首字母），
/// 所以这里把三级口径逐条钉死，包括「中文名没有任何拼音字段 → `#`」这个边界。
void main() {
  Contact friend(
    String id, {
    String displayName = '',
    String realName = '',
    String index = '',
    String py = '',
    String account = '',
    int isGroup = 0,
    int isOnline = 0,
  }) => Contact(
    id: id,
    displayName: displayName,
    realName: realName,
    indexLetter: index,
    namePy: py,
    account: account,
    isGroup: isGroup,
    isOnline: isOnline,
  );

  group('首字母的三级兜底', () {
    test('服务端给了 index 就用它（大小写归一）', () {
      expect(contactIndexLetter(friend('u1', index: 'l')), 'L');
      expect(contactIndexLetter(friend('u1', index: ' L ')), 'L');
      expect(contactIndexLetter(friend('u1', index: '#')), '#');
    });

    test('没有 index 就用 name_py 的首字母', () {
      expect(contactIndexLetter(friend('u1', py: 'xiaoming')), 'X');
      expect(contactIndexLetter(friend('u1', py: 'Zhang San')), 'Z');
    });

    test('两个都没有就看名字本身是不是英文开头', () {
      expect(contactIndexLetter(friend('u1', displayName: 'Alice')), 'A');
      expect(
        contactIndexLetter(friend('u1', displayName: 'alice')),
        'a'.toUpperCase(),
      );
      expect(contactIndexLetter(friend('u1', realName: 'Bob')), 'B');
    });

    test('中文名没有任何拼音字段 → 归到 #（本地不算拼音，跟服务端走）', () {
      expect(contactIndexLetter(friend('u1', displayName: '小明')), '#');
      expect(contactIndexLetter(friend('u1', displayName: '123')), '#');
      expect(contactIndexLetter(friend('u1')), '#');
    });

    test('脏数据：index 是数字/符号时继续往下兜', () {
      expect(contactIndexLetter(friend('u1', index: '2', py: 'lihua')), 'L');
      expect(
        contactIndexLetter(friend('u1', index: '·', displayName: 'Coco')),
        'C',
      );
    });
  });

  group('分组', () {
    test('A–Z 升序，# 永远最后', () {
      final groups = groupByIndex(<Contact>[
        friend('u1', displayName: 'Bob'),
        friend('u2', displayName: '小明'),
        friend('u3', displayName: 'Alice'),
        friend('u4', displayName: 'Zoe'),
      ]);
      expect(groups.map((group) => group.name).toList(), <String>[
        'A',
        'B',
        'Z',
        '#',
      ]);
      expect(groups.last.children.single.displayName, '小明');
    });

    test('同一组内保持接口返回的顺序（老端的比较器对同 index 返回 0）', () {
      final groups = groupByIndex(<Contact>[
        friend('u3', displayName: 'Zoe'),
        friend('u1', displayName: 'Zed'),
        friend('u2', displayName: 'Zack'),
      ]);
      expect(groups.single.children.map((item) => item.id).toList(), <String>[
        'u3',
        'u1',
        'u2',
      ]);
    });

    test('空列表得到空分组，不抛异常', () {
      expect(groupByIndex(const <Contact>[]), isEmpty);
      expect(indexBarLetters(const <ContactGroup>[]), isEmpty);
    });

    test('索引条的字母就是分组名（顺序一致）', () {
      final groups = groupByIndex(<Contact>[
        friend('u1', displayName: 'Coco'),
        friend('u2', displayName: '小明'),
        friend('u3', displayName: 'Ann'),
      ]);
      expect(indexBarLetters(groups), <String>['A', 'C', '#']);
    });
  });

  group('计数与定位', () {
    test('底部「N 个朋友」只数好友', () {
      expect(
        friendCount(<Contact>[
          friend('u1'),
          friend('u2'),
          friend('g1', isGroup: 1),
          friend('system', isGroup: 2),
        ]),
        2,
      );
    });

    test('按 id 能找到它在第几组第几个', () {
      final groups = groupByIndex(<Contact>[
        friend('u1', displayName: 'Ann'),
        friend('u2', displayName: 'Bob'),
        friend('u3', displayName: 'Ben'),
      ]);
      expect(locateContact(groups, 'u3'), (group: 1, child: 1));
      expect(locateContact(groups, 'u1'), (group: 0, child: 0));
      expect(locateContact(groups, 'nobody'), isNull);
    });
  });

  group('搜索', () {
    final list = <Contact>[
      friend('u1', displayName: '小明', py: 'xiaoming', account: 'xiaoming01'),
      friend('u2', displayName: 'Alice', py: 'alice', account: 'alice@a.com'),
      friend('u3', realName: '张三', py: 'zhangsan'),
    ];

    test('空关键词原样返回', () {
      expect(searchContacts(list, '   '), list);
    });

    test('名字 / 拼音 / 账号 / 真名都能命中，且忽略大小写', () {
      expect(searchContacts(list, '小明').single.id, 'u1');
      expect(searchContacts(list, 'XIAO').single.id, 'u1');
      expect(searchContacts(list, 'alice@').single.id, 'u2');
      expect(searchContacts(list, '张三').single.id, 'u3');
      expect(searchContacts(list, 'zhang').single.id, 'u3');
      expect(searchContacts(list, '没这个人'), isEmpty);
    });
  });
}
