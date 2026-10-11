import 'package:flutter/foundation.dart';

import '../../../core/util/json_value.dart';
import 'song.dart';

/// 歌单。
///
/// 「推荐歌单」那种列表项只有 id / 名字 / 封面（`songCount` 是 `null`），
/// 详情接口才会把 `songCount` / `playCount` / 作者 / 歌曲列表给全，
/// 所以这些字段全部可空、页面上按有没有值来决定显不显示。
@immutable
class LingtingSongSheet {
  const LingtingSongSheet({
    required this.sheetId,
    required this.name,
    this.cover = '',
    this.description = '',
    this.authorId = 0,
    this.authorName = '',
    this.authorAvatar = '',
    this.songCount = 0,
    this.playCount = 0,
    this.songs = const <LingtingSong>[],
  });

  static const LingtingSongSheet none = LingtingSongSheet(sheetId: 0, name: '');

  final int sheetId;
  final String name;
  final String cover;
  final String description;

  /// 作者（详情接口里叫 `singerId` / `singerName`，其实是**建歌单的用户**）
  final int authorId;
  final String authorName;
  final String authorAvatar;

  final int songCount;
  final int playCount;

  /// 详情接口直接内嵌的那一页歌曲（列表接口没有）
  final List<LingtingSong> songs;

  bool get isEmpty => sheetId == 0 && name.isEmpty;

  /// 「20 首」这种小字；数量未知时给空串（不写「0 首」误导人）
  String get countLabel => songCount > 0 ? '$songCount' : '';

  factory LingtingSongSheet.fromJson(Map<String, dynamic> json) {
    final rawSongs = json['songList'];
    return LingtingSongSheet(
      sheetId: asInt(json['songSheetId'] ?? json['id'], 0),
      name: asText(json['songSheetName'] ?? json['name']),
      cover: asText(json['songSheetCoverImage'] ?? json['cover']),
      description: asText(json['songSheetDescription'] ?? json['description']),
      authorId: asInt(json['singerId'], 0),
      authorName: asText(json['singerName']),
      authorAvatar: asText(json['singerAvatar']),
      songCount: asInt(json['songCount'], 0),
      playCount: asInt(json['playCount'] ?? json['songSheetPlayCount'], 0),
      songs: songsFromList(rawSongs),
    );
  }

  /// 写进本机缓存用（字段名与 [fromJson] 对齐）
  Map<String, dynamic> toJson() => <String, dynamic>{
    'songSheetId': sheetId,
    'songSheetName': name,
    'songSheetCoverImage': cover,
    'songSheetDescription': description,
    'singerId': authorId,
    'singerName': authorName,
    'singerAvatar': authorAvatar,
    'songCount': songCount,
    'playCount': playCount,
    'songList': songsToJson(songs),
  };

  LingtingSongSheet copyWith({List<LingtingSong>? songs, int? songCount}) =>
      LingtingSongSheet(
        sheetId: sheetId,
        name: name,
        cover: cover,
        description: description,
        authorId: authorId,
        authorName: authorName,
        authorAvatar: authorAvatar,
        songCount: songCount ?? this.songCount,
        playCount: playCount,
        songs: songs ?? this.songs,
      );

  @override
  bool operator ==(Object other) =>
      other is LingtingSongSheet &&
      other.sheetId == sheetId &&
      other.name == name &&
      other.cover == cover &&
      other.songCount == songCount &&
      listEquals(other.songs, songs);

  @override
  int get hashCode =>
      Object.hash(sheetId, name, cover, songCount, Object.hashAll(songs));

  @override
  String toString() => 'LingtingSongSheet($sheetId, $name, ${songs.length} 首)';
}

List<Map<String, dynamic>> songSheetsToJson(List<LingtingSongSheet> sheets) =>
    sheets.map((sheet) => sheet.toJson()).toList(growable: false);

/// 列表接口返回的一串歌单
List<LingtingSongSheet> songSheetsFromList(Object? value) => asList(value)
    .whereType<Map<dynamic, dynamic>>()
    .map((item) => LingtingSongSheet.fromJson(item.cast<String, dynamic>()))
    .toList(growable: false);
