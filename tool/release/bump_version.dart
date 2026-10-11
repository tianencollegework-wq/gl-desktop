/// **版本号管理**的命令行壳（Gracelink 发版规范）。
///
/// 逻辑全在 `tool/release/version.dart` 里（那份能被用例直接测），这里只负责
/// 解析参数、打印人看的话、决定退出码。规范本身见 `docs/release/windows-release.md`。
///
/// ```bash
/// # 发版前自查（CI 与用例都跑它）
/// dart run tool/release/bump_version.dart --check
///
/// # 收一个补丁版：1.0.0 → 1.0.1，内部号自动改成今天（同一天再发就 +1）
/// dart run tool/release/bump_version.dart --bump patch --note "修了登录页弹窗字号"
///
/// # 只重新盖内部号（同一天多次打包 / 重发）
/// dart run tool/release/bump_version.dart --build
///
/// # 明确指定
/// dart run tool/release/bump_version.dart --set 1.1.0 --code 261015
/// ```
///
/// 它一次改四处：`pubspec.yaml`（真源头）、`AppInfo.version`、`profile_form.dart`
/// 里的 `appVersion`（这两处是「读不到本机版本时的兜底」）、以及 `CHANGELOG.md`。
library;

import 'dart:io';

import 'version.dart';

Future<void> main(List<String> args) async {
  try {
    await _run(args);
  } on VersionError catch (error) {
    stderr.writeln('✗ ${error.message}');
    exit(1);
  }
}

Future<void> _run(List<String> args) async {
  final root = projectRoot();
  final options = parseOptions(args);
  final current = readPubspecVersion(root);

  if (options.check) {
    final problems = checkVersion(root);
    stdout.writeln('版本：${current.full}');
    if (problems.isEmpty) {
      stdout.writeln('✓ pubspec / Dart 常量 / CHANGELOG 三处一致，格式也合规');
      return;
    }
    for (final problem in problems) {
      stdout.writeln('✗ $problem');
    }
    throw VersionError('版本号有 ${problems.length} 处对不上（上面那些 ✗）');
  }

  final next = nextVersion(
    current: current,
    set: options.set,
    bump: options.bump,
    build: options.build,
    code: options.code,
  );
  applyVersion(root: root, next: next, note: options.note);

  stdout.writeln('${current.full} → ${next.full}');
  stdout.writeln(
    '  改了：pubspec.yaml / AppInfo.version / profile_form.appVersion / CHANGELOG.md',
  );
  stdout.writeln(
    '  提醒：安装包文件名会变成 Gracelink-Setup-${next.name}.exe；'
    '服务端 update.json 里的 version / code 记得同步改成 '
    '${next.name} / ${next.code}',
  );
}

/// 命令行参数（导出来是为了让用例也能钉住解析本身：认不认得出、报不报错）
class Options {
  const Options({
    required this.check,
    required this.build,
    this.bump,
    this.set,
    this.code,
    this.note,
  });

  final bool check;
  final bool build;
  final String? bump;
  final String? set;
  final int? code;
  final String? note;
}

Options parseOptions(List<String> args) {
  var check = false;
  var build = false;
  String? bump;
  String? set;
  int? code;
  String? note;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--check':
        check = true;
      case '--build':
        build = true;
      case '--bump':
        bump = _value(args, ++i, '--bump');
      case '--set':
        set = _value(args, ++i, '--set');
      case '--code':
        code = int.tryParse(_value(args, ++i, '--code'));
        if (code == null) throw VersionError('--code 要一个整数');
      case '--note':
        note = _value(args, ++i, '--note');
      default:
        throw VersionError('不认识的参数「${args[i]}」（看文件头那段用法）');
    }
  }
  if (!check && !build && bump == null && set == null) {
    throw VersionError(
      '得说一个动作：--check / --build / --bump <级别> / --set <版本名>',
    );
  }
  return Options(
    check: check,
    build: build,
    bump: bump,
    set: set,
    code: code,
    note: note,
  );
}

String _value(List<String> args, int index, String name) {
  if (index >= args.length) throw VersionError('$name 后面要跟一个值');
  return args[index];
}

/// 工程根目录：从本脚本所在目录**往上找 `pubspec.yaml`**。
///
/// 为什么不按「往上退两级」算：Linux / macOS 下退两级对，Windows 上因为盘符
/// （`D:`）也算一段，同样退两级会变成 `…\tool`（一开始就这么错的，用例当场抓住）。
/// 也不看 `Directory.current`：这个工具会被用例从别处拉起，靠 cwd 找文件容易改错仓库。
String projectRoot() {
  final separator = Platform.pathSeparator;
  var dir = Directory.current;
  if (Platform.script.scheme == 'file') {
    dir = File(Platform.script.toFilePath()).parent;
  }
  for (var i = 0; i < 8; i++) {
    final marker = File(<String>[dir.path, ReleaseFiles.pubspec].join(separator));
    if (marker.existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current.path;
}
