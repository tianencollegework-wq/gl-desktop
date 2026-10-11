import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/platform/app_version.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/data/api/update_api.dart';
import 'package:gracelinkim/data/repo/update_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/test_database.dart';

class _FakeVersionSource implements AppVersionSource {
  _FakeVersionSource(this.info);

  final AppVersionInfo info;

  @override
  Future<AppVersionInfo> read() async => info;
}

/// 检查更新的仓库（2026-10-08 起读静态清单）：
/// 读本机版本 → GET 那份 `update.json` → 取当前平台那一格 → 比自己这一份。
///
/// 走真实的 [UpdateApi] + 假 adapter，所以「请求的是哪个地址、是不是 GET、
/// 拿到别平台的格子会不会串台」这几件都在这里钉着。
void main() {
  late StubAdapter adapter;

  /// 挂着假 adapter 的那条 Dio。
  ///
  /// **不该用 `ApiClient` 那份 Dio**：它把 `validateStatus` 设成「永不抛」
  /// （服务端 500 也当成正常响应交给上层按 `code` 判），而清单没有信封、
  /// 非 2xx 必须是**错误**（否则一份 500 的错误页会被当成「没有新版本」）。
  /// 生产那份（`UpdateApi` 自己建的 Dio）就是默认行为，这里照着复现。
  UpdateRepository repositoryFor(AppVersionInfo local) => UpdateRepository(
    UpdateApi(Dio()..httpClientAdapter = adapter),
    _FakeVersionSource(local),
  );

  /// 服务端那份清单（`updateManifestUrl` 那个文件的内容）
  void manifestSays(Map<String, dynamic> entries) {
    adapter.responses[updateManifestUrl] = json.encode(entries);
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await CredentialStore.init();
    adapter = StubAdapter();
  });

  test('本机 1.0.0+261008、清单里安卓是 1.0.1+261009：报有新版本', () async {
    manifestSays(<String, dynamic>{
      'android': <String, dynamic>{
        'version': '1.0.1',
        'code': 261009,
        'url': 'https://message.gracelink.cc/gracelink-1.0.1.apk',
      },
      'ios': <String, dynamic>{
        'version': '1.0.0',
        'code': 261008,
        'url': 'https://message.gracelink.cc/ios',
      },
    });

    final info = await repositoryFor(
      const AppVersionInfo(name: '1.0.0', code: 261008),
    ).check(platform: TargetPlatform.android);

    expect(info!.version, '1.0.1');
    expect(info.code, 261009);
    expect(info.url, 'https://message.gracelink.cc/gracelink-1.0.1.apk');
    // 请求的是清单那个地址本身（不是拼在 API 域名下的接口）
    expect(adapter.paths, <String>[updateManifestUrl]);
  });

  test('清单里跟本机同一个号：没有新版本', () async {
    manifestSays(<String, dynamic>{
      'android': <String, dynamic>{
        'version': '1.0.0',
        'code': 261008,
        'url': 'https://message.gracelink.cc/gracelink-1.0.0.apk',
      },
    });

    expect(
      await repositoryFor(
        const AppVersionInfo(name: '1.0.0', code: 261008),
      ).check(platform: TargetPlatform.android),
      isNull,
    );
  });

  test('清单里安卓那格没动、iOS 那格更新了：安卓这边不该串台', () async {
    manifestSays(<String, dynamic>{
      'android': <String, dynamic>{
        'version': '1.0.0',
        'code': 261008,
        'url': 'https://message.gracelink.cc/gracelink-1.0.0.apk',
      },
      'ios': <String, dynamic>{
        'version': '1.1.0',
        'code': 261100,
        'url': 'https://message.gracelink.cc/ios-1.1.0',
      },
    });

    expect(
      await repositoryFor(
        const AppVersionInfo(name: '1.0.0', code: 261008),
      ).check(platform: TargetPlatform.android),
      isNull,
    );
  });

  test('Windows：本机内部号是 0，退回比版本名（1.0.1 > 1.0.0）', () async {
    manifestSays(<String, dynamic>{
      'windows': <String, dynamic>{
        'version': '1.0.1',
        'code': 261009,
        'url': 'https://message.gracelink.cc/Gracelink-Setup-1.0.1.exe',
      },
    });

    final info = await repositoryFor(
      const AppVersionInfo(name: '1.0.0', code: 0),
    ).check(platform: TargetPlatform.windows);

    expect(info!.version, '1.0.1');
  });

  test('本机内号 0 且版本名一样：没有新版本（PC 上不能永远提示）', () async {
    manifestSays(<String, dynamic>{
      'macos': <String, dynamic>{
        'version': '1.0.0',
        'code': 261008,
        'url': 'https://message.gracelink.cc/Gracelink-1.0.0.dmg',
      },
    });

    expect(
      await repositoryFor(
        const AppVersionInfo(name: '1.0.0', code: 0),
      ).check(platform: TargetPlatform.macOS),
      isNull,
    );
  });

  test('清单里那一格没有地址：当作没有新版本（界面提示「暂无新版本」）', () async {
    manifestSays(<String, dynamic>{
      'android': <String, dynamic>{'version': '1.0.1', 'code': 261009},
    });

    expect(
      await repositoryFor(
        const AppVersionInfo(name: '1.0.0', code: 261008),
      ).check(platform: TargetPlatform.android),
      isNull,
    );
  });

  test('没发的平台（Linux）：直接算没有新版本，连请求都不发', () async {
    expect(
      await repositoryFor(
        const AppVersionInfo(name: '1.0.0', code: 261008),
      ).check(platform: TargetPlatform.linux),
      isNull,
    );
    expect(adapter.paths, isEmpty);
  });

  test('拿不到清单（500 / 断网）把异常抛出去，由界面决定说不说话', () async {
    adapter.statusCodes[updateManifestUrl] = 500;

    await expectLater(
      () => repositoryFor(
        const AppVersionInfo(name: '1.0.0', code: 261008),
      ).check(platform: TargetPlatform.android),
      throwsA(anything),
    );
  });

  test('清单不是 JSON 对象（比如反代回了 HTML 错误页）：抛异常而不是当成没更新', () async {
    adapter.responses[updateManifestUrl] = '<html>502</html>';

    await expectLater(
      () => repositoryFor(
        const AppVersionInfo(name: '1.0.0', code: 261008),
      ).check(platform: TargetPlatform.android),
      throwsA(anything),
    );
  });
}
