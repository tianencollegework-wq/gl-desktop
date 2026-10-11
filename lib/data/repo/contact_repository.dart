import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_exception.dart';
import '../../core/util/json_value.dart';
import '../../domain/chat/forward_targets.dart';
import '../../domain/contacts/friend_apply.dart';
import '../api/chat_api.dart';
import '../api/friend_api.dart';
import '../db/app_database.dart';
// 通讯录的数据库方法是以 extension 形式提供的，必须 import 才会进作用域
import '../db/contact_dao.dart';
// 会话行（聊天列表与聊天页标题）的改法也在 extension 里
import '../db/conversation_dao.dart';
import '../model/contact.dart';
import '../model/user_detail.dart';

/// 通讯录仓库（S5.1）。
///
/// 老端的数据流：`friendList` / `groupList` 两份整份 JSON 塞在 storage 里，
/// 任何一个增量变化（`friendUpdate++`）都触发「重新调接口 → 整份替换」；
/// 未读数全靠内存。
///
/// 新端：落 SQLite，界面订阅流；接口只在进通讯录/下拉刷新时对齐一次，
/// WS 推来的增量（`appendContact` / `addGroup` / `isOnline` / `editGroupName` …）
/// 直接改一行。
class ContactRepository {
  ContactRepository(this._db, this._api, this._friendApi);

  final AppDatabase _db;
  final ChatApi _api;
  final FriendApi _friendApi;

  /// 全部通讯录（好友 + 群聊 + 系统通知）
  Stream<List<Contact>> watch() => _db.watchContacts();

  Stream<List<Contact>> watchFriends() => _db.watchFriends();

  Stream<List<Contact>> watchGroups() => _db.watchGroups();

  Stream<List<Contact>> watchSystems() => _db.watchSystems();

  Future<List<Contact>> all() => _db.allContacts();

  Future<Contact?> find(String id) => _db.findContact(id);

  /// 从服务端对齐通讯录。
  ///
  /// 两个接口分开 try/catch（与老端 `getFriendList` / `getGroupList` 各自
  /// `try` 一致）：群聊列表塌了不该让好友列表也用不了。
  /// 任何一份拉到内容都会落库，**空响应保留本地**。
  Future<void> syncFromServer() async {
    try {
      final friends = await _api.getFriendList();
      final contacts = <Contact>[];
      for (final row in friends) {
        final contact = Contact.fromServerJson(row);
        if (contact.id.isEmpty) continue; // 脏数据跳过
        contacts.add(contact);
      }
      // 这个接口同时给好友（0）与系统通知（2）
      await _db.syncContacts(contacts, kinds: const <int>{0, 2});
    } on ApiException catch (error) {
      debugPrint('[通讯录] 好友列表同步失败：${error.message}');
    }

    try {
      final groups = await _api.getGroupList();
      final contacts = <Contact>[];
      for (final row in groups) {
        final contact = Contact.fromServerJson(row);
        if (contact.id.isEmpty) continue;
        contacts.add(contact);
      }
      await _db.syncContacts(contacts, kinds: const <int>{1});
    } on ApiException catch (error) {
      debugPrint('[通讯录] 群聊列表同步失败：${error.message}');
    }
  }

  /// 待处理的好友申请数（通讯录「新的朋友」那个红点）。
  ///
  /// **与老端不同**：老端那个角标挂的是「系统消息未读数」（`getChatList().count`
  /// 塞进 `sysUnread`），跟「有几个新朋友申请」其实不是一回事。
  /// 新端直接数申请列表里 `status == 2`（待处理）的条数。
  Future<int> pendingApplyCount() async {
    try {
      final page = await _friendApi.applyPage(<String, dynamic>{
        'page': 1,
        // 只为计数，取一页足够（老端也是一页 10 条）
        'limit': 50,
        'is_mine': 0,
      });
      // 与「新朋友」页共用同一套解析（状态口径只有一处）
      return countPendingApplies(parseApplyRows(page.rows));
    } on ApiException catch (error) {
      debugPrint('[通讯录] 好友申请数取不到：${error.message}');
      return 0;
    }
  }

  // ------------------------------------------------- 用户详情与好友操作（S5.2）

  /// 用户详情（老端 `getUserInfo({user_id, group_id})`）。
  ///
  /// `group_id` 只有从群成员列表点进来时才有（详情页里那个「群成员管理」块要用），
  /// 老端不传时会序列化出一个 `undefined`，这里直接不发这个键。
  ///
  /// 而且**只有服务端那种群会话 id（`group-5`）才发出去**：`Im::getUserInfo` 里是
  /// `explode('-', $group_id)[1]`（没有兜底），拿单聊会话 id（那本来就是对方的
  /// `user_id`，如 `5`）当 `group_id` 发过去会踩 PHP 的 undefined offset，
  /// ThinkPHP 把 notice 抛成异常 → HTTP 500 → 客户端只看到「服务器繁忙，请稍后再试」。
  /// 单聊里从聊天信息页点对方头像就是这么炸的（老端那里有 `is_group==1` 判断）。
  Future<UserDetail> userDetail(String userId, {String groupId = ''}) async {
    final group = groupId.trim();
    final json = await _api.getUserInfo(<String, dynamic>{
      'user_id': userId,
      if (group.startsWith(_groupConversationPrefix)) 'group_id': group,
    });
    return UserDetail.fromServerJson(json);
  }

  /// 群会话 id 的形状（老端 `group-5`；服务端那几个群管理接口也按这个 `explode`）
  static const String _groupConversationPrefix = 'group-';

  /// 添加好友（`{user_id, remark}`），返回服务端的 `msg`
  Future<String> addFriend({required String userId, required String remark}) =>
      _friendApi.add(<String, dynamic>{'user_id': userId, 'remark': remark});

  /// 删除好友（`{id, is_black}`），成功后**连本地通讯录一起删**。
  ///
  /// 本地会话（聊天记录）刻意留着：老端删好友后是 `reLaunch` 跳回消息页，
  /// 那条会话还在服务端；把本地记录抹掉反而会把历史消息也删了，不好。
  Future<String> deleteFriend(String userId, {bool isBlack = false}) async {
    final message = await _friendApi.del(<String, dynamic>{
      'id': idValue(userId),
      'is_black': isBlack ? 1 : 0,
    });
    await _db.deleteContact(userId);
    return message;
  }

  /// 设置 / 清空好友备注（`{friend_id, nickname}`），成功后改本地的显示名。
  ///
  /// **老端这边有个笔误**：它写的是 `msgStore.updateContacts({id: this.detaild.user_id, …})`
  /// （多了一个 `d`），拿到的是 `undefined`，所以备注只改了当前详情页，
  /// 回到通讯录还是旧名字。新端真的落库（`displayName` 就是列表上显示的名字）。
  ///
  /// [fallbackName] 是备注清空时用来兜底的显示名（对方的真实昵称）—— 之前空输入
  /// 被直接拦下，备注一旦设过就再也去不掉，现在清空会回到真名（服务端要配合
  /// 收下空串，见 `Friend::setNickname` 那个补丁）。
  ///
  /// 会话行（聊天列表与聊天页标题读的是它）一起改：备注变了名字却没变，
  /// 看着就像没生效。
  Future<String> setFriendNickname({
    required String userId,
    required String friendId,
    required String nickname,
    String fallbackName = '',
  }) async {
    final message = await _friendApi.setNickname(<String, dynamic>{
      'friend_id': idValue(friendId),
      'nickname': nickname,
    });
    final displayName = nickname.isEmpty ? fallbackName : nickname;
    await _db.patchContact(
      userId,
      DbContactsCompanion(displayName: Value(displayName)),
    );
    await _db.patchConversation(
      userId,
      DbConversationsCompanion(displayName: Value(displayName)),
    );
    return message;
  }

  // ------------------------------------------------------------- WS 增量

  /// WS `appendContact`（新好友）/ `addGroup`（被拉进群）：写入或补一条
  Future<void> upsertFromServer(Map<String, dynamic> data) async {
    final contact = Contact.fromServerJson(data);
    if (contact.id.isEmpty) return;
    // 推送里没带 is_group 时按好友处理（老端也只信 data 自己带的字段）
    await _db.upsertContact(contact);
    debugPrint('[通讯录] 新增联系人：${contact.id}（is_group=${contact.isGroup}）');
  }

  /// WS `isOnline`：在线状态（好友列表上的小绿点）
  Future<void> setOnline(String id, int isOnline) =>
      _db.patchContact(id, DbContactsCompanion(isOnline: Value(isOnline)));

  /// WS `editGroupName`：改名
  Future<void> rename(String id, String displayName) => _db.patchContact(
    id,
    DbContactsCompanion(displayName: Value(displayName)),
  );

  /// WS `removeGroup` / 自己被移出群聊
  Future<void> remove(String id) => _db.deleteContact(id);

  /// 登出：清空本地通讯录（换账号不该看到上一个人的好友）
  Future<void> clear() => _db.clearContacts();

  /// 可转发的目标（好友 + 群聊，排除当前会话）。
  ///
  /// 仍然走接口现拉：通讯录落库之后本可以直接读本地，但 S4.5 的转发弹层
  /// 已经有测试钉在「拉接口」这条路上，等 S5.1 收尾时再一起改成读本地
  /// （见规划书 S5.1 的待办）。老端把两个请求分开 try/catch（群聊失败就当没有群），
  /// 这里也一样：好友列表塌了才算失败，群列表塌了只少几个群。
  Future<List<ForwardTarget>> forwardTargets({String? excludeId}) async {
    final friends = await _api.getFriendList();
    var groups = <Map<String, dynamic>>[];
    try {
      groups = await _api.getGroupList();
    } on Object catch (error) {
      debugPrint('[通讯录] 群聊列表取不到，转发候选里少几个群：$error');
    }
    return parseForwardTargets(
      friends: friends,
      groups: groups,
      excludeId: excludeId,
    );
  }
}

final contactRepositoryProvider = Provider<ContactRepository>(
  (ref) => ContactRepository(
    ref.watch(appDatabaseProvider),
    ref.watch(chatApiProvider),
    ref.watch(friendApiProvider),
  ),
);

/// 转发候选（按当前会话 id 排除自己）
final forwardTargetsProvider = FutureProvider.autoDispose
    .family<List<ForwardTarget>, String>((ref, excludeId) {
      return ref
          .watch(contactRepositoryProvider)
          .forwardTargets(excludeId: excludeId);
    });

/// 好友列表（通讯录主页订阅它）
final friendListProvider = StreamProvider<List<Contact>>(
  (ref) => ref.watch(contactRepositoryProvider).watchFriends(),
);

/// 群聊列表
final groupListProvider = StreamProvider<List<Contact>>(
  (ref) => ref.watch(contactRepositoryProvider).watchGroups(),
);

/// 系统通知会话（通讯录顶部那几行）
final systemContactProvider = StreamProvider<List<Contact>>(
  (ref) => ref.watch(contactRepositoryProvider).watchSystems(),
);

/// 待处理好友申请数（「新的朋友」的红点）
final pendingApplyCountProvider = FutureProvider.autoDispose<int>(
  (ref) => ref.watch(contactRepositoryProvider).pendingApplyCount(),
);
