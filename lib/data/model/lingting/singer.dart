import 'package:flutter/foundation.dart';

import '../../../core/util/json_value.dart';
import 'song.dart';

/// 歌手。
///
/// 列表接口（推荐歌手 / 搜索歌手）给 `singerId / singerName / avatar / follow`；
/// 详情接口 additionally 给 `bgImg`（背景图）与 `fans`（粉丝数）。
@immutable
class LingtingSinger {
  const LingtingSinger({
    required this.singerId,
    required this.name,
    this.avatar = '',
    this.background = '',
    this.followed = false,
    this.fans = 0,
    this.songCount = 0,
  });

  static const LingtingSinger none = LingtingSinger(singerId: 0, name: '');

  final int singerId;
  final String name;
  final String avatar;

  /// 详情页背景图（列表接口没有，空串时用纯色兜底）
  final String background;

  final bool followed;
  final int fans;
  final int songCount;

  bool get isEmpty => singerId == 0 && name.isEmpty;

  factory LingtingSinger.fromJson(Map<String, dynamic> json) => LingtingSinger(
    singerId: asInt(json['singerId'] ?? json['id'], 0),
    name: asText(json['singerName'] ?? json['name']),
    avatar: asText(json['avatar']),
    background: asText(json['bgImg']),
    followed: asBool(json['follow']),
    fans: asInt(json['fans'], 0),
    songCount: asInt(json['musicNum'], 0),
  );

  /// 写进本机缓存用（字段名与 [fromJson] 对齐）
  Map<String, dynamic> toJson() => <String, dynamic>{
    'singerId': singerId,
    'singerName': name,
    'avatar': avatar,
    'bgImg': background,
    'follow': followed,
    'fans': fans,
    'musicNum': songCount,
  };

  LingtingSinger copyWith({bool? followed}) => LingtingSinger(
    singerId: singerId,
    name: name,
    avatar: avatar,
    background: background,
    followed: followed ?? this.followed,
    fans: fans,
    songCount: songCount,
  );

  @override
  bool operator ==(Object other) =>
      other is LingtingSinger &&
      other.singerId == singerId &&
      other.name == name &&
      other.avatar == avatar &&
      other.background == background &&
      other.followed == followed &&
      other.fans == fans;

  @override
  int get hashCode =>
      Object.hash(singerId, name, avatar, background, followed, fans);

  @override
  String toString() => 'LingtingSinger($singerId, $name)';
}

/// 专辑。结构与歌手类似：详情接口多给封面/播放数/歌曲列表。
@immutable
class LingtingAlbum {
  const LingtingAlbum({
    required this.albumId,
    required this.name,
    this.cover = '',
    this.singerId = 0,
    this.singerName = '',
    this.singerAvatar = '',
    this.songCount = 0,
    this.playCount = 0,
    this.songs = const <LingtingSong>[],
  });

  static const LingtingAlbum none = LingtingAlbum(albumId: 0, name: '');

  final int albumId;
  final String name;
  final String cover;
  final int singerId;
  final String singerName;
  final String singerAvatar;
  final int songCount;
  final int playCount;
  final List<LingtingSong> songs;

  bool get isEmpty => albumId == 0 && name.isEmpty;

  factory LingtingAlbum.fromJson(Map<String, dynamic> json) => LingtingAlbum(
    albumId: asInt(json['albumId'] ?? json['id'], 0),
    name: asText(json['albumName'] ?? json['name']),
    cover: asText(json['albumCoverImage'] ?? json['cover']),
    singerId: asInt(json['singerId'], 0),
    singerName: asText(json['singerName']),
    singerAvatar: asText(json['singerAvatar']),
    songCount: asInt(json['songCount'], 0),
    playCount: asInt(json['playCount'], 0),
    songs: songsFromList(json['songList']),
  );

  /// 写进本机缓存用（字段名与 [fromJson] 对齐）
  Map<String, dynamic> toJson() => <String, dynamic>{
    'albumId': albumId,
    'albumName': name,
    'albumCoverImage': cover,
    'singerId': singerId,
    'singerName': singerName,
    'singerAvatar': singerAvatar,
    'songCount': songCount,
    'playCount': playCount,
    'songList': songsToJson(songs),
  };

  @override
  bool operator ==(Object other) =>
      other is LingtingAlbum &&
      other.albumId == albumId &&
      other.name == name &&
      other.cover == cover &&
      other.songCount == songCount &&
      listEquals(other.songs, songs);

  @override
  int get hashCode =>
      Object.hash(albumId, name, cover, songCount, Object.hashAll(songs));

  @override
  String toString() => 'LingtingAlbum($albumId, $name)';
}

List<Map<String, dynamic>> singersToJson(List<LingtingSinger> singers) =>
    singers.map((singer) => singer.toJson()).toList(growable: false);

List<Map<String, dynamic>> albumsToJson(List<LingtingAlbum> albums) =>
    albums.map((album) => album.toJson()).toList(growable: false);

List<LingtingSinger> singersFromList(Object? value) => asList(value)
    .whereType<Map<dynamic, dynamic>>()
    .map((item) => LingtingSinger.fromJson(item.cast<String, dynamic>()))
    .toList(growable: false);

List<LingtingAlbum> albumsFromList(Object? value) => asList(value)
    .whereType<Map<dynamic, dynamic>>()
    .map((item) => LingtingAlbum.fromJson(item.cast<String, dynamic>()))
    .toList(growable: false);
