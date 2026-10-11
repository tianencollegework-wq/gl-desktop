import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/platform/background_health.dart';

/// 「后台收不收得到消息」那两道系统开关的 Dart 侧。
///
/// Kotlin 那半只有真机能跑，所以这里验的是**接口契约**（方法名、返回值语义、
/// 出错时偏向哪一边）—— 真机行为（系统设置页真的被打开、电池白名单真的生效）
/// 只能靠手工验，见 REFACTOR_PLAN 的真机清单。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  late Map<String, Object?> results;
  const channel = MethodChannel('gracelinkim/app_settings');

  void installHandler({bool present = true}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          present
              ? (call) async {
                  calls.add(call);
                  return results[call.method];
                }
              : null,
        );
  }

  setUp(() {
    calls = <MethodCall>[];
    results = <String, Object?>{};
    installHandler();
  });

  tearDown(() => installHandler(present: false));

  group('安卓实现', () {
    const health = AndroidBackgroundHealth();

    test('两道开关都从平台通道读，且读回来的就是「要不要提示」的依据', () async {
      expect(health.supported, isTrue);

      results['notificationPermission'] = false;
      results['isIgnoringBatteryOptimizations'] = false;

      expect(await health.notificationGranted(), isFalse);
      expect(await health.ignoringBatteryOptimizations(), isFalse);
      expect(calls.map((call) => call.method).toList(), <String>[
        'notificationPermission',
        'isIgnoringBatteryOptimizations',
      ]);
    });

    test('查不出来一律当成「正常」—— 不能拿一条误报的红提示条去烦用户', () async {
      // 通道压根没注册（桌面/测试环境）：抛异常而不是返回 null
      installHandler(present: false);

      expect(await health.notificationGranted(), isTrue);
      expect(await health.ignoringBatteryOptimizations(), isTrue);

      // 通道在、但方法没实现（返回 null）
      installHandler();
      expect(await health.notificationGranted(), isTrue);
      expect(await health.ignoringBatteryOptimizations(), isTrue);
    });

    test('点提示条的两个动作：同名方法各调一次，失败只返回 false 绝不抛', () async {
      expect(await health.openNotificationSettings(), isTrue);
      expect(await health.requestIgnoreBatteryOptimizations(), isTrue);
      expect(calls.map((call) => call.method).toList(), <String>[
        'openNotificationSettings',
        'requestIgnoreBatteryOptimizations',
      ]);

      // 跳转失败（ROM 没有这个设置页）不能让提示条点一下就崩
      installHandler(present: false);
      expect(await health.openNotificationSettings(), isFalse);
      expect(await health.requestIgnoreBatteryOptimizations(), isFalse);
    });
  });

  group('没有这两道开关的平台', () {
    test('都算正常，界面不该出现这条提示', () async {
      const health = NoopBackgroundHealth();
      expect(health.supported, isFalse);
      expect(await health.notificationGranted(), isTrue);
      expect(await health.ignoringBatteryOptimizations(), isTrue);
      expect(await health.openNotificationSettings(), isFalse);
      expect(await health.requestIgnoreBatteryOptimizations(), isFalse);
    });
  });
}
