import 'package:drift/drift.dart';

import '../model/message.dart';
import 'app_database.dart';

/// 消息的数据库访问。
extension MessageDao on AppDatabase {
  /// 某个会话最新的若干条（升序：早 → 晚，方便直接铺进聊天列表）
  Stream<List<Message>> watchConversation(
    String conversationId, {
    int limit = 50,
  }) {
    final query = select(dbMessages)
      ..where((table) => table.conversationId.equals(conversationId))
      ..orderBy(<OrderClauseGenerator<$DbMessagesTable>>[
        (table) => OrderingTerm.desc(table.sendTime),
        (table) => OrderingTerm.desc(table.localId),
      ])
      ..limit(limit);
    return query.watch().map(_ascending);
  }

  Future<List<Message>> messagesFor(
    String conversationId, {
    int limit = 50,
  }) async {
    final query = select(dbMessages)
      ..where((table) => table.conversationId.equals(conversationId))
      ..orderBy(<OrderClauseGenerator<$DbMessagesTable>>[
        (table) => OrderingTerm.desc(table.sendTime),
        (table) => OrderingTerm.desc(table.localId),
      ])
      ..limit(limit);
    return _ascending(await query.get());
  }

  /// 最旧一条的 `msg_id`（老端 `getMessageList` 的 `last_id` 游标）
  Future<Message?> oldestMessage(String conversationId) async {
    final query = select(dbMessages)
      ..where((table) => table.conversationId.equals(conversationId))
      ..orderBy(<OrderClauseGenerator<$DbMessagesTable>>[
        (table) => OrderingTerm.asc(table.sendTime),
        (table) => OrderingTerm.asc(table.localId),
      ])
      ..limit(1);
    final rows = await query.get();
    return rows.isEmpty ? null : Message.fromRow(rows.first);
  }

  Future<int> messageCount(String conversationId) async {
    final count = dbMessages.localId.count();
    final query = selectOnly(dbMessages)
      ..addColumns(<Expression<Object>>[count])
      ..where(dbMessages.conversationId.equals(conversationId));
    final row = await query.getSingle();
    return row.read(count) ?? 0;
  }

  /// 有没有这条消息（老端 `checkMsg`：按服务端 id 判重）
  Future<bool> hasMessage({
    required String conversationId,
    int? serverId,
    String? msgId,
    String? clientId,
  }) async {
    if (serverId == null &&
        (msgId == null || msgId.isEmpty) &&
        (clientId == null || clientId.isEmpty)) {
      return false;
    }
    final query = select(dbMessages)
      ..where((table) => table.conversationId.equals(conversationId))
      ..limit(1);
    if (serverId != null) {
      query.where((table) => table.serverId.equals(serverId));
    } else if (msgId != null && msgId.isNotEmpty) {
      query.where((table) => table.msgId.equals(msgId));
    } else {
      query.where((table) => table.clientId.equals(clientId!));
    }
    return (await query.get()).isNotEmpty;
  }

  /// 写入一批消息，按「服务端 id / msg_id / 本机 clientId」去重。
  ///
  /// 为什么要手写去重而不是 `insertOnConflictUpdate`：冲突键有好几个
  /// （服务端 `id`、业务 `msg_id`、本机 uuid），而且推送消息可能只有其中一个，
  /// 用唯一索引硬撞会直接抛异常。这里先查再决定插还是改，语义可控。
  ///
  /// 最后一层是 [claimOutgoing]：服务端回显自己发的消息时，可能三个 id 都对不上
  /// （服务端到底回传哪个字段没实测过），那就按"同一会话 + 同一发送人 + 同内容 +
  /// 时间接近 + 本地还在 going"认领那条乐观消息，避免出现两条一样的。
  Future<int> upsertMessages(List<Message> messages) async {
    if (messages.isEmpty) return 0;
    var inserted = 0;
    await transaction(() async {
      for (final message in messages) {
        final existing = await _findExisting(message);
        final target = existing ?? await claimOutgoing(message);
        final targetId = target?.localId;
        if (targetId == null) {
          await into(dbMessages).insert(message.toCompanion());
          inserted += 1;
        } else if (target != null) {
          // 叠加而不是整行覆盖：推送可能只带一个 id 与状态（老端是 `Object.assign`）
          await (update(dbMessages)
                ..where((table) => table.localId.equals(targetId)))
              .write(target.overlayWith(message).toCompanion());
        }
      }
    });
    return inserted;
  }

  /// 认领"本机发出去、还没拿到回执"的那条消息（见 [upsertMessages]）。
  ///
  /// 条件收得比较紧，两类才会被认领：
  /// * 还在 [MessageStatus.going] 的（接口还没回）；
  /// * 接口回了、但**一个服务端 id 都没拿到**的（服务端只回了 `{}` 那种）。
  ///
  /// 已经拿到服务端 id 的行不会被认领——那种情况用 id 就能匹配上，
  /// 靠"同内容"去猜反而会把两条真的一样的消息弄丢。
  Future<Message?> claimOutgoing(Message incoming) async {
    if (incoming.fromUserId.isEmpty) return null;
    final query = select(dbMessages)
      ..where(
        (table) =>
            table.conversationId.equals(incoming.conversationId) &
            table.fromUserId.equals(incoming.fromUserId) &
            table.type.equals(incoming.type) &
            table.content.equals(incoming.content) &
            (table.status.equals(MessageStatus.going) |
                (table.serverId.isNull() & table.msgId.isNull())),
      )
      ..orderBy(<OrderClauseGenerator<$DbMessagesTable>>[
        (table) => OrderingTerm.desc(table.sendTime),
      ])
      ..limit(1);
    final rows = await query.get();
    if (rows.isEmpty) return null;
    final candidate = Message.fromRow(rows.first);
    // 时间差太大就不是同一条了（同一句话隔很久又发一遍）
    final gap = (candidate.sendTime - incoming.sendTime).abs();
    if (gap > _claimWindowMs) return null;
    return candidate;
  }

  /// 插一条「乐观消息」（本机刚发、还没拿到回执）。
  ///
  /// 返回自增的 `localId`，调用方拿着它去标状态。
  Future<int> insertOptimistic(Message message) async {
    final companion = message.toCompanion().copyWith(
      localId: const Value.absent(),
    );
    return into(dbMessages).insert(companion);
  }

  /// 删一条（服务端明确拒绝时用，老端是 `messageList.pop()`）
  Future<void> deleteMessage(int localId) async {
    await (delete(
      dbMessages,
    )..where((table) => table.localId.equals(localId))).go();
  }

  /// 单条消息的局部更新（撤回、编辑重发等）
  Future<void> patchMessage(int localId, DbMessagesCompanion patch) async {
    await (update(
      dbMessages,
    )..where((table) => table.localId.equals(localId))).write(patch);
  }

  /// 按服务端 id / msg_id / 本机 clientId 找一条
  Future<Message?> findMessage(
    String conversationId, {
    int? serverId,
    String? msgId,
    String? clientId,
  }) async {
    final query = select(dbMessages)
      ..where((table) => table.conversationId.equals(conversationId))
      ..limit(1);
    if (serverId != null) {
      query.where((table) => table.serverId.equals(serverId));
    } else if (msgId != null && msgId.isNotEmpty) {
      query.where((table) => table.msgId.equals(msgId));
    } else if (clientId != null && clientId.isNotEmpty) {
      query.where((table) => table.clientId.equals(clientId));
    } else {
      return null;
    }
    final rows = await query.get();
    return rows.isEmpty ? null : Message.fromRow(rows.first);
  }

  /// 把一条乐观消息流转到指定状态（发送成功 / 失败 / 重发）
  Future<void> setStatus(int localId, String status) =>
      patchMessage(localId, DbMessagesCompanion(status: Value(status)));

  /// 标记整个会话已读（老端进聊天页会调 `setMsgIsRead` 并把未读清零）
  Future<void> markConversationRead(String conversationId) async {
    await (update(dbMessages)
          ..where((table) => table.conversationId.equals(conversationId)))
        .write(const DbMessagesCompanion(isRead: Value(1)));
  }

  /// 某个会话里未读的消息数量（本地视角，用于校验未读上报）
  Future<int> unreadCount(String conversationId) async {
    final count = dbMessages.localId.count();
    final query = selectOnly(dbMessages)
      ..addColumns(<Expression<Object>>[count])
      ..where(
        dbMessages.conversationId.equals(conversationId) &
            dbMessages.isRead.equals(0),
      );
    final row = await query.getSingle();
    return row.read(count) ?? 0;
  }

  /// 某个会话里「还没读、且是别人发的」那几个发送人（去重，最近发消息的在前）。
  ///
  /// 用途：进聊天页时把未读在**服务端**也标掉。`setMsgIsRead` 是按发送人上报的
  /// （`{toContactId, is_group, fromUser}`），所以这里要给出是哪些人发来的。
  /// 不这么做的话，服务端的未读一直是旧的，下拉刷新（`getContacts`）
  /// 会把刚读完的角标又带回来。
  ///
  /// [limit] 是安全阀（一个群里几十人同时发消息时不要刷屏）：老端是每收到一条
  /// 就上报一次，所以按人汇总本身就已经比它省。
  Future<List<String>> unreadSenders(
    String conversationId, {
    required String myUserId,
    int limit = 20,
  }) async {
    final query = select(dbMessages)
      ..where(
        (table) =>
            table.conversationId.equals(conversationId) &
            table.isRead.equals(0),
      )
      ..orderBy(<OrderClauseGenerator<$DbMessagesTable>>[
        (table) => OrderingTerm.desc(table.sendTime),
        (table) => OrderingTerm.desc(table.localId),
      ]);
    final rows = await query.get();
    final senders = <String>[];
    for (final row in rows) {
      final id = row.fromUserId;
      // 自己发的不算未读（本地乐观消息默认 isRead == 0）
      if (id.isEmpty || id == myUserId) continue;
      if (senders.contains(id)) continue;
      senders.add(id);
      if (senders.length >= limit) break;
    }
    return senders;
  }

  /// 这个会话里 @ 到我的消息（新 → 旧）。
  ///
  /// `atUsers` 列存的是 JSON 数组，所以用 `LIKE '%"u3"%'` 匹配。
  /// 老端是从服务端 `getMessageInfo` / `atMsgList` 拿这份数据（每次进聊天页还
  /// 要在内存里维护一份），新端本地就是全部历史，直接查库。
  Future<List<Message>> messagesMentioning(
    String conversationId,
    String userId, {
    int limit = 50,
  }) async {
    if (userId.isEmpty) return const <Message>[];
    final query = select(dbMessages)
      ..where(
        (table) =>
            table.conversationId.equals(conversationId) &
            table.atUsers.like('%"$userId"%'),
      )
      ..orderBy(<OrderClauseGenerator<$DbMessagesTable>>[
        (table) => OrderingTerm.desc(table.sendTime),
        (table) => OrderingTerm.desc(table.localId),
      ])
      ..limit(limit);
    return (await query.get()).map(Message.fromRow).toList();
  }

  Future<void> deleteMessages(String conversationId) async {
    await (delete(
      dbMessages,
    )..where((table) => table.conversationId.equals(conversationId))).go();
  }

  /// 清掉**全部**消息（换账号登录时用，见 `ConversationRepository.wipeLocal`）
  Future<void> clearMessages() async => delete(dbMessages).go();

  Future<Message?> _findExisting(Message message) async {
    if (message.serverId != null) {
      final byServerId = await findMessage(
        message.conversationId,
        serverId: message.serverId,
      );
      if (byServerId != null) return byServerId;
    }
    if (message.msgId != null && message.msgId!.isNotEmpty) {
      final byMsgId = await findMessage(
        message.conversationId,
        msgId: message.msgId,
      );
      if (byMsgId != null) return byMsgId;
    }
    if (message.clientId != null && message.clientId!.isNotEmpty) {
      return findMessage(message.conversationId, clientId: message.clientId);
    }
    return null;
  }

  /// 认领窗口：同内容的两条消息时间差在这个范围内才认为是同一条
  static const int _claimWindowMs = 120 * 1000;

  List<Message> _ascending(List<DbMessage> rows) =>
      rows.map(Message.fromRow).toList().reversed.toList();
}
