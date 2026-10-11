/// 用户详情页（S5.2，`pages/contacts/detail.vue`）的纯逻辑：
/// 底部按钮该显示哪些、性别文案、账号是不是手机号。
library;

import 'package:flutter/foundation.dart' show immutable;

import '../../data/model/user_detail.dart';

/// 老端那个手机号正则（`computed.validatePhone`），逐字照抄
final RegExp _mobileAccount = RegExp(r'^1[3456789]\d{9}$');

/// 账号像手机号才给「打电话」（老端 `uni.makePhoneCall` 只能拨号码）
bool isMobileAccount(String account) => _mobileAccount.hasMatch(account.trim());

/// 性别文案的 key。
///
/// 老端是 `[women, man, unknown][value] || unknown`：`0` 女、`1` 男，
/// 其余（含字段缺失时的 `undefined`）都是「未知」。
String sexLabelKey(int sex) {
  if (sex == 0) return 'common.women';
  if (sex == 1) return 'common.man';
  return 'common.unknown';
}

/// 详情页底部那几颗按钮的可见性（老端模板里那几处 `v-if` 的合体）。
///
/// 老端是两层结构：
/// * 外层 `userInfo.user_id != detail.user_id` —— **自己的详情页一个按钮都没有**；
/// * 「互加过」那一块的条件是 `runMode == 1 || detail.friend`
///   （`runMode == 1` 是「无好友体系」的部署模式，谁都能聊）；
/// * 里面四颗按钮各自再判：打电话看账号是不是手机号、音视频看两个开关、
///   删除好友只在 `runMode == 2`；
/// * 「加好友」是独立一块：`runMode == 2 && !detail.friend`。
@immutable
class UserDetailActions {
  const UserDetailActions({
    required this.sendMessage,
    required this.callPhone,
    required this.webrtc,
    required this.addFriend,
    required this.deleteFriend,
  });

  /// 「发消息」：不是自己，且（免好友模式 或 已经是好友）
  final bool sendMessage;

  /// 「打电话」：同上，且账号是手机号
  final bool callPhone;

  /// 「音视频通话」：同上，且服务端开了 webrtc 与简单通信
  final bool webrtc;

  /// 「添加朋友」：`runMode == 2` 且还不是好友
  final bool addFriend;

  /// 「删除好友」：`runMode == 2` 且已经是好友
  final bool deleteFriend;

  /// 「互加过」那一块是否出现（它出现时至少有一颗按钮）
  bool get hasChatBlock => sendMessage || callPhone || webrtc || deleteFriend;

  @override
  String toString() =>
      'UserDetailActions(send=$sendMessage call=$callPhone webrtc=$webrtc '
      'add=$addFriend del=$deleteFriend)';
}

UserDetailActions userDetailActionsOf({
  required UserDetail detail,
  required String myUserId,
  required int runMode,
  bool webrtcEnabled = false,
  bool simpleChatEnabled = false,
}) {
  final isMe = myUserId.isNotEmpty && myUserId == detail.userId;
  final chatBlock = !isMe && (runMode == 1 || detail.isFriend);
  return UserDetailActions(
    sendMessage: chatBlock,
    callPhone: chatBlock && isMobileAccount(detail.account),
    webrtc: chatBlock && webrtcEnabled && simpleChatEnabled,
    // 老端这两块是互斥的（一个要求 `detail.friend`，一个要求 `!detail.friend`）
    addFriend: !isMe && runMode == 2 && !detail.isFriend,
    deleteFriend: chatBlock && runMode == 2,
  );
}
