import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_exception.dart';
import '../../core/util/json_value.dart';
import '../../domain/chat/message_record.dart';
import '../../domain/search/user_search.dart';
import '../api/chat_api.dart';
import '../model/message.dart';
import 'conversation_repository.dart';

/// 聊天记录的一页
@immutable
class MessageRecordPage {
  const MessageRecordPage({required this.messages, required this.total});

  /// 升序（早 → 晚）
  final List<Message> messages;

  /// 服务端信封里的 `count`（分页条用的总条数）
  final int total;
}

/// 搜索（S5.4），对应老端三处：
/// * `pages/contacts/search.vue` —— 服务端搜人（`searchUser`）；
/// * `pages/index/search.vue` —— 本地搜好友/群（纯逻辑在
///   `domain/search/local_search.dart`，不需要仓库）；
/// * `pages/message/record.vue` —— 会话内聊天记录（分页 + 关键词 + 前后文）。
///
/// **这一层刻意不落库**：聊天记录页的数据源是服务端（老端也是如此），而它
/// 返回的字段（搜索结果那一份可能缺 `toContactId`、前后文那一份会带上边界
/// 重复条）不适合当成「本地历史」写进去。要看本地历史有聊天页，它自己会维护。
class SearchRepository {
  SearchRepository(this._api, this._conversations);

  final ChatApi _api;
  final ConversationRepository _conversations;

  // ------------------------------------------------------------------ 搜人

  /// 服务端搜人（关键词为空时直接给空列表，不白跑一趟接口）。
  ///
  /// 接口失败给空列表：`ApiClient` 已经弹过提示，页面只需要显示空态
  /// （老端这时列表也是空着）。
  Future<List<UserSearchResult>> searchUsers(String keyword) async {
    if (isBlankKeyword(keyword)) return const <UserSearchResult>[];
    try {
      final rows = await _api.searchUser(<String, dynamic>{
        'keywords': keyword.trim(),
      });
      return parseUserSearch(rows);
    } on ApiException catch (error) {
      debugPrint('[搜索] 搜人失败：${error.message}');
      return const <UserSearchResult>[];
    }
  }

  /// 从搜索结果进聊天。
  ///
  /// 老端 `sendMsg(id)`：本地会话列表里没有这个人时，先
  /// `getUserInfo({user_id})` 拿 `contactInfo` 补进 `mainContacts` 再进聊天页，
  /// 否则聊天页会说「联系人不存在」。返回是否真的能进。
  Future<bool> ensureChatWith(String userId) async {
    if (userId.isEmpty) return false;
    if (await _conversations.find(userId) != null) return true;
    try {
      final data = await _api.getUserInfo(<String, dynamic>{'user_id': userId});
      final contactInfo = asMap(data['contactInfo']);
      if (contactInfo.isEmpty) {
        debugPrint('[搜索] getUserInfo 没给 contactInfo，进不了聊天：$userId');
        return false;
      }
      await _conversations.ensureFromContactInfo(contactInfo);
      return true;
    } on ApiException catch (error) {
      debugPrint('[搜索] 取用户信息失败：${error.message}');
      return false;
    }
  }

  // ------------------------------------------------------- 会话内聊天记录

  /// 聊天记录（老端 `getMessageList(params)`，`params.type` 是分段、
  /// `keywords` 是搜的关键词、`count` 是总条数）。
  Future<MessageRecordPage> recordPage({
    required String conversationId,
    required int isGroup,
    String type = 'all',
    String keyword = '',
    int page = 1,
    int limit = recordPageLimit,
  }) async {
    final result = await _api.getMessageListPage(<String, dynamic>{
      'toContactId': conversationId,
      'is_group': isGroup,
      'type': type,
      'keywords': keyword.trim(),
      'page': page,
      'limit': limit,
    });
    return MessageRecordPage(
      messages: sortByTime(parseRecordMessages(result.rows, conversationId)),
      total: result.count,
    );
  }

  /// 某条消息的前后文（老端 `getMessageContext({msg_id, is_group, direction})`，
  /// `data` 是数组；`direction` 0 中心、1 更早、2 更晚）。
  Future<List<Message>> contextMessages({
    required String msgId,
    required int isGroup,
    required ContextDirection direction,
  }) async {
    final rows = await _api.getMessageContextList(<String, dynamic>{
      'msg_id': msgId,
      'is_group': isGroup,
      'direction': direction.value,
    });
    return sortByTime(parseRecordMessages(rows, ''));
  }

  /// 把服务端返回的消息行解析成 [Message]。
  ///
  /// 记录接口带 `toContactId`（它就是查询条件），前后文接口不带——所以前后文
  /// 那一份用 `Message.conversationIdFor` 从消息体里推（与 `MessageRepository`
  /// 同一口径）。
  List<Message> parseRecordMessages(
    List<Map<String, dynamic>> rows,
    String conversationId,
  ) => <Message>[
    for (final row in rows)
      if (asText(row['msg_id']).isNotEmpty ||
          asInt(row['id'], 0) > 0 ||
          asText(row['type']).isNotEmpty)
        Message.fromServerJson(
          row,
          conversationId: conversationId.isEmpty
              ? Message.conversationIdFor(row, myUserId: '')
              : conversationId,
        ),
  ];

  /// 按时间升序（服务端返回的顺序不保证，老端直接用它的顺序画）。
  static List<Message> sortByTime(List<Message> messages) {
    final sorted = <Message>[...messages];
    sorted.sort((a, b) {
      final byTime = a.sendTime.compareTo(b.sendTime);
      if (byTime != 0) return byTime;
      return (a.serverId ?? 0).compareTo(b.serverId ?? 0);
    });
    return sorted;
  }
}

final searchRepositoryProvider = Provider<SearchRepository>(
  (ref) => SearchRepository(
    ref.watch(chatApiProvider),
    ref.watch(conversationRepositoryProvider),
  ),
);
