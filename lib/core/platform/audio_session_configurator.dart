import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// **音频会话**（iOS 的 `AVAudioSession` / 安卓的音频焦点）：告诉系统「我接下来要
/// 用哪个喇叭、以什么方式出声」。
///
/// 为什么要有这一层（2026-10-14）：
/// * 安卓那边灵听能被系统继续放，靠的是 `audio_service` 前台服务（见
///   `lingting_audio_handler.dart`），而 `just_audio` 在安卓侧自己会申请音频焦点；
/// * **iOS 上这两条都不成立**：没有前台服务这回事，而 `just_audio` 的 darwin
///   源码里**一行都没碰 `AVAudioSession`**（实测 grep 过）。于是会话停在系统默认的
///   `soloAmbient` 分类上 —— 后果有两条：切后台 / 锁屏几秒后音乐被系统停掉，
///   以及静音键拨到静音时音乐没声（默认分类是「尊重静音键」的那种）。
///   这两条都要靠把分类设成 `playback` 才解决，所以起播前必须显式设一次。
///
/// 为什么只做 iOS：安卓现在这套（`audio_service` + `just_audio` 自己管焦点）是
/// **真机验过的**（1.0.1 在跑），没有任何已知毛病；这个包的安卓侧还会顺手改音频
/// 属性与焦点策略，等于在一个能跑的东西上多拧一颗螺丝。所以非 iOS 上这一整层是
/// 空操作 —— 行为与加它之前**逐字一样**。
///
/// 与通话那条会话（`gracelinkim/call_service` → `CallAudioSession`）的分工：
/// 通话**不归这里管**。通话音要采麦克风，会话分类是 `playAndRecord` + `voiceChat`，
/// 由原生那条通道负责（什么时候起、什么时候关都与通话状态绑定）。这里只管
/// **放音乐**这一种；两边的分类不同，谁也别去动对方的那一份。
abstract interface class AudioSessionConfigurator {
  /// 这个平台认不认「音频会话」这件事（只有 iOS 认）
  bool get supported;

  /// 要开始 / 继续放音乐了：把会话设成放音（iOS = `playback`）并激活。
  /// **幂等**：已经在放了再调一次也无害（切歌、暂停后继续都会走到）。
  Future<void> music();

  /// 不放了（停止播放 / 播放器被释放）：把会话交还系统，
  /// 否则被打断的别的应用（音乐、播客）会一直停在那儿。
  Future<void> idle();
}

/// 没有音频会话可管的平台（桌面 / 安卓 / 单测）：什么都不做。
///
/// **绝不抛异常**是这一层的硬要求：它是「让音乐在后台继续响」的锦上添花，
/// 起不来也只该少这一个好处，绝不能连累播放本身（与 `call_keep_alive` 同一个口径）。
class NoopAudioSessionConfigurator implements AudioSessionConfigurator {
  const NoopAudioSessionConfigurator();

  @override
  bool get supported => false;

  @override
  Future<void> music() async {}

  @override
  Future<void> idle() async {}
}

/// iOS 实现：`audio_session` 包的 [AudioSession]。
///
/// 为什么用这个包而不是自己写一条通道：`AVAudioSession` 这套东西除了「设分类 +
/// 激活」，还有一堆必须配套处理的系统事件（来电 / 闹钟 / Siri 的中断、耳机拔出、
/// 媒体服务重启），包已经把那些事件翻成了 Dart 的流。自己写一条通道也能设分类，
/// 但那些事件就得跟着再写一遍。
class IosAudioSessionConfigurator implements AudioSessionConfigurator {
  const IosAudioSessionConfigurator();

  @override
  bool get supported => true;

  @override
  Future<void> music() => _guard(() async {
    final session = await AudioSession.instance;
    // `music()` 这个预设 = iOS 的 `playback` 分类（切后台继续响、不看静音键）。
    // 换歌 / 继续播放时再设一遍是**故意**的：通话、别的应用或系统中断都可能
    // 把分类改掉，只在第一首之前设一次的话，那些情况之后就再也回不来了。
    await session.configure(const AudioSessionConfiguration.music());
    final activated = await session.setActive(true);
    if (!activated) {
      // 系统没让激活（比如被别的应用占着）：不是错，但要说出来 ——
      // 真机排查「灵听一切后台就停」时，这一行是最直接的线索
      debugPrint('[音频会话] 系统没让激活（这次后台播放可能被停）');
    }
  });

  @override
  Future<void> idle() => _guard(() async {
    final session = await AudioSession.instance;
    // 关掉会话 = 把喇叭还给别的应用（与安卓那句「停掉前台服务」同一个意思）
    await session.setActive(false);
  });

  static Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      // 通道不存在（旧安装包）、系统拒绝、包内部断言…… 一律吞掉，播放照旧
      debugPrint('[音频会话] 这一步没成（不影响播放）：$error');
    }
  }
}

/// 按平台挑一个实现（与 `callKeepAliveProvider` / `permissionGatewayProvider` 同一个套路）
final audioSessionConfiguratorProvider = Provider<AudioSessionConfigurator>((
  ref,
) {
  if (Platform.isIOS) return const IosAudioSessionConfigurator();
  return const NoopAudioSessionConfigurator();
});
