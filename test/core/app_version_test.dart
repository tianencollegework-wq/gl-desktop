import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/platform/app_version.dart';
import 'package:gracelinkim/domain/mine/profile_form.dart' show appVersion;

/// 「本机版本号」这条通道的**契约**（`lib/core/platform/app_version.dart`）。
///
/// 这条通道以前只有安卓那侧有实现（`MainActivity.kt`），PC 上调它只会抛
/// MissingPluginException，于是内部号永远报 0、「检查更新」只能靠版本名去凑。
/// 2026-10-09 给 Windows runner 也补上了实现（`windows/runner/flutter_window.cpp`
/// 里的 `gracelinkim/app_info`），两边靠的就是这几条约定：
///
/// * 通道名 `gracelinkim/app_info`、方法名 `version`；
/// * 返回值是 `{name: 版本名, code: 内部号}`（内部号是整数）；
/// * 读不到（通道没实现 / name 是空）就退回常量，**不许抛**（界面照常显示）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('gracelinkim/app_info');
  final List<MethodCall> calls = <MethodCall>[];

  void mockHandler(Object? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return handler(call);
        });
  }

  setUp(calls.clear);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('读得到：版本名与内部号原样下来（PC runner 报的就是这个形状）', () async {
    mockHandler(
      (_) => <String, Object?>{'name': '1.0.0', 'code': 261008},
    );

    final info = await const PlatformAppVersionSource().read();

    expect(calls.single.method, 'version', reason: '方法名是契约的一部分');
    expect(info.name, '1.0.0');
    expect(info.code, 261008, reason: '内部号要能过 255（yyyyMMdd 那种大整数）');
  });

  test('通道没实现（旧 runner / 单测环境）→ 常量兜底，不抛', () async {
    mockHandler((_) => throw MissingPluginException('没有这条通道'));

    final info = await const PlatformAppVersionSource().read();

    expect(info.name, appVersion);
    expect(info.code, 0, reason: '读不到就报 0：更新检查那边据此退回比版本名');
  });

  test('半截数据（name 是空串）也当读不到', () async {
    mockHandler((_) => <String, Object?>{'name': '', 'code': 12});

    final info = await const PlatformAppVersionSource().read();

    expect(info.name, appVersion);
    expect(info.code, 0);
  });

  test('code 写成了字符串也认（宽松解析，别为这点小事把界面弄空）', () async {
    mockHandler((_) => <String, Object?>{'name': '1.2.3', 'code': '261008'});

    final info = await const PlatformAppVersionSource().read();

    expect(info.name, '1.2.3');
    expect(info.code, 261008);
  });
}
