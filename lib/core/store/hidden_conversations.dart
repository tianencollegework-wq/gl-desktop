import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'credential_store.dart';

/// 「不显示该聊天」的本地名单（微信那个动作只作用在**本机**）。
///
/// 三个刻意的选择：
/// * **不上报服务端、不删消息** —— 只是把它从列表里藏起来（老端没有这个动作，
///   所以没有协议可对）；
/// * 存 `SharedPreferences`（`CredentialStore` 那套），重启还在；
/// * 这个会话**再来一条新消息就自动冒出来**（微信也是这个行为），
///   钩子在 `ChatSyncService.handleIncoming` 里。
class HiddenConversationsNotifier extends Notifier<Set<String>> {
  /// 本地 key：`hiddenConversations`，值是 id 的 JSON 数组
  static const String storageKey = 'hiddenConversations';

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
      // 存坏了就当没设置过，不要因此打不开列表
    }
    return <String>{};
  }

  /// 藏起来（「不显示该聊天」）
  Future<void> hide(String id) async {
    if (id.isEmpty || state.contains(id)) return;
    state = <String>{...state, id};
    await _persist();
  }

  /// 放出来（新消息来了 / 手动恢复）
  Future<void> show(String id) async {
    if (!state.contains(id)) return;
    state = <String>{...state}..remove(id);
    await _persist();
  }

  /// 退出登录时清空（名单是按会话 id 存的，换账号后没有意义）
  Future<void> clear() async {
    if (state.isEmpty) return;
    state = <String>{};
    await _persist();
  }

  Future<void> _persist() => CredentialStore.instance.setString(
    storageKey,
    json.encode(state.toList()),
  );
}

final hiddenConversationsProvider =
    NotifierProvider<HiddenConversationsNotifier, Set<String>>(
      HiddenConversationsNotifier.new,
    );
