/// 打 **Windows 安装包**（Inno Setup 编译 `tool/installer/gracelink.iss`）。
///
/// 跑法（仓库根目录，先 `flutter build windows --release`）：
/// ```
/// dart run tool/installer/build_installer.dart
/// ```
/// 产物：`dist\Gracelink-Setup-<版本名>.exe`（版本名读 `pubspec.yaml`），
/// 这就是发给用户的**一个文件**：双击走一遍向导（协议 → 安装目录 → 附加任务），
/// 装到 `%LOCALAPPDATA%\Programs\Gracelink`，不要管理员权限。
///
/// 三步：**签程序本体** → Inno 编译（它自己把整个程序目录压进一个 exe）→
/// **签安装包并验签**。
///
/// **Inno Setup 不用你手工装**：脚本会找 `build\installer\inno\is\ISCC.exe`，
/// 没有就去 GitHub 下一份官方安装器、用 `/PORTABLE=1` 就地解开（不写注册表、
/// 不进「应用」列表）。想用自己的那一份（比如从 Inno Setup IDE 里编），把
/// `GRACELINK_ISCC` 指到 `ISCC.exe` 上就行。
///
/// > 许可证那件事：Inno Setup 的 LICENSE.TXT 允许商用，但作者**请求**商用用户
/// > 买一份许可（`https://jrsoftware.org/isorder.php`，一次性）。用不用它的决定
/// > 记在 `docs/release/windows-release.md`。
///
/// **代码签名**：配了证书就签，没配就打个「未签名」的提示接着走（内测包不需要
/// 签名）。怎么看自己配上没有、证书哪来 —— `docs/release/windows-release.md`，
/// 或直接看 `tool/release/signing.dart` 顶部那三种方式。
library;

import 'dart:io';

import '../release/signing.dart';

/// 用的 Inno Setup 版本，**钉住**：编译器的小版本会改行为（7 之前的 `x64compatible`
/// 之类的指令就不认识），自动下载就认这一版；换版本要顺手把 `gracelink.iss` 过一遍。
const String innoVersion = '7.1.0';

/// 官方发布在 GitHub（2026-03 起 jrsoftware.org 的文件地址换成 GitHub Releases 了）
const String innoDownloadUrl =
    'https://github.com/jrsoftware/issrc/releases/download/is-7_1_0/'
    'innosetup-7.1.0-x64.exe';

Future<void> main(List<String> args) async {
  final root = Directory.current.path;
  final pubspec = File('$root\\pubspec.yaml').readAsStringSync();
  final version = RegExp(
    r'^version:\s*(\S+)\s*$',
    multiLine: true,
  ).firstMatch(pubspec)?.group(1);
  if (version == null) {
    stderr.writeln('pubspec.yaml 里没读到 version');
    exit(1);
  }
  final versionName = version.split('+').first;
  stdout.writeln('版本：$version（安装包文件名用 $versionName）');

  final release = Directory('$root\\build\\windows\\x64\\runner\\Release');
  if (!release.existsSync()) {
    stderr.writeln('没找到 ${release.path}：先跑 flutter build windows --release');
    exit(1);
  }

  // 代码签名（2026-10-09）：没配证书照样能打内测包，但要**明说**这个包没签名
  SigningConfig? signing;
  try {
    signing = resolveSigning(
      Platform.environment,
      signTool: findSignTool(Platform.environment),
    );
  } on SigningConfigError catch (error) {
    stderr.writeln('✗ $error');
    stderr.writeln('  （配置方式见 docs/release/windows-release.md）');
    exit(1);
  }
  if (signing == null) {
    stdout.writeln('没配代码签名证书 → 这个包是**未签名**的：别人双击时');
    stdout.writeln('  Windows 会显示「未知发布者」（内测无妨；对外发布前请看');
    stdout.writeln('  docs/release/windows-release.md，拿到证书后重跑本脚本）');
  } else {
    stdout.writeln(
      '代码签名：${signing.source}'
      '${signing.strict ? '（严格验签，不过就报错）' : '（宽松：签名写进去即可）'}',
    );
  }

  // 先签**程序本体**：装到用户机器上、以后每次双击的就是它，没签的话每次启动
  // 都可能被 SmartScreen 拦一道。
  if (signing != null) {
    final appExe = File('${release.path}\\gracelinkim.exe');
    if (await _isSigned(appExe)) {
      stdout.writeln('1/3 程序本体已经签过名，跳过（要重签先 flutter build windows --release）');
    } else {
      stdout.writeln('1/3 签程序本体（gracelinkim.exe）…');
      await _sign(appExe, signing);
    }
  } else {
    stdout.writeln('1/3 跳过签名（没配证书）');
  }

  final iscc = await _ensureIscc(root);
  stdout.writeln('2/3 Inno 编译（这一步最慢：要把整个程序目录压进去）…');
  final iss = '$root\\tool\\installer\\gracelink.iss';
  await _run(iscc, <String>[
    '/Qp',
    '/DAppVersion=$versionName',
    // 路径里有空格的话，/D 的值要用引号包起来（用户把仓库放在「我的 文档」里时）
    release.path.contains(' ') ? '/DReleaseDir="${release.path}"' : '/DReleaseDir=${release.path}',
    iss,
  ]);
  final setup = File('$root\\dist\\Gracelink-Setup-$versionName.exe');
  if (!setup.existsSync()) {
    stderr.writeln('Inno 说编完了，但没看到 ${setup.path}（查一下 .iss 里的 OutputDir）');
    exit(1);
  }
  stdout.writeln('    ${_mb(setup.lengthSync())}：${setup.path}');

  // 最后才签安装包：**发出去的就是这一个文件**，用户双击时的「未知发布者」
  // 那一关看的就是它尾巴上这份签名。
  if (signing != null) {
    stdout.writeln('3/3 签安装包…');
    await _sign(setup, signing);
    await _verifySignature(setup, signing);
  } else {
    stdout.writeln('3/3 跳过签名（没配证书）');
  }

  stdout.writeln('产物：${setup.path}');
  stdout.writeln('别忘了：服务端 update.json 的版本 / 内部号 / 下载地址与这次对齐');
  if (signing == null) {
    stdout.writeln('（未签名：Windows 会显示「未知发布者」—— 内测可以，对外发布前要签）');
  }
}

/// 准备好 `ISCC.exe`：`GRACELINK_ISCC` → 缓存里那份 → 下一份官方的就地解开。
///
/// 为什么缓存而不是每次下：14MB 的东西每次打包都拉一遍没必要；缓存在
/// `build\` 下面（`flutter clean` 会清掉，正好，下次重新拿）。
Future<String> _ensureIscc(String root) async {
  final configured = Platform.environment['GRACELINK_ISCC']?.trim();
  if (configured != null && configured.isNotEmpty) {
    if (!File(configured).existsSync()) {
      stderr.writeln('GRACELINK_ISCC 指的 ISCC.exe 不在：$configured');
      exit(1);
    }
    stdout.writeln('用 GRACELINK_ISCC 指定的编译器：$configured');
    return configured;
  }

  final innoDir = Directory('$root\\build\\installer\\inno\\is');
  final cached = File('${innoDir.path}\\ISCC.exe');
  if (cached.existsSync()) {
    stdout.writeln('用缓存里的 Inno Setup：${cached.path}');
    return cached.path;
  }

  stdout.writeln('机器上没有 Inno Setup 编译器 → 下一份官方的（$innoVersion）就地解开');
  stdout.writeln('  $innoDownloadUrl');
  innoDir.createSync(recursive: true);
  final download = File('$root\\build\\installer\\inno\\innosetup-$innoVersion.exe');
  await _run('powershell', <String>[
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    'Invoke-WebRequest -UseBasicParsing -Uri ${_ps(innoDownloadUrl)} '
        '-OutFile ${_ps(download.path)}',
  ]);

  // `/PORTABLE=1`：官方安装器自己的开关，只解文件、不写注册表、不建卸载项
  final result = await Process.run(download.path, <String>[
    '/PORTABLE=1',
    '/VERYSILENT',
    '/SUPPRESSMSGBOXES',
    '/NORESTART',
    '/SP-',
    '/DIR=${innoDir.path}',
  ]);
  if (result.exitCode != 0 || !cached.existsSync()) {
    stderr.writeln('解 Inno Setup 没成功（退出码 ${result.exitCode}）');
    stderr.writeln('  也可以用你自己装的那份：set GRACELINK_ISCC=<ISCC.exe 的路径>');
    exit(1);
  }
  stdout.writeln('    解好了：${cached.path}');
  return cached.path;
}

/// 签一个文件：本地证书走 signtool，云签名服务走它自己的命令
/// （见 `tool/release/signing.dart` 里 [SigningConfig.signCommand] 那段说明）。
Future<void> _sign(File file, SigningConfig signing) async {
  if (!file.existsSync()) {
    stderr.writeln('要签的文件不在：${file.path}');
    exit(1);
  }
  if (signing.signCommand != null) {
    await _run(signing.signCommand!, signing.commandArgsFor(file.path));
  } else {
    await _run(signing.signTool, signing.signArgs(file.path));
  }
  stdout.writeln('    签好了：${file.path.split(RegExp(r'[\\/]')).last}');
}

/// 这个文件上已经有签名了吗。
///
/// 为什么要问：`flutter build` 出的程序本体是**不签名**的，但重复跑本脚本（不重编）
/// 会把名字一遍又一遍盖上去（signtool 默认是**追加**签名，最后文件上挂着一串），
/// 所以已经签过就跳过。
Future<bool> _isSigned(File file) async {
  if (!file.existsSync()) return false;
  final result = await Process.run('powershell', <String>[
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    '(Get-AuthenticodeSignature -LiteralPath ${_ps(file.path)}).Status',
  ]);
  final status = (result.stdout as String).trim();
  return result.exitCode == 0 && status.isNotEmpty && status != 'NotSigned';
}

/// 验签：`signtool verify /pa`（用 Authenticode 策略，默认策略会放过一些不该过的）。
///
/// 自签 / 内网证书在这条路上**一定**失败（信任链回不到受信任的根）—— 那不是 bug，
/// 所以默认只把结果说出来、不拦人；**对外发布那次请开 `GRACELINK_SIGN_STRICT=1`**，
/// 让验签不过就当场报错（见 `docs/release/windows-release.md`）。
Future<void> _verifySignature(File file, SigningConfig signing) async {
  if (signing.signCommand != null) {
    stdout.writeln('    云签名服务那条路自己不验签（用它的控制台看结果）');
    return;
  }
  final result = await Process.run(
    signing.signTool,
    signing.verifyArgs(file.path),
  );
  final output = '${result.stdout}${result.stderr}';
  final line = output
      .split(RegExp(r'\r?\n'))
      .map((part) => part.trim())
      .firstWhere((part) => part.isNotEmpty, orElse: () => '(没有输出)');
  if (result.exitCode == 0) {
    stdout.writeln('    验签通过：$line');
    return;
  }
  if (signing.strict) {
    stderr.writeln('    验签没过：$line');
    stderr.writeln('    （GRACELINK_SIGN_STRICT=1：验签不过就不发这个包）');
    exit(1);
  }
  stdout.writeln('    签名已写进文件，但验签没全绿：$line');
  stdout.writeln('    （自签 / 内网证书这样是正常的；公开分发的证书应该全绿）');
}

String _mb(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';

/// 跑一条命令；**看不成功就说清楚**（编译器的报错在 stdout 上，别吞了）。
Future<void> _run(String exe, List<String> args) async {
  final result = await Process.run(exe, args);
  stdout.write(result.stdout);
  if (result.exitCode != 0) {
    stderr.write(result.stderr);
    throw ProcessException(
      exe,
      args,
      '退出码 ${result.exitCode}',
      result.exitCode,
    );
  }
}

String _ps(String value) => "'${value.replaceAll("'", "''")}'";
