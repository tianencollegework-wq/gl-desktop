import 'package:gracelinkim/core/platform/app_permissions.dart';

/// 权限通道的替身：答案可读可改，调用次数记着。
///
/// [afterRequest] 用来模拟「第一次问被拒、弹系统框时用户点了允许」那一下 ——
/// 不填就是「问完还是老样子」。
class FakePermissionGateway implements PermissionGateway {
  FakePermissionGateway({
    this.status = PermissionStatus.granted,
    this.afterRequest,
  });

  /// `check` 的答案（也是 `request` 之前的答案）
  PermissionStatus status;

  /// `request` 之后的答案（不填 = 不发生改变）
  PermissionStatus? afterRequest;

  int checks = 0;
  int requests = 0;

  /// 每次调用要的是哪个权限（顺序有意义：通话那条先麦克风后摄像头）
  final List<AppPermission> checked = <AppPermission>[];
  final List<AppPermission> requested = <AppPermission>[];

  @override
  Future<PermissionStatus> check(AppPermission permission) async {
    checks += 1;
    checked.add(permission);
    return status;
  }

  @override
  Future<PermissionStatus> request(AppPermission permission) async {
    requests += 1;
    requested.add(permission);
    final next = afterRequest;
    if (next != null) status = next;
    return status;
  }
}
