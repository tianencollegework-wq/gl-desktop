import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

/// 语音消息播放。
///
/// 老端用 `uni.createInnerAudioContext()`（`mixins/chat.js`）：**单通道**，
/// 同一时间只播一条，再点同一条是暂停、点别的会切过去，而且离开页面要停。
/// 新端用同一个模型，只是把它做成一个可替换的 Riverpod 状态：
/// [state] 是“正在播放的那条语音地址”，界面据此高亮。
///
/// 状态里存的是**地址**而不是列表下标：老端靠 `zp_index`（虚拟列表下标）判断
/// 哪条在播，翻页/插入消息后下标会变，高亮就跑到别的消息上了。
class VoicePlayerNotifier extends Notifier<String?> {
  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _stateSub;

  @override
  String? build() {
    ref.onDispose(() => unawaited(_release()));
    return null;
  }

  /// 点同一条：停下来；点别的：切过去（老端 `playVoice` 的行为）
  Future<void> toggle(String url) async {
    if (url.isEmpty) return;
    if (state == url) {
      await stop();
      return;
    }
    await stop();
    state = url;
    try {
      await startEngine(url);
    } catch (error) {
      // 播不出来（没网、地址失效、没有音频设备）不能把界面搞崩
      debugPrint('[语音] 播放失败：$error');
      if (state == url) state = null;
    }
  }

  Future<void> stop() async {
    if (state == null && _player == null) return;
    state = null;
    await stopEngine();
  }

  /// 真正开始播（测试里覆写掉，不碰音频子系统）
  @protected
  Future<void> startEngine(String url) async {
    final player = _player ??= AudioPlayer();
    _stateSub ??= player.playerStateStream.listen(_onPlayerState);
    await player.setUrl(url);
    // 桌面上「点了没反应」时最想看的就是这一行：`setUrl` 成功说明**真的挂上了源**
    // （时长是引擎读出来的）；平台实现没接上时它直接抛，由 [toggle] 兜住并打日志。
    // 2026-10-04 就是靠它查出 Windows 上根本没注册音频插件（语音点了不响）。
    debugPrint('[语音] 开始播放：$url（时长 ${player.duration?.inMilliseconds ?? 0}ms）');
    await player.play();
  }

  /// 真正停止
  @protected
  Future<void> stopEngine() async {
    await _player?.stop();
  }

  /// 播完了（或被系统打断）→ 把高亮清掉，老端的 `onEnded` 就是这个作用。
  ///
  /// 顺手打一行日志：桌面上「点得到、听不到」这类问题（引擎没接上、文件 404、
  /// 没有音频设备）全看这两行 —— 「开始播放」有了、「播完」没来，就说明卡在半路。
  void _onPlayerState(PlayerState value) {
    if (value.processingState == ProcessingState.completed && state != null) {
      debugPrint('[语音] 播完：$state');
      state = null;
    }
  }

  Future<void> _release() async {
    await _stateSub?.cancel();
    _stateSub = null;
    final player = _player;
    _player = null;
    await player?.dispose();
  }
}

final voicePlayingProvider = NotifierProvider<VoicePlayerNotifier, String?>(
  VoicePlayerNotifier.new,
);
