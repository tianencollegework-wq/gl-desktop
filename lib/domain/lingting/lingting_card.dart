/// 音乐卡片消息（`type == 'lingting'`）：发送、渲染、点击的纯逻辑。
///
/// 为什么不复用文本消息：文本里塞「《歌名》- 歌手 + 链接」，别的端看到的是一行
/// 裸文字，我们这边也没法做成一张像样的卡片。这里跟名片（`contact`）用的是
/// **同一套做法**：`content` 放「会话列表/通知里显示的那行字」，真正渲染要用的
/// 字段全部放 `extends`（`{songId, name, singer, cover, audioUrl}`）。
///
/// 服务端不校验 `type` 白名单（实测 `Message` 模型只对 `text` 做长度与 XSS 处理，
/// `type` 原样入库、能转发、能通过 WS 推给客户端），所以新类型可以直接用；
/// 代价是**官方网页端与旧 uniapp 收到会显示「暂不支持的消息类型」**——
/// 这是当初选「新类型」这条路的已知取舍。
library;

import 'package:flutter/foundation.dart';

import '../../core/util/json_value.dart';
import '../../data/model/lingting/song.dart';
import '../../data/model/message.dart';

/// 音乐卡片的消息类型（服务端原样存，不需要它认识）
const String lingtingMessageType = 'lingting';

@immutable
class MusicCard {
  const MusicCard({
    required this.songId,
    required this.name,
    this.singer = '',
    this.singerId = 0,
    this.album = '',
    this.albumId = 0,
    this.cover = '',
    this.audioUrl = '',
  });

  /// 从正在播的那首歌来
  factory MusicCard.fromSong(LingtingSong song) => MusicCard(
    songId: song.songId,
    name: song.name,
    singer: song.singerName,
    singerId: song.singerId,
    album: song.albumName,
    albumId: song.albumId,
    cover: song.cover,
    audioUrl: song.audioUrl,
  );

  final int songId;
  final String name;
  final String singer;

  /// 歌手 id —— 播放页「更多」里的**查看歌手**靠它（没带就只能显示灰的）
  final int singerId;

  /// 专辑名与专辑 id —— **查看专辑**靠它
  final String album;
  final int albumId;
  final String cover;
  final String audioUrl;

  bool get isEmpty => songId == 0 && name.isEmpty;

  /// 有地址才点得动（服务端偶尔有裸记录）
  bool get playable => audioUrl.isNotEmpty;

  String get displayTitle => singer.isEmpty ? '《$name》' : '《$name》- $singer';

  /// `content`：会话列表、通知里显示的那行字（与名片同一套写法）
  String content(String Function(String key) translate) =>
      '[${translate('common.music')}] $displayTitle';

  /// 发出去时放进 `extends` 的字段
  Map<String, dynamic> toExt() => <String, dynamic>{
    'songId': songId,
    'name': name,
    'singer': singer,
    'singerId': singerId,
    'album': album,
    'albumId': albumId,
    'cover': cover,
    'audioUrl': audioUrl,
  };

  /// 点卡片要播的就是这一首。灵听那边只需要这几个字段就能起播（播放页会去补歌词）。
  LingtingSong toSong() => LingtingSong(
    songId: songId,
    name: name,
    singerName: singer,
    singerId: singerId,
    albumName: album,
    albumId: albumId,
    cover: cover,
    audioUrl: audioUrl,
  );

  @override
  String toString() => 'MusicCard($songId, $name - $singer)';
}

/// 从一条消息里读回卡片。
///
/// 字段三个地方都读一遍（`extends` → 消息顶层 `extra`），与文件消息那套
/// 「多来源都认」的做法一致：别人（将来别的端）发的时候可能放在不同位置。
MusicCard musicCardOf(Message message) {
  final ext = message.ext;
  final extra = message.extra;
  String pick(String key) {
    final fromExt = asText(ext[key]);
    if (fromExt.isNotEmpty) return fromExt;
    return asText(extra[key]);
  }

  return MusicCard(
    songId: asInt(ext['songId'] ?? extra['songId'], 0),
    name: pick('name'),
    singer: pick('singer'),
    // 老卡片（2026-09-25 之前发的）没有这两个 id → 为 0，播放页会按 songId
    // 去详情接口补一次，这样「查看歌手 / 查看专辑」照样点得动
    singerId: asInt(ext['singerId'] ?? extra['singerId'], 0),
    album: pick('album'),
    albumId: asInt(ext['albumId'] ?? extra['albumId'], 0),
    cover: pick('cover'),
    audioUrl: pick('audioUrl'),
  );
}
