import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/i18n/app_i18n.dart';
import 'package:gracelinkim/core/i18n/locale_controller.dart';
import 'package:gracelinkim/features/desktop_window/tray_native.dart';

/// 托盘那三句文案（S12.36）。
///
/// 关窗缩到托盘之后，菜单上那两项、以及第一次缩进去时那个气泡，是用户**唯一**
/// 还能看到的字 —— 得跟着 App 的语言走，而且 7 份语言包里都得有真翻译
/// （`i18n_keys_test` 只管「key 在不在」，翻没翻由这里钉）。
///
/// 用户原话（2026-10-06）：「你从 Windows 底部栏右边那个小箭头点开还能看到，
/// 就应用没有真正被关掉」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('gracelinkim/tray');

  setUp(() {
    TrayNative.resetForTest();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('7 份语言包里托盘那三句都是真文案（不是 key、不是空）', () async {
    for (final option in LocaleController.options) {
      final i18n = await AppI18n.load(option.code);
      final payload = TrayNative.payloadOf(i18n);
      expect(payload.keys.toSet(), <String>{
        'open',
        'exit',
        'balloon',
      }, reason: '原生那边认的就是这三个字段');
      for (final entry in payload.entries) {
        expect(
          entry.value.trim(),
          isNotEmpty,
          reason: '${option.code} 的 ${entry.key} 是空的',
        );
        expect(
          entry.value.startsWith('tray.'),
          isFalse,
          reason: '${option.code} 的 ${entry.key} 没翻（原样显示了 key）',
        );
      }
    }
  });

  test('同一种语言只过一次通道；换语言才会再配一次', () async {
    final sent = <Map<String, String>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'configure');
          sent.add((call.arguments as Map).cast<String, String>());
          return null;
        });

    final zh = await AppI18n.load('zh-Hans');
    // `build` 里每次重建都会调一次：同一个语言不能反复过通道
    await TrayNative.configure(zh);
    await TrayNative.configure(zh);
    expect(sent, hasLength(1), reason: '同一个语言配了两遍');

    final en = await AppI18n.load('en');
    await TrayNative.configure(en);
    expect(sent, hasLength(2));
    expect(
      sent.last['exit'],
      isNot(sent.first['exit']),
      reason: '换了语言，菜单文字得跟着换',
    );
  });

  test('通道不在（手机 / 网页 / 老 runner）不抛异常，也不反复重试', () async {
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls++;
          throw MissingPluginException('这台机器上没有托盘');
        });

    final i18n = await AppI18n.load('zh-Hans');
    await TrayNative.configure(i18n); // 吞掉异常
    await TrayNative.configure(i18n); // 失败也算配过：不再重试（不刷日志）
    expect(calls, 1);
  });
}
