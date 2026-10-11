import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../data/model/app_setting.dart';
import '../config/app_config.dart';

/// 新消息提醒（提示音 + 震动）。
///
/// 老端 `App.vue::playSound()` 播放的是**服务端的音频文件**：
/// `config.apiUrl + '/static/voice/notify.mp3'`——不是本地资源，所以直接照搬这个地址。
///
/// 抽成接口是为了单测：测试里换成 [SilentMessageAlerter]，不碰音频子系统。
abstract interface class MessageAlerter {
  /// 按本地设置提醒（关了就什么都不做）
  Future<void> alert(AppSetting setting);

  Future<void> dispose();
}

class RemoteSoundAlerter implements MessageAlerter {
  RemoteSoundAlerter({required this.source});

  /// 提示音地址（服务端静态资源）
  final String source;

  AudioPlayer? _player;
  bool _playing = false;

  @override
  Future<void> alert(AppSetting setting) async {
    if (setting.vibrateStatus) {
      await HapticFeedback.mediumImpact();
    }
    if (!setting.voiceStatus) return;
    if (_playing) return; // 连收多条消息时不要叠加播放

    try {
      final player = _player ??= AudioPlayer();
      await player.setUrl(source);
      _playing = true;
      await player.play();
      _playing = false;
    } catch (error) {
      // 播不出来（没网、插件不可用）不能影响收消息
      _playing = false;
      debugPrint('[提醒] 提示音播放失败：$error');
    }
  }

  @override
  Future<void> dispose() async {
    final player = _player;
    _player = null;
    await player?.dispose();
  }
}

/// 测试/静音环境用
class SilentMessageAlerter implements MessageAlerter {
  int alerts = 0;

  @override
  Future<void> alert(AppSetting setting) async => alerts++;

  @override
  Future<void> dispose() async {}
}

final messageAlerterProvider = Provider<MessageAlerter>((ref) {
  final alerter = RemoteSoundAlerter(
    source: '${ref.watch(appConfigProvider).apiUrl}/static/voice/notify.mp3',
  );
  ref.onDispose(alerter.dispose);
  return alerter;
});
