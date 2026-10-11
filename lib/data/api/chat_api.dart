import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_client.dart';
import 'endpoints.dart';

/// 消息与会话，对应老端 `api/message.js` 的 `msgApi`。
///
/// 参数用 map 透传，理由同 `AuthApi`。
class ChatApi {
  const ChatApi(this._client);

  final ApiClient _client;

  // ------------------------------------------------------------------ 会话

  /// 初始化联系人/会话（进消息页拉全量）。
  ///
  /// 返回的是**数组**（老端 `initContacts(res.data)` 直接按数组处理），
  /// 所以这里用 postListMaps 而不是 postMap。
  Future<List<Map<String, dynamic>>> getContacts([
    Map<String, dynamic> params = const {},
  ]) => _client.postListMaps(ChatPaths.contacts, data: params);

  Future<Map<String, dynamic>> getChatList([
    Map<String, dynamic> params = const {},
  ]) => _client.postMap(ChatPaths.chatList, data: params);

  /// 好友列表。
  ///
  /// 返回的是**数组**：老端 `store/message.js::getFriendList` 拿 `res.data` 直接
  /// `filter(is_group==0)` 用。用 `postMap` 读它会静默得到空 map。
  Future<List<Map<String, dynamic>>> getFriendList([
    Map<String, dynamic> params = const {},
  ]) => _client.postListMaps(ChatPaths.friendList, data: params);

  /// 群聊列表（同为数组，老端 `getGroupList`）
  Future<List<Map<String, dynamic>>> getGroupList([
    Map<String, dynamic> params = const {},
  ]) => _client.postListMaps(ChatPaths.groupList, data: params);

  Future<void> setChatTop(Map<String, dynamic> params) =>
      _client.postVoid(ChatPaths.setChatTop, data: params);

  Future<void> delChat(Map<String, dynamic> params) =>
      _client.postVoid(ChatPaths.delChat, data: params);

  Future<void> isNotice(Map<String, dynamic> params) =>
      _client.postVoid(ChatPaths.isNotice, data: params);

  // ------------------------------------------------------------------ 消息

  /// 消息列表（分页游标是 `last_id` = 当前这批里最旧一条的 `msg_id`）
  Future<List<Map<String, dynamic>>> getMessageList(
    Map<String, dynamic> params,
  ) => _client.postListMaps(ChatPaths.messageList, data: params);

  /// 消息列表 + 总条数。
  ///
  /// 聊天记录页要分页条，而总条数在**信封的 `count`** 里（老端
  /// `uni-pagination :total="dataTotal"` 用的就是它），所以要走 [ApiClient.postPage]。
  Future<({List<Map<String, dynamic>> rows, int count})> getMessageListPage(
    Map<String, dynamic> params,
  ) => _client.postPage(ChatPaths.messageList, data: params);

  Future<Map<String, dynamic>> getMessageContext(Map<String, dynamic> params) =>
      _client.postMap(ChatPaths.messageContext, data: params);

  /// 某条消息的前后文。
  ///
  /// `data` 是**数组**（老端 `let data=res.data; data.forEach(...)`），
  /// 用 `postMap` 读会静默拿到空 map。
  Future<List<Map<String, dynamic>>> getMessageContextList(
    Map<String, dynamic> params,
  ) => _client.postListMaps(ChatPaths.messageContext, data: params);

  Future<Map<String, dynamic>> getMessageInfo(Map<String, dynamic> params) =>
      _client.postMap(ChatPaths.messageInfo, data: params);

  Future<Map<String, dynamic>> sendMessage(Map<String, dynamic> params) =>
      _client.postMap(ChatPaths.sendMessage, data: params);

  /// 上传图片/视频/文件/语音（老端 `uni.uploadFile`）。
  ///
  /// 表单里就两个字段：`message` 是整条消息的 JSON 字符串、`file` 是文件本体，
  /// 请求头带 `Authorization`（由 `ApiClient` 统一加）。返回的 `data` 是
  /// 服务端存下来的那条消息（图片的 `extends.fixMode/width/height` 是服务端算的）。
  Future<Map<String, dynamic>> uploadFile(FormData form) =>
      _client.upload(UploadPaths.file, form);

  Future<void> forwardMessage(Map<String, dynamic> params) =>
      _client.postVoid(ChatPaths.forwardMessage, data: params);

  Future<void> setMsgIsRead(Map<String, dynamic> params) =>
      _client.postVoid(ChatPaths.setMsgIsRead, data: params, notify: false);

  Future<void> readAtMsg(Map<String, dynamic> params) =>
      _client.postVoid(ChatPaths.readAtMsg, data: params, notify: false);

  Future<void> undoMessage(Map<String, dynamic> params) =>
      _client.postVoid(ChatPaths.undoMessage, data: params);

  Future<void> delMessage(Map<String, dynamic> params) =>
      _client.postVoid(ChatPaths.delMessage, data: params);

  Future<void> updateCard(Map<String, dynamic> params) =>
      _client.postVoid(ChatPaths.updateCard, data: params);

  /// 通话信令 + "代发 WS 消息"。
  ///
  /// 返回的消息体里，通话相关的状态放在 `extends` 里（老端会读 `res.data.extends.code`
  /// 判断忙线），所以这里必须把整个对象交回业务层。
  Future<Map<String, dynamic>> sendToMsg(Map<String, dynamic> params) =>
      _client.postMap(ChatPaths.sendToMsg, data: params, notify: false);

  /// Cloudflare Realtime TURN 的短时凭据（服务端签发，2026-09-26 新增）。
  ///
  /// 只需要登录态，不带参数。三种返回都是**正常响应**（服务端不会为它报错）：
  /// `{'iceServers': [...], 'expiresIn': 秒}`、没配密钥时的空列表、
  /// 以及 Cloudflare 取不到凭据时的空列表。解析都在
  /// `domain/call/turn_credentials.dart`（纯函数，整体跑单测）。
  Future<Map<String, dynamic>> turnCredentials() =>
      _client.postMap(ChatPaths.turnCredentials, notify: false);

  // ------------------------------------------------------------------ 用户

  Future<Map<String, dynamic>> getUserInfo(Map<String, dynamic> params) =>
      _client.postMap(ChatPaths.userInfo, data: params);

  Future<Map<String, dynamic>> getContactInfo(Map<String, dynamic> params) =>
      _client.postMap(ChatPaths.contactInfo, data: params);

  /// 搜人（老端 `searchUser({keywords})`）。
  ///
  /// `data` 是**数组**（老端 `this.contacts = res.data` 直接赋值），
  /// 所以是 `postListMaps` 而不是 `postMap`。
  Future<List<Map<String, dynamic>>> searchUser(Map<String, dynamic> params) =>
      _client.postListMaps(ChatPaths.searchUser, data: params);

  Future<void> updateUserInfo(Map<String, dynamic> params) =>
      _client.postVoid(ChatPaths.updateUserInfo, data: params);

  Future<void> editAccount(Map<String, dynamic> params) =>
      _client.postVoid(ChatPaths.editAccount, data: params);

  /// 修改账号，返回服务端的 `msg`
  ///
  /// 老端 `secure.vue` 失败/成功弹的都是 `res.msg`（「修改成功，请重新登陆」之类），
  /// 而 `postVoid` 会把 `msg` 丢掉，所以这两个接口各留一个带回执的出口。
  Future<String> editAccountMessage(Map<String, dynamic> params) async {
    final envelope = await _client.send(ChatPaths.editAccount, data: params);
    return envelope.msg ?? '';
  }

  Future<void> editPassword(Map<String, dynamic> params) =>
      _client.postVoid(ChatPaths.editPassword, data: params);

  /// 修改密码，返回服务端的 `msg`
  Future<String> editPasswordMessage(Map<String, dynamic> params) async {
    final envelope = await _client.send(ChatPaths.editPassword, data: params);
    return envelope.msg ?? '';
  }

  /// 注销账号（不可逆）。返回服务端的 `msg`（「账号已注销」）。
  ///
  /// 服务端那边要**再用密码确认一次**（客户端这层的二次弹窗只是防误触），
  /// 密码不对／是管理员账号都会被拒。
  Future<String> deleteAccountMessage(Map<String, dynamic> params) async {
    final envelope = await _client.send(ChatPaths.deleteAccount, data: params);
    return envelope.msg ?? '';
  }

  /// 扫码登录确认（老端 `msgApi.tokenLogin`）
  Future<Map<String, dynamic>> tokenLogin(Map<String, dynamic> params) =>
      _client.postMap(ChatPaths.tokenLogin, data: params);

  /// 扫码登录确认，返回服务端的 `msg`。
  ///
  /// 老端确认之后弹的就是 `res.msg`（「登录成功」之类），用 [tokenLogin] 的
  /// `postMap` 只会拿到 `data`，那句话就丢了。
  Future<String> tokenLoginMessage(Map<String, dynamic> params) async {
    final envelope = await _client.send(ChatPaths.tokenLogin, data: params);
    return envelope.msg ?? '';
  }

  /// 系统公告
  Future<Map<String, dynamic>> getAdminNotice([
    Map<String, dynamic> params = const {},
  ]) => _client.postMap(ChatPaths.adminNotice, data: params);

  // 表情（列表/上传/删除/移动）不在这里：见 `data/repo/emoji_repository.dart`
  // 与 `data/api/emoji_api.dart`。老端也分了两个文件，这里保持同样的切分。
}

final chatApiProvider = Provider<ChatApi>(
  (ref) => ChatApi(ref.watch(apiClientProvider)),
);
