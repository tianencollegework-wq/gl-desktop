/// **版本号的读写与校验**（Gracelink 发版规范的可执行版本）。
///
/// 规范本身写在 `docs/release/windows-release.md`，这里只放「怎么读、怎么查、
/// 怎么改」——CLI 壳在 `bump_version.dart`，用例直接调这里的函数
/// （`test/release/version_consistency_test.dart`），两边走的是**同一份逻辑**。
///
/// 版本号只有一个真源头：`pubspec.yaml` 的 `version: 版本名+内部号`。其余几处
/// （安装包文件名、runner 的 `FLUTTER_VERSION` 资源）都从它派生；Dart 里那两个
/// 常量是「读不到本机版本时的兜底」，本文件负责让它们永远跟着 pubspec 走。
library;

import 'dart:io';

/// 改坏了的版本号（格式不对、各处不一致……）：一律**报错**，不猜
class VersionError implements Exception {
  VersionError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 一个版本号：`1.0.0+261009`
class ReleaseVersion {
  const ReleaseVersion(this.name, this.code);

  /// 对外版本名（`1.0.0`）：登录页底部、关于页、更新弹窗显示的都是它
  final String name;

  /// 内部号（`YYMMDD`，如 `261009` = 2026-10-09）：与更新清单 `update.json`
  /// 里的 `code`、安卓的 `versionCode` 同源
  final int code;

  String get full => '$name+$code';

  @override
  String toString() => full;
}

/// 版本号散落的几个文件（相对工程根）—— 读写都走这里，用例可以指向一个临时工程
abstract final class ReleaseFiles {
  static const String pubspec = 'pubspec.yaml';
  static const String changelog = 'CHANGELOG.md';

  /// `AppInfo.version`（登录页底部那行「Gracelink for 版本」）
  static const String appInfo = 'lib/core/config/app_info.dart';

  /// `profile_form.appVersion`（关于页 / 设置页）
  static const String profileForm = 'lib/domain/mine/profile_form.dart';
}

/// 从 pubspec 读版本号
ReleaseVersion readPubspecVersion(String root) {
  final file = File('$root/${ReleaseFiles.pubspec}');
  if (!file.existsSync()) {
    throw VersionError('找不到 ${file.path}');
  }
  final match = RegExp(
    r'^version:\s*(\S+)\s*$',
    multiLine: true,
  ).firstMatch(file.readAsStringSync());
  if (match == null) {
    throw VersionError('pubspec.yaml 里没读到 version:');
  }
  final value = match.group(1)!;
  final plus = value.indexOf('+');
  if (plus <= 0) {
    throw VersionError(
      'pubspec 的 version「$value」少了「+内部号」那一半（例：1.0.0+261009）',
    );
  }
  final code = int.tryParse(value.substring(plus + 1));
  if (code == null) {
    throw VersionError('pubspec 的 version「$value」里，加号后面不是整数');
  }
  return ReleaseVersion(value.substring(0, plus), code);
}

/// 查一遍这个工程：返回**所有问题**（空列表 = 全部自洽）。
///
/// 查四件事：
/// 1. 版本名是 `X.Y.Z`、内部号是合法的 6 位日期式（`YYMMDD`）；
/// 2. `AppInfo.version` 与 `profile_form.appVersion` 都等于 pubspec 的版本名；
/// 3. `CHANGELOG.md` 最新一条就是当前版本；
/// 4. CHANGELOG 往下走内部号只能越来越小（发版历史别乱序）。
List<String> checkVersion(String root) {
  final problems = <String>[];
  final current = readPubspecVersion(root);
  problems.addAll(_shapeProblems(current));

  for (final ref in _dartRefs(root)) {
    if (!File(ref.file.path).existsSync()) {
      problems.add('找不到 ${ref.file.path}（${ref.label}）');
      continue;
    }
    final value = ref.readValue();
    if (value != current.name) {
      problems.add(
        '${ref.label} 是「$value」，pubspec 是「${current.name}」'
        '（跑 --bump / --set 让它们对齐）',
      );
    }
  }

  final changelog = File('$root/${ReleaseFiles.changelog}');
  if (!changelog.existsSync()) {
    problems.add('CHANGELOG.md 不存在（发版历史得有地方记）');
    return problems;
  }
  final entries = changelogEntries(changelog.readAsStringSync());
  if (entries.isEmpty) {
    problems.add('CHANGELOG.md 里一条 `## 版本名 · 日期 · 内部号` 都没有');
    return problems;
  }
  final newest = entries.first;
  if (newest.name != current.name || newest.code != current.code) {
    problems.add(
      'CHANGELOG 最新一条是 ${newest.name}+${newest.code}，'
      'pubspec 是 ${current.full}',
    );
  }
  for (var i = 1; i < entries.length; i++) {
    if (entries[i].code > entries[i - 1].code) {
      problems.add(
        'CHANGELOG 顺序不对：${entries[i].name}+${entries[i].code} '
        '比它上面那条还新',
      );
    }
  }
  return problems;
}

/// 下一个内部号：今天（`YYMMDD`）；今天已经用过了就 +1（**只增不减**）
int nextCode(int current, DateTime now) {
  final today =
      (now.year % 100) * 10000 + now.month * 100 + now.day; // 2026-10-09 → 261009
  return today > current ? today : current + 1;
}

/// 算出下一个版本号。[set] 与 [bump] 二选一；[code] 不给就按 [nextCode] 推。
///
/// 抛 [VersionError]：版本名格式不对、`--bump` 的级别不认识、算出来的内部号不合法。
ReleaseVersion nextVersion({
  required ReleaseVersion current,
  String? set,
  String? bump,
  bool build = false,
  int? code,
  DateTime? now,
}) {
  var name = current.name;
  final parts = current.name.split('.').map(int.parse).toList();

  if (set != null) {
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(set)) {
      throw VersionError('--set 要的是三段数字（例：1.0.1），给的是「$set」');
    }
    name = set;
  } else if (bump != null) {
    switch (bump) {
      case 'major':
        parts[0] += 1;
        parts[1] = 0;
        parts[2] = 0;
      case 'minor':
        parts[1] += 1;
        parts[2] = 0;
      case 'patch':
        parts[2] += 1;
      default:
        throw VersionError('--bump 只认 major / minor / patch');
    }
    name = parts.join('.');
  } else if (!build) {
    throw VersionError(
      '没说要干什么：--check / --bump <级别> / --build / --set <版本名>',
    );
  }

  final next = ReleaseVersion(
    name,
    code ?? nextCode(current.code, now ?? DateTime.now()),
  );
  final problems = _shapeProblems(next);
  if (problems.isNotEmpty) {
    throw VersionError(problems.join('；'));
  }
  return next;
}

/// 把新版本号写进那几个文件，并在 CHANGELOG 顶部加一条。
void applyVersion({
  required String root,
  required ReleaseVersion next,
  String? note,
  DateTime? now,
}) {
  _writePubspecVersion(root, next);
  for (final ref in _dartRefs(root)) {
    ref.writeValue(next.name);
  }
  _prependChangelog(root, next, note, now ?? DateTime.now());
}

// ------------------------------------------------------------------ 内部

List<String> _shapeProblems(ReleaseVersion version) {
  final problems = <String>[];
  if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version.name)) {
    problems.add('版本名「${version.name}」不是 X.Y.Z 三段数字');
  }
  final digits = version.code.toString();
  if (digits.length != 6) {
    problems.add('内部号「${version.code}」不是 6 位（YYMMDD，例 261009）');
    return problems;
  }
  final year = 2000 + int.parse(digits.substring(0, 2));
  final month = int.parse(digits.substring(2, 4));
  final day = int.parse(digits.substring(4, 6));
  final parsed = DateTime(year, month, day);
  if (parsed.month != month || parsed.day != day) {
    problems.add('内部号「${version.code}」不是合法日期（YYMMDD）');
  }
  return problems;
}

void _writePubspecVersion(String root, ReleaseVersion version) {
  final file = File('$root/${ReleaseFiles.pubspec}');
  final text = file.readAsStringSync();
  var replaced = false;
  final updated = text.replaceFirstMapped(
    RegExp(r'^version:\s*\S+\s*$', multiLine: true),
    (match) {
      replaced = true;
      return 'version: ${version.full}';
    },
  );
  if (!replaced) {
    throw VersionError('pubspec.yaml 里没找到 version: 那一行，没改动任何文件');
  }
  file.writeAsStringSync(updated);
}

/// Dart 里那两处兜底常量
class _DartVersionRef {
  _DartVersionRef({
    required this.file,
    required this.pattern,
    required this.label,
  });

  final File file;
  final RegExp pattern;

  /// 出错时用的名字（`AppInfo.version`）
  final String label;

  String readValue() {
    final match = pattern.firstMatch(file.readAsStringSync());
    if (match == null) {
      throw VersionError('${file.path} 里没找到声明（$label），同步一下这个工具');
    }
    final text = match.group(0)!;
    return text.substring(text.indexOf("'") + 1, text.lastIndexOf("'"));
  }

  void writeValue(String version) {
    final text = file.readAsStringSync();
    var replaced = false;
    final updated = text.replaceFirstMapped(pattern, (match) {
      replaced = true;
      final original = match.group(0)!;
      final quote = original.indexOf("'");
      return '${original.substring(0, quote)}'
          "'$version'"
          '${original.substring(original.lastIndexOf("'") + 1)}';
    });
    if (!replaced) {
      throw VersionError('${file.path} 里没找到声明（$label），同步一下这个工具');
    }
    file.writeAsStringSync(updated);
  }
}

List<_DartVersionRef> _dartRefs(String root) => <_DartVersionRef>[
  _DartVersionRef(
    file: File('$root/${ReleaseFiles.appInfo}'),
    pattern: RegExp(r"static const String version = '[^']*';"),
    label: 'AppInfo.version',
  ),
  _DartVersionRef(
    file: File('$root/${ReleaseFiles.profileForm}'),
    pattern: RegExp(r"const String appVersion = '[^']*';"),
    label: 'profile_form.appVersion',
  ),
];

/// CHANGELOG 里的一条：`## 1.0.0 · 2026-10-09 · 261009`
class ChangelogEntry {
  const ChangelogEntry({
    required this.name,
    required this.date,
    required this.code,
  });

  final String name;

  /// `YYYY-MM-DD`
  final String date;

  final int code;
}

final RegExp _changelogHeading = RegExp(
  r'^## (\d+\.\d+\.\d+) · (\d{4}-\d{2}-\d{2}) · (\d{6})$',
  multiLine: true,
);

/// 把 CHANGELOG 里所有版本标题按出场顺序读出来（最新一条在最前）
List<ChangelogEntry> changelogEntries(String markdown) => _changelogHeading
    .allMatches(markdown)
    .map(
      (match) => ChangelogEntry(
        name: match.group(1)!,
        date: match.group(2)!,
        code: int.parse(match.group(3)!),
      ),
    )
    .toList();

void _prependChangelog(
  String root,
  ReleaseVersion version,
  String? note,
  DateTime now,
) {
  final file = File('$root/${ReleaseFiles.changelog}');
  final body = file.existsSync() ? file.readAsStringSync() : changelogHead;
  final stamp = '${now.year}-${_two(now.month)}-${_two(now.day)}';
  final bullet = (note == null || note.trim().isEmpty)
      ? '- （这一步改了什么，自己补一句）'
      : '- ${note.trim()}';
  final entry = '## ${version.name} · $stamp · ${version.code}\n\n$bullet\n\n';
  final firstHeading = _changelogHeading.firstMatch(body);
  final updated = firstHeading == null
      ? '$body\n$entry'
      : '${body.substring(0, firstHeading.start)}$entry'
            '${body.substring(firstHeading.start)}';
  file.writeAsStringSync(updated);
}

String _two(int value) => value.toString().padLeft(2, '0');

/// 没有 CHANGELOG 时先写这段头（格式会被 [checkVersion] 校验，别手改）
const String changelogHead = '''
# 更新日志

面向用户的版本历史。**标题行的格式由 `tool/release/bump_version.dart --check` 校验**
（`## 版本名 · YYYY-MM-DD · 内部号`），不要手改格式 —— 这个文件是发版规范的一部分，
不是随手记的笔记。版本号的含义、怎么升版、怎么发，见
`docs/release/windows-release.md`。
''';
