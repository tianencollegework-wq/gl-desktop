import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/platform/call_pip.dart';

/// 通话小窗（画中画，S6.6）的 Dart 侧：把「比例 / 标题 / 进小窗 / 收小窗」翻译成
/// 对 `MainActivity` 的调用。
///
/// Kotlin 那半只有真机能跑，所以这里验的是**接口契约**：发给平台通道的参数对不对
/// （比例随语音/视频走、标题带对方名字）、重复设置会不会白打通道、系统不接受时
/// 谁能兜住（小窗是体验，绝不能影响通话）。
///
/// 注意：这里**没有**「自动缩窗」这件事 —— 按用户要求，只有点按钮才进（`enter`）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('gracelinkim/pip');

  late List<MethodCall> calls;
  late Map<String, Object?> results;

  setUp(() {
    calls = <MethodCall>[];
    results = <String, Object?>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return results[call.method];
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('安卓实现', () {
    test('交参数：语音与视频各发一条（比例与标题都带上）', () async {
      final pip = AndroidCallPip();
      results['setParams'] = true;

      expect(pip.supported, isTrue);
      expect(await pip.setParams(video: false, title: '老B'), isTrue);
      expect(await pip.setParams(video: true, title: '老B'), isTrue);

      expect(calls.map((call) => call.method), <String>[
        'setParams',
        'setParams',
      ]);
      final voice = calls.first.arguments as Map<Object?, Object?>;
      expect(voice['video'], isFalse);
      expect(voice['title'], '老B');
      // 没有「自动缩窗」这个开关了（用户要求：只有点按钮才进）
      expect(voice.containsKey('enabled'), isFalse);

      final video = calls.last.arguments as Map<Object?, Object?>;
      expect(video['video'], isTrue);
    });

    test('参数没变就不重复打通道（控制器每次状态变化都会来问一遍）', () async {
      final pip = AndroidCallPip();
      results['setParams'] = true;

      await pip.setParams(video: false, title: '老B');
      await pip.setParams(video: false, title: '老B');
      await pip.setParams(video: false, title: '老B');
      expect(calls, hasLength(1));

      // 换了一通电话（标题变了）要重新设一次
      await pip.setParams(video: false, title: '小明');
      expect(calls, hasLength(2));
    });

    test('进 / 出小窗：各一条通道调用', () async {
      final pip = AndroidCallPip();
      results['enter'] = true;
      results['exit'] = true;

      expect(await pip.enter(), isTrue);
      expect(await pip.exit(), isTrue);
      expect(calls.map((call) => call.method), <String>['enter', 'exit']);
    });

    test('系统不接受（ROM 关掉了画中画）→ 返回 false，不抛', () async {
      final pip = AndroidCallPip();
      results['setParams'] = false;
      results['enter'] = false;

      expect(await pip.setParams(video: true), isFalse);
      expect(await pip.setParams(video: false), isFalse);
      expect(await pip.enter(), isFalse);
    });

    test('查小窗状态：拿到什么就是什么；通道报错一律当没在小窗里', () async {
      final pip = AndroidCallPip();
      results['isInPip'] = true;
      expect(await pip.isInPip(), isTrue);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => throw PlatformException(code: 'boom'),
          );
      expect(await pip.isInPip(), isFalse);
      expect(await pip.setParams(video: false), isFalse);
      expect(await pip.enter(), isFalse);
      expect(await pip.exit(), isFalse);
    });

    test('原生上报进了 / 出了小窗 → 回调拿到值', () async {
      final pip = AndroidCallPip();
      final modes = <bool>[];
      pip.addModeListener(modes.add);

      Future<void> nativeSays(bool value) async {
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              'gracelinkim/pip',
              const StandardMethodCodec().encodeMethodCall(
                MethodCall('modeChanged', value),
              ),
              (_) {},
            );
      }

      await nativeSays(true);
      await nativeSays(false);
      expect(modes, <bool>[true, false]);
    });

    test('多个监听都在听（1:1 与群通话共用一条通道，谁也不顶掉谁）', () async {
      final pip = AndroidCallPip();
      final first = <bool>[];
      final second = <bool>[];
      pip.addModeListener(first.add);
      pip.addModeListener(second.add);

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'gracelinkim/pip',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('modeChanged', true),
            ),
            (_) {},
          );
      expect(first, <bool>[true]);
      expect(second, <bool>[true]);

      // 摘掉一个：另一个照旧收得到（群通话挂断不该把 1:1 那条监听一起带走）
      pip.removeModeListener(first.add);
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'gracelinkim/pip',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('modeChanged', false),
            ),
            (_) {},
          );
      expect(first, <bool>[true]);
      expect(second, <bool>[true, false]);
    });
  });

  group('没有画中画的平台', () {
    test('空实现：什么都不做，也不打通道（iOS 的画中画跟通话 UI 一起做，属于 S6.4）', () async {
      const pip = NoopCallPip();
      expect(pip.supported, isFalse);
      expect(await pip.setParams(video: true), isFalse);
      expect(await pip.isInPip(), isFalse);
      expect(await pip.enter(), isFalse);
      expect(await pip.exit(), isFalse);
      expect(calls, isEmpty);
    });
  });
}
