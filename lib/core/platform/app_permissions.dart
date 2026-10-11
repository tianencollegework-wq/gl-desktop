import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 本应用要用的那几个**系统运行时权限**。
///
/// 为什么自己写一条通道（不引 `permission_handler`）：这个仓库里已经有四条自己写的
/// 平台通道了（设置页、版本号、通话服务、小窗），而我们要的就这三样 ——
/// 拉一个插件（连同它的 Android 配置与 iOS Podfile 改动）不如这几十行划算。
/// 平台那一侧的实现在 `android/.../MainActivity.kt` 的 `PERMISSIONS_CHANNEL` 里。
///
/// 与 `background_health.dart` 的分工：那边用**专线**查通知与电池（它们各有自己
/// 的语义化写法，界面直接照着用）；这边是统一的「查/申请」入口，给「用之前先确保
/// 拿到」那几处调用（通话、扫码、录音、选图）。
enum AppPermission {
  camera('camera'),
  microphone('microphone'),
  notifications('notifications');

  const AppPermission(this.wireName);

  /// 通道里用的名字（与 MainActivity 的 `permissionOf` 一一对应）
  final String wireName;
}

/// 一次查询/申请的结果。
enum PermissionStatus {
  /// 已经允许
  granted,

  /// 被拒了（但再问一次系统还会弹框）
  denied,

  /// 被拒且**系统不再弹框**了：只能去设置页手动打开（微信那句「去授权」就是这条路）
  permanentlyDenied,

  /// 这个平台/系统上不需要它（桌面端、安卓 13 以下的通知、通道还没有实现…）
  unsupported;

  /// 从「能不能往下走」的角度看算不算通过
  bool get isGranted => this == granted || this == unsupported;

  /// 通道回的那个字符串 → 状态（认不出来一律当 `unsupported`：不误拦）
  static PermissionStatus parse(Object? raw) => switch (raw) {
    'granted' => granted,
    'denied' => denied,
    'permanentlyDenied' => permanentlyDenied,
    _ => unsupported,
  };
}

/// 查 / 申请权限的入口。
///
/// 抽成接口是为了能在测试里注入替身（组件测试里没有真的系统权限框）；
/// 真机实现见 [SystemPermissionGateway]。
abstract class PermissionGateway {
  /// **只查**，绝不弹框（与 `background_health` 那条一样：弹框会把 App 顶到后台，
  /// 而安卓 14 不允许从后台起 mic/camera 类型的前台服务）
  Future<PermissionStatus> check(AppPermission permission);

  /// 查一遍，缺的弹系统框问一次
  Future<PermissionStatus> request(AppPermission permission);
}

/// 真机实现（平台通道）。
///
/// **失败/认不出来一律当「不需要」**（[PermissionStatus.unsupported]）：权限这条
/// 只用来提前说一句话、提前拦一下，它自己绝不能变成新的拦路虎 ——
/// 通道没实现（桌面端、iOS、单测）时行为必须与加它之前**完全一样**。
class SystemPermissionGateway implements PermissionGateway {
  const SystemPermissionGateway({this.isSupported});

  /// 「这台机器上有没有这条通道」。默认按平台判（安卓 / iOS 才有）。
  ///
  /// 可注入是为了**能在测试里跑**：单测跑在桌面上（`Platform.isAndroid` 是 false），
  /// 不注入就永远只能测到「unsupported」那一条分支。
  final bool Function()? isSupported;

  static const MethodChannel _channel = MethodChannel(
    'gracelinkim/permissions',
  );

  @override
  Future<PermissionStatus> check(AppPermission permission) =>
      _invoke('check', permission);

  @override
  Future<PermissionStatus> request(AppPermission permission) =>
      _invoke('request', permission);

  Future<PermissionStatus> _invoke(
    String method,
    AppPermission permission,
  ) async {
    final supported =
        isSupported?.call() ?? (Platform.isAndroid || Platform.isIOS);
    if (!supported) return PermissionStatus.unsupported;

    try {
      final raw = await _channel.invokeMapMethod<String, String>(
        method,
        <String, dynamic>{
          'names': <String>[permission.wireName],
        },
      );
      return PermissionStatus.parse(raw?[permission.wireName]);
    } on MissingPluginException {
      // 还没实现这条通道（比如测试环境、旧版本安装包）
      return PermissionStatus.unsupported;
    } on PlatformException catch (error) {
      // `busy`（另一个请求还在飞）也走这里：当「没拿到」，让调用方自己决定
      debugPrint('[权限] 通道调用失败：${error.code} ${error.message}');
      return PermissionStatus.unsupported;
    }
  }
}

final permissionGatewayProvider = Provider<PermissionGateway>(
  (ref) => const SystemPermissionGateway(),
);
