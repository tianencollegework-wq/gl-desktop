import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/config/app_info.dart';
import 'package:gracelinkim/domain/mine/profile_form.dart' show appVersion;

import '../../tool/release/bump_version.dart' show parseOptions;
import '../../tool/release/version.dart';

/// 版本号的**发版规范**（`docs/release/windows-release.md`）。
///
/// 规范的可执行版本是 `tool/release/version.dart`，CLI 是
/// `tool/release/bump_version.dart`；这份用例做两件事：
///
/// 1. **要求真工程自洽**：pubspec（真源头）与那两处 Dart 兜底常量、CHANGELOG
///    最新一条必须一致；
/// 2. **在一个临时工程上真跑一遍升版**（写 pubspec / 两个常量 / CHANGELOG），
///    再故意改坏一处看它报不报 —— 保证这套逻辑不是「只在自己仓库里碰巧过」。
void main() {
  test('真工程：pubspec / Dart 常量 / CHANGELOG 三处一致', () {
    expect(checkVersion(Directory.current.path), isEmpty);
  });

  test('真工程：Dart 里那两处常量与 pubspec 同号（不然同一台机器两个版本号）', () {
    final current = readPubspecVersion(Directory.current.path);
    expect(AppInfo.version, current.name, reason: '登录页底部「xxx for 版本」读的是它');
    expect(appVersion, current.name, reason: '关于页 / 设置页读的是它');
    expect(current.code.toString(), matches(RegExp(r'^\d{6}$')));
  });

  group('内部号：只增不减', () {
    test('今天比当前新 → 用今天', () {
      expect(nextCode(261008, DateTime(2026, 10, 9)), 261009);
    });

    test('同一天再发一版 → +1（不能停在今天，否则比较大小会判成没更新）', () {
      expect(nextCode(261009, DateTime(2026, 10, 9)), 261010);
    });

    test('系统时间往回跳（换机器 / 改表）→ 仍然 +1，不倒退', () {
      expect(nextCode(261009, DateTime(2026, 1, 5)), 261010);
    });
  });

  group('升哪一段', () {
    const current = ReleaseVersion('1.2.3', 261008);

    test('patch / minor / major', () {
      expect(
        nextVersion(
          current: current,
          bump: 'patch',
          now: DateTime(2026, 10, 9),
        ).full,
        '1.2.4+261009',
      );
      expect(
        nextVersion(
          current: current,
          bump: 'minor',
          now: DateTime(2026, 10, 9),
        ).full,
        '1.3.0+261009',
      );
      expect(
        nextVersion(
          current: current,
          bump: 'major',
          now: DateTime(2026, 10, 9),
        ).full,
        '2.0.0+261009',
      );
    });

    test('--build：只动内部号', () {
      expect(
        nextVersion(
          current: current,
          build: true,
          now: DateTime(2026, 10, 9),
        ).full,
        '1.2.3+261009',
      );
    });

    test('--set 明确指定，--code 可以压住内部号', () {
      expect(
        nextVersion(current: current, set: '1.1.0', code: 261015).full,
        '1.1.0+261015',
      );
    });

    test('写法不对就报错，不猜', () {
      expect(
        () => nextVersion(current: current, bump: '随便'),
        throwsA(isA<VersionError>()),
      );
      expect(
        () => nextVersion(current: current, set: '1.1'),
        throwsA(isA<VersionError>()),
      );
      expect(
        () => nextVersion(current: current, set: '1.1.1', code: 2610),
        throwsA(isA<VersionError>()),
        reason: '内部号必须 6 位（YYMMDD）',
      );
      expect(
        () => nextVersion(current: current),
        throwsA(isA<VersionError>()),
        reason: '什么都没说就该报错，而不是安静地什么都不做',
      );
    });
  });

  group('在一个临时工程上真跑一遍升版', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('gracelink-version');
      File('${root.path}/pubspec.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('name: fixture\nversion: 1.0.0+261008\n');
      File('${root.path}/${ReleaseFiles.appInfo}')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          "abstract final class AppInfo {\n"
          "  static const String name = 'Gracelink';\n"
          "  static const String version = '1.0.0';\n"
          "}\n",
        );
      File('${root.path}/${ReleaseFiles.profileForm}')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          "/// 版本号\nconst String appVersion = '1.0.0';\n",
        );
      File('${root.path}/${ReleaseFiles.changelog}').writeAsStringSync(
        '$changelogHead\n## 1.0.0 · 2026-10-08 · 261008\n\n- 首发\n',
      );
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('一开始是自洽的', () {
      expect(checkVersion(root.path), isEmpty);
    });

    test('applyVersion 四处都改到，CHANGELOG 新条目压在最上面', () {
      applyVersion(
        root: root.path,
        next: const ReleaseVersion('1.0.1', 261009),
        note: '修了登录页那个大弹窗',
        now: DateTime(2026, 10, 9),
      );

      expect(
        File('${root.path}/pubspec.yaml').readAsStringSync(),
        contains('version: 1.0.1+261009'),
      );
      expect(
        File('${root.path}/${ReleaseFiles.appInfo}').readAsStringSync(),
        contains("static const String version = '1.0.1';"),
      );
      expect(
        File('${root.path}/${ReleaseFiles.profileForm}').readAsStringSync(),
        contains("const String appVersion = '1.0.1';"),
      );

      final changelog =
          File('${root.path}/${ReleaseFiles.changelog}').readAsStringSync();
      final entries = changelogEntries(changelog);
      expect(entries.first.name, '1.0.1');
      expect(entries.first.code, 261009);
      expect(entries.first.date, '2026-10-09');
      expect(entries.length, 2, reason: '旧那条要留着（发版历史）');
      expect(changelog, contains('修了登录页那个大弹窗'));
      expect(
        changelog.indexOf('## 1.0.1'),
        lessThan(changelog.indexOf('## 1.0.0')),
      );

      expect(checkVersion(root.path), isEmpty, reason: '改完还得是自洽的');
    });

    test('把 Dart 常量改坏 → checkVersion 必须报出来（不是空转）', () {
      File('${root.path}/${ReleaseFiles.appInfo}')
          .writeAsStringSync(
            "abstract final class AppInfo {\n"
            "  static const String version = '9.9.9';\n"
            "}\n",
          );

      final problems = checkVersion(root.path);
      expect(problems, hasLength(1));
      expect(problems.single, contains('AppInfo.version'));
      expect(problems.single, contains('9.9.9'));
    });

    test('CHANGELOG 最新一条跟不上 pubspec → 也要报出来', () {
      File('${root.path}/pubspec.yaml')
          .writeAsStringSync('name: fixture\nversion: 1.0.2+261010\n');

      final problems = checkVersion(root.path);
      expect(problems.join('\n'), contains('CHANGELOG 最新一条'));
    });
  });

  group('命令行解析', () {
    test('--check', () {
      expect(parseOptions(<String>['--check']).check, isTrue);
    });

    test('--bump patch --note 说明', () {
      final options = parseOptions(<String>['--bump', 'patch', '--note', '一句话']);
      expect(options.bump, 'patch');
      expect(options.note, '一句话');
    });

    test('什么动作都没说 / 参数写错 → 报错（不静默地什么都不做）', () {
      expect(() => parseOptions(<String>[]), throwsA(isA<VersionError>()));
      expect(
        () => parseOptions(<String>['--bump']),
        throwsA(isA<VersionError>()),
        reason: '--bump 后面少了级别',
      );
      expect(
        () => parseOptions(<String>['--随便']),
        throwsA(isA<VersionError>()),
      );
    });
  });
}
