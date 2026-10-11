import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../util/emoji_pack.dart';
import 'credential_store.dart';

/// 「最近使用」的那几个表情。
///
/// 面板最左边那一栏（微信也有，只是它是自动出现的）。纯本机行为，
/// 不涉及协议，所以存 `SharedPreferences`（走 [CredentialStore]，重启还在），
/// 上限 [recentEmojiLimit] 个，越新的越靠前，重复的提到最前而不是再插一遍。
///
/// 只记**系统表情字符**（`😀`），不是 `[!code]` token：面板插进输入框的本来就是字符。
class RecentEmojiNotifier extends Notifier<List<String>> {
  /// 本地 key
  static const String storageKey = 'recentEmojiChars';

  @override
  List<String> build() {
    final raw = CredentialStore.instance.getString(storageKey);
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      final decoded = json.decode(raw);
      if (decoded is List) {
        return decoded
            .map((item) => '$item')
            .where((char) => char.isNotEmpty)
            .take(recentEmojiLimit)
            .toList();
      }
    } on FormatException {
      // 存坏了就当没有常用，不要因此打不开面板
    }
    return const <String>[];
  }

  /// 用过一次：提到最前，超上限的从后面砍掉
  Future<void> use(String char) async {
    if (char.isEmpty) return;
    final next = <String>[char, ...state.where((item) => item != char)];
    state = next.length > recentEmojiLimit
        ? next.sublist(0, recentEmojiLimit)
        : next;
    await _persist();
  }

  /// 退出登录时清空
  Future<void> clearAll() async {
    if (state.isEmpty) return;
    state = const <String>[];
    await _persist();
  }

  Future<void> _persist() =>
      CredentialStore.instance.setString(storageKey, json.encode(state));
}

final recentEmojiProvider = NotifierProvider<RecentEmojiNotifier, List<String>>(
  RecentEmojiNotifier.new,
);
