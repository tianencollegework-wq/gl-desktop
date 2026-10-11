import '../../core/util/json_value.dart';
import 'contact.dart';

/// 用户详情（S5.2），对应老端 `pages/contacts/detail.vue` 里的 `detail`。
///
/// 接口是 `getUserInfo({user_id, group_id})`，响应就是老端整个 `detail` 对象：
/// * 基本资料：`user_id` / `realname` / `account` / `avatar` / `email` / `sex` / `motto`，
///   以及 IP 那两列 `last_login_ip` / `location`；
///
/// 两个服务端细节要记住（`Im::getUserInfo`）：
/// * `account` 是**打过码的**（`substr(0,3).'******'.substr(-2)`），所以拿它去
///   判断「是不是手机号」永远不成立（老端那个「打电话」按钮在真机上其实是死的）；
/// * `motto`（个性签名）就是 `yu_user` 表那一列，原样返回，朋友资料页要显示它。
/// * `friend`：**只有在已经是好友时才有**（里面有 `friend_id` 与备注 `nickname`）；
/// * `contactInfo`：陌生会话用的会话信息（老端 `sendMsg` 靠它 `appendContacts`）；
/// * `groupInfo`：从群成员点进来时的群内信息（管理员操作，S5.3 用）。
///
/// 老端把它们都摊在一个对象里，这里也照抄（只把基本资料拆成字段）。
class UserDetail {
  const UserDetail({
    required this.userId,
    this.realName = '',
    this.account = '',
    this.avatar = '',
    this.email = '',
    this.motto = '',
    this.sex = -1,
    this.lastLoginIp = '',
    this.location = '',
    this.friend = const <String, dynamic>{},
    this.contactInfo = const <String, dynamic>{},
    this.groupInfo = const <String, dynamic>{},
  });

  static const UserDetail empty = UserDetail(userId: '');

  final String userId;
  final String realName;

  /// 账号（老端把它当手机号用：正则通过才显示「打电话」）
  final String account;

  final String avatar;
  final String email;

  /// 个性签名（朋友资料页要显示对方这一栏）
  final String motto;

  /// 0 女、1 男，其它认不出来（老端 `arr[value] || unknown`）
  final int sex;

  /// 上次登录 IP 与归属地（老端 `sysInfo.ipregion` 开着才显示这两列）
  final String lastLoginIp;
  final String location;

  /// 好友信息：`{friend_id, nickname}`；不是好友时是空 map
  final Map<String, dynamic> friend;

  /// 陌生会话信息（会话列表用）
  final Map<String, dynamic> contactInfo;

  /// 群内信息（`{name, owner_id, manageRole, userInfo:{role, no_speak_time}}`）
  final Map<String, dynamic> groupInfo;

  /// 已经是好友（老端 `detail.friend` 的真值判断）
  bool get isFriend => friend.isNotEmpty;

  /// 我给对方设的备注（没设过是空串）
  String get nickname => asText(friend['nickname']);

  /// 改备注/删好友时提交的 `friend_id`；服务端没给就退到 user_id
  String get friendId => asText(friend['friend_id'], userId);

  /// 真名 → user_id（页面上那行大字）
  String get title => realName.isNotEmpty ? realName : userId;

  /// 会话里显示的名字：备注优先（老端 `updateContacts` 也是把备注写进 displayName）
  String get displayName => nickname.isNotEmpty ? nickname : title;

  bool get hasIpInfo => lastLoginIp.isNotEmpty || location.isNotEmpty;

  factory UserDetail.fromServerJson(Map<String, dynamic> json) => UserDetail(
    userId: asText(json['user_id'] ?? json['id']),
    realName: asText(json['realname'] ?? json['displayName']),
    account: asText(json['account']),
    avatar: asText(json['avatar']),
    email: asText(json['email']),
    motto: asText(json['motto']),
    sex: asInt(json['sex'], -1),
    lastLoginIp: asText(json['last_login_ip']),
    location: asText(json['location']),
    friend: asMap(json['friend']),
    contactInfo: asMap(json['contactInfo'] ?? json['contact_info']),
    groupInfo: asMap(json['groupInfo'] ?? json['group_info']),
  );

  /// 从详情造一条会话用的联系人。
  ///
  /// 为什么要这么绕：聊天页认的是**本地库里的会话行**，从陌生人的详情页点「发消息」
  /// 时本地还没有这一行（老端是 `appendContacts(detail.contactInfo)`）。
  /// `contactInfo` 缺失或没有 `id` 时就用详情本身的字段兜底，不能什么都不做
  /// ——否则聊天页会说「联系人不存在」。
  Contact toContact() {
    final info = contactInfo;
    return Contact(
      id: userId,
      displayName: asText(info['displayName'], displayName),
      avatar: asText(info['avatar'], avatar),
      isGroup: asInt(info['is_group'], 0),
      account: account,
      extra: info,
    );
  }

  @override
  String toString() =>
      'UserDetail($userId "$realName" friend=$isFriend nickname=$nickname)';
}
