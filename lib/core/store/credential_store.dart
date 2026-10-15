import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 本地凭据与配置存储，替代老端的 `uni.getStorageSync / setStorageSync`。
///
/// 对应老端用到的那几个 key：
/// `authToken`、`client_id`、`cid`、`userInfo`、`globalConfig`、`appSetting`、`language`。
///
/// 单例在 `main()` 里 `await CredentialStore.init()` 之后可用，provider 见文件末尾。
class CredentialStore {
  CredentialStore._(this._prefs);

  final SharedPreferences _prefs;

  static const String keyAuthToken = 'authToken';
  static const String keyClientId = 'client_id';
  static const String keyCid = 'cid';

  /// iOS 的 VoIP 推送标识（PushKit 给的），与 [keyCid] **分开存**（S8.2）：
  /// 它们在服务端是两行设备，来电只走这一条。
  static const String keyCidVoip = 'cidVoip';

  /// **服务端已经收下过**的那条 VoIP 标识。
  ///
  /// 它与 [keyCidVoip]（本地存下的那条）是两件事：PushKit 的标识常常在**登录之前**
  /// 就到，那一次上报会被跳过（还没有 user / client_id），可本地已经落了盘。
  /// 拿本地值当「已经报过」的判据，那条标识就再也不会重报 —— 服务端设备表里
  /// 没有 `apns_voip:` 那一行，iPhone 的锁屏来电永远不弹（日志里却一片正常）。
  static const String keyCidVoipReported = 'cidVoipReported';
  static const String keyUserInfo = 'userInfo';
  static const String keyGlobalConfig = 'globalConfig';
  static const String keyAppSetting = 'appSetting';
  static const String keyLanguage = 'language';
  static const String keyProtocolLog = 'protocolLogEnabled';

  /// 「记住我」保存的登录表单（老端 `LoginAccount`，存的是整个 loginForm 对象）
  static const String keyLoginAccount = 'LoginAccount';

  /// 上一次登录过的账号（`clearSession` 不删它）：
  /// 本机的会话/消息没有账号维度，换账号登录时要据此把上一份清掉
  static const String keyLastUserId = 'lastUserId';

  static CredentialStore? _instance;

  static CredentialStore get instance {
    final loaded = _instance;
    if (loaded == null) {
      throw StateError(
        'CredentialStore 尚未初始化：请在 main() 中先 await CredentialStore.init()',
      );
    }
    return loaded;
  }

  static Future<CredentialStore> init() async {
    final prefs = await SharedPreferences.getInstance();
    final store = CredentialStore._(prefs);
    _instance = store;
    return store;
  }

  // ---------------------------------------------------------------- 基础读写

  String? getString(String key) => _prefs.getString(key);

  Future<void> setString(String key, String? value) async {
    if (value == null) {
      await _prefs.remove(key);
    } else {
      await _prefs.setString(key, value);
    }
  }

  bool getBool(String key, {bool defaultValue = false}) =>
      _prefs.getBool(key) ?? defaultValue;

  Future<void> setBool(String key, bool value) => _prefs.setBool(key, value);

  Map<String, dynamic>? getJson(String key) {
    final raw = _prefs.getString(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = json.decode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> setJson(String key, Map<String, dynamic>? value) =>
      setString(key, value == null ? null : json.encode(value));

  // ------------------------------------------------------------------ 语义化

  /// 请求头 `Authorization`
  String? get authToken => getString(keyAuthToken);

  Future<void> saveAuthToken(String? value) => setString(keyAuthToken, value);

  /// 请求头 `clientId`，来自 WS `init` 事件
  String? get clientId => getString(keyClientId);

  Future<void> saveClientId(String? value) => setString(keyClientId, value);

  /// 请求头 `cid`（推送客户端 id，M8 接入离线推送后才有值）
  String? get cid => getString(keyCid);

  Future<void> saveCid(String? value) => setString(keyCid, value);

  /// iOS 的 **VoIP 推送标识**（PushKit 给的那串 16 进制），存成 `apns_voip:xxx`。
  ///
  /// 为什么不与 [cid] 并成一条：它们在服务端是**两行设备**（provider 分别是 `fcm_ios`
  /// 与 `apns_voip`），而「锁屏来电」这件事只有后者做得到 —— 普通通知那条路
  /// 在 iPhone 上画不出系统来电界面。
  String? get cidVoip => getString(keyCidVoip);

  Future<void> saveCidVoip(String? value) => setString(keyCidVoip, value);

  /// 服务端已经收下的那条 VoIP 标识（没成功上报过就是 null）
  String? get cidVoipReported => getString(keyCidVoipReported);

  Future<void> saveCidVoipReported(String? value) =>
      setString(keyCidVoipReported, value);

  Map<String, dynamic>? get userInfo => getJson(keyUserInfo);

  Future<void> saveUserInfo(Map<String, dynamic>? value) =>
      setJson(keyUserInfo, value);

  Map<String, dynamic>? get globalConfig => getJson(keyGlobalConfig);

  Future<void> saveGlobalConfig(Map<String, dynamic>? value) =>
      setJson(keyGlobalConfig, value);

  Map<String, dynamic>? get appSetting => getJson(keyAppSetting);

  Future<void> saveAppSetting(Map<String, dynamic>? value) =>
      setJson(keyAppSetting, value);

  /// 语言码，直接用 `zh-Hans` / `en`（老端存的是 `{key, value}` 对象）
  String? get language => getString(keyLanguage);

  Future<void> saveLanguage(String? value) => setString(keyLanguage, value);

  /// 协议日志开关（S1.6）
  bool get protocolLogEnabled => getBool(keyProtocolLog);

  Future<void> saveProtocolLogEnabled(bool value) =>
      setBool(keyProtocolLog, value);

  /// 单个会话的聊天背景，老端 key 是 `chat-bg-info<会话 id>`，值是 `{image, filter}`。
  ///
  /// 这是**设备本地**的偏好（图片是本地文件路径），不跟随账号同步——老端也是存 storage。
  static const String chatBackgroundPrefix = 'chat-bg-info';

  static String chatBackgroundKey(String conversationId) =>
      '$chatBackgroundPrefix$conversationId';

  /// 清掉**所有**会话的聊天背景（换账号登录时用）。
  ///
  /// 背景是按会话 id 存的，而会话 id 在换账号后可能指同一个人：不清理的话，
  /// 新账号和同一个人聊天时会看到上个账号设的背景图（只是观感，不涉及消息）。
  /// 图片文件由 `ChatBackgroundRepository.clearAll` 一起删。
  Future<void> clearChatBackgrounds() async {
    final keys = _prefs
        .getKeys()
        .where((key) => key.startsWith(chatBackgroundPrefix))
        .toList();
    for (final key in keys) {
      await _prefs.remove(key);
    }
  }

  /// 聊天背景：返回 (图片，是否模糊)。没设置过就是空。
  ({String image, bool filter}) chatBackground(String conversationId) {
    final raw = getJson(chatBackgroundKey(conversationId));
    if (raw == null) return (image: '', filter: false);
    final value = raw['filter'];
    return (
      image: raw['image']?.toString() ?? '',
      filter: value == true || value == 1 || value?.toString() == '1',
    );
  }

  Future<void> saveChatBackground(
    String conversationId, {
    required String image,
    required bool filter,
  }) => setJson(chatBackgroundKey(conversationId), <String, dynamic>{
    'image': image,
    'filter': filter,
  });

  /// 上次登录过的 `user_id`（没登过就是空串）
  String get lastUserId => getString(keyLastUserId) ?? '';

  Future<void> saveLastUserId(String value) => setString(keyLastUserId, value);

  /// 是否已登录
  bool get hasSession => (authToken ?? '').isNotEmpty;

  /// 退出登录：清掉会话相关字段，保留语言、设置等本地偏好
  Future<void> clearSession() async {
    await _prefs.remove(keyAuthToken);
    await _prefs.remove(keyUserInfo);
    await _prefs.remove(keyClientId);
  }
}
