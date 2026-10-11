import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/audio/voice_player.dart';
import '../../core/platform/system_media_session.dart';
import '../../data/model/lingting/lyric.dart';
import '../../data/model/lingting/song.dart';
import '../../data/repo/lingting_repository.dart';
import 'lingting_audio_handler.dart';
import 'lingting_downloads.dart';

/// 播放模式：列表循环 / 单曲循环 / 随机
enum LingtingPlayMode { order, single, shuffle }

/// 播放器状态。
///
/// 队列与下标都是**不可变**的（每次换歌造一份新的），这样界面 `watch` 一次
/// 就能拿到「当前这首 + 播放列表 + 播放到哪了」，不用自己拼几处状态。
@immutable
class LingtingPlayerState {
  const LingtingPlayerState({
    this.queue = const <LingtingSong>[],
    this.index = -1,
    this.playing = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.mode = LingtingPlayMode.order,
    this.source = '',
  });

  final List<LingtingSong> queue;
  final int index;
  final bool playing;
  final Duration position;
  final Duration duration;
  final LingtingPlayMode mode;

  /// 这一批是从哪儿播的（「每日三十首」「歌单：xxx」…），播放页顶栏显示
  final String source;

  LingtingSong? get current =>
      index >= 0 && index < queue.length ? queue[index] : null;

  bool get hasSong => current != null;

  /// 迷你条 / 播放页的进度条用（0~1）
  double get progress {
    final total = duration.inMilliseconds;
    if (total <= 0) return 0;
    return (position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  LingtingPlayerState copyWith({
    List<LingtingSong>? queue,
    int? index,
    bool? playing,
    Duration? position,
    Duration? duration,
    LingtingPlayMode? mode,
    String? source,
  }) => LingtingPlayerState(
    queue: queue ?? this.queue,
    index: index ?? this.index,
    playing: playing ?? this.playing,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    mode: mode ?? this.mode,
    source: source ?? this.source,
  );

  @override
  bool operator ==(Object other) =>
      other is LingtingPlayerState &&
      listEquals(other.queue, queue) &&
      other.index == index &&
      other.playing == playing &&
      other.position == position &&
      other.duration == duration &&
      other.mode == mode &&
      other.source == source;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(queue),
    index,
    playing,
    position,
    duration,
    mode,
    source,
  );

  @override
  String toString() =>
      'LingtingPlayerState(${current?.name}, index: $index, playing: $playing)';
}

/// 灵听播放器。
///
/// 与语音消息那套（[VoicePlayerNotifier]）**刻意分开**：语音是「点一条播一条」，
/// 音乐是「队列 + 上下首 + 进度条 + 循环模式」，两套语义混在一起会互相打架。
/// 两者只在一个点上握手：**开始放音乐时把语音停掉**（同一副喇叭）。
class LingtingPlayerNotifier extends Notifier<LingtingPlayerState> {
  AudioPlayer? _player;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<PlayerState>? _playerStateSub;

  /// 这一首已经听了多久（暂停 / 切歌 / 结束时上报给灵听）
  Stopwatch? _clock;

  /// 通知栏/锁屏那行歌词的来源（当前这首的歌词；没有时间轴就推不了）
  LingtingLyric _lyric = LingtingLyric.empty;

  /// 已经推给系统的那一句（同一句不重复推）
  String _pushedLyric = '';

  /// 已经上报过「播放记录」的那首歌（同一首反复点不重复上报）
  int _reportedSongId = 0;

  @override
  LingtingPlayerState build() {
    ref.onDispose(() => unawaited(_release()));
    _bindMediaSession();
    return const LingtingPlayerState();
  }

  /// 把通知栏 / 锁屏 / 耳机键接回这一套逻辑。
  ///
  /// 只做一次接线：系统按了「下一首」，调的还是这个类里的 [next]，
  /// 和播放页那颗按钮走同一条路 —— 不会出现「通知栏在下一首、界面还在上一首」
  /// 这种两套状态各算各的局面。
  ///
  /// 媒体会话不存在时（单测环境、或 `AudioService.init` 起不来）什么都不做：
  /// 音乐照放，只是没有通知栏那一份。
  void _bindMediaSession() {
    final session = activeLingtingAudioHandler;
    // 一条一条赋值（cascade 里连续赋值会被解析成「在前一个赋值结果上继续取属性」）
    if (session != null) {
      session.onPlay = _resume;
      session.onPause = _pause;
      session.onNext = () => next();
      session.onPrevious = previous;
      session.onSeek = seek;
    }
    // 桌面（Windows）那份：`audio_service` 在 Windows 上没有实现（那个 handler
    // 在某些引擎里甚至是空的 —— 比如灵听窗口那颗子引擎），所以系统媒体键与
    // 「正在播放」那张卡片走自己这条通道。两边的回调进的是同一套逻辑。
    SystemMediaSession.bind(
      onPlay: () => unawaited(_resume()),
      onPause: () => unawaited(_pause()),
      onNext: () => unawaited(next()),
      onPrevious: () => unawaited(previous()),
    );
  }

  // ------------------------------------------------------------ 播放入口

  /// 从一批歌里播（列表页的「播放全部」、点某一首）
  Future<void> playQueue(
    List<LingtingSong> songs, {
    int startIndex = 0,
    String source = '',
  }) async {
    // 「能播」= 有直链，**或者本机已经下好了**。
    // 后半句必须有：最早那版下载记录里只有路径、没有直链，只按 `playable`
    // 过滤的话那些歌会被默默踢出队列 —— 表现就是「下载管理里点一下没反应」
    // （本地文件明明在，2026-09-25 用户报的）。
    final downloads = ref.read(lingtingDownloadsProvider);
    final playable = songs
        .where(
          (song) =>
              song.playable || (downloads.pathOf(song.songId) ?? '').isNotEmpty,
        )
        .toList(growable: false);
    if (playable.isEmpty) return;
    await shutVoiceUp();
    final safeIndex = startIndex.clamp(0, playable.length - 1);
    state = state.copyWith(queue: playable, index: safeIndex, source: source);
    await _startCurrent();
  }

  /// 播一首：给了 [queue] 就把它当上下文（这样「下一首」有地方可去）
  Future<void> playSong(
    LingtingSong song, {
    List<LingtingSong>? queue,
    String source = '',
  }) {
    final list = queue ?? <LingtingSong>[song];
    final index = list.indexWhere((item) => item.songId == song.songId);
    return playQueue(list, startIndex: index < 0 ? 0 : index, source: source);
  }

  /// 播放 / 暂停（按钮、迷你条、耳机键都走它）
  Future<void> toggle() async {
    if (!state.hasSong) return;
    if (state.playing) {
      await _pause();
    } else {
      await _resume();
    }
  }

  /// 下一首。[auto] = 自然播完触发的（单曲循环、随机都只在这种时候生效，
  /// 手动点「下一首」应该老老实实往后走）
  Future<void> next({bool auto = false}) async {
    if (state.queue.isEmpty) return;
    _reportElapsed();
    if (auto && state.mode == LingtingPlayMode.single) {
      await _restartCurrent();
      return;
    }
    final next = _nextIndex(auto: auto);
    // 算出的一首还是自己（队列只有一首、或随机又抽到自己）→ 从头重播，
    // 不重新 `setUrl`：那会多一次网络请求，还会把播放统计刷一遍
    if (next == state.index) return _restartCurrent();
    state = state.copyWith(index: next, position: Duration.zero);
    await _startCurrent();
  }

  /// 上一首。与微信/网易云一致：播过 3 秒以上时先回到开头。
  Future<void> previous() async {
    if (state.queue.isEmpty) return;
    if (state.position.inSeconds >= 3) {
      await seek(Duration.zero);
      return;
    }
    _reportElapsed();
    final index = state.index <= 0 ? state.queue.length - 1 : state.index - 1;
    if (index == state.index) return _restartCurrent();
    state = state.copyWith(index: index, position: Duration.zero);
    await _startCurrent();
  }

  /// 把当前这首从头重播（单曲循环、队列只有一首、随机抽到自己都走它）
  Future<void> _restartCurrent() async {
    await seekEngine(Duration.zero);
    await playEngine();
    _startClock();
    state = state.copyWith(playing: true, position: Duration.zero);
    _syncSession();
  }

  Future<void> seek(Duration position) async {
    if (!state.hasSong) return;
    await seekEngine(position);
    state = state.copyWith(position: position);
    // 通知栏/锁屏的进度是系统自己插值的：拖过进度得告诉它新起点
    _syncSession();
  }

  /// 顺序 → 单曲 → 随机 → 顺序
  void cycleMode() {
    const order = <LingtingPlayMode>[
      LingtingPlayMode.order,
      LingtingPlayMode.single,
      LingtingPlayMode.shuffle,
    ];
    final at = order.indexOf(state.mode);
    state = state.copyWith(mode: order[(at + 1) % order.length]);
  }

  /// 停止并清空队列（退出灵听、进入通话时用）
  Future<void> stop() async {
    _reportElapsed();
    await stopEngine();
    _lyric = LingtingLyric.empty;
    _pushedLyric = '';
    state = state.copyWith(
      playing: false,
      position: Duration.zero,
      queue: const <LingtingSong>[],
      index: -1,
      source: '',
    );
    // 队列空了 → 通知栏那一份也收掉（`publishIdle` 由 _syncSession 内部判断）
    _syncSession();
  }

  /// 只暂停（进通话时用：保留队列，通话结束能接着听）
  Future<void> pause() async {
    if (state.playing) await _pause();
  }

  /// 把语音消息的高亮停掉 —— 开始放音乐之前叫一声（同一副喇叭）
  @protected
  Future<void> shutVoiceUp() async {
    try {
      await ref.read(voicePlayingProvider.notifier).stop();
    } on Object catch (error) {
      debugPrint('[灵听] 停语音失败：$error');
    }
  }

  // ------------------------------------------------------------ 内部

  int _nextIndex({required bool auto}) {
    final length = state.queue.length;
    if (length <= 1) return state.index;
    if (state.mode == LingtingPlayMode.shuffle) {
      // 随机到「和当前不同的那一首」，两首的队列也不会原地循环
      final random = Random();
      var candidate = random.nextInt(length);
      if (candidate == state.index) candidate = (candidate + 1) % length;
      return candidate;
    }
    final next = state.index + 1;
    return next >= length ? 0 : next;
  }

  Future<void> _startCurrent() async {
    final song = state.current;
    if (song == null) return;
    if (!state.playing) state = state.copyWith(playing: true);
    // 换歌 → 上一首的歌词不能留在通知栏上（`mediaItemOf` 那份不带歌词，
    // 推上去之后第二行自动回到歌手），新的歌词拿到后面再补
    _lyric = LingtingLyric.empty;
    _pushedLyric = '';
    // 「现在这首」要**先**告诉系统（通知栏/锁屏）：元数据早于播放状态到，
    // 通知栏一建出来就是对的；反过来的话它会先按「没有歌名」建一次，
    // 观感就是「通知栏显示『正在播放音频』，过一会儿才自己变对」。
    _syncSession(queue: true);
    try {
      final duration = await startEngine(song);
      if (!ref.mounted) return;
      state = state.copyWith(
        duration: duration ?? Duration.zero,
        position: Duration.zero,
        playing: true,
      );
      _syncSession(queue: true);
      _startClock();
      unawaited(_loadNotificationLyric(song));
      if (_reportedSongId != song.songId) {
        _reportedSongId = song.songId;
        unawaited(ref.read(lingtingRepositoryProvider).reportPlay(song));
      }
    } on Object catch (error) {
      // 播不出来（没网 / 地址失效 / 没有音频设备）不能把界面搞崩
      debugPrint('[灵听] 播放失败：$error');
      if (ref.mounted) {
        state = state.copyWith(playing: false);
        // 通知栏也别停在一个「正在播」的假象上
        _syncSession();
      }
    }
  }

  Future<void> _pause() async {
    await pauseEngine();
    _reportElapsed();
    if (ref.mounted) {
      state = state.copyWith(playing: false);
      _syncSession();
    }
  }

  Future<void> _resume() async {
    // 播完之后再点播放键：从头来
    final atEnd =
        state.duration > Duration.zero && state.position >= state.duration;
    if (atEnd) await seekEngine(Duration.zero);
    await playEngine();
    _startClock();
    if (ref.mounted) {
      state = state.copyWith(
        playing: true,
        position: atEnd ? Duration.zero : state.position,
      );
      _syncSession();
    }
  }

  void _startClock() {
    _clock?.stop();
    _clock = Stopwatch()..start();
  }

  /// 把这一段听的秒数报上去（暂停 / 切歌 / 播完 / 退出时各报一次）
  void _reportElapsed() {
    final clock = _clock;
    _clock = null;
    if (clock == null) return;
    clock.stop();
    final seconds = clock.elapsed.inSeconds;
    final song = state.current;
    if (song != null && seconds > 0) {
      unawaited(
        ref.read(lingtingRepositoryProvider).reportPlayTime(song, seconds),
      );
    }
  }

  /// 通知栏 / 锁屏那一份状态与队列。
  ///
  /// **只在关键节点推**（切歌、播放暂停、拖动进度、时长变化、队列变化），
  /// 不是每帧推：进度由系统按 `updatePosition + speed` 自己插值，
  /// 每帧推会把通知栏刷成电灯泡（也白耗电）。
  void _syncSession({bool queue = false}) {
    final song = state.current;
    // 手机那份（通知栏 / 锁屏）：桌面子引擎里 `session` 可能压根不存在
    final session = activeLingtingAudioHandler;
    if (session != null) {
      if (song == null) {
        session.publishIdle();
      } else {
        if (queue) session.publishQueue(state.queue, index: state.index);
        session.publishState(
          playing: state.playing,
          position: state.position,
          duration: state.duration,
          index: state.index,
        );
      }
    }
    // 桌面那份（系统媒体控制）：与上面同样只在关键节点推（见方法注释）
    if (song == null) {
      unawaited(SystemMediaSession.clear());
    } else {
      unawaited(
        SystemMediaSession.update(
          title: song.name,
          artist: song.singerName,
          album: song.albumName,
          cover: song.cover,
          playing: state.playing,
          position: state.position.inMilliseconds / 1000,
          duration: state.duration.inMilliseconds / 1000,
        ),
      );
    }
  }

  void _onPosition(Duration value) {
    if (!ref.mounted) return;
    state = state.copyWith(position: value);
    // 通知栏那行歌词跟着唱到哪走（句没变就什么都不做）
    _pushLyricLine();
  }

  /// 单测用：真机上这一帧来自引擎的 `positionStream`（测试里没有引擎，
  /// 由用例自己喂进来）——「通知栏第二行跟着唱到哪走」就是靠它钉的。
  @visibleForTesting
  void feedPosition(Duration value) => _onPosition(value);

  /// 把歌词拿来给通知栏用。
  ///
  /// 先问仓库要「手上现成的」那份（可能是纯文本，那就没法同步、推不了），
  /// 再去要 `.lrc`（有时间轴才能算「现在唱到哪一句」）。
  /// 仓库里按歌曲 id 缓存，所以播放页同时也在放歌词时**不会多下一次**。
  /// 取不到（断网、服务端没做歌词）就当作没歌词 —— 播放不受影响。
  Future<void> _loadNotificationLyric(LingtingSong song) async {
    final repo = ref.read(lingtingRepositoryProvider);
    try {
      final quick = await repo.quickLyric(song);
      if (!ref.mounted || state.current?.songId != song.songId) return;
      if (quick.hasTimeline) {
        _lyric = quick;
        _pushLyricLine();
        return;
      }
      final full = await repo.timelineLyric(song);
      if (!ref.mounted || state.current?.songId != song.songId) return;
      if (!full.hasTimeline) return;
      _lyric = full;
      _pushLyricLine();
    } on Object catch (error) {
      debugPrint('[灵听] 通知栏歌词取不到（不影响播放）：$error');
    }
  }

  /// 把「当前这一句」推给通知栏/锁屏（句没变就不推）
  void _pushLyricLine() {
    final session = activeLingtingAudioHandler;
    if (session == null) return;
    final line = _lyric.hasTimeline ? _lyric.lineAt(state.position) : '';
    if (line == _pushedLyric) return;
    _pushedLyric = line;
    session.publishLyric(line);
  }

  void _onDuration(Duration? value) {
    if (!ref.mounted || value == null) return;
    state = state.copyWith(duration: value);
    // 总时长出来了，锁屏那个进度条才有分母
    _syncSession();
  }

  void _onPlayerState(PlayerState value) {
    if (!ref.mounted) return;
    if (state.playing != value.playing) {
      state = state.copyWith(playing: value.playing);
      _syncSession();
    }
    if (value.processingState == ProcessingState.completed) {
      unawaited(next(auto: true));
    }
  }

  // ------------------------------------------------------------ 引擎（测试里覆写）

  /// 真正开始播：交给 `just_audio`，返回时长
  @protected
  Future<Duration?> startEngine(LingtingSong song) async {
    final player = _player ??= AudioPlayer();
    _positionSub ??= player.positionStream.listen(_onPosition);
    _durationSub ??= player.durationStream.listen(_onDuration);
    _playerStateSub ??= player.playerStateStream.listen(_onPlayerState);
    // 下过的就放本地那一份（弱网/离线也能听），没下过才走网络直链
    final localPath = ref.mounted
        ? ref.read(lingtingDownloadsProvider).pathOf(song.songId)
        : null;
    final duration = localPath != null && localPath.isNotEmpty
        ? await player.setFilePath(localPath)
        : await player.setUrl(song.audioUrl);
    playWithoutWaiting(player);
    return duration;
  }

  @protected
  Future<void> playEngine() async {
    final player = _player;
    if (player != null) playWithoutWaiting(player);
  }

  @protected
  Future<void> pauseEngine() async => _player?.pause();

  @protected
  Future<void> seekEngine(Duration position) async => _player?.seek(position);

  @protected
  Future<void> stopEngine() async => _player?.stop();

  /// 让播放器开始播，但**不 await** —— 这一条是踩过大坑的。
  ///
  /// `just_audio` 的 `play()` 返回的 Future **要到「播完 / 暂停 / 停止」才完成**
  /// （它自己的文档就这么写）。以前这里 `await player.play()`，于是：
  ///
  /// * `_startCurrent` 卡在这一行 → 后面的「把歌名/歌手/封面推给通知栏」永远等不到，
  ///   通知栏一直显示系统那行「正在播放音频」，直到用户点了暂停（那一按才让
  ///   上面那个 Future 完成）—— 用户看到的就是「点一下播放暂停才更新，换歌也一样」；
  /// * 点音乐卡片时 `await playSong(...)` 同样卡住 → 歌是响了，但进播放页那句
  ///   `context.push` 排在它后面，所以「有歌没页面，再点一次才进去」；
  /// * 播放时长的计时表（`_startClock`）也一起被推迟，整段听的秒数都记不上。
  ///
  /// 播放失败照样能知道：`just_audio` 的 `playerStateStream` / `errorStream` 会报，
  /// 这里只是把「等一下」换成「发出去就不管」。
  @protected
  void playWithoutWaiting(AudioPlayer player) {
    unawaited(
      player.play().catchError((Object error) {
        debugPrint('[灵听] 开始播放失败：$error');
      }),
    );
  }

  Future<void> _release() async {
    _clock?.stop();
    _clock = null;
    await _positionSub?.cancel();
    await _durationSub?.cancel();
    await _playerStateSub?.cancel();
    _positionSub = null;
    _durationSub = null;
    _playerStateSub = null;
    final player = _player;
    _player = null;
    await player?.dispose();
  }
}

final lingtingPlayerProvider =
    NotifierProvider<LingtingPlayerNotifier, LingtingPlayerState>(
      LingtingPlayerNotifier.new,
    );
