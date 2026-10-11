import 'package:flutter/foundation.dart';

import 'song.dart';

/// 已下到本机的一首歌。
///
/// 除了文件路径，歌名/歌手/封面/原始地址也一起记：下载就是为了**离线**听，
/// 离线时再去问接口要歌名，下载就白做了（「下载管理」页要直接把它列出来）。
/// [url] 是下载时那条直链，从下载列表点播时用它 —— 播放器会优先用 [path]
/// 那份本地文件（见 `LingtingPlayerNotifier.startEngine`），所以下过的一定能离线播。
///
/// 放在 `data/model` 而不是下载状态那个文件里：`core/store`（本机清单）也要用它，
/// 而 store 不该反过来依赖 domain。
@immutable
class LingtingDownload {
  const LingtingDownload({
    required this.path,
    this.url = '',
    this.name = '',
    this.singer = '',
    this.cover = '',
  });

  /// 本机文件路径（`<应用文档目录>/lingting/<歌曲 id>.mp3`）
  final String path;

  /// 下载时那条直链（离线时没用，联网时「从列表点播」用得到）
  final String url;

  final String name;
  final String singer;
  final String cover;

  /// 从下载列表点这首 → 交给播放器的那首歌
  LingtingSong toSong(int songId) => LingtingSong(
    songId: songId,
    // 老记录没有歌名（最早的形态只存了路径）→ 退成一个不空的占位，免得界面空一行
    name: name.isEmpty ? '$songId' : name,
    singerName: singer,
    cover: cover,
    audioUrl: url,
  );

  /// 缺字段的那种老记录（最早只存了路径）：打开「下载管理」时要按 id 联网补一次。
  ///
  /// 不补的表现就是用户看到的那个画面：歌名是一个数字（`3866`）、封面空白 ——
  /// 而且没有直链就进不了播放队列，点一下没反应（本地文件明明在）。
  bool get needsEnrich =>
      name.isEmpty || singer.isEmpty || cover.isEmpty || url.isEmpty;

  /// 用接口给的详情补上缺的字段（**已经有的不动**，路径永远保留本机那份）。
  LingtingDownload mergedWith(LingtingSong song) => LingtingDownload(
    path: path,
    url: url.isEmpty ? song.audioUrl : url,
    name: name.isEmpty ? song.name : name,
    singer: singer.isEmpty ? song.singerName : singer,
    cover: cover.isEmpty ? song.cover : cover,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'path': path,
    if (url.isNotEmpty) 'url': url,
    if (name.isNotEmpty) 'name': name,
    if (singer.isNotEmpty) 'singer': singer,
    if (cover.isNotEmpty) 'cover': cover,
  };

  /// 读本机那条记录。**老的「只存了一行路径」那种也要认得**（当初就是那么存的）
  static LingtingDownload? fromStore(Object? raw) {
    if (raw is String) return raw.isEmpty ? null : LingtingDownload(path: raw);
    if (raw is Map) {
      final path = raw['path']?.toString() ?? '';
      if (path.isEmpty) return null;
      return LingtingDownload(
        path: path,
        url: raw['url']?.toString() ?? '',
        name: raw['name']?.toString() ?? '',
        singer: raw['singer']?.toString() ?? '',
        cover: raw['cover']?.toString() ?? '',
      );
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is LingtingDownload &&
      other.path == path &&
      other.url == url &&
      other.name == name &&
      other.singer == singer &&
      other.cover == cover;

  @override
  int get hashCode => Object.hash(path, url, name, singer, cover);

  @override
  String toString() => 'LingtingDownload($name → $path)';
}
