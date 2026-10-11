import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/model/user_info.dart';
import 'credential_store.dart';

/// 本机保存的一个「可切换账号」（S10.1）。
///
/// 本机的**会话是单槽位**的（`CredentialStore` 里 authToken / userInfo / client_id
/// 各一份，`hasSession` 就是「token 非空」），路由守卫、网络层、WebSocket 全读那一份。
/// 所以多账号不是在旁边另起一套体系，而是：**当前账号仍然是那一份**，这里的列表
/// 只是「另外几份存起来的账号」，切换 = 把目标那一份写回单槽位。
///
/// 每个槽位要存的东西：
/// * [user]——登录接口返回的整份 `userInfo`（切换时直接 `applyLogin`，不用再请求）；
/// * [authToken]——那一份的令牌。**退出登录会把它清掉**（服务端那份已作废），
///   所以退出过的条目要么重新输密码，要么干脆删掉；
/// * [clientIds]——本机为这个账号用过的 WebSocket `client_id`。只用来判断
///   「被顶下线」的那条推送是不是**自己**（见 `session_service._onOffline`）；
/// * [usedAt]——最近一次使用的时间（毫秒）：列表按它倒序（当前账号自然在最上面），
///   万一存满又来了新的，顶掉的就是最久未用的那一份。
@immutable
class SavedAccount {
  const SavedAccount({
    required this.user,
    this.authToken = '',
    this.clientIds = const <String>[],
    this.usedAt = 0,
  });

  final UserInfo user;

  /// 登录时服务端给的令牌；退出登录后置空（= 这一份要重新登录）
  final String authToken;

  final List<String> clientIds;

  final int usedAt;

  String get userId => user.userId;

  /// 卡片上第一行：昵称
  String get name => user.name;

  /// 卡片上那个头像（空就是灰底小人）
  String get avatar => user.avatar;

  /// 卡片上第二行「恩信号」的值。
  ///
  /// 服务端**没有**单独的号码字段（`userInfo` 里只有 `account` / `realname` /
  /// `mobile` / `user_id`…），所以就把登录账号当恩信号显示；账号为空时退回 `user_id`。
  /// 以后服务端真加了可自定义的恩信号，改这里一处即可。
  String get gracelinkId {
    final account = user.account.trim();
    return account.isEmpty ? userId : account;
  }

  /// 这一份现在还能一键切过去吗（token 还在才可以直接切，否则要重新登录）
  bool get canSwitchOnline => authToken.isNotEmpty;

  SavedAccount copyWith({
    UserInfo? user,
    String? authToken,
    List<String>? clientIds,
    int? usedAt,
  }) => SavedAccount(
    user: user ?? this.user,
    authToken: authToken ?? this.authToken,
    clientIds: clientIds ?? this.clientIds,
    usedAt: usedAt ?? this.usedAt,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'user': user.toJson(),
    'authToken': authToken,
    'clientIds': clientIds,
    'usedAt': usedAt,
  };

  factory SavedAccount.fromJson(Map<String, dynamic> json) {
    final rawUser = json['user'];
    final rawIds = json['clientIds'];
    return SavedAccount(
      user: UserInfo.fromJson(
        rawUser is Map ? rawUser.cast<String, dynamic>() : <String, dynamic>{},
      ),
      authToken: json['authToken']?.toString() ?? '',
      clientIds: rawIds is List
          ? rawIds.map((item) => '$item').where((id) => id.isNotEmpty).toList()
          : const <String>[],
      usedAt: int.tryParse('${json['usedAt']}') ?? 0,
    );
  }
}

/// 可切换账号的本地列表（最多 [maxAccounts] 份）。
///
/// 与 [ClearedChatsStore] 一个路子：单例 + 从 [CredentialStore] 里读写一份 JSON，
/// 构造函数公开是为了测试能换成一个干净的实例。
class SavedAccountsStore {
  static SavedAccountsStore instance = SavedAccountsStore();

  static const String storageKey = 'savedAccounts';

  /// 最多能存几个账号（用户 2026-09-29 定的：三个）
  static const int maxAccounts = 3;

  /// 每个账号最多记几个 client_id（够用来判断「是不是本机自己」就行了）
  static const int maxClientIds = 6;

  List<SavedAccount> _accounts = <SavedAccount>[];

  /// 列表变了就通知界面（切换账号页要重画）
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 按最近使用倒序（当前账号在最上面，与用户给的那张图一致）
  List<SavedAccount> get accounts => List<SavedAccount>.unmodifiable(_accounts);

  bool get isEmpty => _accounts.isEmpty;

  /// 满了：界面上那行「添加账号」会藏起来（要加先删）
  bool get isFull => _accounts.length >= maxAccounts;

  SavedAccount? byId(String userId) {
    for (final account in _accounts) {
      if (account.userId == userId) return account;
    }
    return null;
  }

  /// 这个 `client_id` 是不是本机**自己**用过的（用来挡「自己被自己顶下线」）
  bool isOwnClientId(String clientId) {
    if (clientId.isEmpty) return false;
    for (final account in _accounts) {
      if (account.clientIds.contains(clientId)) return true;
    }
    return false;
  }

  /// 从本地存储读回来（启动时调一次；测试里改完 mock 值也要调）
  void reload() {
    _accounts = <SavedAccount>[];
    final raw = CredentialStore.instance.getString(storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = json.decode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              final account = SavedAccount.fromJson(
                item.cast<String, dynamic>(),
              );
              // 没有 user_id 的脏数据直接丢掉：切过去也没身份可用
              if (account.userId.isEmpty) continue;
              _accounts.add(account);
            }
          }
        }
      } on FormatException {
        // 存坏了就当没存过，不能让「设置」打不开
      }
    }
    _sort();
    revision.value += 1;
  }

  /// 存一份（同一个 user_id 就整份替换）。
  ///
  /// 满载时**不会**把传入的这一份顶掉：当前账号必须在列表里，否则切换页上
  /// 看不到自己；被顶掉的是最久未用的那一份。
  Future<SavedAccount> upsert(SavedAccount account) async {
    if (account.userId.isEmpty) return account;
    final rest = _accounts
        .where((item) => item.userId != account.userId)
        .toList();
    rest.add(account);
    // 超了就砍最久未用的（当前这份不动）
    while (rest.length > maxAccounts) {
      var oldestIndex = -1;
      for (var i = 0; i < rest.length; i++) {
        if (rest[i].userId == account.userId) continue;
        if (oldestIndex < 0 || rest[i].usedAt < rest[oldestIndex].usedAt) {
          oldestIndex = i;
        }
      }
      if (oldestIndex < 0) break;
      rest.removeAt(oldestIndex);
    }
    _accounts = rest;
    await _persist();
    return account;
  }

  /// 记一次「最近使用」
  Future<void> touch(String userId) async {
    final saved = byId(userId);
    if (saved == null) return;
    await upsert(saved.copyWith(usedAt: _now()));
  }

  /// 记一个本机用过的 `client_id`（每次 WS `init` 都会来一个）
  Future<void> rememberClientId(String userId, String clientId) async {
    if (clientId.isEmpty) return;
    final saved = byId(userId);
    if (saved == null) return;
    if (saved.clientIds.contains(clientId)) return;
    final ids = <String>[...saved.clientIds, clientId];
    await upsert(
      saved.copyWith(
        clientIds: ids.length > maxClientIds
            ? ids.sublist(ids.length - maxClientIds)
            : ids,
      ),
    );
  }

  /// 删掉一份（管理模式里的删除）
  Future<void> remove(String userId) async {
    if (byId(userId) == null) return;
    _accounts = _accounts.where((account) => account.userId != userId).toList();
    await _persist();
  }

  Future<void> clearAll() async {
    if (_accounts.isEmpty) return;
    _accounts = <SavedAccount>[];
    await _persist();
  }

  /// 列表顺序：最近使用的在前
  void _sort() => _accounts.sort((a, b) => b.usedAt.compareTo(a.usedAt));

  int _now() => DateTime.now().millisecondsSinceEpoch;

  Future<void> _persist() async {
    _sort();
    revision.value += 1;
    await CredentialStore.instance.setString(
      storageKey,
      json.encode(_accounts.map((account) => account.toJson()).toList()),
    );
  }
}

/// 给界面用的入口（会话层直接读 [SavedAccountsStore.instance]）
final savedAccountsProvider = Provider<SavedAccountsStore>(
  (ref) => SavedAccountsStore.instance,
);
