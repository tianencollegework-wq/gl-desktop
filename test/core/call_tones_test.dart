import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/audio/call_tones.dart';

/// 通话铃声与挂断音（S6.2）。
///
/// 能在这里验的只有三件：静音替身的行为、铃声**真的随包打进去了**、
/// 挂断音地址拼对了。真正「放得出声音」只有设备能验——`AssetCallTones` 在测试
/// 环境里会被 `just_audio` 的 `MissingPluginException` 打穿（那是它内部的
/// 未捕获异步异常，我们那层 `try/catch` 拦不住），所以不在这里碰它。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('静音替身（测试与静音环境用）', () {
    test('记下响铃 / 停铃 / 挂断音的次数与当前状态', () async {
      final tones = SilentCallTones();

      expect(tones.ringing, isFalse);
      await tones.startRing();
      await tones.startRing();
      expect(tones.ringStarts, 2);
      expect(tones.ringing, isTrue);

      await tones.stopRing();
      expect(tones.ringStops, 1);
      expect(tones.ringing, isFalse);

      await tones.playHangup();
      expect(tones.hangupTones, 1);

      await tones.dispose();
    });
  });

  group('铃声资源', () {
    test('calling.mp3 真的在包里（老端 hybrid/html/voice/calling.mp3 的同一份）', () async {
      final data = await rootBundle.load(AssetCallTones.ringAsset);

      expect(data.lengthInBytes, greaterThan(1000));
      // MP3 头：老端那份带 ID3v2 标签，这里只验「是个 mp3 而不是空文件/占位文本」
      final header = data.buffer.asUint8List(0, 3);
      expect(String.fromCharCodes(header), 'ID3');
    });
  });

  group('挂断音地址（老端 call.vue::closeCall 用的是服务端资源）', () {
    test('拼成 {apiUrl}/static/voice/guaduan.mp3', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final tones = container.read(callTonesProvider);

      expect(tones, isA<AssetCallTones>());
      expect(
        (tones as AssetCallTones).hangupSource,
        'https://message.gracelink.cc/static/voice/guaduan.mp3',
      );
    });
  });
}
