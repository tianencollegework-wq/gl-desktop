import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'credential_store.dart';

/// 一个会话「清空聊天记录」时被清掉的那批消息。
///
/// [ids] 同时装消息的 `msgId` 与 `serverId`（两个都记，匹配哪个都行）；
/// [lastSendTime] 是这批里最新一条的 `sendTime`（**服务端的毫秒**），
/// 用来把会话列表里那行预览也一起抹掉。
@immutable
class ClearedChat {
  const ClearedChat({required this.ids, required this.lastSendTime});

  final Set<String> ids;
  final int lastSendTime;

  factory ClearedChat.fromJson(Map<String, dynamic> json) => ClearedChat(
    ids: <String>{
      ...(json['ids'] is List
          ? (json['ids'] as List).map((item) => '$item')
          : const <String>[]),
    },
    lastSendTime: int.tryParse('${json['lastSendTime']}') ?? 0,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'ids': ids.toList(),
    'lastSendTime': lastSendTime,
  };
}

/// 「清空聊天记录」的本地账本（S5.3b）。
///
/// **为什么要记这笔账**：服务端没有「只清我这边」的接口，历史消息还在库里，
/// 聊天页一进去就会把最近一页拉回来 —— 只删本地的话，用户一刷新消息又回来了，
/// 看起来就是「清空不管用」。所以清空时把**当前手上这批消息的 id 记下来**，
/// 之后任何一次从服务端拉回来的、命中这份名单的消息都直接丢掉。
///
/// 记 id 而不是记时间戳：时间戳会踩设备时钟与服务端时钟不同步的坑
/// （手机快几分钟就会把刚收到的新消息一起吞掉）。
///
/// 边界（刻意如此）：
/// * 只影响**本机**：对方的记录还在，换台设备登录也还能看到历史（服务端没删）；
/// * 新消息（id 不在名单里）照常进；
/// * 退出登录清空（按账号存没有意义）。
class ClearedChatsStore {
  /// 单例：仓库层（不在 Riverpod 里）也要能用，和 [CredentialStore] 一个路子。
  ///
  /// 构造函数是**公开**的：测试要能把单例换成一个干净的实例（见
  /// `test/core/cleared_chats_test.dart`）。
  static ClearedChatsStore instance = ClearedChatsStore();

  static const String storageKey = 'clearedChats';

  /// 单个会话最多记多少条 id（清空时手上能有多少就记多少，超了砍掉最老的）
  static const int maxIdsPerChat = 3000;

  Map<String, ClearedChat> _cleared = <String, ClearedChat>{};

  /// 变了就通知界面（会话列表要重画那行空白预览）
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 从本地存储读回来（启动时调一次；测试里改完 mock 值也要调）
  void reload() {
    _cleared = <String, ClearedChat>{};
    final raw = CredentialStore.instance.getString(storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = json.decode(raw);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (value is Map) {
              _cleared['$key'] = ClearedChat.fromJson(
                value.cast<String, dynamic>(),
              );
            }
          });
        }
      } on FormatException {
        // 存坏了就当没清空过，不能让会话列表打不开
      }
    }
    revision.value += 1;
  }

  /// 这条消息是不是已经被「清空聊天记录」清掉了
  bool hides(String conversationId, String? id) {
    if (id == null || id.isEmpty) return false;
    return _cleared[conversationId]?.ids.contains(id) ?? false;
  }

  /// 会话列表那行的预览：服务端给的最后一条正好是被清掉的那条 → 抹掉预览
  bool hidesPreview(String conversationId, int lastSendTime) {
    final cleared = _cleared[conversationId];
    if (cleared == null || lastSendTime <= 0) return false;
    return cleared.lastSendTime == lastSendTime;
  }

  /// 记一笔：这个会话的这批消息被清掉了
  Future<void> mark(
    String conversationId, {
    required Set<String> ids,
    required int lastSendTime,
  }) async {
    if (conversationId.isEmpty) return;
    final previous = _cleared[conversationId];
    final merged = <String>{...?previous?.ids, ...ids};
    final trimmed = merged.length > maxIdsPerChat
        ? merged.skip(merged.length - maxIdsPerChat).toSet()
        : merged;
    _cleared[conversationId] = ClearedChat(
      ids: trimmed,
      lastSendTime: lastSendTime > (previous?.lastSendTime ?? 0)
          ? lastSendTime
          : previous?.lastSendTime ?? lastSendTime,
    );
    await _persist();
  }

  /// 退出登录清空
  Future<void> clearAll() async {
    if (_cleared.isEmpty) return;
    _cleared = <String, ClearedChat>{};
    await _persist();
  }

  Future<void> _persist() async {
    revision.value += 1;
    await CredentialStore.instance.setString(
      storageKey,
      json.encode(
        _cleared.map(
          (key, value) => MapEntry<String, dynamic>(key, value.toJson()),
        ),
      ),
    );
  }
}
