import 'package:flutter/foundation.dart';

import '../../../core/util/json_value.dart';
import 'markup.dart';

/// 一首歌。
///
/// 灵听把「列表项」和「详情」放在同一张表里（详情多几个字段），这里也共用一个
/// 模型，缺的字段留空 —— 列表接口那 20 来个字段里，我们真正要用的是
/// id / 名字 / 歌手 / 专辑 / 封面 / 音频地址 / 喜欢状态 / 歌词。
///
/// 两个实测细节：
/// * `audioLink` 是**直链 mp3**（`resource.lingtingmusic.com`），可以直接交给
///   `just_audio` 播，不需要再换链；
/// * `lyric` 有两种形态：详情接口给的是 **LRC 文件地址**，搜索接口给的却是
///   **歌词正文**（没有时间轴）。所以这一列不能当 URL 用，得先看内容
///   （见 `LingtingLyricSource`）。
///
/// 有意**不解析** `like` 字段：灵听那套收藏绑在 `memberId` 上，而我们只借了
/// 匿名身份 —— 收进界面就是「收藏了但换台设备就没了」，所以整个收藏功能不做，
/// 连这一个字段也不留在模型里（免得界面上再长出心形来）。
@immutable
class LingtingSong {
  const LingtingSong({
    required this.songId,
    required this.name,
    this.singerName = '',
    this.singerId = 0,
    this.albumName = '',
    this.albumId = 0,
    this.cover = '',
    this.audioUrl = '',
    this.videoId = 0,
    this.rawLyric = '',
  });

  static const LingtingSong none = LingtingSong(songId: 0, name: '');

  final int songId;
  final String name;
  final String singerName;
  final int singerId;
  final String albumName;
  final int albumId;
  final String cover;
  final String audioUrl;

  /// 有关联 MV 时非 0（灵听详情接口会给，我们只用来显示一行提示）
  final int videoId;

  /// 歌词原样：可能是 LRC 地址，也可能是正文（见类注释）
  final String rawLyric;

  bool get isEmpty => songId == 0 && name.isEmpty;

  /// 能播（地址非空）。不能播的（服务端偶尔有裸记录）不进播放列表。
  bool get playable => audioUrl.isNotEmpty;

  /// 页面上那行小字：`歌手 - 专辑`（专辑没给就只显示歌手）
  String get subtitle =>
      albumName.isEmpty ? singerName : '$singerName - $albumName';

  /// 歌名 / 歌手 / 专辑都在这里去掉**搜索命中标记**（`[一粒][麦子]` → `一粒麦子`）。
  ///
  /// 标记只出现在搜索结果里（详情与首页列表都是干净的），具体实测见
  /// `markup.dart` 的文件注释。放在解析层做，界面与分享出去的内容就都是干净的。
  factory LingtingSong.fromJson(Map<String, dynamic> json) => LingtingSong(
    songId: asInt(json['songId'] ?? json['id'], 0),
    name: stripLingtingMarkup(asText(json['songName'] ?? json['name'])),
    singerName: stripLingtingMarkup(asText(json['singerName'])),
    singerId: asInt(json['singerId'], 0),
    albumName: stripLingtingMarkup(asText(json['albumName'])),
    albumId: asInt(json['albumId'], 0),
    cover: asText(json['songCoverImage'] ?? json['cover']),
    audioUrl: asText(json['audioLink'] ?? json['audioUrl']),
    videoId: asInt(json['videoId'], 0),
    rawLyric: asText(json['lyric']),
  );

  /// 同一首歌（同一个 id + 同一份音频地址）—— 用来判断「这条是不是正在播的那首」
  bool sameSongAs(LingtingSong other) =>
      other.songId == songId && other.audioUrl == audioUrl;

  /// 写进本机缓存用。
  ///
  /// 字段名跟 [fromJson] 读的那几个**逐字对齐**（包括它兜底认的那几个别名）：
  /// 缓存一来一回必须跟接口回来那一份解析出同样的对象，所以这里写的是
  /// `songName` / `audioLink` 这一套接口的风格，而不是我们自己字段的名字。
  /// 至于搜索命中标记（`[恩典]`），[fromJson] 会再剥一次，重复剥是无害的。
  Map<String, dynamic> toJson() => <String, dynamic>{
    'songId': songId,
    'songName': name,
    'singerName': singerName,
    'singerId': singerId,
    'albumName': albumName,
    'albumId': albumId,
    'songCoverImage': cover,
    'audioLink': audioUrl,
    'videoId': videoId,
    'lyric': rawLyric,
  };

  @override
  bool operator ==(Object other) =>
      other is LingtingSong &&
      other.songId == songId &&
      other.name == name &&
      other.singerName == singerName &&
      other.singerId == singerId &&
      other.albumName == albumName &&
      other.albumId == albumId &&
      other.cover == cover &&
      other.audioUrl == audioUrl &&
      other.videoId == videoId &&
      other.rawLyric == rawLyric;

  @override
  int get hashCode => Object.hash(
    songId,
    name,
    singerName,
    singerId,
    albumName,
    albumId,
    cover,
    audioUrl,
    videoId,
    rawLyric,
  );

  @override
  String toString() => 'LingtingSong($songId, $name - $singerName)';
}

/// 把接口返回的列表（`List<dynamic>`）转成歌曲列表，顺带丢掉不能播的
/// 一串歌 → 缓存用的 JSON 数组
List<Map<String, dynamic>> songsToJson(List<LingtingSong> songs) =>
    songs.map((song) => song.toJson()).toList(growable: false);

List<LingtingSong> songsFromList(Object? value, {bool playableOnly = false}) =>
    asList(value)
        .whereType<Map<dynamic, dynamic>>()
        .map((item) => LingtingSong.fromJson(item.cast<String, dynamic>()))
        .where((song) => !playableOnly || song.playable)
        .toList(growable: false);
