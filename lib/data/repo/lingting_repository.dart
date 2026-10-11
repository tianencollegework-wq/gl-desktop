import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_exception.dart';
import '../../core/store/lingting_store.dart';
import '../../core/util/json_value.dart';
import '../api/lingting/lingting_api.dart';
import '../model/lingting/home.dart';
import '../model/lingting/lyric.dart';
import '../model/lingting/singer.dart';
import '../model/lingting/song.dart';
import '../model/lingting/song_sheet.dart';

/// 灵听的仓库层：把「会话、歌词、喜欢、播放上报」这几件跨页面的活儿收在一处。
///
/// 页面只管调它，不直接碰接口；这样匿名登录、401 重登、歌词缓存这些细节
/// 只需要在这里对一次。
class LingtingRepository {
  LingtingRepository(this._api, this._store);

  final LingtingApi _api;
  final LingtingStore _store;

  /// 歌词缓存（按歌曲 id）：切歌来回切不重复下载 .lrc。
  ///
  /// 缓存里存的永远是**目前拿到的最好那一份**：有时间轴的优先，没有才放纯文本。
  final Map<int, LingtingLyric> _lyrics = <int, LingtingLyric>{};

  /// 已经问过 `.lrc` 的歌曲：服务端没给歌词时不要每次进页面都再问一遍
  final Set<int> _timelineAsked = <int>{};

  String get anonymousId => _store.anonymousId;

  // ------------------------------------------------------------ 会话

  /// 确保手里有一枚可用的 token。
  ///
  /// 匿名账号是**按本机 anonymousId** 建的：同一台机器每次都登回同一个账号，
  /// 所以「喜欢 / 最近播放」不会因为重装页面就换主人。
  Future<void> ensureSession({bool force = false}) async {
    if (!force && _store.hasSession) return;
    final token = await _api.anonymousLogin(
      anonymousId: _store.anonymousId,
      deviceId: _store.deviceId,
    );
    if (token.isEmpty) {
      throw const UnknownApiException('灵听登录失败');
    }
    await _store.saveSession(token: token, memberId: memberIdOfToken(token));
  }

  /// 带会话保护的调用：401（token 过期）时**重新匿名登录一次**再重试。
  ///
  /// 只重试一次：灵听的 token 有效期很长（实测 JWT 的 `exp` 在若干年后），
  /// 走到这里基本是「服务端换了密钥」，重试第二次也没意义。
  Future<T> guarded<T>(Future<T> Function() action) async {
    await ensureSession();
    try {
      return await action();
    } on UnauthorizedException {
      debugPrint('[灵听] 会话失效，重新匿名登录后重试');
      await ensureSession(force: true);
      return action();
    }
  }

  /// JWT 里那枚 `memberId`（payload 的 `id`）。
  ///
  /// 实测：`{"id":1404914,"exp":…}`。解不出来就退到 0（弱鉴权接口仍然能用，
  /// 强鉴权接口会 401 → 上层会重登）。
  @visibleForTesting
  static int memberIdOfToken(String token) {
    try {
      final parts = token.split('.');
      if (parts.length < 2) return 0;
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final decoded = json.decode(payload);
      if (decoded is Map) return int.tryParse(decoded['id'].toString()) ?? 0;
    } on Object catch (error) {
      debugPrint('[灵听] token 解析失败：$error');
    }
    return 0;
  }

  // ------------------------------------------------------------ 歌词

  /// 第一段歌词：**手上现成的那份**（列表/搜索自带的 `lyric` 纯文本），不发请求。
  ///
  /// 先给这一份是为了「进播放页立刻有字」，不至于为了等一次 `.lrc` 请求而转圈。
  /// 纯文本按 `;` 拆行（见 `plainLyricLines`），所以铺出来也是逐行歌词，
  /// 只是没有时间轴、不能跟着高亮。
  Future<LingtingLyric> quickLyric(LingtingSong song) async {
    final cached = _lyrics[song.songId];
    if (cached != null) return cached;
    final lyric = await _resolveLyric(song.rawLyric);
    _remember(song.songId, lyric);
    return lyric;
  }

  /// 第二段歌词：去要 `.lrc`（**有时间轴**的那份）。
  ///
  /// 实测：列表/搜索里的 `lyric` 只是把整首歌用 `;` 连成一行、**且往往比正文短**
  /// （抽的 180 首里，166 首不足 60 字），真正完整的歌词在
  /// `/v1/music/lyric` 给的那个 `.lrc` 地址上，带 `[mm:ss.xx]` 时间戳。
  ///
  /// 拿不到（接口空、下载失败、服务端没做这首歌的歌词）就返回 [LingtingLyric.empty]，
  /// 调用方继续用第一段那份；同一个歌曲 id **只问一次**。
  Future<LingtingLyric> timelineLyric(LingtingSong song) async {
    final cached = _lyrics[song.songId];
    if (cached != null && cached.hasTimeline) return cached;
    if (!_timelineAsked.add(song.songId)) return LingtingLyric.empty;

    final url = await guarded(
      () => _api.lyricUrl(song.songId),
    ).catchError((Object _) => '');
    if (url.isEmpty) return LingtingLyric.empty;
    final lyric = await _resolveLyric(url);
    if (!lyric.hasTimeline) return LingtingLyric.empty;
    _remember(song.songId, lyric);
    return lyric;
  }

  /// 两段一起走（测试与「不怕等」的调用方用）：拿不到时间轴就用手上那份纯文本。
  Future<LingtingLyric> lyric(LingtingSong song) async {
    final quick = await quickLyric(song);
    if (quick.hasTimeline) return quick;
    final full = await timelineLyric(song);
    return full.hasTimeline ? full : quick;
  }

  /// 只留更好的那一份：有时间轴的压过纯文本，纯文本压过空。
  void _remember(int songId, LingtingLyric lyric) {
    final cached = _lyrics[songId];
    if (cached != null && cached.hasTimeline && !lyric.hasTimeline) return;
    if (lyric.isEmpty && cached != null) return;
    _lyrics[songId] = lyric;
  }

  Future<LingtingLyric> _resolveLyric(String raw) async {
    final source = LingtingLyricSource.parse(raw);
    if (source.value.isEmpty) return LingtingLyric.empty;
    if (source.isUrl) {
      try {
        final text = await _api.client.getPlainText(source.value);
        return _lyricOf(text);
      } on Object catch (error) {
        // 歌词是「锦上添花」：下载失败（断网、COS 抽风、地址形态怪）就当作没歌词，
        // 绝不能把异常抛到播放页去把整页变成错误态
        debugPrint('[灵听] 歌词下载失败：$error');
        return LingtingLyric.empty;
      }
    }
    return _lyricOf(source.value);
  }

  /// 有 `[mm:ss]` 就当时间轴，没有就当纯文本（搜索接口给的就是纯文本）
  static LingtingLyric _lyricOf(String raw) {
    final lines = parseLrc(raw);
    if (lines.isNotEmpty) return LingtingLyric(lines: lines);
    final plain = plainLyricLines(raw);
    return plain.isEmpty
        ? LingtingLyric.empty
        : LingtingLyric(plain: plain.join('\n'));
  }

  // ------------------------------------------------------------ 详情

  /// 一首歌的详情（按 `songId`）。
  ///
  /// 目前只有一个用处：**「下载管理」里那种老记录只有一条磁盘路径**
  /// （最早那版下载只存了路径），歌名/歌手/封面/直链都缺 —— 打开那一页时按 id
  /// 补一次详情，把缺的字段填上（见 `LingtingDownloadsNotifier.enrichMissing`）。
  Future<LingtingSong> songDetail(int songId) =>
      guarded(() => _api.songDetail(songId));

  // ------------------------------------------------------------ 上报

  /// 开始播一首（灵听用它做「最近播放」）。失败不打扰用户。
  Future<void> reportPlay(LingtingSong song) async {
    try {
      await guarded(
        () => _api.reportPlay(song, anonymousId: _store.anonymousId),
      );
    } on ApiException catch (error) {
      debugPrint('[灵听] 播放上报失败：${error.message}');
    }
  }

  /// 这一首听了多久（秒）；为 0 就不发
  Future<void> reportPlayTime(LingtingSong song, int seconds) async {
    if (seconds <= 0) return;
    try {
      await guarded(
        () => _api.reportPlayTime(
          song: song,
          seconds: seconds,
          anonymousId: _store.anonymousId,
        ),
      );
    } on ApiException catch (error) {
      debugPrint('[灵听] 播放时长上报失败：${error.message}');
    }
  }

  // ------------------------------------------------------------ 内容缓存
  //
  // 「分层加载」的前半段：页面进来先问这里要一份**本机存着的**内容，立刻出画；
  // 网络上那份回来了再盖上去（见 `lingting_providers.dart`）。
  //
  // 存的是 JSON（不是内存对象）：冷启动也得能秒出画，只有内存缓存是不够的。
  // 区段键带 id，歌单/歌手/专辑各存各的；没有有效期 —— 内容过期与否交给
  // 「后台刷新」去解决，宁可先给一份旧的也不要转圈。

  static String homeCacheKey = 'home';
  static String sheetCacheKey(int sheetId) => 'sheet.$sheetId';
  static String singerCacheKey(int singerId) => 'singer.$singerId';
  static String singerSongsCacheKey(int singerId) => 'singer.$singerId.songs';
  static String singerAlbumsCacheKey(int singerId) => 'singer.$singerId.albums';
  static String albumCacheKey(int albumId) => 'album.$albumId';

  /// 本机存着的首页内容（没有 → null）
  LingtingHome? cachedHome() {
    final raw = _store.cacheRead(homeCacheKey);
    if (raw is! Map) return null;
    final home = LingtingHome.fromJson(raw.cast<String, dynamic>());
    return home.isEmpty ? null : home;
  }

  Future<void> saveHome(LingtingHome home) =>
      _store.cacheWrite(homeCacheKey, home.toJson());

  LingtingSongSheet? cachedSheet(int sheetId) => _decode(
    _store.cacheRead(sheetCacheKey(sheetId)),
    (json) => LingtingSongSheet.fromJson(json),
    (value) => value.isEmpty,
  );

  Future<void> saveSheet(LingtingSongSheet sheet) => sheet.isEmpty
      ? Future<void>.value()
      : _store.cacheWrite(sheetCacheKey(sheet.sheetId), sheet.toJson());

  LingtingSinger? cachedSinger(int singerId) => _decode(
    _store.cacheRead(singerCacheKey(singerId)),
    (json) => LingtingSinger.fromJson(json),
    (value) => value.isEmpty,
  );

  Future<void> saveSinger(int singerId, LingtingSinger singer) => singer.isEmpty
      ? Future<void>.value()
      : _store.cacheWrite(singerCacheKey(singerId), singer.toJson());

  List<LingtingSong> cachedSingerSongs(int singerId) =>
      songsFromList(_store.cacheRead(singerSongsCacheKey(singerId)));

  Future<void> saveSingerSongs(int singerId, List<LingtingSong> songs) =>
      songs.isEmpty
      ? Future<void>.value()
      : _store.cacheWrite(singerSongsCacheKey(singerId), songsToJson(songs));

  List<LingtingAlbum> cachedSingerAlbums(int singerId) =>
      albumsFromList(_store.cacheRead(singerAlbumsCacheKey(singerId)));

  Future<void> saveSingerAlbums(int singerId, List<LingtingAlbum> albums) =>
      albums.isEmpty
      ? Future<void>.value()
      : _store.cacheWrite(singerAlbumsCacheKey(singerId), albumsToJson(albums));

  LingtingAlbum? cachedAlbum(int albumId) => _decode(
    _store.cacheRead(albumCacheKey(albumId)),
    (json) => LingtingAlbum.fromJson(json),
    (value) => value.isEmpty,
  );

  Future<void> saveAlbum(LingtingAlbum album) => album.isEmpty
      ? Future<void>.value()
      : _store.cacheWrite(albumCacheKey(album.albumId), album.toJson());

  /// 读回一份对象（形态不对 / 解析失败 → null）：缓存坏了不该把页面弄崩
  static T? _decode<T>(
    Object? raw,
    T Function(Map<String, dynamic> json) parse,
    bool Function(T value) isEmpty,
  ) {
    if (raw is! Map) return null;
    try {
      final value = parse(asMap(raw));
      return isEmpty(value) ? null : value;
    } on Object catch (error) {
      debugPrint('[灵听] 缓存解析失败：$error');
      return null;
    }
  }

  // ------------------------------------------------------------ 透传

  LingtingApi get api => _api;
}

final lingtingRepositoryProvider = Provider<LingtingRepository>(
  (ref) => LingtingRepository(
    ref.watch(lingtingApiProvider),
    LingtingStore.instance,
  ),
);
