import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/data/model/app_update.dart';

/// 检查更新的纯逻辑（2026-10-08 换成静态清单那套）。
///
/// 三件事必须钉死：
/// * 四个系统各取各的那一格（取错就是「给我下 iOS 的包」）；
/// * 「没有 url 就是没有新版本」（老端那条规矩的延续）；
/// * 判定规则：两边都有内部号就**只比内部号**，本机内部号是 0（PC 现在读不到）
///   时退回比版本名。
void main() {
  /// 一份四端的清单（与用户放上去的那份同形状）
  Map<String, dynamic> manifest({
    int androidCode = 261009,
    String androidUrl = 'https://cdn.test/gracelink-1.0.1.apk',
    String androidVersion = '1.0.1',
    Object? ios = const <String, dynamic>{
      'version': '1.0.1',
      'code': 261009,
      'url': 'https://cdn.test/ios',
    },
    Object? windows = const <String, dynamic>{
      'version': '1.0.1',
      'code': 261009,
      'url': 'https://cdn.test/win.exe',
    },
    Object? macos = const <String, dynamic>{
      'version': '1.0.1',
      'code': 261009,
      'url': 'https://cdn.test/mac.dmg',
    },
  }) => <String, dynamic>{
    'android': <String, dynamic>{
      'version': androidVersion,
      'code': androidCode,
      'url': androidUrl,
    },
    'ios': ios,
    'windows': windows,
    'macos': macos,
  };

  group('平台 → 清单里哪一格', () {
    test('四个系统各归各的', () {
      expect(updatePlatformKeyOf(TargetPlatform.android), 'android');
      expect(updatePlatformKeyOf(TargetPlatform.iOS), 'ios');
      expect(updatePlatformKeyOf(TargetPlatform.windows), 'windows');
      expect(updatePlatformKeyOf(TargetPlatform.macOS), 'macos');
    });

    test('没发的平台（Linux 等）没有格子：空串', () {
      expect(updatePlatformKeyOf(TargetPlatform.linux), '');
      expect(updatePlatformKeyOf(TargetPlatform.fuchsia), '');
    });

    test('取那一格：字段齐全', () {
      final info = appUpdateEntryOf(manifest(), 'android');

      expect(info!.version, '1.0.1');
      expect(info.code, 261009);
      expect(info.url, 'https://cdn.test/gracelink-1.0.1.apk');
      expect(info.note, '');
      expect(info.force, isFalse);
    });

    test('取 iOS 那格拿到的不是安卓的地址', () {
      final info = appUpdateEntryOf(manifest(), 'ios');
      expect(info!.url, 'https://cdn.test/ios');
    });
  });

  group('哪些情况算「没有新版本」（返回 null）', () {
    test('平台上没有这个格子', () {
      expect(appUpdateEntryOf(manifest(), ''), isNull, reason: 'Linux 那种没格子');
      expect(appUpdateEntryOf(manifest(), 'linux'), isNull);
    });

    test('这一格没有 url（老端：没有 downloadUrl 就当没有新版本）', () {
      expect(
        appUpdateEntryOf(manifest(androidUrl: '   '), 'android'),
        isNull,
        reason: '只有空白也不算',
      );
      expect(appUpdateEntryOf(manifest(ios: null), 'ios'), isNull);
    });

    test('这一格不是对象（清单被改坏了）', () {
      expect(appUpdateEntryOf(manifest(ios: '1.0.1'), 'ios'), isNull);
      expect(
        appUpdateEntryOf(<String, dynamic>{'android': <String>[]}, 'android'),
        isNull,
      );
    });

    test('清单根本不是清单（比如拿到的是别的东西）', () {
      expect(appUpdateEntryOf(<String, dynamic>{}, 'android'), isNull);
    });
  });

  group('两个号：对外版本名 / 内部版本号', () {
    test('两边都有内部号：只比内部号', () {
      final info = appUpdateEntryOf(manifest(), 'android')!;

      expect(info.isNewerThan(version: '1.0.0', code: 261008), isTrue);
      expect(info.isNewerThan(version: '1.0.0', code: 261009), isFalse);
      expect(info.isNewerThan(version: '1.0.0', code: 261100), isFalse);
    });

    test('内部号说了算：版本名写得比本机旧也照样提示', () {
      final info = appUpdateEntryOf(
        manifest(androidVersion: '0.9.9', androidCode: 261009),
        'android',
      )!;

      expect(
        info.isNewerThan(version: '1.0.0', code: 261008),
        isTrue,
        reason: '内部号更大就是有新版本（版本名只用来显示）',
      );
    });

    test('本机内部号是 0（Windows/macOS 现在读不到）：退回比版本名', () {
      final info = appUpdateEntryOf(manifest(), 'windows')!;

      expect(info.isNewerThan(version: '1.0.0', code: 0), isTrue);
      expect(info.isNewerThan(version: '1.0.1', code: 0), isFalse);
    });

    test('清单里漏了内部号（手改漏了）：也退回比版本名，不当成“0 号最新”', () {
      final info = appUpdateEntryOf(
        <String, dynamic>{
          'android': <String, dynamic>{
            'version': '1.0.1',
            'url': 'https://cdn.test/a.apk',
          },
        },
        'android',
      )!;

      expect(info.code, 0);
      expect(info.isNewerThan(version: '1.0.0', code: 261008), isTrue);
    });

    test('字段类型宽一点也能认（数字写成字符串）', () {
      final info = appUpdateEntryOf(
        <String, dynamic>{
          'android': <String, dynamic>{
            'version': '1.0.1',
            'code': '261009',
            'url': 'https://cdn.test/a.apk',
          },
        },
        'android',
      )!;

      expect(info.code, 261009);
    });
  });

  group('版本名按段比大小', () {
    test('逐段比数字，不是比字符串', () {
      expect(compareVersionNames('1.0.10', '1.0.9'), greaterThan(0));
      expect(compareVersionNames('1.0.9', '1.0.10'), lessThan(0));
      expect(compareVersionNames('1.0.0', '1.0.0'), 0);
    });

    test('段数不齐的补 0（1.1 与 1.1.0 一样大）', () {
      expect(compareVersionNames('1.1', '1.1.0'), 0);
      expect(compareVersionNames('1.1.1', '1.1'), greaterThan(0));
    });

    test('拆段时只看开头的数字，别的字样不参与', () {
      expect(versionPartsOf('1.0.10'), <int>[1, 0, 10]);
      expect(versionPartsOf('v1.2.3'), <int>[1, 2, 3]);
      expect(versionPartsOf('1.0.0-beta'), <int>[1, 0, 0]);
      expect(versionPartsOf(''), <int>[0]);
    });
  });

  group('可选的更新说明与强制更新', () {
    test('note 支持分行；force 只认 true 那种写法', () {
      final info = appUpdateEntryOf(<String, dynamic>{
        'android': <String, dynamic>{
          'version': '1.0.1',
          'code': 261009,
          'url': 'https://cdn.test/a.apk',
          'note': '修复 A\n新增 B',
          'force': true,
        },
      }, 'android')!;

      expect(appUpdateLines(info.note), <String>['修复 A', '新增 B']);
      expect(info.force, isTrue);
    });

    test('note 为空时弹窗那段就整段不显示', () {
      expect(appUpdateLines(''), isEmpty);
      expect(appUpdateLines('  \n \n'), isEmpty);
    });

    test('force 写成别的（字符串 true / 1）也认', () {
      bool forceOf(Object? value) => appUpdateEntryOf(<String, dynamic>{
        'android': <String, dynamic>{
          'version': '1.0.1',
          'url': 'https://cdn.test/a.apk',
          'force': value,
        },
      }, 'android')!.force;

      expect(forceOf(true), isTrue);
      expect(forceOf('true'), isTrue);
      expect(forceOf(1), isTrue);
      expect(forceOf(false), isFalse);
      expect(forceOf(null), isFalse);
    });
  });
}
