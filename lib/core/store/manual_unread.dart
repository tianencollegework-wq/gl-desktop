import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'credential_store.dart';

/// 「标为未读」的本地名单。
///
/// 微信长按会话选「标为未读」之后，那一行会顶一个**小红点**（不带数字），
/// 点了进去就消失。这件事在老端和协议里都不存在，纯本机标记，所以要自己存：
///
/// * 存 `SharedPreferences`（和「不显示该聊天」一样走 [CredentialStore]），重启还在；
/// * 打开那个会话（`markReadLocally`）时清掉；
/// * 退出登录时清空（id 是按账号的，换账号没意义）。
///
/// 会话行是**同时**改数据库里的 `unread` 的（`ConversationRepository.markUnread`），
/// 这样底部 tab 的红点、服务端对齐后的未读口径都还是自洽的；
/// 这份名单只负责一件事：**这一条的红点不要显示数字**。
class ManualUnreadNotifier extends Notifier<Set<String>> {
  /// 本地 key：`manualUnreadConversations`，值是 id 的 JSON 数组
  static const String storageKey = 'manualUnreadConversations';

  @override
  Set<String> build() {
    final raw = CredentialStore.instance.getString(storageKey);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final decoded = json.decode(raw);
      if (decoded is List) {
        return decoded
            .map((item) => '$item')
            .where((id) => id.isNotEmpty)
            .toSet();
      }
    } on FormatException {
      // 存坏了就当没标过，不要因此打不开列表
    }
    return <String>{};
  }

  /// 标为未读
  Future<void> mark(String id) async {
    if (id.isEmpty || state.contains(id)) return;
    state = <String>{...state, id};
    await _persist();
  }

  /// 进会话（或清未读）时把标记消掉
  Future<void> clear(String id) async {
    if (!state.contains(id)) return;
    state = <String>{...state}..remove(id);
    await _persist();
  }

  /// 退出登录时清空
  Future<void> clearAll() async {
    if (state.isEmpty) return;
    state = <String>{};
    await _persist();
  }

  Future<void> _persist() => CredentialStore.instance.setString(
    storageKey,
    json.encode(state.toList()),
  );
}

final manualUnreadProvider =
    NotifierProvider<ManualUnreadNotifier, Set<String>>(
      ManualUnreadNotifier.new,
    );
