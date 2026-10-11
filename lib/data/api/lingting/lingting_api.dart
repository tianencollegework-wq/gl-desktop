import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/net/api_exception.dart';
import '../../../core/util/json_value.dart';
import '../../model/lingting/home.dart';
import '../../model/lingting/search.dart';
import '../../model/lingting/singer.dart';
import '../../model/lingting/song.dart';
import '../../model/lingting/song_sheet.dart';
import 'lingting_client.dart';

/// 灵听的接口清单。
///
/// 只包我们用得到的那一批（接口全集见 `docs/api/lingting-api.md`）：
/// 首页五个接口、搜索三个、详情四类（歌/歌单/歌手/专辑）、匿名登录、
/// 歌词、播放上报。
///
/// 两个实测要点写在对应方法上：
/// * 灵听的**写接口参数都挂在 query 上**（`play?songId=27`、
///   `play_time` 的 body 反而是空的）；
/// * 首页/搜索这类聚合页要「**一块挂了不能整页白屏**」，所以逐个 catch。
class LingtingApi {
  LingtingApi(this._client);

  final LingtingClient _client;

  LingtingClient get client => _client;

  // ------------------------------------------------------------ 账户

  /// 匿名登录，换来一枚 JWT（`data` 就是 token 字符串）。
  ///
  /// 我们**不是**要把灵听的账号体系接进聊天里 —— 只是拿一个身份，
  /// 让「喜欢 / 最近播放」有地方存。所以用本机的 `anonymousId` 建一个匿名账号，
  /// 同一台机器每次都登录回同一个账号（token 里带着它的 `memberId`）。
  Future<String> anonymousLogin({
    required String anonymousId,
    required String deviceId,
    String appVersion = '1.0.0',
  }) async {
    final data = await _client.post(
      '/v1/account/anonymous/login',
      data: <String, dynamic>{
        'anonymousId': anonymousId,
        'deviceId': deviceId,
        'deviceType': 'android',
        'appVersion': appVersion,
        'loginType': 0,
        'loginStatus': 1,
      },
    );
    return asText(data);
  }

  // ------------------------------------------------------------ 首页

  /// 首页被拆成**五个独立的方法**（原先是一个 `home()` 把五个请求 `Future.wait`
  /// 到一起）：首页那一页就是靠它们**一块一块往外画**的，哪一块先回来就先出现，
  /// 不再等最慢的那一个（用户 2026-09-30：「每次要转圈圈大半天」）。
  ///
  /// 每一块自己吐自己那一段，任一块挂了只让它自己空着（`_orNull`）。

  /// 轮播
  Future<List<LingtingBanner>> homeBanners() async =>
      bannersFromList(await _orNull(() => _client.get('/v1/music/banner')));

  /// 「每日三十首」。
  ///
  /// 这个接口有个实测出来的脾气：**新注册的匿名账号会拿到 401**
  /// （同一个 token 换老账号就好使，见用例注释），于是这一块会静悄悄地空掉 ——
  /// 首页看起来就是「少了一段」。所以这里加一道兜底：拿不到每日三十首就退到
  /// **置顶栏**那几条歌曲列表（新歌首发 → 纯音乐），它们是同一套歌曲结构、
  /// 且匿名账号也能拉到。`fromTop` 让界面换成对应的标题，不冒充。
  Future<({List<LingtingSong> songs, bool fromTop})> homeDaily() async {
    final songs = songsFromList(
      await _orNull(() => _client.get('/v1/homepage/daily/songs')),
    );
    if (songs.isNotEmpty) return (songs: songs, fromTop: false);
    final fresh = songsFromList(await _topSongs('new'));
    if (fresh.isNotEmpty) return (songs: fresh, fromTop: true);
    return (songs: songsFromList(await _topSongs('absolute')), fromTop: true);
  }

  /// 热门歌曲
  Future<List<LingtingSong>> homeHot() async =>
      songsFromList(await _orNull(() => _client.get('/v1/homepage/hot/songs')));

  /// 推荐歌单
  Future<List<LingtingSongSheet>> homeSheets() async => songSheetsFromList(
    await _orNull(() => _client.get('/v1/homepage/recommend/songSheet')),
  );

  /// 推荐歌手
  Future<List<LingtingSinger>> homeSingers() async => singersFromList(
    await _orNull(() => _client.get('/v1/homepage/recommend/singer')),
  );

  /// 置顶栏那三条歌曲列表（`new` 新歌首发 / `absolute` 纯音乐 / `singer` 精选歌手）。
  ///
  /// 实测：这三条**不需要** `token`，但都要带 `userId`（给 0 也行）。
  Future<Object?> _topSongs(String kind) => _orNull(
    () => _client.get(
      '/v1/homepage/top/$kind/song',
      query: <String, dynamic>{
        'pageNum': 1,
        'pageSize': 30,
        // `userId` 只当排序偏好用，匿名账号给 0 也照样有数据
        'userId': 0,
      },
    ),
  );

  // ------------------------------------------------------------ 搜索

  /// 搜索联想（输入框边打字边给候选）
  Future<List<String>> suggest(String keyword) async {
    final data = await _client.get(
      '/v1/search/associate',
      query: <String, dynamic>{'keyword': keyword},
    );
    return asList(data).map((item) => item.toString()).toList(growable: false);
  }

  /// 搜索也是**一块一块来**的：单曲 / 歌手 / 歌单各是一个接口，页面让它们各走各的
  /// （哪块先回来先显示哪块），所以这里也拆成三个方法。
  ///
  /// 一次搜到底（三块 `Future.wait`）请用 [searchAll]。
  Future<LingtingSearchResult> searchSongs(
    String keyword, {
    int pageSize = 30,
  }) async => LingtingSearchResult.fromMusic(
    await _orNull(() => _search('music', keyword, pageSize)),
  );

  Future<LingtingSearchResult> searchSingers(
    String keyword, {
    int pageSize = 30,
  }) async => LingtingSearchResult.fromSinger(
    await _orNull(() => _search('singer', keyword, pageSize)),
  );

  Future<LingtingSearchResult> searchSheets(
    String keyword, {
    int pageSize = 30,
  }) async => LingtingSearchResult.fromSheet(
    await _orNull(() => _search('song-sheet', keyword, pageSize)),
  );

  /// 单曲 / 歌手 / 歌单三个接口并行搜一次（不怕等一会儿的调用方用这个）
  Future<LingtingSearchResult> searchAll(
    String keyword, {
    int pageSize = 30,
  }) async {
    final results =
        await Future.wait<LingtingSearchResult>(<Future<LingtingSearchResult>>[
          searchSongs(keyword, pageSize: pageSize),
          searchSingers(keyword, pageSize: pageSize),
          searchSheets(keyword, pageSize: pageSize),
        ]);
    return results.reduce((a, b) => a.mergeWith(b));
  }

  Future<Object?> _search(String kind, String keyword, int pageSize) =>
      _client.get(
        '/v1/search/$kind',
        query: <String, dynamic>{
          'keyword': keyword,
          'pageNum': 1,
          'pageSize': pageSize,
        },
      );

  // ------------------------------------------------------------ 详情

  Future<LingtingSong> songDetail(int songId) async {
    final data = await _client.get(
      '/v1/music/detail',
      query: <String, dynamic>{'songId': songId},
    );
    return LingtingSong.fromJson(asMap(data));
  }

  /// 歌词接口给的是**一个 `.lrc` 地址**（可能为空串）
  Future<String> lyricUrl(int songId) async {
    final data = await _client.get(
      '/v1/music/lyric',
      query: <String, dynamic>{'songId': songId},
    );
    return asText(data);
  }

  Future<LingtingSongSheet> sheetDetail(int sheetId) async {
    final data = await _client.get(
      '/v1/song-sheet/detail',
      query: <String, dynamic>{'songSheetId': sheetId},
    );
    return LingtingSongSheet.fromJson(asMap(data));
  }

  /// 歌单里的歌曲（详情接口只内嵌第一页，翻页用这个）
  Future<List<LingtingSong>> sheetSongs(
    int sheetId, {
    int pageNum = 1,
    int pageSize = 50,
  }) async {
    final data = await _client.get(
      '/v1/song-sheet/songList',
      query: <String, dynamic>{
        'songSheetId': sheetId,
        'pageNum': pageNum,
        'pageSize': pageSize,
      },
    );
    return songsFromList(data);
  }

  Future<LingtingSinger> singerDetail(int singerId) async {
    final data = await _client.get(
      '/v1/singer/detail',
      query: <String, dynamic>{'singerId': singerId},
    );
    return LingtingSinger.fromJson(asMap(data));
  }

  Future<List<LingtingSong>> singerSongs(
    int singerId, {
    int pageNum = 1,
    int pageSize = 30,
  }) async {
    final data = await _client.get(
      '/v1/singer/song/list',
      query: <String, dynamic>{
        'singerId': singerId,
        'pageNum': pageNum,
        'pageSize': pageSize,
      },
    );
    return songsFromList(data);
  }

  Future<List<LingtingAlbum>> singerAlbums(int singerId) async {
    final data = await _client.get(
      '/v1/singer/album/list',
      query: <String, dynamic>{'singerId': singerId},
    );
    return albumsFromList(data);
  }

  Future<LingtingAlbum> albumDetail(int albumId) async {
    final data = await _client.get(
      '/v1/Album/detail',
      query: <String, dynamic>{'albumId': albumId},
    );
    return LingtingAlbum.fromJson(asMap(data));
  }

  // ------------------------------------------------------------ 上报
  //
  // 「喜欢 / 收藏」那一套**没做**（2026-09-23 用户决定去掉）：
  // 那是 `/v1/music/like` 与 `/v1/member/collect/*`，必须带真 token 与真实
  // `memberId`，而我们只借了灵听一个**匿名**身份 —— 收藏进得去、但对用户
  // 没有意义（换个设备就没了，也没法跟聊天账号对应）。所以这一块整个不接。

  /// 播放记录（灵听拿它做「最近播放」与推荐）
  Future<void> reportPlay(LingtingSong song, {String anonymousId = ''}) =>
      _client.post(
        '/v1/music/play',
        query: <String, dynamic>{
          'songId': song.songId,
          if (anonymousId.isNotEmpty) 'anonymousId': anonymousId,
        },
      );

  /// 播放时长（`{songId, time}`，time 是秒）
  Future<void> reportPlayTime({
    required LingtingSong song,
    required int seconds,
    String anonymousId = '',
  }) => _client.post(
    '/v1/music/play_time',
    data: <String, dynamic>{
      'songId': song.songId,
      'time': seconds,
      if (anonymousId.isNotEmpty) 'anonymousId': anonymousId,
    },
  );

  /// 聚合页里「挂一块不挂一页」：单个请求失败就返回 null，让那一块空着。
  ///
  /// 只吞 [ApiException]（接口/网络问题）；其它异常照旧往上抛，
  /// 免得把编程错误也一并藏掉。
  static Future<Object?> _orNull(Future<Object?> Function() request) async {
    try {
      return await request();
    } on ApiException {
      return null;
    }
  }
}

final lingtingApiProvider = Provider<LingtingApi>((ref) {
  return LingtingApi(LingtingClient());
});
