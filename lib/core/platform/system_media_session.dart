/// Windows 的**系统媒体控制**（SMTC）：任务栏 / 音量面板上那张「正在播放」卡片，
/// 以及键盘上的媒体键（播放-暂停、上一首、下一首）。
///
/// 为什么不用 `audio_service`：它在 Windows 上**没有实现**（包里只有
/// android / darwin / web），手机那份通知栏在桌面上是空的 —— 桌面这一份由 runner
/// 出的 `gracelinkim/media_session` 通道接手（见
/// `windows/runner/flutter_window.cpp` 里那段 SMTC）。
///
/// 和 [DesktopWindowNative] 一个路子：非桌面、通道没注册、系统不给会话……
/// 一律吞掉 —— 系统那张卡片是锦上添花，放歌不受影响。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'desktop_shell.dart';

class SystemMediaSession {
  const SystemMediaSession._();

  static const MethodChannel _channel = MethodChannel(
    'gracelinkim/media_session',
  );

  /// 把系统那几颗键接回播放器（和通知栏那份走同一套逻辑：都进
  /// `LingtingPlayerNotifier`，不会出现「媒体键在下一首、界面还在上一首」）。
  static void bind({
    required VoidCallback onPlay,
    required VoidCallback onPause,
    required VoidCallback onNext,
    required VoidCallback onPrevious,
  }) {
    if (!isDesktopRuntime) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'media_button') return null;
      final args = call.arguments;
      final button = args is Map ? '${args['button']}' : '';
      debugPrint('[灵听] 系统那颗键：$button');
      switch (button) {
        case 'play':
          onPlay();
        case 'pause':
          onPause();
        case 'next':
          onNext();
        case 'previous':
          onPrevious();
      }
      return null;
    });
  }

  /// 现在在放什么 → 系统那张卡片（歌名 / 歌手 / 专辑 / 封面 / 进度）
  static Future<void> update({
    required String title,
    required String artist,
    required String album,
    required String cover,
    required bool playing,
    required double position,
    required double duration,
  }) => _guard(() async {
    final ok = await _channel.invokeMethod<bool>('update', <String, dynamic>{
      'title': title,
      'artist': artist,
      'album': album,
      'cover': cover,
      'playing': playing,
      'position': position,
      'duration': duration,
    });
    // 原生那边拿不到会话（老系统 / 被策略挡了）会回 false：不是错，静默降级，
    // 但记一笔 —— 实机排查「系统那张卡片怎么不出现」时就看这一条
    if (ok != true) {
      debugPrint('[灵听] 系统那边没给媒体会话（这台机器上没有那张「正在播放」卡片）');
    }
  });

  /// 没有在放了 → 把那张卡片收掉
  static Future<void> clear() =>
      _guard(() => _channel.invokeMethod<void>('clear'));

  static Future<void> _guard(Future<void> Function() action) async {
    // 手机上这份由 `audio_service` 管，通道也不存在；非桌面上直接不动
    if (!isDesktopRuntime) return;
    try {
      await action();
    } on Object catch (error) {
      debugPrint('[灵听] 系统媒体会话没更新上（不影响播放）：$error');
    }
  }
}
