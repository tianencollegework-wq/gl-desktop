import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/platform/audio_session_configurator.dart';

/// 音频会话这一层的**契约**（不是它的实现细节）。
///
/// 这条链是 2026-10-14 补的：iOS 上灵听切后台 / 锁屏会被系统停，因为从来没人把
/// `AVAudioSession` 的分类设成 `playback`（`just_audio` 的 darwin 源码里一行都没碰它）。
///
/// 要钉住的三件事：
/// 1. 非 iOS 上它是**空操作**（安卓那套 `audio_service` + 音频焦点是真机验过的，
///    不能因为这一层被多拧一颗螺丝）；
/// 2. iOS 上它**永不抛**（会话设不上只该少一个好处，绝不能把音乐掐掉）；
/// 3. 失败要留在它自己这层 —— 调用方（灵听播放器）那条路照样往下走。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('桌面 / 安卓上是空操作：调了什么都不发生，也不抛', () async {
    const configurator = NoopAudioSessionConfigurator();
    expect(configurator.supported, isFalse, reason: '只有 iOS 认「音频会话」这件事');
    await configurator.music();
    await configurator.idle();
  });

  test('按平台挑实现：单测跑在桌面上 → 拿到的是空操作', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final configurator = container.read(audioSessionConfiguratorProvider);
    // 真实现调的是 `AVAudioSession`，在桌面上根本不存在；挑错实现的表现是
    // 「每次放歌都多一条什么也不干的平台调用」，以及与通话那条会话各设各的。
    expect(configurator, isA<NoopAudioSessionConfigurator>());
    expect(configurator.supported, isFalse);
  });

  test('iOS 那份：通道不在（单测 / 旧安装包）时只记一行，绝不抛', () async {
    const configurator = IosAudioSessionConfigurator();
    expect(configurator.supported, isTrue);
    // 测试环境里 `audio_session` 的原生那边并不存在，两次调用都会以异常收场 ——
    // 而它们必须是「被吞掉的异常」：这一层一旦漏出去，就轮到播放那条路崩了
    await configurator.music();
    await configurator.idle();
  });
}
