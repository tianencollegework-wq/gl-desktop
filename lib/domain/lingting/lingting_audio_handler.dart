import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import '../../data/model/lingting/song.dart';

/// 灵听的**媒体会话**：通知栏、锁屏、耳机线控、手表都挂在它身上。
///
/// 为什么不用 `just_audio_background`（做同一件事、代码更少）：它源码里
/// **只允许一个播放器实例**，第二个 `AudioPlayer` 一创建就抛
/// `just_audio_background supports only a single player instance` —— 而我们还有
/// 语音消息、来电铃声、拨号音、消息提示音四个播放器，装上去一点提示音就炸。
/// `audio_service` 不代理播放器（播放器还是我们自己的），所以两边能共存。
///
/// 这个 handler **不负责播放**，只做两件事：
/// 1. 把「正在播哪首、播到哪了、系统按了什么」告诉系统（[publishQueue] /
///    [publishState] / [publishIdle]）；
/// 2. 把系统那几颗键（播放-暂停、上一首、下一首、拖进度）回调给播放器
///    （[onPlay] / [onPause] / [onNext] / [onPrevious] / [onSeek]）。
///
/// 这样「通知栏按下一首」和「播放页按下一首」走的是同一套逻辑（都进
/// `LingtingPlayerNotifier`），不会出现两条路各自算一遍的局面。
class LingtingAudioHandler extends BaseAudioHandler with SeekHandler {
  /// 播放 / 暂停（通知栏那颗键、耳机上的播放键）
  Future<void> Function()? onPlay;
  Future<void> Function()? onPause;
  Future<void> Function()? onNext;
  Future<void> Function()? onPrevious;
  Future<void> Function(Duration position)? onSeek;

  LingtingAudioHandler();

  @override
  Future<void> play() async => onPlay?.call();

  @override
  Future<void> pause() async => onPause?.call();

  @override
  Future<void> skipToNext() async => onNext?.call();

  @override
  Future<void> skipToPrevious() async => onPrevious?.call();

  @override
  Future<void> seek(Duration position) async => onSeek?.call(position);

  /// 系统要求「停」：当作暂停处理（队列留着，回到 App 还能接着听）
  @override
  Future<void> stop() async {
    await onPause?.call();
    await super.stop();
  }

  /// 队列变了（「播放全部」、点另一首、切歌）→ 交给系统
  ///
  /// 通知栏的「上一首 / 下一首」靠这份队列才显示得出来（锁屏、耳机键同理）。
  void publishQueue(List<LingtingSong> queue, {required int index}) {
    final items = queue.map(mediaItemOf).toList(growable: false);
    if (items.isEmpty) return;
    this.queue.add(items);
    if (index >= 0 && index < items.length) mediaItem.add(items[index]);
  }

  /// 播放状态变了 → 交给系统（**别每帧调**：进度由系统自己插值，
  /// 这里只在 切歌 / 播放暂停 / 拖动进度 / 时长变化 时推一次）
  void publishState({
    required bool playing,
    required Duration position,
    required Duration duration,
    required int index,
  }) {
    // 总时长只有播起来才知道（列表接口不给）——它是锁屏/通知栏那根进度条的分母，
    // 补进当前曲目里（只在真变了的时候写，否则会把 mediaItem 流刷爆）
    final item = mediaItem.value;
    if (item != null && duration > Duration.zero && item.duration != duration) {
      mediaItem.add(item.copyWith(duration: duration));
    }
    playbackState.add(
      playbackState.value.copyWith(
        controls: <MediaControl>[
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
        ],
        // 折叠态那三颗键（微信/网易云也是这三颗）
        androidCompactActionIndices: const <int>[0, 1, 2],
        systemActions: const <MediaAction>{
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        processingState: AudioProcessingState.ready,
        playing: playing,
        updatePosition: position,
        // 直链播放拿不到真实缓冲进度，这里按「整首都已缓冲」画：进度条看着干净，
        // 不会出现一根永远追不上播放头的灰条
        bufferedPosition: duration > Duration.zero ? duration : position,
        speed: 1.0,
        queueIndex: index < 0 ? null : index,
      ),
    );
  }

  /// 通知栏/锁屏上那行**歌词**。
  ///
  /// 放的位置是 `displaySubtitle`：系统那里「第二行」的取值顺序是
  /// DISPLAY_SUBTITLE → ARTIST，所以给它歌词，通知栏第二行就从歌手变成当前这句；
  /// 传空串（或还没拿到有时间轴的歌词）就把 `displaySubtitle` 去掉，
  /// 第二行自动回到歌手。标题、封面、锁屏上那份元数据（ARTIST/ALBUM）都不动。
  ///
  /// **只在换句时调**：进度每 200ms 就来一帧，每帧推一次会把通知栏刷成电灯泡。
  void publishLyric(String line) {
    final item = mediaItem.value;
    if (item == null) return;
    final text = line.trim();
    if ((item.displaySubtitle ?? '') == text) return; // 同一句不重复推
    mediaItem.add(
      MediaItem(
        id: item.id,
        title: item.title,
        album: item.album,
        artist: item.artist,
        genre: item.genre,
        duration: item.duration,
        artUri: item.artUri,
        artHeaders: item.artHeaders,
        playable: item.playable,
        // 空串 → 交回给 ARTIST（歌手）当第二行
        displaySubtitle: text.isEmpty ? null : text,
        displayDescription: item.displayDescription,
        extras: item.extras,
      ),
    );
  }

  /// 没有在播了（退出灵听 / 停止）→ 把通知收掉
  void publishIdle() {
    mediaItem.add(null);
    playbackState.add(
      playbackState.value.copyWith(
        controls: <MediaControl>[],
        processingState: AudioProcessingState.idle,
        playing: false,
      ),
    );
  }
}

/// 当前那个媒体会话（`main()` 里 `AudioService.init` 建好之后放这儿）。
///
/// 全局一个：它是**常驻**的媒体会话，不属于任何页面或 provider 的生命周期。
/// 为了能在单测里跑（测试环境没有平台通道，`AudioService.init` 起不来），
/// 播放器那头对它的使用全是「有就用、没有就算」。
LingtingAudioHandler? activeLingtingAudioHandler;

/// 一首歌 → 系统能认的 [MediaItem]（通知栏上的封面 / 歌名 / 歌手就是它）
///
/// `id` 用歌曲 id：系统靠它区分「换歌了」，重复的话通知栏会不刷新。
MediaItem mediaItemOf(LingtingSong song) => MediaItem(
  id: '${song.songId}',
  title: song.name,
  artist: song.singerName,
  album: song.albumName,
  duration: null,
  artUri: song.cover.isEmpty ? null : Uri.tryParse(song.cover),
  extras: <String, dynamic>{'songId': song.songId},
);

/// 给 `main()` 用的初始化（测试里不调它）。
///
/// **永不抛异常**：媒体通知是锦上添花，起不来（清单写错、ROM 限制、系统
/// 拒绝前台服务）也只当作「没有通知栏那一份」，绝不能连累整个 App 起不来。
Future<LingtingAudioHandler?> initLingtingAudioService() async {
  try {
    final handler = await AudioService.init(
      builder: LingtingAudioHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'cc.gracelink.im.lingting',
        androidNotificationChannelName: '灵听播放',
        androidNotificationChannelDescription: '正在播放的歌曲与播放控制',
        // 正在播时通知不能被划掉（划过的人其实想要的是「暂停」）
        androidNotificationOngoing: true,
        // 暂停时把前台服务停掉（通知留着）：省电，也少一个常驻服务
        androidStopForegroundOnPause: true,
        androidNotificationClickStartsActivity: true,
      ),
    );
    activeLingtingAudioHandler = handler;
    debugPrint('[灵听] 媒体会话就绪');
    return handler;
  } on Object catch (error) {
    debugPrint('[灵听] 媒体会话起不来（不影响播放，只是没有通知栏那份）：$error');
    return null;
  }
}
