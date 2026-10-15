import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/store/lingting_store.dart';
import '../../data/model/lingting/download.dart';
import '../../data/model/lingting/song.dart';
import '../../data/repo/lingting_repository.dart';

/// 一首歌在本机的下载状态。
enum LingtingDownloadStatus {
  /// 没下过
  none,

  /// 正在下（[LingtingDownloads.progressOf] 给 0..1）
  downloading,

  /// 已下好，本地有文件
  done,

  /// 下失败了（网络、磁盘），再点一次可以重试
  failed,
}

/// 下载状态：哪些在下、哪些下好了。
///
/// **为什么要有这个功能**：灵听的音频是直链 mp3，下到本机之后播放不再走网络，
/// 弱网/离线也能听 —— 微信那个播放器里的「下载」就是这个意思（不是「发到聊天」）。
///
/// 落盘位置：`<应用文档目录>/lingting/<歌曲 id>.mp3`，记录在
/// [LingtingStore.downloads] 里。
@immutable
class LingtingDownloads {
  const LingtingDownloads({
    this.progress = const <int, double>{},
    this.items = const <int, LingtingDownload>{},
    this.failed = const <int>{},
  });

  static const LingtingDownloads empty = LingtingDownloads();

  /// 正在下载的：歌曲 id → 0..1
  final Map<int, double> progress;

  /// 已下好的：歌曲 id → 本机那一份（路径 + 歌名/歌手/封面/直链）
  final Map<int, LingtingDownload> items;

  /// 上次下失败的（点了重试就会从这儿消失）
  final Set<int> failed;

  LingtingDownloads copyWith({
    Map<int, double>? progress,
    Map<int, LingtingDownload>? items,
    Set<int>? failed,
  }) => LingtingDownloads(
    progress: progress ?? this.progress,
    items: items ?? this.items,
    failed: failed ?? this.failed,
  );

  LingtingDownloadStatus statusOf(int songId) {
    if (progress.containsKey(songId)) return LingtingDownloadStatus.downloading;
    if (items.containsKey(songId)) return LingtingDownloadStatus.done;
    if (failed.contains(songId)) return LingtingDownloadStatus.failed;
    return LingtingDownloadStatus.none;
  }

  double progressOf(int songId) => progress[songId] ?? 0;

  /// 本地文件路径（没下过给 null）
  String? pathOf(int songId) => items[songId]?.path;

  /// 「下载管理」页要列的那几首（没下过就是空表）
  List<LingtingSong> get songs => items.entries
      .map((entry) => entry.value.toSong(entry.key))
      .toList(growable: false);

  @override
  bool operator ==(Object other) =>
      other is LingtingDownloads &&
      mapEquals(other.progress, progress) &&
      mapEquals(other.items, items) &&
      setEquals(other.failed, failed);

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(progress.entries),
    Object.hashAllUnordered(items.entries),
    Object.hashAllUnordered(failed),
  );
}

class LingtingDownloadsNotifier extends Notifier<LingtingDownloads> {
  /// 正在下的那些：歌曲 id → 取消用的 token
  final Map<int, CancelToken> _tokens = <int, CancelToken>{};

  @override
  LingtingDownloads build() {
    // 页面退出/换歌时把还在下的那几路取消掉，别让它在后台继续占流量
    ref.onDispose(() {
      for (final token in _tokens.values) {
        token.cancel('下载页已退出');
      }
      _tokens.clear();
    });
    // 先信本机那份记录（同步读，不阻塞首帧）
    final remembered = LingtingStore.instance.downloads;
    unawaited(_pruneMissing(remembered));
    return LingtingDownloads(items: remembered);
  }

  /// 把「记录里有、磁盘上已经没有」的那几条剔掉（用户清了缓存、换了机器）
  Future<void> _pruneMissing(Map<int, LingtingDownload> remembered) async {
    if (remembered.isEmpty) return;
    final alive = <int, LingtingDownload>{};
    for (final entry in remembered.entries) {
      if (await File(entry.value.path).exists()) alive[entry.key] = entry.value;
    }
    if (alive.length == remembered.length) return;
    await LingtingStore.instance.saveDownloads(alive);
    if (ref.mounted) state = state.copyWith(items: alive);
  }

  /// 把「本机有文件、但记录里缺歌名/歌手/封面/直链」的那几条补全（老记录）。
  ///
  /// 为什么需要：最早那版下载**只存了一行路径**，于是「下载管理」里歌名是一个
  /// 歌曲 id（`3866`）、封面空白，而且没有直链就进不了播放队列 —— 点一下没反应
  /// （2026-09-25 用户报的现场）。打开这一页时按 `songId` 向灵听要一次详情，
  /// 把缺的字段补齐并存回本机清单（只补缺的，已在的那几栏不动）。
  ///
  /// 断网 / 接口挂了就安静跳过：那一页**不联网也能用**（本地文件照样能播）。
  Future<void> enrichMissing() async {
    final missing = state.items.entries
        .where(
          (entry) =>
              entry.value.needsEnrich &&
              // 盘上真的还有那一份才补：被系统清掉的那些交给 `_pruneMissing` 剔掉，
              // 这里不管 —— 否则会把刚剔掉的那一行又补回来（变成一条点不开的记录）
              File(entry.value.path).existsSync(),
        )
        .map((entry) => entry.key)
        .toList(growable: false);
    if (missing.isEmpty) return;
    final repo = ref.read(lingtingRepositoryProvider);
    final items = <int, LingtingDownload>{...state.items};
    var changed = false;
    for (final songId in missing) {
      try {
        final song = await repo.songDetail(songId);
        final old = items[songId];
        if (old == null) continue; // 补的路上被删掉了
        items[songId] = old.mergedWith(song);
        changed = true;
      } on Object catch (error) {
        debugPrint('[灵听] 补全下载记录失败 $songId（不影响本地播放）：$error');
      }
      if (!ref.mounted) return;
    }
    if (!changed) return;
    try {
      await LingtingStore.instance.saveDownloads(items);
    } on Object catch (error) {
      debugPrint('[灵听] 补全后存下载清单失败（界面照旧）：$error');
    }
    if (ref.mounted) state = state.copyWith(items: items);
  }

  /// 下载一首（已经在下的忽略；已下好的忽略）
  Future<void> download(LingtingSong song) async {
    if (song.audioUrl.isEmpty) return;
    final status = state.statusOf(song.songId);
    if (status == LingtingDownloadStatus.downloading ||
        status == LingtingDownloadStatus.done) {
      return;
    }

    final token = CancelToken();
    _tokens[song.songId] = token;
    state = state.copyWith(
      progress: <int, double>{...state.progress, song.songId: 0},
      failed: <int>{...state.failed}..remove(song.songId),
    );

    try {
      final file = await downloadLingtingSong(
        song,
        onProgress: (value) {
          if (!ref.mounted || _tokens[song.songId] != token) return;
          state = state.copyWith(
            progress: <int, double>{...state.progress, song.songId: value},
          );
        },
        cancelToken: token,
      );
      if (file == null) throw const FileSystemException('无法创建下载目录');

      final items = <int, LingtingDownload>{
        ...state.items,
        song.songId: LingtingDownload(
          path: file.path,
          url: song.audioUrl,
          name: song.name,
          singer: song.singerName,
          cover: song.cover,
        ),
      };
      // 记本机清单失败**不算下载失败**：文件已经在盘上了，顶多下次少一条「已下载」
      // 标记（这一句以前会把整条下载判成失败 —— 2026-09-25 真机上「下载一直失败」
      // 就是这么来的：文件早下好了，坏在 json.encode 那一步）。
      try {
        await LingtingStore.instance.saveDownloads(items);
      } on Object catch (error) {
        debugPrint('[灵听] 记下载清单失败（文件已下好，不影响播放）：$error');
      }
      if (!ref.mounted) return;
      state = state.copyWith(
        items: items,
        progress: <int, double>{...state.progress}..remove(song.songId),
      );
    } on Object catch (error) {
      debugPrint('[灵听] 下载失败 ${song.name}（${song.audioUrl}）：$error');
      if (!ref.mounted) return;
      state = state.copyWith(
        progress: <int, double>{...state.progress}..remove(song.songId),
        failed: <int>{...state.failed, song.songId},
      );
      rethrow;
    } finally {
      _tokens.remove(song.songId);
    }
  }

  /// 删掉本地那一份（「下载管理」页长按删除、腾空间用）
  Future<void> remove(int songId) async {
    final path = state.pathOf(songId);
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on FileSystemException catch (error) {
      debugPrint('[灵听] 删本地文件失败：$error');
    }
    final items = <int, LingtingDownload>{...state.items}..remove(songId);
    await LingtingStore.instance.saveDownloads(items);
    if (ref.mounted) state = state.copyWith(items: items);
  }
}

final lingtingDownloadsProvider =
    NotifierProvider<LingtingDownloadsNotifier, LingtingDownloads>(
      LingtingDownloadsNotifier.new,
    );

/// 真正把文件拉下来（抽成顶层函数，方便单测直接喂一个本机服务 + 临时目录）
///
/// [rootDir] 不给就用 `<应用文档目录>/lingting`（真机上就是这个）。
///
/// ## 为什么要「卡住就掐 + 断了接着下」，而不是一句 `dio.download` 了事
///
/// 灵听的音频在腾讯 CDN（`resource.lingtingmusic.com`）上。2026-09-25 拿真实
/// 地址在本机连着测：**同一个链接，直接要整份经常握手成功只给几 KB 就没声了**
/// （一次 0 字节、一次只到 32768 字节就卡死不动），而同一时刻带上
/// `Range: bytes=N-` 从断点接着要，一次就把剩下的 13MB 全拿回来了。
/// 偏偏 Dio 的 `receiveTimeout` **只管「等响应头」那一小段**，body 中途卡住它
/// 不管（见 `io_adapter.dart`）—— 一句 `download` 摆在那儿，表现就是
/// 「下载一直失败」（用户 2026-09-25 报的就是这个）。所以这里自己管三件事：
///
/// 1. **卡住就掐**：起手一根看门狗，[stallTimeout] 内没拿到新字节就 `cancel`
///    （Dio 的 cancel 会把连接掐掉并抛异常）；
/// 2. **断了接着下**：失败后看磁盘上已经有多少字节，带 `Range: bytes=N-` 续传
///    （`FileAccessMode.append`），不是从 0 重来；
/// 3. **长度对齐才算下好**：服务端报的完整长度和磁盘上的字节数对上了才把
///    `.part` 改名成 `<id>.mp3` —— 半截文件永远不会冒充「已下载」。
///    服务端不认 Range（回 200 整份）时，续写会把旧前缀拼进去，这种情况
///    直接把这一份丢掉重来。
///
/// 失败时**保留** `.part`（就是下次接着下的原料）；它不叫 `.mp3`，所以
/// 不会被当成「下好了」——「断网不留一个看着像下好了的残文件」这条仍然成立。
/// [attempts] 是「一共试几轮」，每轮失败后小退再试。
Future<File?> downloadLingtingSong(
  LingtingSong song, {
  void Function(double progress)? onProgress,
  CancelToken? cancelToken,
  Dio? dio,
  Directory? rootDir,
  int attempts = 4,
  Duration stallTimeout = const Duration(seconds: 15),
}) async {
  final dir =
      await (rootDir ??
              Directory(
                '${(await getApplicationDocumentsDirectory()).path}/lingting',
              ))
          .create(recursive: true);
  final file = File('${dir.path}/${song.songId}.mp3');
  // 先下到 `.part`，下完再改名 —— 中途断网不会留下一个「看着像下好了」的残文件
  final part = File('${file.path}.part');
  final client = dio ?? Dio();

  /// 服务端报的**整首**长度（第一次拿到之后就不再变）
  int? total;
  Object? lastError;

  for (var attempt = 1; attempt <= attempts; attempt++) {
    final already = await _lengthOf(part);

    // 每一轮**新造**一枚闸刀。Dio 只认一枚 CancelToken，而我们要拿它做两件事：
    // 「卡住就掐」和「调用方取消」。掐过的那一枚本身已经废了（Dio 见到已取消的
    // token 会直接拒掉请求）—— 续传那一轮再用它就是「一上来就被取消」，永远下不完。
    final stop = CancelToken();
    if (cancelToken != null) {
      unawaited(
        cancelToken.whenCancel.then((error) {
          if (!stop.isCancelled) stop.cancel(error.message);
        }),
      );
    }

    Timer? watchdog;
    void bump() {
      watchdog?.cancel();
      watchdog = Timer(stallTimeout, () {
        if (!stop.isCancelled) stop.cancel('下载卡住');
      });
    }

    bump(); // 起手就计时：等响应头那一段也算
    try {
      final response = await client.download(
        song.audioUrl,
        part.path,
        cancelToken: stop,
        // 断了要留着已经下到的部分（下一轮的续传原料），所以不删
        deleteOnError: false,
        fileAccessMode: already > 0
            ? FileAccessMode.append
            : FileAccessMode.write,
        options: Options(
          headers: already > 0
              ? <String, dynamic>{'Range': 'bytes=$already-'}
              : null,
        ),
        onReceiveProgress: (received, length) {
          bump();
          // 续传时服务端给的 `content-length` 是「剩下的那截」，得拿整首的长度来算比例
          final full = total ?? (length > 0 ? already + length : null);
          if (full != null && full > 0) {
            onProgress?.call(
              ((already + received) / full).clamp(0, 1).toDouble(),
            );
          }
        },
      );
      final status = response.statusCode ?? 0;
      final reported = _declaredLength(response.headers, ranged: already > 0);
      if (reported != null) total = reported;

      // 要了 Range 却回了整份（200）→ 我们刚把整份**接在**旧前缀后面了，这一份是脏的
      if (already > 0 && status != 206) {
        debugPrint('[灵听] 服务端不认断点续传（HTTP $status），这一份丢掉重下');
        if (await part.exists()) await part.delete();
        continue;
      }

      final size = await part.length();
      if (total == null || size >= total) {
        if (await file.exists()) await file.delete();
        // `await` 是必须的（2026-10-15，Flutter 3.47 的
        // `unawaited_return_in_try_block` 抓出来的）：不 await 的话，
        // `finally` 会在改名**还没做完**时就跑掉，而且改名失败会直接越过
        // 下面的 `on Object catch` —— 一次失败的改名不进 `lastError`、
        // 也不走重试，用户看到的是「下载完了但文件不在」。
        return await part.rename(file.path);
      }
      debugPrint('[灵听] 只下到 $size/$total 字节，接着下（第 $attempt 轮）');
    } on Object catch (error) {
      lastError = error;
      // 用户主动取消（退出页面/清队列）→ 不再重试，直接往上报
      if (cancelToken != null && cancelToken.isCancelled) rethrow;
      debugPrint('[灵听] 下载中断（第 $attempt 轮）：$error');
    } finally {
      watchdog?.cancel();
    }

    if (attempt < attempts) {
      await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
    }
  }

  if (lastError != null) throw lastError;
  throw const FileSystemException('下载未完成（连接反复中断）');
}

/// 磁盘上已有多少字节（文件不在就是 0）
Future<int> _lengthOf(File file) async =>
    (await file.exists()) ? file.length() : 0;

/// 服务端报的**整首**长度（不知道就给 null，调用方就不拿它验完整性）。
///
/// * [ranged] = 这一轮是带着 `Range` 去续传的 → 只能看
///   `Content-Range: bytes 32768-13056044/13056045`，最后一个 `/` 后面就是整首长度
///   （`*` = 未知）。这时候的 `Content-Length` 只是「这一截」，不能当整首用；
/// * 否则看 `Content-Length`（整份下载时它就是整首长度）。
int? _declaredLength(Headers headers, {required bool ranged}) {
  if (ranged) {
    final range = headers.value('content-range');
    if (range == null || !range.contains('/')) return null;
    final parsed = int.tryParse(range.split('/').last.trim());
    return parsed != null && parsed > 0 ? parsed : null;
  }
  final length = int.tryParse(headers.value('content-length') ?? '');
  return length != null && length > 0 ? length : null;
}
