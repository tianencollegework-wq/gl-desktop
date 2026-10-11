/// 名片消息（S4.6 补漏）：发送与点击的纯逻辑。
///
/// 对照老端两处：
/// * `components/message/im-input.vue::sendContactCard` —— 发出去的是
///   `type: 'contact'`，`content` 是 `[个人名片] 张三`（会话列表预览、通知里那行字），
///   真正渲染用的是 `extends` 里那三个键 `{avatar, displayName, id}`；
/// * `mixins/chat.js::openContact` —— 点名片跳
///   `/pages/contacts/detail?id=<extends.id>`。
library;

import 'package:flutter/foundation.dart';

import '../../data/model/contact.dart';
import '../../data/model/message.dart';
import 'message_media.dart';

/// 要发出去的那张名片（老端 `extends` 的三个字段）
@immutable
class ContactCard {
  const ContactCard({
    required this.id,
    required this.displayName,
    required this.avatar,
  });

  /// 从通讯录里的一项来（老端是在好友列表里选一个）
  factory ContactCard.fromContact(Contact contact) => ContactCard(
    id: contact.id,
    displayName: contact.displayName,
    avatar: contact.avatar,
  );

  /// 对方的 `user_id`
  final String id;

  final String displayName;
  final String avatar;

  bool get isEmpty => id.isEmpty && displayName.isEmpty;

  /// 老端 `extends` 的写法（连键的顺序都照抄）
  Map<String, dynamic> toExt() => <String, dynamic>{
    'avatar': avatar,
    'displayName': displayName,
    'id': id,
  };

  /// `content`：会话列表与通知里显示的那行字（老端 `[个人名片] 张三`）
  String content(String Function(String key) translate) =>
      '[${translate('chat.userIDcard')}] $displayName';

  @override
  String toString() => 'ContactCard($id, $displayName)';
}

/// 点一张收到的名片要跳到哪个用户（老端 `openContact(item.extends)`）。
///
/// 空串表示这张名片没带 `id`（老端会把 `undefined` 拼进 URL，跳出一个坏页面；
/// 新端在调用处直接不跳）。
String contactCardTargetId(Message message) => contactPayloadOf(message).id;
