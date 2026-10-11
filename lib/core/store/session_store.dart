import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/model/app_setting.dart';
import '../../data/model/global_config.dart';
import '../../data/model/user_info.dart';
import 'credential_store.dart';

/// 会话状态：登录用户 + 全局配置 + 本地设置 + 连接相关标记。
///
/// 对应老端 `store/login.js`（pinia）的 state。差别只有一处刻意的：
/// **这里带一个 [ready] 标记**——老端启动时不管有没有 token 都直接把主界面画出来，
/// 等接口 401 了才把人踢去登录页；新端在启动时就把本地会话读干净，
/// 由路由守卫直接决定去登录页还是主界面，避免主页闪一下再跳走。
@immutable
class SessionState {
  const SessionState({
    this.user,
    this.config = GlobalConfig.defaults,
    this.setting = AppSetting.defaults,
    this.multiport = false,
    this.ready = false,
    this.hasToken = false,
  });

  /// 当前登录用户，未登录为 null
  final UserInfo? user;

  final GlobalConfig config;
  final AppSetting setting;

  /// 是否多端在线（WS `pong` 的 `multiport`）
  final bool multiport;

  /// 本地会话是否已恢复完毕（路由守卫据此决定要不要停在启动页）
  final bool ready;

  /// 本地是否存在 authToken（可能比 [user] 更可靠，token 在但用户信息丢了也算已登录）
  final bool hasToken;

  bool get isLoggedIn => hasToken && user != null;

  String get userId => user?.userId ?? '';

  SessionState copyWith({
    UserInfo? user,
    GlobalConfig? config,
    AppSetting? setting,
    bool? multiport,
    bool? ready,
    bool? hasToken,
    bool clearUser = false,
  }) => SessionState(
    user: clearUser ? null : (user ?? this.user),
    config: config ?? this.config,
    setting: setting ?? this.setting,
    multiport: multiport ?? this.multiport,
    ready: ready ?? this.ready,
    hasToken: hasToken ?? this.hasToken,
  );

  /// 从本地存储恢复（老端是 pinia state 初始化时直接读 storage）
  factory SessionState.restore(CredentialStore store) {
    final rawUser = store.userInfo;
    return SessionState(
      user: rawUser == null ? null : UserInfo.fromJson(rawUser),
      config: GlobalConfig.fromJson(store.globalConfig),
      setting: AppSetting.fromJson(store.appSetting),
      hasToken: store.hasSession,
    );
  }
}

/// 会话状态容器。所有变更都会同步落盘（老端也是 pinia + storage 双写）。
class SessionStore extends Notifier<SessionState> {
  @override
  SessionState build() => SessionState.restore(CredentialStore.instance);

  CredentialStore get _store => CredentialStore.instance;

  /// 登录成功：存 token 与用户信息（老端 `store/login.js` 的 `login()`）
  void applyLogin(UserInfo user, {String? authToken}) {
    if (authToken != null) {
      unawaited(_store.saveAuthToken(authToken));
    }
    unawaited(_store.saveUserInfo(user.toJson()));
    state = state.copyWith(user: user, hasToken: true, ready: true);
    debugPrint('[会话] 登录成功：${user.userId} / ${user.name}');
  }

  /// 覆盖全局配置（来源：接口拉取或 WS `updateConfig`）
  void applyConfig(GlobalConfig config) {
    unawaited(_store.saveGlobalConfig(config.toJson()));
    state = state.copyWith(config: config);
  }

  void applySetting(AppSetting setting) {
    unawaited(_store.saveAppSetting(setting.toJson()));
    state = state.copyWith(setting: setting);
  }

  void applyMultiport(bool value) => state = state.copyWith(multiport: value);

  void markReady() => state = state.copyWith(ready: true);

  /// 退出登录 / 被顶下线：清会话，保留语言与本地设置
  void clearSession() {
    unawaited(_store.clearSession());
    state = state.copyWith(clearUser: true, hasToken: false);
    debugPrint('[会话] 已清除本地会话');
  }
}

final sessionStoreProvider = NotifierProvider<SessionStore, SessionState>(
  SessionStore.new,
);
