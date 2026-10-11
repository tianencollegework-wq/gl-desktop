import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/mine/profile_form.dart' show appVersion;

/// 本机版本信息（老端 `plus.runtime.getProperty` 回调里拿到的
/// `versionName` + `versionCode`）。
///
/// 检查更新（S7.2）要把它上报给服务端：`{release: versionCode, version: versionName}`，
/// 服务端据此判断有没有新版本。
@immutable
class AppVersionInfo {
  const AppVersionInfo({required this.name, required this.code});

  /// 版本名（`1.0.0`，pubspec 里 `version:` 加号前那一半）
  final String name;

  /// 版本号（安卓的 `versionCode`，pubspec 里加号后那一半）
  final int code;

  /// 读不到时用的兜底（真机读不到几乎只发生在测试环境）
  static const AppVersionInfo fallback = AppVersionInfo(
    name: appVersion,
    code: 0,
  );

  @override
  String toString() => 'AppVersionInfo($name+$code)';
}

/// 版本信息的来源（抽出来是为了测试里能换成一个固定值）
abstract interface class AppVersionSource {
  Future<AppVersionInfo> read();
}

/// 真机实现：安卓走 `MainActivity.kt` 里那条小通道读 `PackageManager`。
///
/// 为什么不用 `package_info_plus`：它依赖 `win32 ^5.5.3`，而 `file_picker` 那条
/// 依赖链要 `win32 ^6.3.0`，两边解不开（`flutter pub get` 直接失败）。为了一个
/// 版本号不值得动文件选择器，所以自己写这十几行。
class PlatformAppVersionSource implements AppVersionSource {
  const PlatformAppVersionSource();

  @override
  Future<AppVersionInfo> read() async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>('version');
      final name = result?['name']?.toString() ?? '';
      final code = int.tryParse(result?['code']?.toString() ?? '') ?? 0;
      if (name.isEmpty) return AppVersionInfo.fallback;
      return AppVersionInfo(name: name, code: code);
    } on Object catch (error) {
      // 非安卓 / 单测环境没有这条通道：退回 pubspec 里那个常量，界面照常显示
      debugPrint('[版本] 读不到本机版本，用常量兜底：$error');
      return AppVersionInfo.fallback;
    }
  }
}

const MethodChannel _channel = MethodChannel('gracelinkim/app_info');

final appVersionSourceProvider = Provider<AppVersionSource>(
  (ref) => const PlatformAppVersionSource(),
);

/// 「我的」页那行版本号与检查更新都用它
final appVersionInfoProvider = FutureProvider<AppVersionInfo>(
  (ref) => ref.watch(appVersionSourceProvider).read(),
);
