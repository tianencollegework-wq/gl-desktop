import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import '../../domain/chat/conversation_rules.dart';
import '../model/conversation.dart';
import '../model/time_units.dart';
import 'app_database.dart';
import 'message_dao.dart';

/// 会话与草稿的数据库访问。
///
/// 用 `extension` 而不是 drift 的 `@DriftAccessor`：这类方法全是简单的
/// 增删改查，不需要再生成一层代码，也省掉 `part` 文件的折腾。
extension ConversationDao on AppDatabase {
  /// 读全部会话（顺序按老端规则：置顶在前、其余按最后消息时间倒序）
  Stream<List<Conversation>> watchConversations() =>
      select(dbConversations).watch().map(_sorted);

  Future<List<Conversation>> allConversations() async =>
      _sorted(await select(dbConversations).get());

  Future<Conversation?> findConversation(String id) async {
    final row = await (select(
      dbConversations,
    )..where((table) => table.id.equals(id))).getSingleOrNull();
    return row == null ? null : Conversation.fromRow(row);
  }

  /// 写入（新建或整体覆盖）。
  ///
  /// 注意给 [Conversation.draft] 留空：草稿在 [DbDrafts] 表里，
  /// 会话行上的 draft 列只是给"老端字段"留的位置，不参与读写。
  Future<void> upsertConversation(Conversation conversation) =>
      into(dbConversations).insertOnConflictUpdate(conversation.toCompanion());

  Future<void> upsertConversations(List<Conversation> conversations) async {
    if (conversations.isEmpty) return;
    await batch((batch) {
      batch.insertAllOnConflictUpdate(
        dbConversations,
        conversations.map((item) => item.toCompanion()).toList(),
      );
    });
  }

  /// 服务端同步：覆盖式写入（老端 `initContacts` 就是整份替换）
  ///
  /// **空列表不清本地**（与老端不同，刻意的）：老端没有本地历史，服务端返回空
  /// 数组时看不出区别；新端本地是真相，如果某次响应是空（token 过期、网关抽风、
  /// 分页参数异常），照搬"整份替换"就会把用户整个聊天列表抹掉。
  /// 所以：非空才做删除差集，空列表保留本地。
  Future<void> syncConversations(List<Conversation> conversations) async {
    if (conversations.isEmpty) {
      debugPrint('[会话] 服务端返回空列表，保留本地缓存（不清空聊天列表）');
      return;
    }
    await batch((batch) {
      batch.insertAllOnConflictUpdate(
        dbConversations,
        conversations.map((item) => item.toSyncCompanion()).toList(),
      );
      // 老端是全量替换：服务端不再返回的会话就从列表里去掉
      batch.deleteWhere(
        dbConversations,
        (table) =>
            table.id.isNotIn(conversations.map((item) => item.id).toList()),
      );
    });
  }

  /// 局部更新（老端 `updateContacts` 的 `Object.assign(contact, data)`）
  Future<void> patchConversation(
    String id,
    DbConversationsCompanion patch,
  ) async {
    await (update(dbConversations)..where((table) => table.id.equals(id)))
        .write(patch.copyWith(updatedAt: Value(nowMillis())));
  }

  /// 删除会话（连同它的聊天记录与草稿）
  Future<void> deleteConversation(String id) async {
    await (delete(dbConversations)..where((table) => table.id.equals(id))).go();
    await deleteMessages(id);
  }

  /// 清空某个会话的未读与 @ 计数
  /// 清未读。
  ///
  /// **只清 `unread`，不动 `is_at`**：老端进聊天页只把未读数归零，
  /// 「有人 @ 我」的角标要等你真的点开 @ 面板才清（`clearAt`）。
  /// 之前两者一起清，导致进一次聊天页 @ 角标就没了（组件测试抓出来的）。
  Future<void> clearUnread(String id) async {
    await (update(dbConversations)..where((table) => table.id.equals(id)))
        .write(const DbConversationsCompanion(unread: Value(0)));
  }

  /// 清掉**全部**会话（换账号登录时用，见 `ConversationRepository.wipeLocal`）
  Future<void> clearConversations() async => delete(dbConversations).go();

  // ------------------------------------------------------------------ 草稿

  /// 存/清草稿（老端 `draft_<会话 id>` 的等价物）
  Future<void> saveDraft(String conversationId, String content) =>
      patchConversation(
        conversationId,
        DbConversationsCompanion(draft: Value(content)),
      );

  Future<String> draftOf(String conversationId) async {
    final row = await (select(
      dbConversations,
    )..where((table) => table.id.equals(conversationId))).getSingleOrNull();
    return row?.draft ?? '';
  }

  List<Conversation> _sorted(List<DbConversation> rows) =>
      ConversationRules.topFirst(rows.map(Conversation.fromRow).toList());
}
