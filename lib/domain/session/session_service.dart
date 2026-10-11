import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/voice_player.dart';
import '../../core/net/api_exception.dart';
import '../../core/notify/message_notification_presenter.dart';
import '../../core/store/cleared_chats.dart';
import '../../core/store/credential_store.dart';
import '../../core/store/hidden_conversations.dart';
import '../../core/store/recent_emoji.dart';
import '../../core/store/manual_unread.dart';
import '../../core/store/saved_accounts.dart';
import '../../core/store/session_store.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/util/json_value.dart';
import '../../core/ws/ws_event.dart';
import '../../core/ws/ws_handlers.dart';
import '../../core/ws/ws_router.dart';
import '../../core/ws/ws_service.dart';
import '../../data/api/auth_api.dart';
import '../../data/model/global_config.dart';
import '../../data/model/user_info.dart';
import '../../data/repo/chat_background_repository.dart';
import '../../data/repo/conversation_repository.dart';
import '../notify/push_registrar.dart';

/// 切换账号的结果（S10.1）。
///
/// 页面据此决定下一步：切过去了就回主界面；要重新登录就把人送到登录表单。
enum AccountSwitchResult {
  /// 切过去了
  switched,

  /// 本来就是当前账号（点自己那颗卡片）
  alreadyActive,

  /// 本机没存过这个账号
  unknown,

  /// 这一份的令牌已经作废（在设置里退出登录过）→ 要重新输密码
  needsLogin,
}

/// 会话链路：登录、注册、登出、启动、绑定设备、切换账号。
///
/// 完整对照老端三处代码：
/// * `pages/login/index.vue` → 登录 / 记住账号 / 忘记密码
/// * `store/login.js` → 配置拉取、登录后落盘
/// * `App.vue` 的 `init` / `offline` / `updateConfig` 三个分支 → 绑定设备、被顶下线、配置热更新
///
/// 启动顺序（老端是「onLaunch 拉配置 + onShow 连 WS」两件事并行，这里保持一致）：
/// 1. 读本地会话（`SessionState.restore`，同步）；
/// 2. 连 WS（连接就绪后服务端下发 `init`，若本地已登录则自动 `bindUid`）；
/// 3. 后台刷新全局配置，**不阻塞界面**（老端同样不等它）。
class SessionService {
  SessionService(this._ref, this._auth, this._ws, this._push);

  final Ref _ref;
  final AuthApi _auth;
  final WsService _ws;

  /// 设备标识（推送）的登记：登录与连接就绪时都要跑一遍（S8.1）
  final PushRegistrar _push;

  SessionStore get _session => _ref.read(sessionStoreProvider.notifier);

  SessionState get _state => _ref.read(sessionStoreProvider);

  /// 全局配置拿到过没有（没拿到就不停重试：见 [refreshGlobalConfig] 与
  /// [_bindAfterInit] 里的"连接就绪再补一次"）。
  bool _configLoaded = false;

  /// HTTP `bindUid` 的重试次数与退避基数（第 n 次失败等 n 倍基数）。
  ///
  /// 只影响「推送设备标识登记」这一件事，实时消息不依赖它。
  static const int _bindAttempts = 3;
  static const Duration _bindRetryDelay = Duration(seconds: 2);

  /// 启动：注册 WS 处理器 → 连 WS → 后台刷新配置 → 标记本地会话就绪
  Future<void> bootstrap() async {
    _ws.router.registerAll(<String, WsHandler>{
      WsEvents.offline: _onOffline,
      WsEvents.updateConfig: _onUpdateConfig,
    });
    // 服务端 `init` 到达后（连接就绪），如果本地已有登录态就自动绑定设备
    _ws.onClientReady = (clientId) => unawaited(_bindAfterInit(clientId));

    _ws.start();

    // 推送设备标识：独立于登录态先跑一遍（拿到就落盘成 cid，更新了就上报）。
    // 它可能要等 Firebase 初始化，所以不 await —— 界面与绑设备都不该等它。
    _push.start();
    unawaited(_push.ensure());

    // 老端也是不等配置返回就渲染界面，先用本地缓存 / 默认值
    unawaited(refreshGlobalConfig());

    _session.markReady();
  }

  /// 拉取全局配置（老端 `store/login.js` 的 `getGlobalConfig`）。
  ///
  /// 与老端的一处刻意差异：**带退避重试**。老端（和新端之前）只发一次，
  /// 冷启动时若撞上"网络刚恢复 / DNS 刚就绪"那一下，就一路用本地缓存或默认值
  /// 把界面画出来——用户看到的就是登录页上那个默认站名 `Im`，以及接着所有
  /// 请求都失败，重启一次才正常。这里失败后重试几次，另外 WS 一连上还会
  /// 再多试一次（见 [_bindAfterInit]），不需要用户重启。
  Future<GlobalConfig> refreshGlobalConfig({int attempts = 3}) async {
    var delay = const Duration(milliseconds: 800);
    for (var attempt = 1; ; attempt++) {
      if (!_ref.mounted) return GlobalConfig.defaults;
      final before = _state.config;

      try {
        final data = await _auth.getSystemInfo();
        // 这个请求是 unawaited 发出去的，回来时容器可能已经销毁（退出 App / 测试拆容器），
        // 所以每个 await 之后都要重新确认 provider 还活着
        if (!_ref.mounted) return before;
        if (data.isEmpty) {
          // 接口返回空数据（例如 `data: null`）时**不能**用默认值覆盖现有配置：
          // 否则 WS 刚推来的 updateConfig、或本地缓存里的配置会被一起抹掉。
          // 老端这里是无脑覆盖的（`globalConfig = res.data`），属于它的一个坑。
          debugPrint('[会话] 全局配置接口返回空数据，保留现有配置');
          _configLoaded = true;
          return before;
        }
        final config = GlobalConfig.fromJson(data);
        _session.applyConfig(config);
        _configLoaded = true;
        return config;
      } on ApiException catch (error) {
        // 拿不到配置不阻塞启动：继续用缓存或默认值（老端也一样静默失败）
        debugPrint('[会话] 全局配置拉取失败（第 $attempt 次）：${error.message}');
        // 业务错误（比如鉴权、参数）重试也没用，只有网络/服务端抖动值得等
        final retryable =
            error is NetworkUnavailableException || error is ServerException;
        if (!retryable || attempt >= attempts || !_ref.mounted) return before;
        await Future<void>.delayed(delay);
        delay *= 2;
      }
    }
  }

  // ------------------------------------------------------------------ 登录

  /// 登录。成功返回用户信息；失败抛 [ApiException]（提示已由网络层发出）。
  ///
  /// 请求体与老端 `pages/login/index.vue` 的 `loginForm` 一致：
  /// `account` / `password` / `code` / `client_id` / `rememberMe`。
  /// 忘记密码模式下老端会把 `password` 写死成 `123456` 并只带 `code`，
  /// 这里保持同样的行为（由页面传进来）。
  Future<UserInfo> login({
    required String account,
    required String password,
    String code = '',
    bool rememberMe = false,
  }) async {
    final clientId = CredentialStore.instance.clientId ?? '';
    final data = await _auth.login(<String, dynamic>{
      'account': account,
      'password': password,
      'code': code,
      'client_id': clientId,
      'rememberMe': rememberMe,
    });

    final token = asText(data['authToken']);
    final rawUser = asMap(data['userInfo']);
    if (token.isEmpty || rawUser.isEmpty) {
      // 协议对不上时明确报出来，而不是带着半个登录态继续跑
      throw const UnknownApiException('登录响应缺少 authToken / userInfo，请检查服务端协议');
    }

    return _applyLoginToken(token, rawUser);
  }

  /// 扫码登录成功：把那台电脑的登录态落到本机（S12.17）。
  ///
  /// 数据是服务端**推**过来的（`{type:'tokenLogin', data:{sessionId, authToken,
  /// userInfo}}`，见 `app/enterprise/controller/Im.php::tokenLogin`）：电脑端这一半
  /// 没有任何 HTTP 请求 —— 手机扫码、在手机上点确认之后，服务端把登录态推给
  /// **那条要登录的连接**，同时把它 `bindUid` 到那个人。
  ///
  /// 与密码登录共用 [_applyLoginToken]：换账号清本机数据、进切换列表、登记推送
  /// 设备标识、发 WS `bindUid` 这几件事一件不少。
  Future<UserInfo> applyQrLogin(Map<String, dynamic> data) async {
    final token = asText(data['authToken']);
    final rawUser = asMap(data['userInfo']);
    if (token.isEmpty || rawUser.isEmpty) {
      throw const UnknownApiException(
        '扫码登录推送里缺少 authToken / userInfo，请检查服务端协议',
      );
    }
    return _applyLoginToken(token, rawUser);
  }

  /// 拿到 `authToken` + `userInfo` 之后的**共同后半段**（密码登录与扫码登录共用）。
  Future<UserInfo> _applyLoginToken(
    String token,
    Map<String, dynamic> rawUser,
  ) async {
    final user = UserInfo.fromJson(rawUser);
    // 先把**当前这个账号**连同令牌存进切换列表（S10.1），以后在设置里能一键切回来。
    // 必须赶在 `applyLogin` 覆盖掉 token 之前；也要赶在清本机数据之前
    // （那一步只清数据，不动列表，但顺序上放前面读起来更顺）。
    await _preserveCurrentAccount();
    // 换账号：先把本机上一份会话/消息清掉（本地库没有账号维度，见这个方法自己的注释）
    await _resetLocalDataForAccount(user.userId);
    _session.applyLogin(user, authToken: token);
    // 新账号也进列表（它是当前这一份，切换页上要看得到自己）
    await _rememberAccount(user, token);

    // 登录成功后补登记一次设备标识：第一次装推送版时 `cid` 是空的，
    // 这一步负责把它填上并上报（未登录时上报会被跳过，见 push_registrar）
    unawaited(_push.ensure());

    // 老端登录成功后立刻发 bindUid（此时连接早已建立，init 已来过）。
    //
    // 扫码登录这条路上，「那条要登录的连接」其实是登录页自己开的那条匿名连接 ——
    // 服务端已经把**它**绑到这个人了；我们自己那条聊天连接是另外一条，要拿新令牌
    // 再绑一次（与密码登录一模一样）。
    _ws.send(<String, dynamic>{
      'type': WsEvents.bindUid,
      'user_id': user.userId,
      'token': token,
    });

    return user;
  }

  /// 换账号登录时清掉本机的会话与消息（同账号重新登录不动）。
  ///
  /// [force] 是「**确定换人了**」时走的（切换账号）：那时不再看 `lastUserId` ——
  /// 它是「上一次登录过谁」的记录，只要它被人为清掉（老版本的库、设置被清过一半），
  /// 不 force 的话就会把上一个账号的会话与消息留给新账号。
  ///
  /// 为什么非要清：本机数据是**一份**，没有账号维度，而「我的收藏」的会话 id 是
  /// **固定的 `-1`**（系统通知是 `system`，其它会话 id 都是对方的 `user_id`）。
  /// 同一台手机先登 a 再登 b，a 的收藏与 b 的收藏就落在本机同一条会话里，
  /// 打开看像两个人在一个群里说话（用户 2026-09-21 报的「乱套了」就是这个）。
  ///
  /// 服务端是按人的（收藏那条记录的 `chat_identify` 里含 `user_id`），
  /// 所以清的只是本机缓存：重新登录会重新拉会话列表，进会话时分页拉回历史。
  ///
  /// 放在 `applyLogin` **之前**、而且是 await 的：否则新账号的首次同步
  /// 可能跑在清理前面，把刚拉回来的数据又删一遍。
  Future<void> _resetLocalDataForAccount(
    String userId, {
    bool force = false,
  }) async {
    final store = CredentialStore.instance;
    final last = store.lastUserId;
    if (force || (last.isNotEmpty && last != userId)) {
      debugPrint('[会话] 换账号登录（$last → $userId），清掉本机的会话与消息');
      await _ref.read(conversationRepositoryProvider).wipeLocal();
      // 那几份按会话 id 存的本地偏好同理：不显示该聊天 / 手动未读 / 清空记录名单 /
      // 最近用过的表情。退出登录时也会清它们，但被顶下线与 token 失效那两条路
      // 不一定都走到（比如 ReloginNotice 只清了会话），所以在这里再统一收一道。
      await _ref.read(hiddenConversationsProvider.notifier).clear();
      await _ref.read(manualUnreadProvider.notifier).clearAll();
      await ClearedChatsStore.instance.clearAll();
      await _ref.read(recentEmojiProvider.notifier).clearAll();
      // 聊天背景也是按会话 id 存的本机偏好：新账号跟同一个人聊会沿用上个账号设的图
      await _ref.read(chatBackgroundRepositoryProvider).clearAll();
    }
    await store.saveLastUserId(userId);
  }

  /// 注册（老端 `pages/login/register.vue` 的 `regForm`）
  Future<void> register({
    required String account,
    required String realName,
    required String password,
    required String repass,
    String code = '',
  }) => _auth.register(<String, dynamic>{
    'account': account,
    'realname': realName,
    'password': password,
    'repass': repass,
    'code': code,
  });

  /// 发送验证码。`type`：1 登录 / 忘记密码，2 注册（老端两处调用分别是这两个值）
  Future<void> sendCode({required String account, required int type}) =>
      _auth.sendCode(<String, dynamic>{'account': account, 'type': type});

  /// 登出。
  ///
  /// 与老端的一处差别：老端只在接口 `code == 0` 时清本地，接口失败就登不出去；
  /// 这里无论服务端结果如何都清本地（否则用户会被卡在登录态里出不来）。
  Future<void> logout() async {
    final clientId = CredentialStore.instance.clientId;
    if (clientId != null && clientId.isNotEmpty) {
      try {
        await _auth.logout(<String, dynamic>{'client_id': clientId});
      } on ApiException catch (error) {
        debugPrint('[会话] 登出接口失败（本地仍会清会话）：${error.message}');
      }
    }
    await _ws.stop();
    // 「不显示该聊天」的名单是按会话 id 存的，换账号后没有意义，一起清掉
    await _ref.read(hiddenConversationsProvider.notifier).clear();
    await _ref.read(manualUnreadProvider.notifier).clearAll();
    // 「清空聊天记录」记的那份消息名单同理（「最近用过的表情」也一起）
    await ClearedChatsStore.instance.clearAll();
    await _ref.read(recentEmojiProvider.notifier).clearAll();
    // 退出登录：这一份**留在切换列表里**（用户 2026-09-29 定的语义），但服务端那份
    // 令牌已经作废，所以把它清空 —— 卡上会标「已退出」，再点它要重新输密码。
    await _forgetActiveAccountToken();
    _session.clearSession();
  }

  // ------------------------------------------------------------------ 切换账号

  /// 一键切到本机存过的另一个账号（S10.1）。
  ///
  /// 做的事情，以及**刻意不做**的事情：
  ///
  /// * **不调服务端登出接口**：那会把上一个账号的令牌作废，切回去就得重新输密码。
  ///   只把它的令牌连同 `userInfo` 存回列表（[SavedAccountsStore]），随时可以切回；
  /// * 断掉旧账号的 WS 连接，再把新账号写进那三份单槽位（`authToken` / `userInfo`），
  ///   重连后服务端 `init` 一到就自动 `bindUid`（见 [_bindAfterInit]）；
  /// * 本机聊天数据**照旧清掉**（`_resetLocalDataForAccount`：本地库没有账号维度，
  ///   不清就会把两个人的收藏、同一个人的会话串在一起 —— 用户 2026-09-21 报过）；
  /// * 上一个账号的通讯录、群语音那本账、正在跑的那通群通话由 `main.dart` 里那段
  ///   「登录态变了 / 换人了」的监听收掉（会话状态一变它就会跑）。
  Future<AccountSwitchResult> switchAccount(String userId) async {
    final accounts = SavedAccountsStore.instance;
    final target = accounts.byId(userId);
    if (target == null) return AccountSwitchResult.unknown;
    if (target.userId == _state.userId) {
      return AccountSwitchResult.alreadyActive;
    }
    if (!target.canSwitchOnline) return AccountSwitchResult.needsLogin;

    await _preserveCurrentAccount();
    await _ws.stop();
    // 强制清：本地库没有账号维度，只要换人就一定要清干净，不能看 `lastUserId`
    // （它是记录，不是真相；参见这个方法自己的注释）
    await _resetLocalDataForAccount(target.userId, force: true);
    // 界面以外的痕迹（通知栏、正在播的语音）也收掉
    await _clearPreviousAccountTraces();
    _session.applyLogin(target.user, authToken: target.authToken);
    await accounts.touch(target.userId);
    // 重连：`init` 到了会拿**新账号**的 token 重新 bindUid
    _ws.start();
    debugPrint('[会话] 已切换到 ${target.name}（${target.userId}）');
    return AccountSwitchResult.switched;
  }

  /// 切换之前，把上一个账号留在**界面以外**的痕迹收掉：
  ///
  /// * **通知栏**：那几条通知属于上一个人，点一下会拿着新账号的身份去开那个会话 id
  ///   （轻则一个空会话，重则跳到不相干的人那儿）；
  /// * **正在播的语音**：那是一条属于上个账号的消息，切过去还在响，高亮也会留在
  ///   新账号的同一行上。
  ///
  /// 剩下那几样不在这一步，各自有主（都是「按当前 user_id 重建」的路子）：
  /// 通讯录 / 群语音那本账 / 正在跑的那通群通话在 `main.dart` 的「换人了」分支，
  /// 1:1 通话控制器在 `callControllerProvider`（它盯 `user_id`，重建后
  /// `call_host` 会把通话页收掉）。
  Future<void> _clearPreviousAccountTraces() async {
    try {
      await _ref.read(messageNotificationPresenterProvider).cancelAll();
    } on Object catch (error) {
      // 清通知失败不能挡住切换
      debugPrint('[会话] 清通知栏失败：$error');
    }
    try {
      await _ref.read(voicePlayingProvider.notifier).stop();
    } on Object catch (error) {
      debugPrint('[会话] 停语音播放失败：$error');
    }
  }

  /// 把当前登录态（含令牌）存进切换列表。没登录、或令牌不在（刚被踢）就什么也不做。
  Future<void> _preserveCurrentAccount() async {
    final user = _state.user;
    final token = CredentialStore.instance.authToken ?? '';
    if (user == null || user.userId.isEmpty || token.isEmpty) return;
    await _rememberAccount(user, token);
  }

  /// 记一份账号（已有就整份替换，`clientIds` 那些本机痕迹保留）
  Future<void> _rememberAccount(UserInfo user, String token) async {
    if (user.userId.isEmpty) return;
    final previous = SavedAccountsStore.instance.byId(user.userId);
    await SavedAccountsStore.instance.upsert(
      SavedAccount(
        user: user,
        authToken: token,
        clientIds: previous?.clientIds ?? const <String>[],
        usedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// 退出登录时把当前账号那一份的令牌清空（条目留在列表里）
  Future<void> _forgetActiveAccountToken() async {
    final userId = _state.userId;
    if (userId.isEmpty) return;
    final saved = SavedAccountsStore.instance.byId(userId);
    if (saved == null) return;
    await SavedAccountsStore.instance.upsert(saved.copyWith(authToken: ''));
  }

  // -------------------------------------------------------- WS 事件（M2 部分）

  /// `init`：连接就绪，服务端分配了 client_id。
  ///
  /// **先发 WS `bindUid`，再跑 HTTP `bindUid`** —— 顺序与老端相反，是故意的。
  ///
  /// 老端是「HTTP 成功之后才发 WS bindUid；HTTP 失败就什么都不发」，本项目原先照抄了
  /// 这个顺序（还多一个 `return`），留下一个**静默失效**的坑：那一次 HTTP 请求一旦
  /// 失败（网络刚切换、服务端清缓存后第一个请求触发 token 刷新而报错……），WS 的
  /// `bindUid` 就**永远不发**，于是进入「连接是通的、心跳也正常，但服务端不知道这个
  /// uid 在线」的状态：收不到任何消息、来电与回执，界面却一直显示已连接。
  /// （2026-09-26 用户实际撞上：网页端拨号手机端毫无反应、新消息要重进会话才出现。）
  ///
  /// 两件事的职责本来就不同，拆开即可：
  /// * **WS `bindUid`** 决定「服务端能不能把实时消息推给我」——不能失败，也不该等谁；
  /// * **HTTP `bindUid`** 只是登记 `client_id` 与推送设备标识 `cid`——失败重试即可。
  Future<void> _bindAfterInit(String clientId) async {
    // 连接都通了，说明网络确实可用：配置还没拿到就再补一次
    // （冷启动第一次拉配置失败时，靠这一步自愈，不用重启 App）
    if (!_configLoaded) unawaited(refreshGlobalConfig());

    final state = _state;
    final user = state.user;
    if (user == null) {
      debugPrint('[会话] 连接就绪但未登录，暂不绑定设备（登录成功后会自动绑定）');
      return;
    }

    _sendWsBindUid(user.userId);
    // 记下本机为这个账号用过的 client_id：`offline`（被顶下线）那条推送要拿它
    // 判断「是不是本机自己」（见 [_onOffline]）
    unawaited(
      SavedAccountsStore.instance.rememberClientId(user.userId, clientId),
    );

    // 设备标识就绪了再登记：这一次请求就能把 `cid` 带上，不用等下次连接。
    // 最多等 2 秒（拿不到就先用本地缓存那份，别耽误收消息）——
    // token 晚到了也会自己补报一次（PushRegistrar.apply）。
    await _push.ensure().timeout(const Duration(seconds: 2), onTimeout: () {});
    if (!_ref.mounted) return;

    await _bindDevice(clientId, user.userId);
  }

  /// WS `bindUid`：让服务端把**这条连接**与 uid 关联起来。
  ///
  /// 收消息、收来电、收回执全都依赖它，所以它必须无条件发出（见 [_bindAfterInit]）。
  void _sendWsBindUid(String userId) {
    final sent = _ws.send(<String, dynamic>{
      'type': WsEvents.bindUid,
      'user_id': userId,
      'token': CredentialStore.instance.authToken ?? '',
    });
    if (!sent) {
      debugPrint('[WS] 连接未就绪，bindUid 未发出（重连后的 init 会再绑一次）');
    }
  }

  /// HTTP `bindUid`：登记 `client_id` 与推送 `cid`。**只重试，绝不抛。**
  ///
  /// 它失败不影响实时消息（WS 那边已经独立绑过了），所以只在日志里留痕；
  /// 但重试是必要的 —— 老端那套「一次失败就永久不绑定」正是上面那个坑的来源。
  Future<void> _bindDevice(String clientId, String userId) async {
    for (var attempt = 1; attempt <= _bindAttempts; attempt++) {
      try {
        await _auth.bindUid(<String, dynamic>{
          'client_id': clientId,
          'user_id': userId,
          'cid': CredentialStore.instance.cid ?? '',
        });
        return;
      } on ApiException catch (error) {
        debugPrint(
          '[会话] bindUid 失败（第 $attempt/$_bindAttempts 次）：${error.message}',
        );
        if (attempt >= _bindAttempts) return;
        await Future<void>.delayed(_bindRetryDelay * attempt);
        if (!_ref.mounted) return;
      }
    }
  }

  /// `offline`：被顶下线。
  ///
  /// 老端判断条件（三者同时成立才踢）：`id == user_id`、`client_id != 本地 client_id`、
  /// `isMobile`。并且**开启了多端登录就直接忽略**这个事件。
  Future<void> _onOffline(WsEvent event) async {
    if (_state.config.multiDeviceLogin) {
      debugPrint('[WS] offline：服务端允许多端登录，忽略');
      return;
    }

    final user = _state.user;
    if (user == null) return;

    final id = asText(event.data['id'] ?? event.top('id'));
    final eventClientId = asText(
      event.data['client_id'] ?? event.top('client_id'),
    );
    final localClientId = CredentialStore.instance.clientId ?? '';
    final isMobile = asBool(event.data['isMobile'] ?? event.top('isMobile'));

    if (id != user.userId) return;
    if (eventClientId.isEmpty || eventClientId == localClientId) return;
    // 这个 client_id 是本机**自己**用过的（切换账号时上一个连接、或者重开 App 时
    // 那条旧连接）→ 服务端把「旧连接下线」的事件发到了这条新连接上，不能当成
    // 「别的设备登录」而把自己踢掉。别的设备的 client_id 不会出现在这份名单里，
    // 所以真被顶下线时照样会踢。
    if (SavedAccountsStore.instance.isOwnClientId(eventClientId)) {
      debugPrint('[WS] offline：client_id 是本机自己用过的，忽略（不是别的设备）');
      return;
    }
    if (!isMobile) {
      debugPrint('[WS] offline：id 匹配但 isMobile 为假，按老端行为不踢下线');
      return;
    }

    noticeBus.toast('您的账号在其他设备登录，已被迫下线！');
    await _ws.stop();
    await _ref.read(hiddenConversationsProvider.notifier).clear();
    await _ref.read(manualUnreadProvider.notifier).clearAll();
    await ClearedChatsStore.instance.clearAll();
    await _ref.read(recentEmojiProvider.notifier).clearAll();
    _session.clearSession();
  }

  /// `updateConfig`：服务端热更新全局配置。
  ///
  /// 老端直接把这个事件的 `data` 当成整份配置覆盖。这里做一层兜底：
  /// 如果 `data` 是空的（服务端也可能把字段平铺在顶层），就用顶层字段。
  Future<void> _onUpdateConfig(WsEvent event) async {
    final payload = event.data.isNotEmpty
        ? event.data
        : (Map<String, dynamic>.from(event.raw)..remove('type'));
    if (payload.isEmpty) return;
    _session.applyConfig(GlobalConfig.fromJson(payload));
    debugPrint('[WS] 全局配置已更新');
  }
}

final sessionServiceProvider = Provider<SessionService>((ref) {
  return SessionService(
    ref,
    ref.watch(authApiProvider),
    ref.watch(wsServiceProvider),
    ref.watch(pushRegistrarProvider),
  );
});
