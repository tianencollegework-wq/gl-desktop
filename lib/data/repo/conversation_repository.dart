import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_exception.dart';
import '../../core/store/cleared_chats.dart';
import '../../core/store/hidden_conversations.dart';
import '../../core/util/json_value.dart';
import '../../domain/chat/conversation_rules.dart';
import '../api/chat_api.dart';
import '../db/app_database.dart';
// 会话/消息的数据库方法是以 extension 形式提供的，必须 import 才会进作用域
import '../db/conversation_dao.dart';
import '../db/message_dao.dart';
import '../model/contact.dart';
import '../model/conversation.dart';
import '../model/message.dart';

/// 会话仓库（S3.3）。
///
/// 老端的会话数据流：每次进消息页调 `getContacts` → 整份塞进
/// `uni.setStorageSync('allContacts')` 与 `mainContacts`，之后所有增删改
/// 都是"读出整份数组 → 改 → 写回整份"，并且未读、置顶、免打扰
/// 这些状态全靠前端自己维护，重装/清缓存即丢。
///
/// 新端的会话数据流：
/// * 本地 SQLite 是唯一真相（UI 直接订阅 `watch()` 的流，进页面秒开）；
/// * 接口只在启动/下拉刷新时做一次全量对齐（[syncFromServer]）；
/// * 推送消息用 [applyIncomingMessage] 增量更新（不重写整表）。
class ConversationRepository {
  ConversationRepository(this._db, this._api);

  final AppDatabase _db;
  final ChatApi _api;

  /// 会话列表（已按老端规则排序：置顶在前、其余按最后消息时间倒序）
  Stream<List<Conversation>> watch() => _db.watchConversations();

  /// 换账号登录时把本机的会话与消息清掉（**同账号重新登录不清**，调用方判断）。
  ///
  /// 为什么非清不可：本机这份数据**没有账号维度**，而「我的收藏」的会话 id 是
  /// **固定的 `-1`**（系统通知是 `system`，其它会话 id 都是对方的 `user_id`）。
  /// 同一台手机先登 a 再登 b 时，a 的收藏与 b 的收藏会落在本机**同一条会话**里，
  /// 看起来像两个人在一个群里说话（用户 2026-09-21 报的）。
  ///
  /// 服务端是按人的（收藏的记录标识 `chat_identify` 里含 `user_id`，见
  /// `Message::sendMessage` 里 `toContactId == -1` 那一段），所以清掉的只是
  /// **本机缓存**：重新登录时会话列表会重新拉，聊天记录进会话时按需分页拉回来。
  Future<void> wipeLocal() async {
    await _db.clearConversations();
    await _db.clearMessages();
  }

  Future<List<Conversation>> all() => _db.allConversations();

  /// 按 id 取一条会话（聊天页进页时用）
  Future<Conversation?> find(String id) => _db.findConversation(id);

  /// 「清空聊天记录」之后：把那行的预览与未读抹掉，**会话本身留着**。
  ///
  /// 微信清空聊天记录后聊天还在列表里，只是那一行空了 —— 删会话是另一件事
  /// （长按 → 删除该聊天，走的是 [removeLocal] 那条路）。
  Future<void> clearPreview(String id) => _db.patchConversation(
    id,
    const DbConversationsCompanion(
      lastContent: Value(''),
      unread: Value(0),
      isAt: Value(0),
    ),
  );

  Stream<Conversation?> watchOne(String id) =>
      _db.watchConversations().map((list) => _firstWhereOrNull(list, id));

  /// 未读汇总（老端 `store/message.js` 里的 `unread` / `msgAt` / `unreadIds`）
  Stream<Totals> watchTotals() => watch().map(ConversationRules.totals);

  Future<Totals> totals() async => ConversationRules.totals(await all());

  /// 从服务端全量对齐。
  ///
  /// 与老端一致：服务端不再返回的会话会从本地列表消失（老端是整份替换）。
  /// 本地独有的东西不受影响——草稿在会话行的 `draft` 列里，
  /// 而同步用的是不含 `draft` 的 [Conversation.toSyncCompanion]。
  Future<List<Conversation>> syncFromServer() async {
    final rows = await _api.getContacts();
    final conversations = <Conversation>[];
    for (final row in rows) {
      var conversation = Conversation.fromServerJson(row);
      if (conversation.id.isEmpty) continue; // 脏数据直接跳过，不让它污染列表
      conversation = _blankClearedPreview(conversation);
      conversations.add(conversation);
    }
    await _db.syncConversations(conversations);
    return conversations;
  }

  /// 「清空聊天记录」过的会话：服务端列表里那行预览还是旧消息，抹掉。
  ///
  /// 只看最后一条的 `sendTime` 是不是当初被清掉的那条 —— 之后再来新消息，
  /// `sendTime` 变了，预览自然就正常显示了。
  Conversation _blankClearedPreview(Conversation conversation) {
    final cleared = ClearedChatsStore.instance;
    if (!cleared.hidesPreview(conversation.id, conversation.lastSendTime)) {
      return conversation;
    }
    return conversation.copyWith(lastContent: '', unread: 0, isAt: 0);
  }

  /// 推送消息落地到会话（老端 `App.vue::appendMessage` 的等价物）。
  ///
  /// 返回更新后的会话；调用方通常不需要它，但测试与"新会话"提示要用到。
  Future<Conversation?> applyIncomingMessage(
    Message message, {
    required String myUserId,
  }) async {
    if (message.conversationId.isEmpty) return null;
    // 系统消息不建会话（老端只把 `sysUnread` 加一）
    if (message.conversationId == 'system') return null;

    final existing = await _db.findConversation(message.conversationId);
    final result = ConversationRules.applyIncoming(
      existing: existing,
      message: message,
      myUserId: myUserId,
    );

    if (existing == null) {
      await _db.upsertConversation(result.conversation);
    } else {
      // 只写变化的列：避免把本地草稿、extra 等服务端没有的字段覆盖掉
      await _db.patchConversation(
        message.conversationId,
        DbConversationsCompanion(
          lastContent: Value(result.conversation.lastContent),
          lastSendTime: Value(result.conversation.lastSendTime),
          lastType: Value(result.conversation.lastType),
          unread: Value(result.conversation.unread),
          isAt: Value(result.conversation.isAt),
        ),
      );
    }
    return result.conversation;
  }

  /// 置顶（本地立即生效，接口失败只记日志——老端是等接口成功才改本地）
  ///
  /// `is_group` 是老端必传的字段（`pages/message/index.vue::btnTap`），照抄。
  Future<void> setTop(String id, int isTop, {required int isGroup}) async {
    await _db.patchConversation(
      id,
      DbConversationsCompanion(isTop: Value(isTop)),
    );
    try {
      await _api.setChatTop(<String, dynamic>{
        'id': id,
        'is_top': isTop,
        'is_group': isGroup,
      });
    } on ApiException catch (error) {
      debugPrint('[会话] 置顶同步失败：${error.message}');
    }
  }

  /// 免打扰
  Future<void> setNotice(
    String id,
    int isNotice, {
    required int isGroup,
  }) async {
    await _db.patchConversation(
      id,
      DbConversationsCompanion(isNotice: Value(isNotice)),
    );
    try {
      await _api.isNotice(<String, dynamic>{
        'id': id,
        'is_notice': isNotice,
        'is_group': isGroup,
      });
    } on ApiException catch (error) {
      debugPrint('[会话] 免打扰同步失败：${error.message}');
    }
  }

  /// 在线状态（WS `isOnline`）
  Future<void> setOnline(String id, int isOnline) => _db.patchConversation(
    id,
    DbConversationsCompanion(isOnline: Value(isOnline)),
  );

  /// 只删本地（WS `removeGroup` / 被移出群聊时用：服务端已经删了，别再调接口）
  Future<void> removeLocal(String id) => _db.deleteConversation(id);

  /// 删除会话（同时清掉本地聊天记录）
  Future<void> remove(String id, {required int isGroup}) async {
    await _db.deleteConversation(id);
    try {
      await _api.delChat(<String, dynamic>{'id': id, 'is_group': isGroup});
    } on ApiException catch (error) {
      debugPrint('[会话] 删除同步失败：${error.message}');
    }
  }

  /// 清未读（进聊天页时调用；老端只改本地，不调接口）
  Future<void> markReadLocally(String id) async {
    await _db.clearUnread(id);
    await _db.markConversationRead(id);
  }

  /// 「标为未读」（微信长按菜单那一项）：只改本地，不上报服务端。
  ///
  /// 下次从服务端对齐会话列表时会被服务端的未读数覆盖 —— 这是预期，
  /// 因为这个动作在老端/协议里都不存在，纯属本机标记。
  Future<void> markUnread(String id) async {
    await _db.patchConversation(
      id,
      const DbConversationsCompanion(unread: Value(1)),
    );
  }

  /// 清 @ 提醒（老端打开 @ 面板时调 `readAtMsg`）
  Future<void> clearAt(String id) async {
    await _db.patchConversation(
      id,
      const DbConversationsCompanion(isAt: Value(0)),
    );
    try {
      await _api.readAtMsg(<String, dynamic>{'toContactId': id});
    } on ApiException catch (error) {
      debugPrint('[会话] 清 @ 失败：${error.message}');
    }
  }

  /// 服务端同步过来的会话字段（WS `setChatTop` / `setIsNotice` / 群相关事件）
  Future<void> applyServerPatch(
    String id, {
    int? isTop,
    int? isNotice,
    int? isOnline,
    String? avatar,
    String? displayName,
    int? role,
  }) => _db.patchConversation(
    id,
    DbConversationsCompanion(
      isTop: isTop == null ? const Value.absent() : Value(isTop),
      isNotice: isNotice == null ? const Value.absent() : Value(isNotice),
      isOnline: isOnline == null ? const Value.absent() : Value(isOnline),
      avatar: avatar == null ? const Value.absent() : Value(avatar),
      displayName: displayName == null
          ? const Value.absent()
          : Value(displayName),
      role: role == null ? const Value.absent() : Value(role),
    ),
  );

  /// 新增/补齐一个会话（WS `addGroup` / `appendContact`）
  Future<void> upsert(Conversation conversation) =>
      _db.upsertConversation(conversation);

  /// 推送里带的 `contactInfo`（陌生会话）直接建一条
  Future<void> ensureFromContactInfo(Map<String, dynamic> contactInfo) async {
    final id = asText(contactInfo['id']);
    if (id.isEmpty) return;
    if (await _db.findConversation(id) != null) return;
    await _db.upsertConversation(Conversation.fromContactInfo(contactInfo));
  }

  /// 从通讯录点进一个**还没聊过**的会话（群聊列表 / 新朋友里的「发消息」）。
  ///
  /// 老端是先 `appendContacts(items)` 把这项补进 `mainContacts`，再 `navigateTo`
  /// 聊天页；新端聊天页认的是**本地库里的会话行**，没有就会显示「联系人不存在」，
  /// 所以这一步不能省。已存在就原样返回（不覆盖未读、草稿、置顶这些本地状态）。
  Future<Conversation> ensureFromContact(Contact contact) async {
    final existing = await _db.findConversation(contact.id);
    if (existing != null) return existing;
    final conversation = Conversation(
      id: contact.id,
      displayName: contact.title,
      avatar: contact.avatar,
      isGroup: contact.isGroup,
      role: contact.role,
      isOnline: contact.isOnline,
    );
    await _db.upsertConversation(conversation);
    return conversation;
  }

  /// 改会话显示名（本地）。
  ///
  /// 用在「改群名」与「改好友备注」上：名称是两个接口的结果，但列表读的是本地这列，
  /// 不跟着改就会出现「详情页叫新名字、列表还是旧名字」。
  Future<void> renameLocal(String id, String displayName) =>
      _db.patchConversation(
        id,
        DbConversationsCompanion(displayName: Value(displayName)),
      );

  /// 存草稿
  Future<void> saveDraft(String id, String content) =>
      _db.saveDraft(id, content);

  Future<String> draft(String id) => _db.draftOf(id);
}

Conversation? _firstWhereOrNull(List<Conversation> list, String id) {
  for (final item in list) {
    if (item.id == id) return item;
  }
  return null;
}

final conversationRepositoryProvider = Provider<ConversationRepository>(
  (ref) => ConversationRepository(
    ref.watch(appDatabaseProvider),
    ref.watch(chatApiProvider),
  ),
);

/// 会话列表（UI 直接订阅这个流）
final conversationListProvider = StreamProvider<List<Conversation>>(
  (ref) => ref.watch(conversationRepositoryProvider).watch(),
);

/// 未读汇总（底部 tab 的红点与消息页角标都用它）
final conversationTotalsProvider = StreamProvider<Totals>(
  (ref) => ref.watch(conversationRepositoryProvider).watchTotals(),
);

/// 真正显示在列表里的会话：「不显示该聊天」藏掉的那些不算。
///
/// 列表与红点都要走这个（而不是 [conversationListProvider] / [conversationTotalsProvider]），
/// 否则会出现「底部有红点、列表里找不到那个会话」。
final visibleConversationsProvider = Provider<AsyncValue<List<Conversation>>>((
  ref,
) {
  final hidden = ref.watch(hiddenConversationsProvider);
  return ref
      .watch(conversationListProvider)
      .whenData(
        (list) => list.where((item) => !hidden.contains(item.id)).toList(),
      );
});

/// 与可见列表口径一致的未读汇总
final visibleTotalsProvider = Provider<AsyncValue<Totals>>((ref) {
  final hidden = ref.watch(hiddenConversationsProvider);
  return ref
      .watch(conversationListProvider)
      .whenData(
        (list) => ConversationRules.totals(
          list.where((item) => !hidden.contains(item.id)),
        ),
      );
});
