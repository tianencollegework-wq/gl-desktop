import 'dart:async';

import 'package:gracelinkim/core/store/lingting_store.dart';
import 'package:gracelinkim/data/api/lingting/lingting_api.dart';
import 'package:gracelinkim/data/api/lingting/lingting_client.dart';
import 'package:gracelinkim/data/model/lingting/home.dart';
import 'package:gracelinkim/data/model/lingting/lyric.dart';
import 'package:gracelinkim/data/model/lingting/search.dart';
import 'package:gracelinkim/data/model/lingting/singer.dart';
import 'package:gracelinkim/data/model/lingting/song.dart';
import 'package:gracelinkim/data/model/lingting/song_sheet.dart';
import 'package:gracelinkim/data/repo/lingting_repository.dart';

/// 假的灵听接口：只记「被调了什么」，返回用例摆好的数据。
///
/// 注意要在 `LingtingStore.init()`（`SharedPreferences.setMockInitialValues`）之后
/// 构造 —— `LingtingClient` 会去拿 store。
class FakeLingtingApi extends LingtingApi {
  FakeLingtingApi() : super(LingtingClient());

  LingtingHome homeResult = LingtingHome.empty;
  LingtingSearchResult searchResult = LingtingSearchResult.empty;
  List<String> suggestions = const <String>[];
  LingtingSong? detailResult;
  LingtingSongSheet sheetResult = LingtingSongSheet.none;

  /// 歌手页那三块（不摆就用一份带名字的假资料）
  LingtingSinger? singerResult;
  List<LingtingSong> singerSongsResult = const <LingtingSong>[];
  List<LingtingAlbum> singerAlbumsResult = const <LingtingAlbum>[];

  /// 专辑详情（不摆也用假的）
  LingtingAlbum? albumResult;

  final List<String> searched = <String>[];
  final List<String> suggested = <String>[];
  int homeCalls = 0;

  /// 「这一块先挂住」：给某个区块装一个闸门，用例自己决定什么时候放它过。
  ///
  /// 分层加载那几条用例靠它钉：**慢的区块不该拦住快的区块**。
  final Map<String, Completer<void>> gates = <String, Completer<void>>{};

  Future<void> _wait(String key) async {
    final gate = gates[key];
    if (gate != null) await gate.future;
  }

  /// 放行某个区块（没装闸门就什么都不做）
  void open(String key) {
    final gate = gates.remove(key);
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  // 首页五块：`homeResult` 一份拆成五块喂给分层加载
  //（用例还是只摆一份数据，不用按区块摆五遍）

  @override
  Future<List<LingtingBanner>> homeBanners() async {
    homeCalls += 1;
    await _wait('banners');
    return homeResult.banners;
  }

  @override
  Future<({List<LingtingSong> songs, bool fromTop})> homeDaily() async {
    homeCalls += 1;
    await _wait('daily');
    return (songs: homeResult.daily, fromTop: homeResult.dailyFromTop);
  }

  @override
  Future<List<LingtingSong>> homeHot() async {
    homeCalls += 1;
    await _wait('hot');
    return homeResult.hot;
  }

  @override
  Future<List<LingtingSongSheet>> homeSheets() async {
    homeCalls += 1;
    await _wait('sheets');
    return homeResult.sheets;
  }

  @override
  Future<List<LingtingSinger>> homeSingers() async {
    homeCalls += 1;
    await _wait('singers');
    return homeResult.singers;
  }

  @override
  Future<LingtingSinger> singerDetail(int singerId) async {
    await _wait('singerDetail');
    return singerResult ??
        LingtingSinger(singerId: singerId, name: '歌手 $singerId');
  }

  @override
  Future<List<LingtingSong>> singerSongs(
    int singerId, {
    int pageNum = 1,
    int pageSize = 30,
  }) async {
    await _wait('singerSongs');
    return singerSongsResult;
  }

  @override
  Future<List<LingtingAlbum>> singerAlbums(int singerId) async {
    await _wait('singerAlbums');
    return singerAlbumsResult;
  }

  @override
  Future<LingtingAlbum> albumDetail(int albumId) async {
    await _wait('albumDetail');
    return albumResult ?? LingtingAlbum(albumId: albumId, name: '专辑 $albumId');
  }

  /// 搜一次：三个接口是**分开**的，用例把三块拼成一份喂回来
  /// （`searchResult` 里只有单曲也罢，另外两块就是空）
  void _recordSearch(String keyword) {
    if (searched.isEmpty || searched.last != keyword) searched.add(keyword);
  }

  @override
  Future<LingtingSearchResult> searchSongs(
    String keyword, {
    int pageSize = 30,
  }) async {
    _recordSearch(keyword);
    await _wait('searchSongs');
    return LingtingSearchResult(
      songs: searchResult.songs,
      songCount: searchResult.songCount,
      keyword: searchResult.keyword,
    );
  }

  @override
  Future<LingtingSearchResult> searchSingers(
    String keyword, {
    int pageSize = 30,
  }) async {
    _recordSearch(keyword);
    await _wait('searchSingers');
    return LingtingSearchResult(
      singers: searchResult.singers,
      singerCount: searchResult.singerCount,
    );
  }

  @override
  Future<LingtingSearchResult> searchSheets(
    String keyword, {
    int pageSize = 30,
  }) async {
    _recordSearch(keyword);
    await _wait('searchSheets');
    return LingtingSearchResult(
      sheets: searchResult.sheets,
      sheetCount: searchResult.sheetCount,
    );
  }

  @override
  Future<List<String>> suggest(String keyword) async {
    suggested.add(keyword);
    return suggestions;
  }

  /// 详情接口被要了几次（「补全下载记录」那条路靠它钉）
  int detailCalls = 0;
  final List<int> detailSongIds = <int>[];

  @override
  Future<LingtingSong> songDetail(int songId) async {
    detailCalls += 1;
    detailSongIds.add(songId);
    return detailResult ?? LingtingSong(songId: songId, name: '详情 $songId');
  }

  @override
  Future<LingtingSongSheet> sheetDetail(int sheetId) async {
    await _wait('sheetDetail');
    return sheetResult;
  }
}

/// 假的仓库：**不打网络**。
///
/// 重点是把 [guarded] 与 [`ensureSession`] 换掉 —— 真的那两个会去
/// `check-api.lingtingmusic.com` 匿名登录，用例里不允许有真网络。
class FakeLingtingRepository extends LingtingRepository {
  FakeLingtingRepository(this.fakeApi) : super(fakeApi, LingtingStore.instance);

  final FakeLingtingApi fakeApi;

  int ensuredSessions = 0;
  int reportedPlays = 0;
  final List<int> reportedSeconds = <int>[];

  /// 第一段歌词（手上现成的那份纯文本）
  LingtingLyric lyricResult = LingtingLyric.empty;

  /// 第二段歌词（`.lrc` 那份，有时间轴）。默认空 = 「服务端没给时间轴」
  LingtingLyric timelineResult = LingtingLyric.empty;

  /// 歌词被「真取」了几次（缓存命中不算）—— 「播放进度跳动不该让歌词重取」
  /// 「播放页与通知栏各问一次、但只取一份」这两条就靠它钉
  int lyricCalls = 0;

  /// `.lrc` 被真取了几次（「只问一次」「拿到就升级」这两条靠它）
  int timelineCalls = 0;

  /// 真取过歌词的歌（缓存命中不记）—— 「切歌会重新取」靠它钉
  final List<int> lyricSongIds = <int>[];

  /// 与真仓库一个口径的缓存：谁先拿到就记谁，有了时间轴就不再要纯文本
  final Map<int, LingtingLyric> _lyrics = <int, LingtingLyric>{};
  final Set<int> _timelineAsked = <int>{};

  @override
  Future<void> ensureSession({bool force = false}) async {
    ensuredSessions += 1;
  }

  @override
  Future<T> guarded<T>(Future<T> Function() action) => action();

  @override
  Future<void> reportPlay(LingtingSong song) async {
    reportedPlays += 1;
  }

  @override
  Future<void> reportPlayTime(LingtingSong song, int seconds) async {
    reportedSeconds.add(seconds);
  }

  @override
  Future<LingtingLyric> quickLyric(LingtingSong song) async {
    final cached = _lyrics[song.songId];
    if (cached != null) return cached;
    lyricCalls += 1;
    lyricSongIds.add(song.songId);
    _lyrics[song.songId] = lyricResult;
    return lyricResult;
  }

  @override
  Future<LingtingLyric> timelineLyric(LingtingSong song) async {
    final cached = _lyrics[song.songId];
    if (cached != null && cached.hasTimeline) return cached;
    // 同一首只问一次（播放页和通知栏都会来问，闸门在仓库这边）
    if (!_timelineAsked.add(song.songId)) return LingtingLyric.empty;
    timelineCalls += 1;
    final full = timelineResult;
    if (full.hasTimeline) _lyrics[song.songId] = full;
    return full;
  }

  @override
  Future<LingtingLyric> lyric(LingtingSong song) async {
    final quick = await quickLyric(song);
    if (quick.hasTimeline) return quick;
    final full = await timelineLyric(song);
    return full.hasTimeline ? full : quick;
  }
}

/// 造一首可播的歌（`audioUrl` 非空，否则进不了播放队列）
LingtingSong fakeSong(
  int id, {
  String name = '',
  String singer = '小羊诗歌',
  String album = '我愿意',
}) => LingtingSong(
  songId: id,
  name: name.isEmpty ? '歌曲 $id' : name,
  singerName: singer,
  albumName: album,
  cover: 'https://example.test/cover$id.jpg',
  audioUrl: 'https://example.test/song$id.mp3',
);
