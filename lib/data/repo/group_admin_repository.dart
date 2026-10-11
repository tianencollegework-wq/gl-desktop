import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_exception.dart';
import '../../core/util/json_value.dart';
import '../../domain/chat/chat_sync_service.dart';
import '../../domain/chat/group_admin.dart';
import '../../domain/chat/group_join.dart';
import '../../domain/chat/group_members.dart';
import '../api/group_api.dart';
import '../db/app_database.dart';
// 会话/消息/通讯录的数据库方法都是 extension，必须 import
import '../db/conversation_dao.dart';
import '../db/message_dao.dart';
import '../model/conversation.dart';
import 'contact_repository.dart';
import 'conversation_repository.dart';

/// 「群成员」列表：成员（**含自己**，界面上要给自己打「我的」标签）+ 总数
class GroupMemberList {
  const GroupMemberList({required this.members, required this.count});

  final List<GroupMember> members;

  /// 信封里的 `count`（老端那个「查看全部群成员 N 人」用它）
  final int count;
}

/// 群管理（S5.3），对应老端 `pages/message/group/groupUser.vue` 与
/// `pages/message/detail.vue` 里那批 `/enterprise/group/*` 接口。
///
/// 与老端不同（刻意的）：
/// * 改名 / 退群 / 解散 / 清空记录**都会同步动本地库**（老端只调接口，
///   本地那份会话是等到下次整份同步才变，界面会短暂对不上）；
/// * 退群 / 解散之后本地会话与联系人一起删掉——服务端已经把关系断了，
///   留着只会在列表上留一条点进去报「联系人不存在」的死行。
class GroupAdminRepository {
  GroupAdminRepository(
    this._api,
    this._db,
    this._conversations,
    this._contacts, {
    required Future<void> Function(String groupId) bindClient,
    // 具名参数不能叫 `_bindClient`（下划线开头），所以只能这样赋值
    // ignore: prefer_initializing_formals
  }) : _bindClient = bindClient;

  final GroupApi _api;
  final AppDatabase _db;
  final ConversationRepository _conversations;
  final ContactRepository _contacts;

  /// 把本端 client 绑到新建的群上（实现在 [ChatSyncService.bindGroupClient]）。
  ///
  /// 做成钩子是为了让这一层不依赖 WS / 鉴权那两套东西（创建之外的群操作都用不到）。
  final Future<void> Function(String groupId) _bindClient;

  // --------------------------------------------------------------- 读

  /// 全部群成员（含自己）
  Future<GroupMemberList> members(String groupId) async {
    final page = await _api.userListPage(<String, dynamic>{
      'group_id': groupId,
    });
    return GroupMemberList(
      members: parseGroupMembers(page.rows),
      count: page.count == 0 ? page.rows.length : page.count,
    );
  }

  // --------------------------------------------------------------- 写

  /// 创建群聊（老端 `msgApi.addGroup({user_ids})` + `msgStore.appendContacts(res.data)`）。
  ///
  /// 返回新群 id。与老端不同（刻意的）：老端只把接口返回的那条塞进本地缓存，
  /// 等 `addGroup` 推送再补 `bindGroup`；这里**不赌推送**——建完就把 client 绑上，
  /// 并把通讯录与会话两处都写掉，这样点进新群立刻就能聊。
  Future<String> createGroup({required List<String> userIds}) async {
    if (userIds.isEmpty) {
      throw const BusinessException(400, '请选择人员');
    }
    // `notify: false`：这条路上提示由页面统一弹（同一句话弹两次很难看）
    final group = await _api.add(<String, dynamic>{
      'user_ids': userIds,
    }, notify: false);
    final id = asText(group['id']);
    if (id.isEmpty) {
      throw const UnknownApiException('创建群聊失败：服务端没有返回群 id');
    }
    await _registerGroup(group);
    return id;
  }

  /// 扫群二维码看到的「群资料」（老端 `pages/message/group/info.vue::getGroupInfo`）。
  ///
  /// ⚠️ 服务端这个接口**只认群成员**（`Group::groupInfo` 先 `checkGroupMember`，
  /// 不过就回一句「您没有操作权限！」）—— 未入群的人拉不到。扫群二维码那条路上
  /// 传 `notify: false`：那一句是**预期之内**的拒绝，不该糊到用户脸上，页面会用
  /// 扫码那一步服务端给的资料照常显示（见 [GroupJoinPage.scanned]）。
  Future<GroupJoinInfo> joinInfo(String groupId, {bool notify = true}) async {
    final data = await _api.groupInfo(<String, dynamic>{
      'group_id': groupId,
    }, notify: notify);
    return GroupJoinInfo.fromJson(<String, dynamic>{
      ...data,
      if (asText(data['id'] ?? data['group_id']).isEmpty) 'id': groupId,
    });
  }

  /// 加入群聊（老端 `joinGroup({group_id, inviteUid})`）。
  ///
  /// 与老端一致：成功后直接把这条塞进通讯录与会话，然后进群；
  /// 与老端不同（刻意的）：顺手绑一次 client（同 [createGroup]，不赌推送）。
  Future<void> join(
    String groupId, {
    String inviteUid = '',
    Map<String, dynamic> group = const <String, dynamic>{},
  }) async {
    await _api.joinGroup(<String, dynamic>{
      'group_id': groupId,
      'inviteUid': inviteUid,
    });
    await _registerGroup(<String, dynamic>{
      ...group,
      'id': groupId,
      'is_group': 1,
    });
  }

  /// 把一个新群写进本地（通讯录 + 会话）并把本端 client 绑上去。
  ///
  /// 「自己建群」与「扫别人的群二维码进群」走的是同一段——两边的差别只在
  /// 调哪个接口。
  Future<void> _registerGroup(Map<String, dynamic> group) async {
    final id = asText(group['id']);
    if (id.isEmpty) return;
    await _contacts.upsertFromServer(<String, dynamic>{
      ...group,
      'is_group': asInt(group['is_group'], 1),
    });
    await _conversations.upsert(Conversation.fromServerJson(group));
    try {
      await _bindClient(id);
    } on Object catch (error) {
      // 群已经建好/已经加入了：绑定只是「本端收不收到群消息」这一件事，
      // 失败不该让整件事失败
      debugPrint('[群] bindGroup 失败：$error');
    }
  }

  /// 修改群名称（老端 `editGroupName({id, displayName})`）
  Future<void> rename(String groupId, String displayName) async {
    await _api.editName(<String, dynamic>{
      'id': groupId,
      'displayName': displayName,
    });
    await _contacts.rename(groupId, displayName);
    await _conversations.renameLocal(groupId, displayName);
  }

  /// 修改群公告（老端 `setNotice({id, notice})`）。
  ///
  /// 公告存在会话行的 `extra.notice` 里（老端读的 `contact.notice` 就是服务端
  /// 会话列表那一行的字段），所以改完顺手把本地这一格也覆盖掉。
  Future<void> setNotice(String groupId, String notice) async {
    await _api.setNotice(<String, dynamic>{'id': groupId, 'notice': notice});
    final conversation = await _db.findConversation(groupId);
    if (conversation == null) return;
    final extra = Map<String, dynamic>.from(conversation.extra)
      ..['notice'] = notice;
    await _db.patchConversation(
      groupId,
      DbConversationsCompanion(extra: Value(jsonEncode(extra))),
    );
  }

  /// 保存群管理开关（老端 `groupSetting({id, setting})`）。
  ///
  /// 老端是「点一下改内存 → 点保存才发请求」，新端也一样：页面自己攒 setting，
  /// 这里只负责发。
  Future<void> saveSettings(String groupId, Map<String, dynamic> setting) =>
      _api.groupSetting(<String, dynamic>{'id': groupId, 'setting': setting});

  /// 设置/取消禁言（`choice == null` 是取消禁言）
  Future<void> muteMember({
    required String groupId,
    required String userId,
    NoSpeakChoice? choice,
  }) => _api.setNoSpeak(
    noSpeakPayload(groupId: groupId, userId: userId, choice: choice),
  );

  /// 设置 / 取消管理员（老端 `setManager({id, user_id, role})`，role 2 是管理员）
  Future<void> setManager({
    required String groupId,
    required String userId,
    required int role,
  }) => _api.setManager(<String, dynamic>{
    'id': groupId,
    'user_id': userId,
    'role': role,
  });

  /// 添加群成员（老端 `addGroupUser({user_ids, id})`，支持一次多个）
  Future<void> addMembers({
    required String groupId,
    required List<String> userIds,
  }) => _api.addUser(<String, dynamic>{'id': groupId, 'user_ids': userIds});

  /// 移出群成员（`is_black` 是那个「加入黑名单」开关）
  Future<void> removeMember({
    required String groupId,
    required String userId,
    bool isBlack = false,
  }) => _api.removeUser(<String, dynamic>{
    'id': groupId,
    'user_id': userId,
    'is_black': isBlack ? 1 : 0,
  });

  /// 转让群主（老端转让成功后 `reLaunch` 回首页——权限整个换了，留在原页没意义）
  Future<void> changeOwner({required String groupId, required String userId}) =>
      _api.changeOwner(<String, dynamic>{'id': groupId, 'user_id': userId});

  /// 解散群聊（群主）
  Future<void> disband(String groupId) async {
    await _api.removeGroup(<String, dynamic>{'id': groupId});
    await _forgetGroup(groupId);
  }

  /// 退出群聊（把自己移出成员列表）
  Future<void> quit(String groupId, String myUserId) async {
    await _api.removeUser(<String, dynamic>{
      'id': groupId,
      'user_id': myUserId,
      'is_black': 0,
    });
    await _forgetGroup(groupId);
  }

  /// 清空聊天记录（群主）：服务端清所有人的，本地也一起清
  Future<void> clearMessages(String groupId) async {
    await _api.clearMessage(<String, dynamic>{'id': groupId});
    await _db.deleteMessages(groupId);
  }

  /// 不在这个群里了：本地联系人 + 会话一起删（聊天记录随会话一起走）
  Future<void> _forgetGroup(String groupId) async {
    await _contacts.remove(groupId);
    await _conversations.removeLocal(groupId);
  }
}

final groupAdminRepositoryProvider = Provider<GroupAdminRepository>(
  (ref) => GroupAdminRepository(
    ref.watch(groupApiProvider),
    ref.watch(appDatabaseProvider),
    ref.watch(conversationRepositoryProvider),
    ref.watch(contactRepositoryProvider),
    bindClient: (groupId) =>
        ref.watch(chatSyncServiceProvider).bindGroupClient(groupId),
  ),
);
