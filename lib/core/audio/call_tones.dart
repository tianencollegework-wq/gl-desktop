import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../config/app_config.dart';

/// 通话声音（S6.2）：铃声与挂断音。
///
/// 老端两处分开：
/// * **铃声**是随包资源（`hybrid/html/voice/calling.mp3`），WebView 里那个 `<audio loop>`
///   循环播放——去电拨号中与被叫来电台都放它；
/// * **挂断音**是服务端资源（`{apiUrl}/static/voice/guaduan.mp3`），在关闭通话页时
///   （`call.vue::closeCall`）播一次。
///
/// 新端两样照搬，用两个 `AudioPlayer`：铃声要循环、挂断音要一次性，
/// 而且挂断音可能紧跟在停铃之后播（共用一条通道会互相打断）。
///
/// 抽成接口是为了单测（与 [MessageAlerter] / [VoicePlayerNotifier] 同一个理由）：
/// 测试里换成 [SilentCallTones]，不碰音频子系统。
abstract interface class CallTones {
  /// 循环放铃声（重复调用要幂等——老端那个 `<audio>` 也是靠 `paused` 判断的）
  Future<void> startRing();

  /// 停铃
  Future<void> stopRing();

  /// 播一次挂断音
  Future<void> playHangup();

  Future<void> dispose();
}

class AssetCallTones implements CallTones {
  AssetCallTones({required this.hangupSource});

  /// 挂断音地址（服务端静态资源，老端就是这么取的）
  final String hangupSource;

  /// 铃声（随包资源）
  static const String ringAsset = 'assets/audio/calling.mp3';

  AudioPlayer? _ring;
  AudioPlayer? _tone;
  bool _ringing = false;

  @override
  Future<void> startRing() async {
    if (_ringing) return;
    _ringing = true;
    try {
      final player = _ring ??= AudioPlayer();
      if (player.audioSource == null) {
        await player.setAsset(ringAsset);
      }
      await player.setLoopMode(LoopMode.one);
      // 不 await `play()`：它要到播放结束才返回，await 会把调用方卡住
      unawaited(player.play());
    } catch (error) {
      // 没有音频设备/资源缺失都不能影响通话流程
      debugPrint('[通话] 铃声播放失败：$error');
    }
  }

  @override
  Future<void> stopRing() async {
    if (!_ringing && _ring == null) return;
    _ringing = false;
    try {
      await _ring?.stop();
    } catch (error) {
      debugPrint('[通话] 停铃失败：$error');
    }
  }

  @override
  Future<void> playHangup() async {
    try {
      final player = _tone ??= AudioPlayer();
      await player.setUrl(hangupSource);
      await player.play();
    } catch (error) {
      debugPrint('[通话] 挂断音播放失败：$error');
    }
  }

  @override
  Future<void> dispose() async {
    final ring = _ring;
    final tone = _tone;
    _ring = null;
    _tone = null;
    _ringing = false;
    try {
      await ring?.dispose();
      await tone?.dispose();
    } catch (error) {
      debugPrint('[通话] 释放播放器失败：$error');
    }
  }
}

/// 测试/静音环境用：只记次数
class SilentCallTones implements CallTones {
  int ringStarts = 0;
  int ringStops = 0;
  int hangupTones = 0;
  bool ringing = false;

  @override
  Future<void> startRing() async {
    ringStarts += 1;
    ringing = true;
  }

  @override
  Future<void> stopRing() async {
    ringStops += 1;
    ringing = false;
  }

  @override
  Future<void> playHangup() async => hangupTones += 1;

  @override
  Future<void> dispose() async {}
}

final callTonesProvider = Provider<CallTones>((ref) {
  final tones = AssetCallTones(
    hangupSource:
        '${ref.watch(appConfigProvider).apiUrl}/static/voice/guaduan.mp3',
  );
  ref.onDispose(tones.dispose);
  return tones;
});
