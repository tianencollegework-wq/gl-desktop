import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/platform/app_version.dart';
import 'package:gracelinkim/data/api/update_api.dart';
import 'package:gracelinkim/data/model/app_update.dart';

/// 线上清单自检（**要联网**，所以放在 `tool/` 下：`flutter test` 跑全套时不会
/// 收它，手工跑才跑）：
///
/// ```
/// flutter test tool/probe/update_manifest_probe_test.dart
/// ```
///
/// 用途：你发新版、改完 `update.json` 之后，先在这里看一眼四个系统各自被认成了
/// 什么（有没有新版本、地址对不对），不用把 App 打开点一遍。
void main() {
  test('线上那份清单：四个系统都取得出来', () async {
    final manifest = await UpdateApi().fetchManifest();
    // ignore: avoid_print
    print('清单地址：$updateManifestUrl');
    // ignore: avoid_print
    print('顶层键：${manifest.keys.toList()}');

    const local = AppVersionInfo(name: '1.0.0', code: 261008);
    // ignore: avoid_print
    print('本机：${local.name}+${local.code}');

    var found = 0;
    for (final key in <String>['android', 'ios', 'windows', 'macos']) {
      final info = appUpdateEntryOf(manifest, key);
      if (info == null) {
        // ignore: avoid_print
        print('  $key：清单里没有这一格（或缺 url）→ 不提示更新');
        continue;
      }
      found++;
      // ignore: avoid_print
      print(
        '  $key：version=${info.version} code=${info.code} '
        '有新版本=${info.isNewerThan(version: local.name, code: local.code)} '
        'url=${info.url}',
      );
    }
    expect(found, 4, reason: '四个系统都该有自己那一格');
  });
}
