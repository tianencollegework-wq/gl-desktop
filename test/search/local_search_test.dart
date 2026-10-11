import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/contact.dart';
import 'package:gracelinkim/domain/search/local_search.dart';
import 'package:gracelinkim/domain/search/user_search.dart';

/// 本地搜索（S5.4）的纯逻辑。
void main() {
  Contact contact(
    String id, {
    String name = '小明',
    String realname = '',
    String py = 'xiaoming',
    String account = '',
    int isGroup = 0,
  }) => Contact(
    id: id,
    displayName: name,
    realName: realname,
    namePy: py,
    account: account,
    isGroup: isGroup,
  );

  final List<Contact> contacts = <Contact>[
    contact('u2', name: '小明', py: 'xiaoming', account: 'ming123'),
    contact('u3', name: '小明他妈', py: 'xiaomingtama', account: 'mama'),
    contact('u4', name: 'Alice', py: 'alice', account: 'alice_1'),
    contact('g1', name: '产品群', py: 'chanpin', account: 'prod', isGroup: 1),
    contact('g2', name: '小明的群', py: 'xiaomingde', isGroup: 1),
    contact('system', name: '系统通知', isGroup: 2),
  ];

  group('入口类型', () {
    test('按老端的 options.type 认，认不出来当全局搜索', () {
      expect(LocalSearchType.fromValue('1'), LocalSearchType.all);
      expect(LocalSearchType.fromValue('2'), LocalSearchType.contacts);
      expect(LocalSearchType.fromValue('3'), LocalSearchType.groups);
      // 老端 `onLoad` 没传 type 时 `options.type` 是 undefined
      expect(LocalSearchType.fromValue(null), LocalSearchType.all);
      expect(LocalSearchType.fromValue('9'), LocalSearchType.all);
    });

    test('标题与「好友段要不要显示」逐条照老端', () {
      expect(LocalSearchType.all.titleKey, 'common.search');
      expect(LocalSearchType.contacts.titleKey, 'common.searchContacts');
      expect(LocalSearchType.groups.titleKey, 'common.searchGroup');
      // 老端 `v-if="type<3"`，只有 type=3 不显示好友段
      expect(LocalSearchType.all.showFriends, isTrue);
      expect(LocalSearchType.contacts.showFriends, isTrue);
      expect(LocalSearchType.groups.showFriends, isFalse);
    });
  });

  group('本地搜索', () {
    test('按名字/拼音/账号匹配，好友与群聊分两段', () {
      final results = localSearch(contacts, '小明', type: LocalSearchType.all);
      expect(results.friends.map((item) => item.id), <String>['u2', 'u3']);
      expect(results.groups.map((item) => item.id), <String>['g2']);
      expect(results.total, 3);
    });

    test('拼音与账号都能搜到', () {
      expect(
        localSearch(
          contacts,
          'chanpin',
          type: LocalSearchType.all,
        ).groups.map((item) => item.id),
        <String>['g1'],
      );
      expect(
        localSearch(
          contacts,
          'alice_1',
          type: LocalSearchType.all,
        ).friends.map((item) => item.id),
        <String>['u4'],
      );
    });

    test('忽略大小写（老端是 indexOf，大小写敏感；新端统一小写）', () {
      expect(
        localSearch(
          contacts,
          'ALICE',
          type: LocalSearchType.all,
        ).friends.map((item) => item.id),
        <String>['u4'],
      );
    });

    test('type=3 只搜群：好友段恒空', () {
      final results = localSearch(contacts, '小明', type: LocalSearchType.groups);
      expect(results.friends, isEmpty);
      expect(results.groups.map((item) => item.id), <String>['g2']);
    });

    test('type=2 与 type=1 的搜索结果一样（区别只在标题和点行去哪）', () {
      final all = localSearch(contacts, '小明', type: LocalSearchType.all);
      final contactsOnly = localSearch(
        contacts,
        '小明',
        type: LocalSearchType.contacts,
      );
      expect(all.friends.length, contactsOnly.friends.length);
      expect(all.groups.length, contactsOnly.groups.length);
    });

    test('系统通知会话（is_group=2）既不算好友也不算群', () {
      final results = localSearch(contacts, '系统', type: LocalSearchType.all);
      expect(results.isEmpty, isTrue);
    });

    test('空关键词（或只有空格）两个分段都空', () {
      expect(
        localSearch(contacts, '', type: LocalSearchType.all).isEmpty,
        isTrue,
      );
      expect(
        localSearch(contacts, '   ', type: LocalSearchType.all).isEmpty,
        isTrue,
      );
    });

    test('搜不到就是空（不是「全部」）', () {
      expect(
        localSearch(contacts, '不存在的人', type: LocalSearchType.all).isEmpty,
        isTrue,
      );
    });
  });

  group('搜人结果的解析', () {
    test('字段口径：user_id / realname / avatar / friend', () {
      final results = parseUserSearch(<Map<String, dynamic>>[
        <String, dynamic>{
          'user_id': 'u9',
          'realname': '张三',
          'avatar': 'https://cdn.test/u9.png',
          'friend': 1,
        },
        <String, dynamic>{
          'user_id': 'u10',
          'realname': '李四',
          'avatar': '',
          'friend': 0,
        },
      ]);

      expect(results, hasLength(2));
      expect(results[0].userId, 'u9');
      expect(results[0].realName, '张三');
      expect(results[0].isFriend, isTrue);
      expect(results[1].isFriend, isFalse);
      // 会话 id 就是对方的 user_id
      expect(results[0].conversationId, 'u9');
    });

    test('friend 是布尔或字符串都能认（老端是松散判断）', () {
      expect(
        parseUserSearch(<Map<String, dynamic>>[
          <String, dynamic>{'user_id': 'u1', 'friend': true},
        ]).single.isFriend,
        isTrue,
      );
      expect(
        parseUserSearch(<Map<String, dynamic>>[
          <String, dynamic>{'user_id': 'u1', 'friend': '1'},
        ]).single.isFriend,
        isTrue,
      );
      expect(
        parseUserSearch(<Map<String, dynamic>>[
          <String, dynamic>{'user_id': 'u1', 'friend': '0'},
        ]).single.isFriend,
        isFalse,
      );
    });

    test('右侧动作：好友给「发消息」，否则「查看」', () {
      expect(
        parseUserSearch(<Map<String, dynamic>>[
          <String, dynamic>{'user_id': 'u1', 'friend': 1},
        ]).single.actionKey,
        'message.send',
      );
      expect(
        parseUserSearch(<Map<String, dynamic>>[
          <String, dynamic>{'user_id': 'u1'},
        ]).single.actionKey,
        'common.view',
      );
    });

    test('没有 user_id 的脏数据跳过（点下去也无处可去）', () {
      expect(
        parseUserSearch(<Map<String, dynamic>>[
          <String, dynamic>{'realname': '没有 id'},
          <String, dynamic>{'user_id': 'u1', 'realname': '有的'},
        ]).map((item) => item.userId),
        <String>['u1'],
      );
    });

    test('空关键词判断（老端只挡空串，新端连空格一起挡）', () {
      expect(isBlankKeyword(''), isTrue);
      expect(isBlankKeyword('  '), isTrue);
      expect(isBlankKeyword('张三'), isFalse);
    });
  });
}
