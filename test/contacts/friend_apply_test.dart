import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/domain/contacts/friend_apply.dart';

/// 好友申请（S5.1）：解析、状态、分页计算。
///
/// 这里钉的字段名全部来自老端 `pages/contacts/friend.vue` 的真实读法
/// （`create_user_info` / `user_id_info` / `friend_id` / `status`）。
void main() {
  /// 服务端真实那一行：**只有表字段**（主键叫 `friend_id`，没有 `id`）。
  ///
  /// 老端 `friend.vue` 读的就是 `x.friend_id` / `x.create_user_info` /
  /// `x.user_id_info` / `x.status`，拿它去调 `acceptApply({friend_id})`。
  Map<String, dynamic> incoming({
    Object? friendId = 3,
    Object? status = 2,
    String remark = '我是隔壁老王',
    Object? userId = 'u3',
    String realname = '老王',
    String avatar = 'https://cdn.test/u3.png',
  }) => <String, dynamic>{
    // friend_id 用 Object? 是为了喂 null 进去测退路（null 时整个键不出现）
    'friend_id': ?friendId,
    'status': status,
    'remark': remark,
    'create_user_info': <String, dynamic>{
      'user_id': userId,
      'realname': realname,
      'avatar': avatar,
    },
  };

  test('我收到的：读 create_user_info，字段与 friend_id 都对', () {
    final apply = FriendApply.fromServerJson(incoming());

    // 2026-09-25：这里原来是 `expect(apply.id, '1')`，因为当时假数据里凭空多写了
    // 一个服务端从来没有的 `id` 键，把「拿 id 当有效凭据」这个 bug 盖住了。
    expect(apply.id, '3', reason: '记录 id 就是 friend_id');
    expect(apply.friendId, '3');
    expect(apply.status, ApplyStatus.pending);
    expect(apply.isPending, isTrue);
    expect(apply.remark, '我是隔壁老王');
    expect(apply.userId, 'u3');
    expect(apply.realName, '老王');
    expect(apply.title, '老王');
    expect(apply.avatar, 'https://cdn.test/u3.png');
  });

  test('我发起的：读 user_id_info，同一套字段', () {
    final apply = FriendApply.fromServerJson(<String, dynamic>{
      'status': 1,
      'friend_id': 7,
      'user_id_info': <String, dynamic>{
        'user_id': 'u7',
        'realname': '小美',
        'avatar': 'https://cdn.test/u7.png',
      },
    });

    expect(apply.status, ApplyStatus.accepted);
    expect(apply.isAccepted, isTrue);
    expect(apply.userId, 'u7');
    expect(apply.realName, '小美');
  });

  test('服务端没给 friend_id 就留空，不拿对方的 user_id 顶', () {
    // 拿 user_id 当 friend_id 发过去，服务端可能撞到**别人**那一行
    //（两张表各自自增，id 空间重叠），所以宁可留空让页面报一句清楚的错。
    final apply = FriendApply.fromServerJson(incoming(friendId: null));

    expect(apply.friendId, isEmpty);
    // 用户那几栏照样读得到（列表还能正常显示）
    expect(apply.userId, 'u3');
    expect(apply.realName, '老王');
  });

  test('状态是字符串也能认；认不出的值三种判断全为 false', () {
    expect(FriendApply.fromServerJson(incoming(status: '0')).status, 0);
    expect(FriendApply.fromServerJson(incoming(status: '2')).isPending, isTrue);
    // 数值型但不在 0/1/2 里：原样留着（老端也不认识），界面上不显示任何操作
    final weird = FriendApply.fromServerJson(incoming(status: 99));
    expect(weird.status, 99);
    expect(weird.isPending, isFalse);
    expect(weird.isAccepted, isFalse);
    expect(weird.isRefused, isFalse);
  });

  test('备注缺失是空串（不会画出 undefined）', () {
    final apply = FriendApply.fromServerJson(incoming(remark: ''));
    expect(apply.remark, '');
  });

  test('没有真名时用 user_id 当名字', () {
    final apply = FriendApply.fromServerJson(incoming(realname: ''));
    expect(apply.title, 'u3');
  });

  test('一页原始数据：连主键都没有的脏数据才跳过', () {
    final items = parseApplyRows(<Map<String, dynamic>>[
      incoming(friendId: 1),
      <String, dynamic>{'status': 2, 'create_user_info': <String, dynamic>{}},
      incoming(friendId: 2),
    ]);

    expect(items.map((item) => item.id).toList(), <String>['1', '2']);
  });

  test('服务端不给 id（真机就是这样）也照样列得出来', () {
    // 这一条钉的是用户 2026-09-25 报的「新的朋友一直暂无数据」：
    // 以前解析层拿 `id` 当凭据，服务端只给 `friend_id`，于是整页都被丢掉。
    final rows = <Map<String, dynamic>>[
      incoming(friendId: 66, realname: '隔壁老王'),
    ];
    expect(rows.single.containsKey('id'), isFalse, reason: '服务端本来就没有这个键');

    final items = parseApplyRows(rows);

    expect(items.length, 1);
    expect(items.single.title, '隔壁老王');
    expect(items.single.isPending, isTrue);
    expect(countPendingApplies(items), 1, reason: '通讯录那个红点也靠它');
  });

  test('待处理条数只数 status == 2（红点数的是它）', () {
    final items = parseApplyRows(<Map<String, dynamic>>[
      incoming(friendId: 1, status: 2),
      incoming(friendId: 2, status: 1),
      incoming(friendId: 3, status: 2),
      incoming(friendId: 4, status: 0),
    ]);

    expect(countPendingApplies(items), 2);
    expect(countPendingApplies(const <FriendApply>[]), 0);
  });

  test('两个分段的 is_mine 与文案 key 照老端', () {
    expect(ApplyTab.received.isMine, 0);
    expect(ApplyTab.sent.isMine, 1);
    expect(ApplyTab.received.labelKey, 'user.recieve');
    expect(ApplyTab.sent.labelKey, 'user.sendApply');
  });

  group('分页计算', () {
    test('总数为 0 也算一页（老端分页组件画 1/1）', () {
      expect(pageCountFor(total: 0, pageSize: 10), 1);
      expect(hasNextPage(page: 1, total: 0, pageSize: 10), isFalse);
    });

    test('除不尽向上取整', () {
      expect(pageCountFor(total: 25, pageSize: 10), 3);
      expect(pageCountFor(total: 20, pageSize: 10), 2);
    });

    test('首页没有上一页、末页没有下一页', () {
      expect(hasPrevPage(1), isFalse);
      expect(hasPrevPage(2), isTrue);
      expect(hasNextPage(page: 1, total: 25, pageSize: 10), isTrue);
      expect(hasNextPage(page: 3, total: 25, pageSize: 10), isFalse);
    });

    test('pageSize 非法时不做除法（防崩）', () {
      expect(pageCountFor(total: 25, pageSize: 0), 1);
    });
  });
}
