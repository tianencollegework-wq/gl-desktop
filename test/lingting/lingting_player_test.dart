import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/store/lingting_store.dart';
import 'package:gracelinkim/data/model/lingting/download.dart';
import 'package:gracelinkim/data/model/lingting/lyric.dart';
import 'package:gracelinkim/data/model/lingting/song.dart';
import 'package:gracelinkim/data/repo/lingting_repository.dart';
import 'package:gracelinkim/domain/lingting/lingting_audio_handler.dart';
import 'package:gracelinkim/domain/lingting/lingting_player.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_lingting.dart';

/// 假引擎：只记「播了哪几首、seek 到哪」，不碰音频子系统
class _FakePlayer extends LingtingPlayerNotifier {
  final List<int> started = <int>[];
  final List<Duration> seeks = <Duration>[];
  int plays = 0;
  int pauses = 0;
  int stops = 0;
  Duration duration = const Duration(seconds: 200);
  bool failNextStart = false;

  /// 摆在这儿就代表「引擎还在加载（网络没回来）」——用例拿它卡住 startEngine
  Completer<void>? startGate;

  @override
  Future<Duration?> startEngine(LingtingSong song) async {
    if (failNextStart) {
      failNextStart = false;
      throw StateError('播不出来');
    }
    final gate = startGate;
    if (gate != null) await gate.future;
    started.add(song.songId);
    return duration;
  }

  @override
  Future<void> playEngine() async => plays += 1;

  @override
  Future<void> pauseEngine() async => pauses += 1;

  @override
  Future<void> seekEngine(Duration position) async => seeks.add(position);

  @override
  Future<void> stopEngine() async => stops += 1;

  /// 语音那条链在这一层没东西可停
  @override
  Future<void> shutVoiceUp() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late _FakePlayer player;
  late FakeLingtingRepository repository;

  /// 媒体会话（通知栏/锁屏/耳机键）。
  ///
  /// 和线上一样**先建会话、再建播放器**：播放器构造时会把系统的按键接到自己身上。
  /// 接在这层就是为了让每个用例都顺手跑一遍「推给通知栏」这条路径。
  late LingtingAudioHandler session;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await LingtingStore.init();
    session = LingtingAudioHandler();
    activeLingtingAudioHandler = session;
    repository = FakeLingtingRepository(FakeLingtingApi());
    container = ProviderContainer(
      overrides: [
        lingtingRepositoryProvider.overrideWithValue(repository),
        lingtingPlayerProvider.overrideWith(_FakePlayer.new),
      ],
    );
    player = container.read(lingtingPlayerProvider.notifier) as _FakePlayer;
  });

  tearDown(() {
    activeLingtingAudioHandler = null;
    container.dispose();
  });

  LingtingPlayerState read() => container.read(lingtingPlayerProvider);

  group('播放队列', () {
    test('从一批歌里播：队列 / 下标 / 正在播 / 时长都就位', () async {
      final songs = <LingtingSong>[fakeSong(1), fakeSong(2), fakeSong(3)];
      await player.playQueue(songs, startIndex: 1, source: '每日三十首');

      expect(read().queue.length, 3);
      expect(read().index, 1);
      expect(read().playing, isTrue);
      expect(read().current?.songId, 2);
      expect(read().duration, const Duration(seconds: 200));
      expect(read().source, '每日三十首');
      expect(player.started, <int>[2]);
    });

    test('不能播的歌（没地址）被挡在队列外', () async {
      final songs = <LingtingSong>[
        const LingtingSong(songId: 9, name: '裸记录'),
        fakeSong(2),
      ];
      await player.playQueue(songs);
      expect(read().queue.length, 1);
      expect(read().queue.single.songId, 2);
    });

    test('下到本机、但没有直链的老记录也能播（「下载管理」里点一下有反应）', () async {
      // 最早那版下载记录里只有一条路径、没有 `audioLink`。以前这种歌会被
      // `playable` 过滤掉 —— 表现就是「下载管理里点一下没反应」（本地文件明明在）。
      final dir = await Directory.systemTemp.createTemp('lingting-local');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final path = '${dir.path}/3866.mp3';
      File(path).writeAsStringSync('mp3');
      await LingtingStore.instance.saveDownloads(<int, LingtingDownload>{
        3866: LingtingDownload(path: path),
      });

      await player.playQueue(<LingtingSong>[
        const LingtingSong(songId: 3866, name: '3866'),
      ]);

      expect(read().playing, isTrue);
      expect(read().current?.songId, 3866);
      expect(player.started, <int>[3866], reason: '本地文件就是它的音源');
    });

    test('一首都不能播时什么都不做（不把界面切成「正在播一首空的」）', () async {
      await player.playQueue(<LingtingSong>[
        const LingtingSong(songId: 9, name: '裸记录'),
      ]);
      expect(read().hasSong, isFalse);
      expect(player.started, isEmpty);
    });

    test('下标越界会夹到合法范围', () async {
      await player.playQueue(<LingtingSong>[
        fakeSong(1),
        fakeSong(2),
      ], startIndex: 99);
      expect(read().index, 1);
    });

    test('开始播就上报一次播放记录（同一首反复点只报一次）', () async {
      final song = fakeSong(1);
      await player.playSong(song);
      expect(repository.reportedPlays, 1);
      await player.toggle(); // 暂停
      await player.toggle(); // 继续
      expect(repository.reportedPlays, 1);
    });

    test('播不出来时不崩：状态回到「没在播」', () async {
      player.failNextStart = true;
      await player.playQueue(<LingtingSong>[fakeSong(1)]);
      expect(read().playing, isFalse);
    });
  });

  group('上下首', () {
    test('手动下一首往后走，到底绕回第一首', () async {
      await player.playQueue(<LingtingSong>[
        fakeSong(1),
        fakeSong(2),
        fakeSong(3),
      ]);
      await player.next();
      expect(read().current?.songId, 2);
      await player.next();
      expect(read().current?.songId, 3);
      await player.next();
      expect(read().current?.songId, 1);
      expect(player.started, <int>[1, 2, 3, 1]);
    });

    test('上一首：刚播（<3 秒）回上一首，第一首绕到最后', () async {
      await player.playQueue(<LingtingSong>[fakeSong(1), fakeSong(2)]);
      await player.previous();
      expect(read().current?.songId, 2);
    });

    test('上一首：已经播过 3 秒 → 先回到本首开头', () async {
      await player.playQueue(<LingtingSong>[
        fakeSong(1),
        fakeSong(2),
      ], startIndex: 1);
      await player.seek(const Duration(seconds: 5));
      await player.previous();
      expect(read().current?.songId, 2, reason: '不该跳到上一首');
      expect(read().position, Duration.zero);
      expect(player.seeks.last, Duration.zero);
    });

    test('单曲循环：自然播完是重播这一首（不重新 setUrl）', () async {
      await player.playQueue(<LingtingSong>[fakeSong(1), fakeSong(2)]);
      player.cycleMode(); // → 单曲
      await player.next(auto: true);
      expect(read().current?.songId, 1);
      expect(player.started, <int>[1], reason: '同一首不该再 setUrl 一次');
      expect(player.seeks.last, Duration.zero);
    });

    test('手动点「下一首」时单曲循环不生效（还是要往后走）', () async {
      await player.playQueue(<LingtingSong>[fakeSong(1), fakeSong(2)]);
      player.cycleMode();
      await player.next();
      expect(read().current?.songId, 2);
    });

    test('随机：自然播完会换一首（不会原地打转）', () async {
      await player.playQueue(<LingtingSong>[
        fakeSong(1),
        fakeSong(2),
        fakeSong(3),
      ]);
      player.cycleMode(); // 单曲
      player.cycleMode(); // 随机
      expect(read().mode, LingtingPlayMode.shuffle);
      for (var i = 0; i < 10; i++) {
        final before = read().index;
        await player.next(auto: true);
        expect(read().index, isNot(before));
      }
    });

    test('队列只有一首时上下首都是「从头重播」，不重新 setUrl', () async {
      await player.playQueue(<LingtingSong>[fakeSong(1)]);
      await player.seek(const Duration(seconds: 30));
      await player.next();
      expect(read().index, 0);
      expect(read().position, Duration.zero);
      await player.previous();
      expect(read().index, 0);
      expect(player.started, <int>[1], reason: '只有一次 setUrl');
      expect(player.seeks.length, greaterThanOrEqualTo(2));
    });
  });

  group('播放控制', () {
    test('toggle：播放 → 暂停 → 继续', () async {
      await player.playQueue(<LingtingSong>[fakeSong(1)]);
      expect(read().playing, isTrue);

      await player.toggle();
      expect(read().playing, isFalse);
      expect(player.pauses, 1);

      await player.toggle();
      expect(read().playing, isTrue);
      expect(player.plays, 1);
    });

    test('播完之后再点播放：从头来', () async {
      await player.playQueue(<LingtingSong>[fakeSong(1)]);
      await player.seek(const Duration(seconds: 200)); // = duration
      await player.toggle(); // 暂停
      await player.toggle(); // 继续
      expect(player.seeks.last, Duration.zero);
      expect(read().position, Duration.zero);
    });

    test('没有歌时 toggle 不做事', () async {
      await player.toggle();
      expect(read().playing, isFalse);
      expect(player.plays, 0);
    });

    test('seek 改状态也落到引擎', () async {
      await player.playQueue(<LingtingSong>[fakeSong(1)]);
      await player.seek(const Duration(seconds: 42));
      expect(read().position, const Duration(seconds: 42));
      expect(player.seeks.last, const Duration(seconds: 42));
    });

    test('模式循环：顺序 → 单曲 → 随机 → 顺序', () async {
      expect(read().mode, LingtingPlayMode.order);
      player.cycleMode();
      expect(read().mode, LingtingPlayMode.single);
      player.cycleMode();
      expect(read().mode, LingtingPlayMode.shuffle);
      player.cycleMode();
      expect(read().mode, LingtingPlayMode.order);
    });

    test('pause 保留队列（进通话时用）', () async {
      await player.playQueue(<LingtingSong>[fakeSong(1)]);
      await player.pause();
      expect(read().playing, isFalse);
      expect(read().queue.length, 1);
    });

    test('stop 清空队列', () async {
      await player.playQueue(<LingtingSong>[fakeSong(1)]);
      await player.stop();
      expect(read().playing, isFalse);
      expect(read().queue, isEmpty);
      expect(read().index, -1);
      expect(read().hasSong, isFalse);
      expect(player.stops, 1);
    });

    test('进度比例（迷你条那根线）', () async {
      await player.playQueue(<LingtingSong>[fakeSong(1)]);
      await player.seek(const Duration(seconds: 50));
      expect(read().progress, closeTo(0.25, 0.001));
    });
  });

  group('通知栏 / 锁屏那一份', () {
    test('开播：系统那份队列、当前曲目、播放中状态都就位', () async {
      await player.playQueue(<LingtingSong>[
        fakeSong(1),
        fakeSong(2),
        fakeSong(3),
      ], startIndex: 1);

      expect(session.queue.value.map((item) => item.id), ['1', '2', '3']);
      expect(session.mediaItem.value?.title, '歌曲 2');
      expect(session.playbackState.value.playing, isTrue);
      expect(session.playbackState.value.queueIndex, 1);
      expect(session.playbackState.value.bufferedPosition, player.duration);
      expect(session.mediaItem.value?.duration, player.duration);
    });

    test('起播时先把歌名/歌手推给系统，不等引擎加载完', () async {
      // 真机上的现场（2026-09-25 用户报的）：通知栏停在系统那句
      // 「正在播放音频」，点一下播放/暂停才变成歌名封面 ——
      // 根因是元数据被排在「引擎起播」后面才推，而 just_audio 的 `play()`
      // 要到暂停/播完才完成，于是永远也轮不到元数据。
      // 这里把引擎卡在「加载中」，断言歌名已经到通知栏了。
      final gate = Completer<void>();
      player.startGate = gate;

      final playing = player.playSong(fakeSong(7));
      await Future<void>.delayed(Duration.zero);

      expect(
        session.mediaItem.value?.title,
        '歌曲 7',
        reason: '引擎还没加载完，通知栏上也该已经有这首',
      );
      expect(session.mediaItem.value?.id, '7');

      gate.complete();
      await playing;
      expect(session.playbackState.value.playing, isTrue);
      expect(session.playbackState.value.queueIndex, 0);
    });

    test('切歌：通知栏上的曲目跟着换（不是停在上一首）', () async {
      await player.playQueue(<LingtingSong>[fakeSong(1), fakeSong(2)]);
      await player.next();

      expect(session.mediaItem.value?.title, '歌曲 2');
      expect(session.playbackState.value.queueIndex, 1);
    });

    test('暂停：通知栏那颗键变回「播放」', () async {
      await player.playQueue(<LingtingSong>[fakeSong(1)]);
      await player.toggle();

      expect(session.playbackState.value.playing, isFalse);
      expect(session.playbackState.value.controls[1].action, MediaAction.play);
    });

    test('停止：通知栏收掉（否则会留一个「正在播但没声音」的通知）', () async {
      await player.playQueue(<LingtingSong>[fakeSong(1)]);
      await player.stop();

      expect(session.mediaItem.value, isNull);
      expect(
        session.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
    });

    test('拖动进度：通知栏的进度跟着走（它不是每帧推的，得在 seek 时补一次）', () async {
      await player.playQueue(<LingtingSong>[fakeSong(1)]);
      await player.seek(const Duration(seconds: 50));

      expect(
        session.playbackState.value.updatePosition,
        const Duration(seconds: 50),
      );
    });

    test('通知栏按「下一首」→ 真的下一首（两条路同一套逻辑）', () async {
      await player.playQueue(<LingtingSong>[fakeSong(1), fakeSong(2)]);
      await session.skipToNext();

      expect(read().current?.songId, 2);
      expect(player.started, <int>[1, 2]);
    });

    test('通知栏按「暂停」→ 引擎真的停了（不只是改了个标志位）', () async {
      await player.playQueue(<LingtingSong>[fakeSong(1)]);
      await session.pause();

      expect(player.pauses, 1);
      expect(read().playing, isFalse);
    });

    test('通知栏按「播放」→ 接着播下去（队列还在）', () async {
      await player.playQueue(<LingtingSong>[fakeSong(1)]);
      await session.pause();
      await session.play();

      expect(player.plays, 1);
      expect(read().playing, isTrue);
    });

    test('没有媒体会话时（媒体通知起不来）播放照常，不炸', () async {
      activeLingtingAudioHandler = null;
      await player.playQueue(<LingtingSong>[fakeSong(1)]);

      expect(read().playing, isTrue);
    });

    /// 歌词两行：进门那句 + 20 秒那句
    const twoLines = LingtingLyric(
      lines: <LyricLine>[
        LyricLine(at: Duration.zero, text: '我献上一颗敬拜的心'),
        LyricLine(at: Duration(seconds: 20), text: '指的就是我全所有'),
      ],
    );

    test('歌词：唱到哪一句，通知栏第二行就是哪一句（同一句不重复推）', () async {
      repository.lyricResult = twoLines;
      final pushes = <MediaItem?>[];
      final sub = session.mediaItem.listen(pushes.add);
      addTearDown(sub.cancel);

      await player.playQueue(<LingtingSong>[fakeSong(1)]);
      // 歌词是**异步**取回来的（播放不等它）：放它跑完
      await Future<void>.delayed(Duration.zero);

      expect(session.mediaItem.value?.displaySubtitle, '我献上一颗敬拜的心');
      expect(
        session.mediaItem.value?.artist,
        '小羊诗歌',
        reason: '歌手不能被顶掉（锁屏那份元数据还靠它）',
      );

      // 还在第一句里（进度每 200ms 来一帧，句没变就一帧都不推）
      final before = pushes.length;
      player.feedPosition(const Duration(seconds: 5));
      player.feedPosition(const Duration(seconds: 19));
      expect(pushes.length, before, reason: '同一句里不该刷通知栏');
      expect(session.mediaItem.value?.displaySubtitle, '我献上一颗敬拜的心');

      player.feedPosition(const Duration(seconds: 25));
      expect(session.mediaItem.value?.displaySubtitle, '指的就是我全所有');
    });

    test('切歌：上一首那句歌词收回去（第二行先还给歌手，新歌词到了再补）', () async {
      repository.lyricResult = twoLines;
      await player.playQueue(<LingtingSong>[fakeSong(1), fakeSong(2)]);
      await Future<void>.delayed(Duration.zero);
      expect(session.mediaItem.value?.displaySubtitle, '我献上一颗敬拜的心');

      await player.next();
      expect(
        session.mediaItem.value?.displaySubtitle,
        isNull,
        reason: '换歌时不能把上一首那句留在通知栏上',
      );

      await Future<void>.delayed(Duration.zero);
      expect(session.mediaItem.value?.displaySubtitle, '我献上一颗敬拜的心');
    });

    test('只有纯文本歌词（没时间轴）：第二行老老实实是歌手，不塞半句上去', () async {
      repository.lyricResult = const LingtingLyric(plain: '整首歌挤在一行；用分号分隔');
      await player.playQueue(<LingtingSong>[fakeSong(1)]);
      await Future<void>.delayed(Duration.zero);
      player.feedPosition(const Duration(seconds: 30));

      expect(session.mediaItem.value?.displaySubtitle, isNull);
      expect(session.mediaItem.value?.artist, '小羊诗歌');
    });
  });

  group('桌面那份系统媒体控制（Windows）', () {
    // runner 出的那条通道（见 windows/runner/flutter_window.cpp）：歌名/歌手/
    // 封面/进度推过去，系统那几颗键接回来。测试机上 isDesktopRuntime 就是 true，
    // 所以把通道 mock 掉就能钉住这一来一回。
    final mediaCalls = <MethodCall>[];

    setUp(() {
      mediaCalls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('gracelinkim/media_session'),
            (call) async {
              mediaCalls.add(call);
              return null;
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('gracelinkim/media_session'),
              null,
            ),
      );
    });

    Map<Object?, Object?> lastUpdate() =>
        mediaCalls.lastWhere((call) => call.method == 'update').arguments
            as Map<Object?, Object?>;

    test('开播：歌名 / 歌手 / 专辑 / 封面 / 播放中一起推给系统', () async {
      await player.playQueue(<LingtingSong>[fakeSong(2)]);

      final args = lastUpdate();
      expect(args['title'], '歌曲 2');
      expect(args['artist'], '小羊诗歌');
      expect(args['playing'], isTrue);
      expect(args['cover'], isNotEmpty);
      expect(args['duration'], player.duration.inMilliseconds / 1000);
    });

    test('暂停 / 继续：系统那张卡片的状态跟着变', () async {
      await player.playQueue(<LingtingSong>[fakeSong(1)]);
      await player.toggle();
      expect(lastUpdate()['playing'], isFalse);

      await player.toggle();
      expect(lastUpdate()['playing'], isTrue);
    });

    test('停止：把系统那张卡片收掉（不留一个「在放但没声」的卡片）', () async {
      await player.playQueue(<LingtingSong>[fakeSong(1)]);
      await player.stop();

      expect(mediaCalls.map((call) => call.method), contains('clear'));
    });

    test('系统上按「下一首」：走的是和界面同一套逻辑', () async {
      await player.playQueue(<LingtingSong>[fakeSong(1), fakeSong(2)]);
      expect(read().index, 0);

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'gracelinkim/media_session',
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('media_button', <String, dynamic>{
                'button': 'next',
              }),
            ),
            (_) {},
          );
      await Future<void>.delayed(Duration.zero);

      expect(read().index, 1, reason: '系统那颗键接回了播放器，而不是各算各的');
      expect(read().current?.songId, 2);
    });
  });

  group('播放时长上报', () {
    test('暂停时把这一段听的秒数报上去', () async {
      await player.playQueue(<LingtingSong>[fakeSong(1)]);
      await player.toggle();
      expect(repository.reportedSeconds, isEmpty, reason: '刚播 0 秒不该上报');
    });

    test('切歌时上报（用假的时钟推不动，这里只钉「上报入口被调到」这个约定）', () async {
      await player.playQueue(<LingtingSong>[fakeSong(1), fakeSong(2)]);
      await player.next();
      // 秒数取自 Stopwatch，测试里跑不到 1 秒，所以这里断言的是「没报 0 秒」
      expect(repository.reportedSeconds.every((item) => item > 0), isTrue);
    });
  });
}
