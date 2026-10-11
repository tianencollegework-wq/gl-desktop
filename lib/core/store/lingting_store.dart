import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/model/lingting/download.dart';

/// 灵听（第三方音乐服务）在本机的凭据与偏好。
///
/// **刻意和 [CredentialStore] 分开**：灵听是另一个服务、另一套账号体系
/// （`memberId` + JWT `token`，走 `check-api.lingtingmusic.com`）。
/// 混进聊天那份凭据里的话，退出聊天账号会把灵听会话一起清掉 ——
/// 而灵听对我们来说只是「一个频道」，不该跟着聊天账号生死。
///
/// 单例在 `main()` 里 `await LingtingStore.init()` 之后可用。
class LingtingStore {
  LingtingStore._(this._prefs);

  final SharedPreferences _prefs;

  static const String keyAnonymousId = 'lingting.anonymousId';
  static const String keyToken = 'lingting.token';
  static const String keyMemberId = 'lingting.memberId';
  static const String keySearchHistory = 'lingting.searchHistory';

  /// 已下载到本机的歌：`{歌曲 id: 文件路径}` 的 JSON
  static const String keyDownloads = 'lingting.downloads';

  /// 本机搜索历史最多留这么多条（老端搜索历史也是本地存的）
  static const int maxSearchHistory = 20;

  static LingtingStore? _instance;

  static LingtingStore get instance {
    final loaded = _instance;
    if (loaded == null) {
      throw StateError(
        'LingtingStore 尚未初始化：请在 main() 中先 await LingtingStore.init()',
      );
    }
    return loaded;
  }

  static Future<LingtingStore> init() async {
    final prefs = await SharedPreferences.getInstance();
    final store = LingtingStore._(prefs);
    _instance = store;
    return store;
  }

  /// 本机的匿名设备标识（`anonymousId` 与 `deviceId` 都用它）。
  ///
  /// 服务端靠它认出「这还是同一台机器上的同一个匿名用户」，
  /// 所以**只能生成一次**：生成后立刻落盘，之后每次读回同一个值。
  /// （每次调用都新生成的话，灵听那边会不停建新匿名账号。）
  String get anonymousId {
    final existing = _prefs.getString(keyAnonymousId);
    if (existing != null && existing.isNotEmpty) return existing;
    final created = _generateAnonymousId();
    unawaited(_prefs.setString(keyAnonymousId, created));
    return created;
  }

  /// 与 [anonymousId] 同值：灵听的 `deviceId` 也是「一台机器一个」的口径
  String get deviceId => anonymousId;

  String? get token => _prefs.getString(keyToken);

  /// JWT 里解出来的 `memberId`（实名/匿名登录都有）
  int get memberId => int.tryParse(_prefs.getString(keyMemberId) ?? '') ?? 0;

  bool get hasSession {
    final value = token;
    return value != null && value.isNotEmpty;
  }

  Future<void> saveSession({
    required String token,
    required int memberId,
  }) async {
    await _prefs.setString(keyToken, token);
    await _prefs.setString(keyMemberId, memberId.toString());
  }

  /// 只清会话，**保留 [anonymousId]** —— 同一个匿名账号还能重新登录回来，
  /// 收藏/播放记录不会因为 token 过期就换了主人。
  Future<void> clearSession() async {
    await _prefs.remove(keyToken);
    await _prefs.remove(keyMemberId);
  }

  // ------------------------------------------------------------ 搜索历史

  List<String> get searchHistory {
    final raw = _prefs.getString(keySearchHistory);
    if (raw == null || raw.isEmpty) return const <String>[];
    try {
      final decoded = json.decode(raw);
      if (decoded is! List) return const <String>[];
      return decoded
          .map((item) => item.toString())
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    } on FormatException {
      return const <String>[];
    }
  }

  /// 记一条搜索历史：重复的先提到最前，超出上限的丢掉（老端也是这个行为）
  Future<void> addSearchHistory(String keyword) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return;
    final next = <String>[
      trimmed,
      ...searchHistory.where((item) => item != trimmed),
    ];
    if (next.length > maxSearchHistory) {
      next.removeRange(maxSearchHistory, next.length);
    }
    unawaited(_prefs.setString(keySearchHistory, json.encode(next)));
  }

  Future<void> clearSearchHistory() => _prefs.remove(keySearchHistory);

  // ------------------------------------------------------------ 下载

  /// 本机已下载的歌：歌曲 id → [LingtingDownload]（路径 + 歌名/歌手/封面/直链）
  ///
  /// 歌名封面也存是因为「下载」就是为了**离线**听：只看路径的话，离线时
  /// 「下载管理」页只能列出一堆文件路径。文件真被系统清理掉时由
  /// [LingtingDownloadsNotifier] 负责剔除。
  /// 读取兼容最早那种「只存一行路径」的形态（[LingtingDownload.fromStore]）。
  Map<int, LingtingDownload> get downloads {
    final raw = _prefs.getString(keyDownloads);
    if (raw == null || raw.isEmpty) return <int, LingtingDownload>{};
    try {
      final decoded = json.decode(raw);
      if (decoded is! Map) return <int, LingtingDownload>{};
      final result = <int, LingtingDownload>{};
      for (final entry in decoded.entries) {
        final songId = int.tryParse(entry.key.toString());
        if (songId == null) continue;
        final download = LingtingDownload.fromStore(entry.value);
        if (download != null) result[songId] = download;
      }
      return result;
    } on FormatException {
      return <int, LingtingDownload>{};
    }
  }

  /// 记下「哪些歌已下到本机」。
  ///
  /// **键必须先转成字符串**：JSON 对象的键只能是字符串，把 `Map<int, String>` 直接
  /// 丢给 `json.encode` 会抛 `Converting object to an encodable object failed: _Map len:1`。
  /// 这一条坑了整整一轮：文件其实已经下好了，是**存清单**这一步把整条下载判成了失败
  /// （用户看到的就是「下载一直失败」，日志里那句编码错误是 2026-09-25 从真机 logcat 里
  /// 抓到的）。读回来的那一侧（[downloads]）本来就是按字符串键 `int.tryParse` 的。
  Future<void> saveDownloads(Map<int, LingtingDownload> value) =>
      _prefs.setString(
        keyDownloads,
        json.encode(<String, dynamic>{
          for (final entry in value.entries)
            entry.key.toString(): entry.value.toJson(),
        }),
      );

  /// 只删一条
  Future<void> removeSearchHistory(String keyword) async {
    final next = searchHistory.where((item) => item != keyword).toList();
    unawaited(_prefs.setString(keySearchHistory, json.encode(next)));
  }

  // ------------------------------------------------------------ 内容缓存
  //
  // 灵听每一页拉回来的内容都往这里放一份（JSON + 写入时间）：下次进来**先画它**、
  // 再在后台刷新 —— 用户看到的就是「秒出画 + 悄悄变新」，而不是每次一片转圈
  //（见 `LingtingRepository` 的 `cachedXxx` / `saveXxx` 与 `lingting_providers.dart`）。

  /// 缓存根键：`{<区段键>: {"at": <写入毫秒>, "v": <JSON>}}`
  static const String keyCache = 'lingting.cache';

  Map<String, dynamic> _cacheRoot() {
    final raw = _prefs.getString(keyCache);
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = json.decode(raw);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    } on FormatException {
      // 坏了就当没有：一份缓存解析失败不该让页面崩，下一次写入会把整块盖掉
      debugPrint('[灵听] 缓存坏了，当作没有');
    }
    return <String, dynamic>{};
  }

  /// 读一个区段的值（没有 / 坏了 → null）
  Object? cacheRead(String key) {
    final entry = _cacheRoot()[key];
    if (entry is! Map) return null;
    return entry['v'];
  }

  /// 这个区段是什么时候写的（没有 → null）
  DateTime? cacheTime(String key) {
    final entry = _cacheRoot()[key];
    if (entry is! Map) return null;
    final at = int.tryParse(entry['at'].toString());
    return at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
  }

  /// 写一个区段（值必须能被 `jsonEncode`）
  Future<void> cacheWrite(String key, Object? value) {
    final root = _cacheRoot();
    root[key] = <String, dynamic>{
      'at': DateTime.now().millisecondsSinceEpoch,
      'v': value,
    };
    return _prefs.setString(keyCache, json.encode(root));
  }

  Future<void> cacheRemove(String key) {
    final root = _cacheRoot()..remove(key);
    return _prefs.setString(keyCache, json.encode(root));
  }

  /// 把灵听攒下来的内容缓存全清掉（设置页要加「清理缓存」时用它）
  Future<void> cacheClear() => _prefs.remove(keyCache);

  static String _generateAnonymousId() {
    final random = Random.secure();
    final buffer = StringBuffer('gracelink-');
    buffer.write(DateTime.now().millisecondsSinceEpoch.toRadixString(16));
    buffer.write('-');
    for (var i = 0; i < 8; i++) {
      buffer.write(random.nextInt(16).toRadixString(16));
    }
    return buffer.toString();
  }
}
