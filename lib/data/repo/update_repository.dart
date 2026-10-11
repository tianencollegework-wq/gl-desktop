import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/app_version.dart';
import '../api/update_api.dart';
import '../model/app_update.dart';

/// 检查更新（S7.2，2026-10-08 换成读静态清单）。
///
/// 三步：读本机版本 → 抓清单 → 取当前平台那一格比自己这一份。
/// 这里只回答「有没有新版本」，**怎么装**交给界面
/// （`features/mine/app_update_flow.dart`）。
class UpdateRepository {
  const UpdateRepository(this._api, this._versionSource);

  final UpdateApi _api;
  final AppVersionSource _versionSource;

  /// 查一次新版本。没有新版本返回 null。
  ///
  /// 判定规则（比内部号、以及内部号读不到时怎么退）全在
  /// [AppUpdateInfo.isNewerThan] 里，这里只负责把两边凑齐。
  Future<AppUpdateInfo?> check({required TargetPlatform platform}) async {
    final key = updatePlatformKeyOf(platform);
    if (key.isEmpty) return null;
    final current = await _versionSource.read();
    final manifest = await _api.fetchManifest();
    final info = appUpdateEntryOf(manifest, key);
    if (info == null) return null;
    return info.isNewerThan(version: current.name, code: current.code)
        ? info
        : null;
  }
}

final updateRepositoryProvider = Provider<UpdateRepository>(
  (ref) => UpdateRepository(
    ref.watch(updateApiProvider),
    ref.watch(appVersionSourceProvider),
  ),
);
