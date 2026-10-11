import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/lingting/song.dart';
import 'package:gracelinkim/domain/lingting/lingting_audio_handler.dart';

import '../support/fake_lingting.dart';

/// 媒体会话（通知栏 / 锁屏 / 耳机键）这一层。
///
/// 这里能直接 new 出 handler：它只是几个广播流，不碰平台通道
/// （真正的 `AudioService.init` 在 `main()` 里，测试环境起不来也不需要）。
void main() {
  group('歌 → 系统那份曲目', () {
    test('歌名 / 歌手 / 专辑 / 封面都交给系统', () {
      final item = mediaItemOf(fakeSong(7, name: '敬拜的心', singer: '约书亚乐团'));

      expect(item.id, '7');
      expect(item.title, '敬拜的心');
      expect(item.artist, '约书亚乐团');
      expect(item.album, '我愿意');
      expect(item.artUri.toString(), 'https://example.test/cover7.jpg');
      expect(item.extras?['songId'], 7);
    });

    test('没有封面时不塞空 Uri（否则通知栏会出现一个空白图位）', () {
      const bare = LingtingSong(songId: 9, name: '裸记录');
      expect(mediaItemOf(bare).artUri, isNull);
    });

    test('id 用歌曲 id：重复的话系统认不出「换歌了」，通知栏不会刷新', () {
      expect(mediaItemOf(fakeSong(1)).id, isNot(mediaItemOf(fakeSong(2)).id));
    });
  });

  group('推给系统的内容', () {
    late LingtingAudioHandler handler;

    setUp(() => handler = LingtingAudioHandler());

    test('队列与当前这一首', () {
      final songs = <LingtingSong>[fakeSong(1), fakeSong(2), fakeSong(3)];
      handler.publishQueue(songs, index: 1);

      expect(handler.queue.value.map((item) => item.id), ['1', '2', '3']);
      expect(handler.mediaItem.value?.title, '歌曲 2');
    });

    test('空队列什么都不推（免得通知栏闪一下就没了）', () {
      handler.publishQueue(const <LingtingSong>[], index: 0);
      expect(handler.queue.value, isEmpty);
      expect(handler.mediaItem.value, isNull);
    });

    test('下标越界时只推队列、不推当前曲目', () {
      handler.publishQueue(<LingtingSong>[fakeSong(1)], index: 5);
      expect(handler.queue.value.length, 1);
      expect(handler.mediaItem.value, isNull);
    });

    test('播放状态：播/暂停、进度、队列下标、折叠态三颗键', () {
      handler.publishQueue(<LingtingSong>[fakeSong(1), fakeSong(2)], index: 1);
      handler.publishState(
        playing: true,
        position: const Duration(seconds: 30),
        duration: const Duration(seconds: 200),
        index: 1,
      );

      final state = handler.playbackState.value;
      expect(state.playing, isTrue);
      expect(state.processingState, AudioProcessingState.ready);
      expect(state.updatePosition, const Duration(seconds: 30));
      expect(state.bufferedPosition, const Duration(seconds: 200));
      expect(state.queueIndex, 1);
      // 折叠态那三颗：上一首 / 暂停 / 下一首
      expect(state.controls.length, 3);
      expect(state.controls[1].action, MediaAction.pause);
      expect(state.androidCompactActionIndices, [0, 1, 2]);
      expect(state.systemActions, contains(MediaAction.seek));
    });

    test('总时长补进曲目里（锁屏/通知栏那根进度条的分母）', () {
      handler.publishQueue(<LingtingSong>[fakeSong(1)], index: 0);
      expect(handler.mediaItem.value?.duration, isNull, reason: '列表接口不给时长');

      handler.publishState(
        playing: true,
        position: Duration.zero,
        duration: const Duration(seconds: 200),
        index: 0,
      );

      expect(handler.mediaItem.value?.duration, const Duration(seconds: 200));
    });

    test('时长还不知道（0）时不往曲目里塞一个 0，免得进度条显示 0:00/0:00', () {
      handler.publishQueue(<LingtingSong>[fakeSong(1)], index: 0);
      handler.publishState(
        playing: true,
        position: Duration.zero,
        duration: Duration.zero,
        index: 0,
      );

      expect(handler.mediaItem.value?.duration, isNull);
      expect(handler.playbackState.value.bufferedPosition, Duration.zero);
    });

    test('暂停时中间那颗键变回「播放」', () {
      handler.publishState(
        playing: false,
        position: Duration.zero,
        duration: const Duration(seconds: 200),
        index: 0,
      );
      expect(handler.playbackState.value.controls[1].action, MediaAction.play);
    });

    test('没得播了：清掉曲目并把状态收回 idle（通知消失）', () {
      handler.publishQueue(<LingtingSong>[fakeSong(1)], index: 0);
      handler.publishIdle();

      expect(handler.mediaItem.value, isNull);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
      expect(handler.playbackState.value.playing, isFalse);
      expect(handler.playbackState.value.controls, isEmpty);
    });
  });

  group('系统按键 → 播放器', () {
    test('播放 / 暂停 / 上一首 / 下一首 / 拖进度都回传给播放器', () async {
      final handler = LingtingAudioHandler();
      var plays = 0;
      var pauses = 0;
      var nexts = 0;
      var previouses = 0;
      final seeks = <Duration>[]; // 一条一条赋值：cascade 里连续赋值会解析成「在前一个赋值结果上继续取属性」
      handler.onPlay = () async => plays += 1;
      handler.onPause = () async => pauses += 1;
      handler.onNext = () async => nexts += 1;
      handler.onPrevious = () async => previouses += 1;
      handler.onSeek = (position) async => seeks.add(position);

      await handler.play();
      await handler.pause();
      await handler.skipToNext();
      await handler.skipToPrevious();
      await handler.seek(const Duration(seconds: 42));

      expect(plays, 1);
      expect(pauses, 1);
      expect(nexts, 1);
      expect(previouses, 1);
      expect(seeks, [const Duration(seconds: 42)]);
    });

    test('系统要求「停」按暂停处理：队列留着，回到 App 还能接着听', () async {
      final handler = LingtingAudioHandler();
      var pauses = 0;
      handler.onPause = () async => pauses += 1;

      await handler.stop();

      expect(pauses, 1);
    });

    test('播放器没接电线时按键不炸（App 还没起来那一瞬间系统可能就按键了）', () async {
      final handler = LingtingAudioHandler();
      await handler.play();
      await handler.pause();
      await handler.skipToNext();
      await handler.seek(Duration.zero);
    });
  });
}
