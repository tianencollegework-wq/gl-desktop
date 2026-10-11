/// 检查更新的数据模型与纯逻辑（2026-10-08 换成**一份静态清单**）。
///
/// 老方案是 `POST /common/pub/checkVersion`：把本机版本上报给服务端，由服务端按
/// 平台分档回一条更新信息（`versionName`/`versionCode`/`updateType`/`downloadUrl`，
/// 还带 `.wgt` 资源包那一套）——用户原话「太乱」。新方案只有一个静态文件
/// （[updateManifestUrl]，见 `data/api/update_api.dart`），四个系统各一格：
///
/// ```json
/// {
///   "android": { "version": "1.0.1", "code": 2123, "url": "https://…/app.apk" },
///   "ios":     { "version": "1.0.1", "code": 2123, "url": "https://…" },
///   "windows": { "version": "1.0.1", "code": 2123, "url": "https://…" },
///   "macos":   { "version": "1.0.1", "code": 2123, "url": "https://…" }
/// }
/// ```
///
/// * 三样**必填**：`version`（对外版本名，弹窗里显示）、`code`（内部版本号，
///   整数，每次发版递增）、`url`（下载地址；**没有它就算没有新版本**）；
/// * 两样**可选**：`note`（更新说明，支持 `\n` 分行，不加就不显示那一段）、
///   `force`（`true` = 强制更新：弹窗没有「暂不升级」、下载不给取消）。
///
/// 有没有新版本（[AppUpdateInfo.isNewerThan]）：
/// * 本机与清单**都有内部号**（> 0）→ **只比内部号**（`2123 > 2122` 就是有新版本，
///   版本名写成一样也不会误判）；
/// * 本机内部号是 0 → 退回比版本名（[compareVersionNames]，`1.0.10 > 1.0.9`）。
///   为什么要有这条兜底：Windows / macOS 现在读不到自己包里的内部号
///   （`app_version.dart` 那条通道只有安卓有，PC 上拿到的是 `AppVersionInfo.fallback`
///   的 `code: 0`）——只认内部号的话，PC 上会**永远**提示有新版本。
library;

import 'package:flutter/foundation.dart' show TargetPlatform, immutable;

import '../../core/util/json_value.dart';

/// 服务端清单里的一格（一个平台的更新信息）
@immutable
class AppUpdateInfo {
  const AppUpdateInfo({
    required this.version,
    required this.code,
    required this.url,
    this.note = '',
    this.force = false,
  });

  /// 对外版本名（`1.0.1`）：弹窗里显示的就是它
  final String version;

  /// 内部版本号（整数，与 `pubspec.yaml` 里 `1.0.0+2122` 的加号后那一半同源）。
  /// 本机读不到时是 0（见 [isNewerThan] 的兜底）。
  final int code;

  /// 下载地址（安卓是 APK、桌面是 exe/dmg、iOS 一般是 App Store 链接）
  final String url;

  /// 更新说明（可空；弹窗里按行显示）
  final String note;

  /// 强制更新
  final bool force;

  /// 本机（[version] + [code]）比起来算不算新版本。
  ///
  /// 规则见文件头：两边都有内部号就只比内部号，否则退回比版本名。
  bool isNewerThan({required String version, required int code}) {
    if (this.code > 0 && code > 0) return this.code > code;
    return compareVersionNames(this.version, version) > 0;
  }

  @override
  String toString() =>
      'AppUpdateInfo($version+$code force=$force $url${note.isEmpty ? '' : ' note=${note.length}字'} )';

  @override
  bool operator ==(Object other) =>
      other is AppUpdateInfo &&
      other.version == version &&
      other.code == code &&
      other.url == url &&
      other.note == note &&
      other.force == force;

  @override
  int get hashCode => Object.hash(version, code, url, note, force);
}

/// 当前平台对应清单里的哪一格。
///
/// 只认清单里那四个系统（用户 2026-10-08 定的：安卓 / 苹果 / Windows / macOS）；
/// 其它平台（Linux 那种我们没发的）给空串 = 清单里没有它那一格。
String updatePlatformKeyOf(TargetPlatform platform) => switch (platform) {
  TargetPlatform.android => 'android',
  TargetPlatform.iOS => 'ios',
  TargetPlatform.windows => 'windows',
  TargetPlatform.macOS => 'macos',
  _ => '',
};

/// 从整份清单里取 [platformKey] 那一格。
///
/// 返回 null = **没有新版本可报**，三种情况都算：
/// * 清单里没有这个平台的格子（[platformKey] 是空串、或那个键缺失/不是对象）；
/// * 那一格里没有 `url`（老端那句「没有 downloadUrl 就是没有新版本」的延续：
///   服务端把地址撤了，就等于这次不发版）；
/// * 格子里的字段类型不对劲（[asText] / [asInt] 会宽松兜底，不会抛）。
AppUpdateInfo? appUpdateEntryOf(
  Map<String, dynamic> manifest,
  String platformKey,
) {
  if (platformKey.isEmpty) return null;
  final raw = manifest[platformKey];
  if (raw is! Map) return null;
  final entry = raw.cast<String, dynamic>();
  final url = asText(entry['url']).trim();
  if (url.isEmpty) return null;
  return AppUpdateInfo(
    version: asText(entry['version']).trim(),
    code: asInt(entry['code'], 0),
    url: url,
    note: asText(entry['note']),
    force: asBool(entry['force']),
  );
}

/// 版本名拆成数字段（`1.0.10` → `[1, 0, 10]`）。
///
/// 段里只取开头的连续数字（`1.0.0-beta` 的 `beta` 段算 0），认不出的段一律 0 ——
/// 这份清单是**用户手改的**，写错一个字符不该让「检查更新」整条挂掉。
List<int> versionPartsOf(String version) => version
    .split('.')
    .map((part) {
      final match = RegExp(r'^\D*(\d+)').firstMatch(part.trim());
      return match == null ? 0 : int.tryParse(match.group(1)!) ?? 0;
    })
    .toList();

/// 按段比版本名：`a` 新返回正数、`b` 新返回负数、一样返回 0。
///
/// 段数不齐的补 0（`1.1` 与 `1.1.0` 一样大），所以 `1.0.10 > 1.0.9`
/// （逐段比数字，不是字符串比大小）。
int compareVersionNames(String a, String b) {
  final left = versionPartsOf(a);
  final right = versionPartsOf(b);
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final x = i < left.length ? left[i] : 0;
    final y = i < right.length ? right[i] : 0;
    if (x != y) return x > y ? 1 : -1;
  }
  return 0;
}

/// 更新说明按行拆开（弹窗里逐行显示）
List<String> appUpdateLines(String note) => note
    .split(RegExp('\\r?\\n'))
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty)
    .toList();
