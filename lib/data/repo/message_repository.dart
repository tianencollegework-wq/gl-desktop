import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_exception.dart';
import '../../core/store/cleared_chats.dart';
import '../api/chat_api.dart';
import '../db/app_database.dart';
// 消息的数据库方法是以 extension 形式提供的，必须 import 才会进作用域
import '../db/message_dao.dart';
import '../model/message.dart';

/// 一页消息
@immutable
class MessagePage {
  const MessagePage({
    required this.messages,
    required this.hasMore,
    this.oldestMsgId,
  });

  /// 升序（早 → 晚）
  final List<Message> messages;

  /// 还有更早的消息
  final bool hasMore;

  /// 这一页里最旧一条的 `msg_id`，作为下一页的游标
  final String? oldestMsgId;

  bool get isEmpty => messages.isEmpty;
}

/// 消息仓库（S3.3）。
///
/// 老端聊天页是"接口拉一页 → 塞进 `msgStore.msgList`"，
/// 退出页面即丢（`onLoad` 里还专门清空 `msgStore.msgList = []` 防串台），
/// 所以每次进聊天都得等接口，且不能本地搜索。
///
/// 新端：消息落库，聊天页先显示本地缓存（`watch()`），再拉接口补历史。
class MessageRepository {
  MessageRepository(this._db, this._api);

  final AppDatabase _db;
  final ChatApi _api;

  /// 本地缓存的消息流（升序），用于聊天页首屏
  Stream<List<Message>> watch(String conversationId, {int limit = 50}) =>
      _db.watchConversation(conversationId, limit: limit);

  Future<List<Message>> cached(String conversationId, {int limit = 50}) =>
      _db.messagesFor(conversationId, limit: limit);

  Future<int> countIn(String conversationId) =>
      _db.messageCount(conversationId);

  /// 从服务端拉一页历史并落库。
  ///
  /// 参数与老端 `chat.vue::queryList` 完全一致：
  /// `{is_group, toContactId, last_id, page, limit}`；
  /// `last_id` 是"当前手里最旧那条的 msg_id"，服务端据此往前翻（老端取
  /// `res.data[0].msg_id` 作为下一页游标）。
  Future<MessagePage> loadPage({
    required String conversationId,
    required int isGroup,
    String? lastId,
    int page = 1,
    int limit = 20,
  }) async {
    final rows = await _api.getMessageList(<String, dynamic>{
      'is_group': isGroup,
      'toContactId': conversationId,
      'last_id': lastId ?? '',
      'page': page,
      'limit': limit,
    });

    final messages = _dropCleared(
      rows
          .map(
            (row) =>
                Message.fromServerJson(row, conversationId: conversationId),
          )
          .where((message) => message.type.isNotEmpty)
          .toList(),
    );

    await _db.upsertMessages(messages);

    // 老端直接用接口返回的顺序（数组第一个是最旧的）；这里统一按时间升序，
    // 免得服务端某天换了排序把界面搞乱
    final ascending = _sortedByTime(messages);
    return MessagePage(
      messages: ascending,
      hasMore: messages.length >= limit,
      oldestMsgId: ascending.isEmpty ? null : ascending.first.msgId,
    );
  }

  /// 补一次「最新一页」（进聊天页时调用）。
  ///
  /// 与 [loadPage] 的翻历史不是一回事：老端每次进聊天页都用空 `last_id`
  /// 拉第一页，所以哪怕它离线期间漏了推送，进聊天页也能看到最新几条。
  /// 新端界面先出本地缓存是对的，但**最新一页不能省**——不补就会出现
  /// 「会话列表有预览、点进去什么都没有」（离线/断线期间的消息只在服务端）。
  Future<MessagePage> refreshNewest({
    required String conversationId,
    required int isGroup,
    int limit = 20,
  }) => loadPage(
    conversationId: conversationId,
    isGroup: isGroup,
    page: 1,
    limit: limit,
  );

  /// 某条消息的上下文（引用/定位用）
  Future<List<Message>> loadContext({
    required String msgId,
    required int isGroup,
    String direction = 'down',
  }) async {
    final row = await _api.getMessageContext(<String, dynamic>{
      'msg_id': msgId,
      'is_group': isGroup,
      'direction': direction,
    });
    final data = row['data'];
    final list = data is List ? data : const <dynamic>[];
    final messages = list
        .whereType<Map<dynamic, dynamic>>()
        .map((item) => item.cast<String, dynamic>())
        .map(
          (json) => Message.fromServerJson(
            json,
            // 上下文接口不带 toContactId，只能从消息体里推
            conversationId: Message.conversationIdFor(json, myUserId: ''),
          ),
        )
        .toList();
    await _db.upsertMessages(_dropCleared(messages));
    return _sortedByTime(messages);
  }

  /// 推送/本地乐观消息落库（按服务端 id 与 msg_id 去重）
  Future<int> save(List<Message> messages) =>
      _db.upsertMessages(_dropCleared(messages));

  Future<int> saveOne(Message message) =>
      _db.upsertMessages(_dropCleared(<Message>[message]));

  /// 丢掉「已经被清空聊天记录清掉的那批」消息（见 [ClearedChatsStore]）。
  ///
  /// 不加这一步的话：清空本地 → 重新进聊天页拉第一页 → 旧消息原样回来，
  /// 用户看到的就是「清空不管用」。
  List<Message> _dropCleared(List<Message> messages) {
    final store = ClearedChatsStore.instance;
    return messages
        .where(
          (message) =>
              !store.hides(message.conversationId, message.msgId) &&
              !store.hides(
                message.conversationId,
                message.serverId?.toString(),
              ),
        )
        .toList();
  }

  Future<bool> has(String conversationId, {int? serverId, String? msgId}) =>
      _db.hasMessage(
        conversationId: conversationId,
        serverId: serverId,
        msgId: msgId,
      );

  Future<Message?> find(
    String conversationId, {
    int? serverId,
    String? msgId,
  }) => _db.findMessage(conversationId, serverId: serverId, msgId: msgId);

  Future<Message?> oldest(String conversationId) =>
      _db.oldestMessage(conversationId);

  /// 上报"我读了这条消息"（老端在聊天页收到新消息时调，参数就这四项）
  ///
  /// ⚠️ **`messages` 不能省**。服务端 `Im::setMsgIsRead()` 里第一件事就是
  /// `$param['messages']`（`is_array($param['messages'][0] ?? '')`），
  /// 少了这个键 → PHP notice → ThinkPHP 把它转成 ErrorException → **HTTP 500**
  /// （线上日志里就是 `[8]未定义数组索引: messages[Im.php:518]`，一天几十条）。
  /// 客户端这里 `notify: false` 所以看不到提示，但请求确实失败了。
  ///
  /// 单聊那条分支（`app/job/Work.php::setIsRead`）其实不看 `messages` 的内容，
  /// 它按 `chat_identify + to_user` 把整个会话标已读；群聊分支拿它去挑 @ 消息
  /// （`Message::setAtread` 会跳过没有 `at` 字段的项）。所以这里照老端传**一条**就行。
  Future<void> reportRead({
    required String conversationId,
    required int isGroup,
    required String fromUserId,
  }) async {
    try {
      await _api.setMsgIsRead(<String, dynamic>{
        'toContactId': conversationId,
        'is_group': isGroup,
        'fromUser': fromUserId,
        'messages': <Map<String, dynamic>>[
          <String, dynamic>{'fromUser': fromUserId},
        ],
      });
    } on ApiException catch (error) {
      debugPrint('[消息] 已读上报失败：${error.message}');
    }
  }

  /// 这个会话里「还没读、且是别人发的」那几个发送人（去重，最近的在前）。
  ///
  /// 进聊天页时用它把未读在服务端也标掉（`setMsgIsRead` 是按发送人上报的），
  /// 否则服务端的旧未读会在下次同步（`getContacts`）时把角标带回来。
  Future<List<String>> unreadSenders(
    String conversationId, {
    required String myUserId,
    int limit = 20,
  }) => _db.unreadSenders(conversationId, myUserId: myUserId, limit: limit);

  /// 这个会话里 @ 到我的消息（新 → 旧），给「N 人提到我」面板用
  Future<List<Message>> mentioning(
    String conversationId,
    String myUserId, {
    int limit = 50,
  }) => _db.messagesMentioning(conversationId, myUserId, limit: limit);

  /// 删除一条消息（老端 `chat.vue::delMsg`）。
  ///
  /// 老端只发 `{id}`，成功后把自己列表里那条 splice 掉；界面上它还会先弹
  /// 一句「删除消息会从所有人的聊天记录中抹掉，是否确定?」。
  /// 新端本地也真的删（老端因为没本地历史，删不删都一样）。
  Future<void> delete({
    required String conversationId,
    int? serverId,
    String? msgId,
  }) async {
    final message = await find(
      conversationId,
      serverId: serverId,
      msgId: msgId,
    );
    final identity = _identityOf(message, serverId: serverId, msgId: msgId);
    if (identity.isEmpty) {
      debugPrint('[消息] 删除：这条既没有服务端 id 也没有 msg_id，跳过');
      return;
    }
    try {
      await _api.delMessage(identity);
    } on ApiException catch (error) {
      debugPrint('[消息] 删除失败：${error.message}');
      rethrow;
    }
    if (message?.localId != null) {
      await _db.deleteMessage(message!.localId!);
    }
  }

  /// 转发给一个或多个人/群（老端 `userSelection.vue` 的 type 3 分支：
  /// `forwardMessage({user_ids, msg_id})`，服务端负责把消息复制过去）。
  ///
  /// 老端限 5 个（`message.forwardLimit`），这里由调用方先判（文案在界面层）。
  Future<void> forward({
    required List<String> userIds,
    required String msgId,
  }) => _api.forwardMessage(<String, dynamic>{
    'user_ids': userIds,
    'msg_id': msgId,
  });

  /// 撤回（老端 `chat.vue::undoMsg`；服务端之后会推 `undoMessage` 事件）。
  ///
  /// 顺序照老端：**先问服务端，成功了才本地标记**（老端是在 `.then` 里才
  /// `updateMessage`）。新端此前反着来 —— 先把本地标成 `is_undo`、再发请求，
  /// 请求一失败，界面上就是「显示『你撤回了一条消息』、对方那条其实还在」
  /// （用户 2026-09-30 报的）。
  ///
  /// 返回是否真的撤了（服务端确认且本地已标记）。
  Future<bool> undo({
    required String conversationId,
    int? serverId,
    String? msgId,
  }) async {
    final message = await find(
      conversationId,
      serverId: serverId,
      msgId: msgId,
    );
    final identity = _identityOf(message, serverId: serverId, msgId: msgId);
    if (identity.isEmpty) {
      debugPrint('[消息] 撤回：这条既没有服务端 id 也没有 msg_id，跳过');
      return false;
    }
    try {
      await _api.undoMessage(identity);
    } on ApiException catch (error) {
      // 失败**不动本地**：服务端没撤，界面就不该写「你撤回了一条消息」。
      // 提示由接口层统一弹（`undoMessage` 没关掉 notify）。
      debugPrint('[消息] 撤回失败：${error.message}');
      return false;
    }
    final localId = message?.localId;
    if (localId != null) {
      await _db.patchMessage(
        localId,
        const DbMessagesCompanion(isUndo: Value(1)),
      );
    }
    return true;
  }

  /// 撤回 / 删除请求体里那个 `id`：**服务端认那条消息的键**。
  ///
  /// 老端发的是手里的 `message.id`；在新端它落在两处（见 `Message.fromServerJson`）：
  /// * 服务端给的是**数字** → `serverId`；
  /// * 服务端把我们发出去时用的 **uuid 原样回传**（老端自己的行为）→ `clientId`。
  ///
  /// 这两个都不带、只发 `msg_id` 是不行的：`Im.php::undo()` 取的是 `$param['id']`，
  /// 少了它 → PHP notice → ThinkPHP 抛 ErrorException → HTTP 500 → 界面上那句
  /// 「服务器繁忙，请稍后再试」。用户 2026-09-30 报的撤回失败就是这个：
  /// 刚发出去的那条还没拿到数字 id，旧代码于是只发了 `msg_id`。
  static Map<String, dynamic> _identityOf(
    Message? message, {
    int? serverId,
    String? msgId,
  }) {
    final Object? id = serverId ?? message?.clientId;
    return <String, dynamic>{
      if (id != null && '$id'.isNotEmpty) 'id': id,
      if (msgId != null && msgId.isNotEmpty) 'msg_id': msgId,
    };
  }

  /// 服务端推来的撤回通知（`undoMessage` 事件）
  Future<void> applyUndo({
    required String conversationId,
    int? serverId,
    String? msgId,
    String? content,
  }) async {
    final message = await find(
      conversationId,
      serverId: serverId,
      msgId: msgId,
    );
    final localId = message?.localId;
    if (localId == null) {
      debugPrint('[消息] 撤回了一条本地没有的消息（$serverId / $msgId）');
      return;
    }
    await _db.patchMessage(
      localId,
      DbMessagesCompanion(
        isUndo: const Value(1),
        content: content == null ? const Value.absent() : Value(content),
      ),
    );
  }

  Future<void> deleteFor(String conversationId) =>
      _db.deleteMessages(conversationId);

  List<Message> _sortedByTime(List<Message> messages) {
    final sorted = <Message>[...messages];
    sorted.sort((a, b) {
      final byTime = a.sendTime.compareTo(b.sendTime);
      if (byTime != 0) return byTime;
      return (a.serverId ?? a.localId ?? 0).compareTo(
        b.serverId ?? b.localId ?? 0,
      );
    });
    return sorted;
  }
}

final messageRepositoryProvider = Provider<MessageRepository>(
  (ref) => MessageRepository(
    ref.watch(appDatabaseProvider),
    ref.watch(chatApiProvider),
  ),
);
