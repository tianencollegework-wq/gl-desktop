import 'package:flutter/foundation.dart';

import '../../../core/util/json_value.dart';
import 'singer.dart';
import 'song.dart';
import 'song_sheet.dart';

/// 搜索一次的结果。
///
/// 灵听的搜索是**分接口**的（`/search/music`、`/search/singer`、
/// `/search/song-sheet`…），每个接口回一个 `{songList|singerList|…, counts}`。
/// 页面上是三个 tab（单曲 / 歌手 / 歌单），所以这里把「一次搜索」收成一个对象：
/// [tabs] 决定显示哪些 tab（按有结果的来），[keyword] 是服务端回显的关键词
/// （它会做简繁转换，回显的是 `tkeyword`）。
@immutable
class LingtingSearchResult {
  const LingtingSearchResult({
    this.keyword = '',
    this.songs = const <LingtingSong>[],
    this.singers = const <LingtingSinger>[],
    this.sheets = const <LingtingSongSheet>[],
    this.songCount = 0,
    this.singerCount = 0,
    this.sheetCount = 0,
  });

  static const LingtingSearchResult empty = LingtingSearchResult();

  final String keyword;
  final List<LingtingSong> songs;
  final List<LingtingSinger> singers;
  final List<LingtingSongSheet> sheets;

  /// 服务端给的匹配总数（`counts`，比本页条数大，用来说「共 N 条」）
  final int songCount;
  final int singerCount;
  final int sheetCount;

  bool get isEmpty => songs.isEmpty && singers.isEmpty && sheets.isEmpty;

  /// 单曲接口的返回：`{songList, counts, keyword, tkeyword}`
  factory LingtingSearchResult.fromMusic(Object? data) {
    final json = asMap(data);
    final list = songsFromList(json['songList']);
    return LingtingSearchResult(
      keyword: asText(json['tkeyword'] ?? json['keyword']),
      songs: list,
      songCount: asInt(json['counts'], list.length),
    );
  }

  /// 歌手接口的返回：`{singerList, …}`
  factory LingtingSearchResult.fromSinger(Object? data) {
    final json = asMap(data);
    final list = singersFromList(json['singerList']);
    return LingtingSearchResult(
      keyword: asText(json['tkeyword'] ?? json['keyword']),
      singers: list,
      singerCount: asInt(json['counts'], list.length),
    );
  }

  /// 歌单接口的返回：`{songSheetList, …}`
  factory LingtingSearchResult.fromSheet(Object? data) {
    final json = asMap(data);
    final list = songSheetsFromList(json['songSheetList']);
    return LingtingSearchResult(
      keyword: asText(json['tkeyword'] ?? json['keyword']),
      sheets: list,
      sheetCount: asInt(json['counts'], list.length),
    );
  }

  /// 把后来的一块并进来（**分层搜索**用：三个接口各回各的，哪块先回来先显示哪块）。
  ///
  /// 加法语义：新一次搜索从 [empty] 开始，三块各并一次；同一块并两次会翻倍，
  /// 调用方保证一块只并一次（见 `lingting_search_page.dart` 的 `search`）。
  LingtingSearchResult mergeWith(LingtingSearchResult other) =>
      LingtingSearchResult(
        keyword: keyword.isNotEmpty ? keyword : other.keyword,
        songs: <LingtingSong>[...songs, ...other.songs],
        singers: <LingtingSinger>[...singers, ...other.singers],
        sheets: <LingtingSongSheet>[...sheets, ...other.sheets],
        songCount: songCount + other.songCount,
        singerCount: singerCount + other.singerCount,
        sheetCount: sheetCount + other.sheetCount,
      );

  /// 把三个接口的结果并成一次搜索（三块一起拿到时用）
  static LingtingSearchResult merge(
    LingtingSearchResult music,
    LingtingSearchResult singer,
    LingtingSearchResult sheet,
  ) => LingtingSearchResult(
    keyword: music.keyword.isNotEmpty
        ? music.keyword
        : (singer.keyword.isNotEmpty ? singer.keyword : sheet.keyword),
    songs: music.songs,
    singers: singer.singers,
    sheets: sheet.sheets,
    songCount: music.songCount,
    singerCount: singer.singerCount,
    sheetCount: sheet.sheetCount,
  );
}

/// 搜索结果的三个 tab（顺序固定：单曲 → 歌手 → 歌单；没有结果的 tab 不出现）
enum LingtingSearchTab { song, singer, sheet }

/// 这次搜索该显示哪几个 tab（纯函数，好单测）
List<LingtingSearchTab> searchTabsOf(LingtingSearchResult result) =>
    <LingtingSearchTab>[
      if (result.songs.isNotEmpty) LingtingSearchTab.song,
      if (result.singers.isNotEmpty) LingtingSearchTab.singer,
      if (result.sheets.isNotEmpty) LingtingSearchTab.sheet,
    ];
