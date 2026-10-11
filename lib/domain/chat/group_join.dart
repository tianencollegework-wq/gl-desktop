import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/util/json_value.dart';

/// 扫码进来看到的「群资料」，对应老端 `pages/message/group/info.vue`
/// （那个页面唯一的用途就是：扫到群二维码 → 看群资料 → 加入群聊 / 进群）。
///
/// 字段形态沿老端：`{avatar, name, groupUserCount, isJoin, setting.invite, inviteUid}`。
/// 老端对 `isJoin` / `invite` 都当 JS 里的真假值用（可能是 `0/1`、也可能是
/// 布尔），所以这里两种都吃（[tolerantFlag]）。
///
/// **两份来源**（都走这个 `fromJson`）：
/// * `/enterprise/group/groupInfo` —— 字段齐（多了人数与 `isJoin`），但只给**群成员**；
/// * 扫码验证那条（`/scan/g/<token>`）—— 服务端把群表那一行原样给回来，
///   未入群也能拿到，代价是**没有人数与 `isJoin`**、`setting` 还是数据库里那个
///   JSON 字符串、邀请人在 `invite_id` 上（服务端 `Index::group` 注入的）。
@immutable
class GroupJoinInfo {
  const GroupJoinInfo({
    required this.id,
    this.name = '',
    this.avatar = '',
    this.memberCount = 0,
    this.joined = false,
    this.inviteOpen = true,
    this.inviteUid = '',
    this.qrUrl = '',
    this.qrExpire = '',
  });

  final String id;
  final String name;
  final String avatar;

  /// 群人数（老端 `groupUserCount`，界面上跟名字拼在一起显示）
  final int memberCount;

  /// 我已经在这个群里了 → 按钮是「进入群聊」而不是「加入群聊」
  final bool joined;

  /// 群还在开放加群（老端 `setting.invite == 0` 时点加入会被拦下来提示）
  final bool inviteOpen;

  /// 服务端给的邀请人标识，加群时要带回去（老端 `inviteUid`）。
  ///
  /// 服务端新版本会用 `group_user` 里的人校验它（不是群成员就回「您没有操作权限！」），
  /// 所以扫码那条路必须用服务端自己给的 `invite_id`（= 生成这张二维码的那个人，
  /// 必然在群里），不能自己编一个。
  final String inviteUid;

  /// 群二维码的内容（老端 `data.qrUrl`，二维码页直接拿它当码值）
  final String qrUrl;

  /// 二维码有效期文案（老端 `data.qrExpire`，原样拼进「...前到期」那句）
  final String qrExpire;

  factory GroupJoinInfo.fromJson(Map<String, dynamic> json) {
    final setting = _asSetting(json['setting']);
    return GroupJoinInfo(
      id: asText(json['id'] ?? json['group_id']),
      // 这个接口老端读的是 `name`（不是 `displayName`）
      name: asText(json['name'] ?? json['displayName']),
      avatar: asText(json['avatar']),
      memberCount: asInt(
        json['groupUserCount'] ??
            json['group_user_count'] ??
            json['user_count'],
        0,
      ),
      joined: tolerantFlag(json['isJoin'] ?? json['is_join']),
      // 老端是 `setting.invite == 0` 才拦；字段缺失时不拦（等于开放）
      inviteOpen:
          setting.isEmpty || tolerantFlag(setting['invite'], fallback: true),
      inviteUid: asText(
        json['inviteUid'] ?? json['invite_uid'] ?? json['invite_id'],
      ),
      qrUrl: asText(json['qrUrl'] ?? json['qr_url']),
      qrExpire: asText(json['qrExpire'] ?? json['qr_expire']),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GroupJoinInfo &&
      other.id == id &&
      other.name == name &&
      other.avatar == avatar &&
      other.memberCount == memberCount &&
      other.joined == joined &&
      other.inviteOpen == inviteOpen &&
      other.inviteUid == inviteUid &&
      other.qrUrl == qrUrl &&
      other.qrExpire == qrExpire;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    avatar,
    memberCount,
    joined,
    inviteOpen,
    inviteUid,
    qrUrl,
    qrExpire,
  );

  @override
  String toString() =>
      'GroupJoinInfo($id "$name", members=$memberCount, joined=$joined, '
      'inviteOpen=$inviteOpen)';
}

/// `setting` 可能是**对象**（`groupInfo` 那条已经 `json_decode` 过），
/// 也可能是**JSON 字符串**（扫码那条把群表那一行原样给回来，字段就是库里那份）。
///
/// 两种都要吃：只认对象的话，扫码进来的「群已关闭加群」会被当成「没有这个字段」
/// 而按开放处理（[GroupJoinInfo.inviteOpen] 的兜底是 true）。
Map<String, dynamic> _asSetting(Object? value) {
  if (value is Map) return value.cast<String, dynamic>();
  if (value is String && value.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } on FormatException {
      // 库里存了一段坏 JSON：当「没有设置」处理（与字段缺失同一个口径）
    }
  }
  return const <String, dynamic>{};
}

/// 既能吃 `0/1`（含字符串）也能吃 `true/false` 的真假值。
///
/// 老端这两处都是在 JS 里直接当布尔用，哪种形态都得能接。
bool tolerantFlag(Object? value, {bool fallback = false}) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = value?.toString().trim().toLowerCase() ?? '';
  if (text.isEmpty) return fallback;
  if (text == 'true') return true;
  if (text == 'false') return false;
  final number = int.tryParse(text);
  if (number != null) return number != 0;
  return fallback;
}
