/// 接口路径常量，与老端 `api/*.js` 一一对应。
///
/// 注意：老端有些路径少了前导斜杠（`enterprise/im/searchUser` 等），这里统一补上，
/// 交给 `ApiClient.normalizePath` 之后行为一致。
abstract final class AuthPaths {
  static const String login = '/common/Pub/login';
  static const String logout = '/common/Pub/logout';
  static const String register = '/common/pub/register';
  static const String bindUid = '/common/Pub/bindUid';
  static const String bindGroup = '/common/pub/bindGroup';
  static const String systemInfo = '/common/pub/getSystemInfo';
  static const String sendCode = '/common/pub/sendCode';
}

// 检查更新不再走接口（2026-10-08）：它读的是一份静态清单，地址在
// `data/api/update_api.dart::updateManifestUrl`（公开文件、无需登录态），
// 老端那个 `POST /common/pub/checkVersion` 已经不用了。

abstract final class ChatPaths {
  static const String contacts = '/enterprise/im/getContacts';
  static const String chatList = '/enterprise/im/getChatList';
  static const String friendList = '/enterprise/im/getFriendList';
  static const String groupList = '/enterprise/im/getGroupList';
  static const String messageList = '/enterprise/im/getMessageList';
  static const String messageContext = '/enterprise/im/getMessageContext';
  static const String messageInfo = '/enterprise/im/getMessageInfo';
  static const String setChatTop = '/enterprise/im/setChatTop';
  static const String delChat = '/enterprise/im/delChat';
  static const String sendMessage = '/enterprise/im/sendMessage';
  static const String forwardMessage = '/enterprise/im/forwardMessage';
  static const String setMsgIsRead = '/enterprise/im/setMsgIsRead';
  static const String readAtMsg = '/enterprise/im/readAtMsg';
  static const String undoMessage = '/enterprise/im/undoMessage';
  static const String delMessage = '/enterprise/im/delMessage';

  /// 通话信令与"代发 WS 消息"都走这里，见 docs/protocol/call-signaling.md
  static const String sendToMsg = '/enterprise/im/sendToMsg';

  /// Cloudflare Realtime TURN 的短时凭据（服务端签发，2026-09-26 新增）。
  ///
  /// 站点没配密钥时服务端返回空列表（正常响应），客户端据此退回「只有 STUN」——
  /// 见 `domain/call/turn_credentials.dart`。
  static const String turnCredentials = '/enterprise/im/turnCredentials';

  static const String isNotice = '/enterprise/im/isNotice';
  static const String updateCard = '/enterprise/im/updateCard';
  static const String userInfo = '/enterprise/im/getUserInfo';
  static const String tokenLogin = '/enterprise/im/tokenLogin';
  static const String searchUser = '/enterprise/im/searchUser';
  static const String updateUserInfo = '/enterprise/im/updateUserInfo';
  static const String editAccount = '/enterprise/im/editAccount';
  static const String editPassword = '/enterprise/im/editPassword';

  /// 注销账号（不可逆，2026-09-25 新增：账号与安全 › 注销账号）
  static const String deleteAccount = '/enterprise/im/deleteAccount';
  static const String contactInfo = '/enterprise/im/getContactInfo';
  static const String adminNotice = '/enterprise/im/getAdminNotice';
}

abstract final class GroupPaths {
  static const String joinGroup = '/enterprise/group/joinGroup';
  static const String userList = '/enterprise/group/groupUserList';
  static const String setNotice = '/enterprise/group/setNotice';
  static const String info = '/enterprise/group/groupInfo';
  static const String setting = '/enterprise/group/groupSetting';
  static const String changeOwner = '/enterprise/group/changeOwner';
  static const String allUser = '/enterprise/group/getAllUser';
  static const String add = '/enterprise/group/add';
  static const String bindGroup = '/common/index/bindGroup';
  static const String editName = '/enterprise/group/editGroupName';
  static const String addUser = '/enterprise/group/addGroupUser';
  static const String removeUser = '/enterprise/group/removeUser';
  static const String removeGroup = '/enterprise/group/removeGroup';
  static const String clearMessage = '/enterprise/group/clearMessage';
  static const String setManager = '/enterprise/group/setManager';
  static const String setNoSpeak = '/enterprise/group/setNoSpeak';
}

abstract final class FriendPaths {
  static const String del = '/enterprise/friend/del';
  static const String add = '/enterprise/friend/add';
  static const String applyList = '/enterprise/friend/index';
  static const String acceptApply = '/enterprise/friend/update';
  static const String setNickname = '/enterprise/friend/setNickname';
}

abstract final class EmojiPaths {
  static const String list = '/enterprise/emoji/index';
  static const String add = '/enterprise/emoji/add';
  static const String del = '/enterprise/emoji/del';
  static const String move = '/enterprise/emoji/move';
}

abstract final class UploadPaths {
  static const String file = '/common/upload/uploadFile';
  static const String avatar = '/common/upload/uploadAvatar';
  static const String emoji = '/common/upload/uploadEmoji';
}

/// 群通话（Cloudflare Realtime SFU）的控制面代理，见 `docs/protocol/sfu-group-call.md`。
///
/// 全部 `POST`：沿用 `ApiClient` 与登录态。**媒体不走这里** —— 音视频是
/// 端点 ↔ Cloudflare 直连，这些接口只转发几百字节的 SDP 与房间注册表读写。
///
/// 为什么不让客户端直连 Cloudflare：App Secret 是账号级长期密钥（CF 没有客户端用的
/// 短时令牌），且 CF 明确说 session id / track name 都不代表权限、房间发现要应用自己做
/// —— 密钥、成员资格校验、订阅目标分发三件事都只能在服务端。
///
/// ⚠️ 路径是 `/enterprise/sfu/…`（**独立控制器** `app/enterprise/controller/Sfu.php`）。
/// 群通话那 8 个接口没有塞进 `Im.php`：一是那文件已经 1200 多行，二是这里的
/// 动作名都是**单个小写单词**（session / close / room …），不依赖框架对驼峰动作名
/// 的处理，少一处会踩的坑。服务端补丁包里有一份交叉自检（check_server.js）钉这件事。
abstract final class SfuPaths {
  /// 建一条会话：`{room_id, purpose}` → `{session_id}`
  static const String session = '/enterprise/sfu/session';

  /// 发布（`location: local`）
  static const String publish = '/enterprise/sfu/publish';

  /// 订阅（`location: remote`，一次可带多条、可跨发布者，上限 64）。
  /// **不带本地 offer**：订阅是 SFU 回 offer，端点作答后走 [renegotiate]。
  static const String subscribe = '/enterprise/sfu/subscribe';

  /// 关 track（停止订阅/停止发布/停共享屏）：`{session_id, mids, sdp_offer?, force?}`
  static const String closeTracks = '/enterprise/sfu/close';

  /// 把端点的 answer 交回 CF：`{session_id, sdp_answer}`
  static const String renegotiate = '/enterprise/sfu/renegotiate';

  /// 房间快照：成员 + 各自的发布会话与 track 名 + 注册表 `epoch`
  static const String roomState = '/enterprise/sfu/room';

  /// 心跳：在房间里每 20 秒一次，注册表靠它续命（服务端也在这一刻清掉超时的人）
  /// （发布之后一直不动的客户端不会被当成掉线清掉）。回包里带回 `epoch`，
  /// 所以它顺便也是"刚才那条 WS 推送丢没丢"的自检。
  static const String heartbeat = '/enterprise/sfu/heartbeat';

  /// 声明"我的麦克风是不是静音中"：`{room_id, muted}`。
  ///
  /// 为什么需要单开一个接口：**静音不动发布关系** —— `mic` 那条 track 一直挂在
  /// 注册表上（拆掉它对方就会退订，取消静音时重发布一失败，对方就再也听不到我，
  /// 那正是「说话没声」的成因）。所以静音只是**一个显示态**，靠 `publish` /
  /// `close` 的副作用根本表达不出来，必须单独告诉服务端一声。
  ///
  /// 不告诉的后果（2026-10-07 真机）：手机端 B 关掉麦克风，电脑端 A 那行
  /// 一直写「麦克风已开」—— 因为 A 读到的注册表还是 `tracks:["mic"]`。
  static const String mute = '/enterprise/sfu/mute';

  /// 离开房间：关会话 + 从注册表移除
  static const String leave = '/enterprise/sfu/leave';
}
