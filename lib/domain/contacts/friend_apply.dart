/// 好友申请（S5.1 的「新朋友」页），对应老端 `pages/contacts/friend.vue`。
///
/// 服务端一个接口（`/enterprise/friend/index`）按 `is_mine` 给两种口径的列表：
/// * `is_mine = 0`「我收到的」——每条带 `create_user_info`（申请人）与 `friend_id`；
/// * `is_mine = 1`「我发起的」——每条带 `user_id_info`（被申请的人）。
///
/// 两种口径的字段名不同，老端为此在模板里写了两份几乎一样的 `v-for`；这里先
/// 统一成一个模型，界面只按 [status] 决定右边显示什么。
library;

import 'package:flutter/foundation.dart' show immutable;

import '../../core/util/json_value.dart';

/// 「新朋友」页顶上那两个分段（老端 `uni-segmented-control` 的 `items`）
enum ApplyTab {
  /// 我收到的（`is_mine = 0`）
  received(0, 'user.recieve'),

  /// 我发起的（`is_mine = 1`）
  sent(1, 'user.sendApply');

  const ApplyTab(this.isMine, this.labelKey);

  /// 请求里的 `is_mine`
  final int isMine;

  final String labelKey;
}

/// 申请状态（老端模板里到处在比这三个数）
abstract final class ApplyStatus {
  /// 已拒绝
  static const int refused = 0;

  /// 已同意
  static const int accepted = 1;

  /// 待处理
  static const int pending = 2;
}

@immutable
class FriendApply {
  const FriendApply({
    required this.id,
    required this.friendId,
    required this.status,
    this.remark = '',
    this.userId = '',
    this.realName = '',
    this.avatar = '',
  });

  /// 申请记录 id。
  ///
  /// 就是服务端那一行的**主键** `friend_id`（`Friend::index()` 返回的是原始表行，
  /// 字段名就是建表时那些，**根本没有 `id`**）。别写成 `id` —— 2026-09-25
  /// 用户报的「A 给 B 发了好友申请，B 的『新的朋友』显示暂无数据」就是这么来的：
  /// 解析层拿 `id` 当「有没有拿到记录」的凭据，而服务端从来没给过这个键，
  /// 于是**每一条都被当成脏数据丢掉**（通讯录那个红点也因此永远是 0）。
  final String id;

  /// 同意/拒绝时提交的 `friend_id`（老端 `acceptApply({friend_id: x.friend_id})`）
  ///
  /// 服务端 `Friend::update()` 是按 `friend_id` 查那一行的，所以**不能**拿对方的
  /// `user_id` 顶（两张表的 id 各自自增，撞上了就会处理错一条申请）。
  /// 真的缺了就留空，让 `respond()` 报一句清楚的错。
  final String friendId;

  /// [ApplyStatus] 里的三个值；认不出来时是 `-1`（老端此时也不显示任何操作）
  final int status;

  /// 验证信息（列表里那行小字）
  final String remark;

  /// 对方 `user_id`（列表里点名字进详情、点「发消息」进聊天都用它）
  final String userId;

  final String realName;
  final String avatar;

  bool get isPending => status == ApplyStatus.pending;
  bool get isAccepted => status == ApplyStatus.accepted;
  bool get isRefused => status == ApplyStatus.refused;

  /// 界面上的名字：真名 → user_id（不要出现空白行）
  String get title => realName.isNotEmpty ? realName : userId;

  /// 从接口原始 JSON 解析。
  ///
  /// 两个嵌套字段都试（`create_user_info` / `user_id_info`）：服务端在两种口径下
  /// 各给一个，而**这一层不该知道调用方是哪个口径**——真机上如果发现它两处都给，
  /// 这样写也不会出错。
  factory FriendApply.fromServerJson(Map<String, dynamic> json) {
    final info = asMap(json['create_user_info'] ?? json['user_id_info']);
    final userId = asText(info['user_id']);
    // 记录 id 就是 `friend_id`（老端也是拿它当 key、拿它去接受申请）；
    // 有些接口会另外包一层 `id`，两种都认。
    final friendId = asText(json['friend_id'], asText(json['id']));
    return FriendApply(
      id: friendId,
      friendId: friendId,
      status: asInt(json['status'], -1),
      remark: asText(json['remark']),
      userId: userId,
      realName: asText(info['realname'] ?? info['displayName'] ?? info['name']),
      avatar: asText(info['avatar']),
    );
  }

  @override
  String toString() =>
      'FriendApply($id friend=$friendId status=$status "$realName")';
}

/// 把一页原始行解析成申请列表。
///
/// 「这一行是不是有效记录」只看 `friend_id`（服务端的行主键）—— 以前这里看的是
/// `id`，而服务端从来不返回这个键，于是整页都被过滤掉（见 [FriendApply.id]）。
List<FriendApply> parseApplyRows(List<Map<String, dynamic>> rows) =>
    <FriendApply>[
      for (final row in rows)
        if (asText(row['friend_id'], asText(row['id'])).isNotEmpty)
          FriendApply.fromServerJson(row),
    ];

/// 待处理的条数（通讯录「新的朋友」那个红点数的是它）
int countPendingApplies(List<FriendApply> applies) =>
    applies.where((apply) => apply.isPending).length;

/// 总页数（老端 `uni-pagination` 用 `total` 与 `pageSize` 算）
///
/// 总数为 0 时也算 1 页：老端分页组件此时画「1/1」，界面不显示页码但语义一致。
int pageCountFor({required int total, required int pageSize}) {
  if (pageSize <= 0 || total <= 0) return 1;
  return (total + pageSize - 1) ~/ pageSize;
}

/// 还有下一页吗
bool hasNextPage({
  required int page,
  required int total,
  required int pageSize,
}) => page < pageCountFor(total: total, pageSize: pageSize);

/// 还有上一页吗
bool hasPrevPage(int page) => page > 1;
