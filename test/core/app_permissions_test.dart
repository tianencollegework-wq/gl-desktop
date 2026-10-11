import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/platform/app_permissions.dart';

/// 自己写的那条权限通道（`android/.../MainActivity.kt` 的 `PERMISSIONS_CHANNEL`）。
///
/// 两批事：①通道回来的字符串怎么翻译成 [PermissionStatus]；
/// ②**认不出来的时候绝不能拦人** —— 通道没实现（桌面端、旧安装包、单测）时，
/// 行为必须与加权限这层之前一模一样。
bool _supported() => true;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('gracelinkim/permissions');
  late List<MethodCall> calls;

  void mockChannel(Object? Function(MethodCall call) handler) {
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return handler(call);
        });
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('通道怎么翻译', () {
    for (final (wire, expected) in <(String, PermissionStatus)>[
      ('granted', PermissionStatus.granted),
      ('denied', PermissionStatus.denied),
      ('permanentlyDenied', PermissionStatus.permanentlyDenied),
    ]) {
      test('通道说 $wire → $expected', () async {
        mockChannel((_) => <String, String>{'camera': wire});
        const gateway = SystemPermissionGateway(isSupported: _supported);
        expect(await gateway.check(AppPermission.camera), expected);
      });
    }

    test('通道回了个没听说过的词：当「不需要」，不拦人', () async {
      mockChannel((_) => <String, String>{'camera': 'whatever'});
      const gateway = SystemPermissionGateway(isSupported: _supported);
      expect(
        await gateway.check(AppPermission.camera),
        PermissionStatus.unsupported,
      );
    });

    test('通道压根没回这一项：也是「不需要」', () async {
      mockChannel((_) => <String, String>{'microphone': 'denied'});
      const gateway = SystemPermissionGateway(isSupported: _supported);
      expect(
        await gateway.check(AppPermission.camera),
        PermissionStatus.unsupported,
      );
    });
  });

  group('通道怎么被调用', () {
    test('check 发的是 check + 权限名（与 Kotlin 那边的映射一一对应）', () async {
      mockChannel((_) => <String, String>{'microphone': 'granted'});
      const gateway = SystemPermissionGateway(isSupported: _supported);
      await gateway.check(AppPermission.microphone);

      expect(calls.single.method, 'check');
      expect(calls.single.arguments, <String, dynamic>{
        'names': <String>['microphone'],
      });
    });

    test('request 发的是 request（那一步才会弹系统框）', () async {
      mockChannel((_) => <String, String>{'notifications': 'granted'});
      const gateway = SystemPermissionGateway(isSupported: _supported);
      await gateway.request(AppPermission.notifications);

      expect(calls.single.method, 'request');
      expect(calls.single.arguments, <String, dynamic>{
        'names': <String>['notifications'],
      });
    });

    test('通道抛异常（比如 busy/没实现）：当「不需要」，不往上冒', () async {
      mockChannel(
        (_) => throw PlatformException(code: 'busy', message: '另一个请求还在飞'),
      );
      const gateway = SystemPermissionGateway(isSupported: _supported);
      expect(
        await gateway.request(AppPermission.camera),
        PermissionStatus.unsupported,
      );
    });

    test('没有这条通道（Host 平台 / 老安装包）：也不拦人，而且一次都不去调', () async {
      mockChannel((_) => <String, String>{'camera': 'denied'});
      const gateway = SystemPermissionGateway(isSupported: _unsupported);
      expect(
        await gateway.check(AppPermission.camera),
        PermissionStatus.unsupported,
      );
      expect(calls, isEmpty, reason: '不是移动端就别去敲那条通道');
    });
  });

  group('能不能往下走', () {
    test('unsupported 算通过（这个系统上不需要它）', () {
      expect(PermissionStatus.unsupported.isGranted, isTrue);
    });

    test('denied / permanentlyDenied 都不算通过', () {
      expect(PermissionStatus.denied.isGranted, isFalse);
      expect(PermissionStatus.permanentlyDenied.isGranted, isFalse);
    });
  });
}

bool _unsupported() => false;
