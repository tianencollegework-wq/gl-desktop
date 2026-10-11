import 'package:flutter/foundation.dart';

import '../../core/util/json_value.dart';

/// 登录用户，对应老端 `uni.getStorageSync('userInfo')`。
///
/// 字段清单是从老端代码里实际读到的用法倒推的（`userInfo.user_id`、
/// `.displayName`、`.avatar`、`.realname`、`.is_auth`…），不是照文档猜的。
/// 登录接口返回的 `userInfo` 会整份存下来，未知字段保留在 [raw] 里。
@immutable
class UserInfo {
  const UserInfo({
    required this.userId,
    this.account = '',
    this.displayName = '',
    this.realName = '',
    this.avatar = '',
    this.mobile = '',
    this.email = '',
    this.sex = 0,
    this.motto = '',
    this.role = 0,
    this.isAuth = 0,
    this.namePy = '',
    this.qrUrl = '',
    this.raw = const <String, dynamic>{},
  });

  /// 用户唯一 id（老端 `userInfo.user_id`，也有地方写成 `id`）
  final String userId;

  final String account;

  /// 服务端可直接用于展示的名字（老端列表里优先用它）
  final String displayName;

  final String realName;
  final String avatar;
  final String mobile;
  final String email;
  final int sex;
  final String motto;
  final int role;

  /// 是否实名/认证
  final int isAuth;

  /// 昵称拼音（通讯录排序用）
  final String namePy;

  /// 个人二维码链接
  final String qrUrl;

  final Map<String, dynamic> raw;

  factory UserInfo.fromJson(Map<String, dynamic> json) {
    return UserInfo(
      userId: asText(json['user_id'] ?? json['id']),
      account: asText(json['account']),
      displayName: asText(json['displayName']),
      realName: asText(json['realname']),
      avatar: asText(json['avatar']),
      mobile: asText(json['mobile']),
      email: asText(json['email']),
      sex: asInt(json['sex'], 0),
      motto: asText(json['motto']),
      role: asInt(json['role'], 0),
      isAuth: asInt(json['is_auth'], 0),
      namePy: asText(json['name_py']),
      qrUrl: asText(json['qrUrl']),
      raw: json,
    );
  }

  Map<String, dynamic> toJson() => raw.isEmpty ? _fallbackJson() : raw;

  /// 按用户 id 比较：老端到处拿 `userInfo.user_id` 做判断，
  /// 这里让同一个人的两份数据（接口返回 / 本地缓存）相等。
  @override
  bool operator ==(Object other) =>
      other is UserInfo &&
      other.userId == userId &&
      other.name == name &&
      other.avatar == avatar;

  @override
  int get hashCode => Object.hash(userId, name, avatar);

  /// 展示名：老端优先 `displayName`，回落 `realname`，再回落账号
  String get name {
    for (final candidate in <String>[displayName, realName, account]) {
      if (candidate.trim().isNotEmpty) return candidate.trim();
    }
    return '未命名';
  }

  Map<String, dynamic> _fallbackJson() => <String, dynamic>{
    'user_id': userId,
    'account': account,
    'displayName': displayName,
    'realname': realName,
    'avatar': avatar,
    'mobile': mobile,
    'email': email,
    'sex': sex,
    'motto': motto,
    'role': role,
    'is_auth': isAuth,
    'name_py': namePy,
    'qrUrl': qrUrl,
  };
}
