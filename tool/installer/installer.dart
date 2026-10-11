/// **已停用（2026-10-09）**：安装包改成 Inno Setup 打（`tool/installer/gracelink.iss`，
/// 双击走正常向导：许可协议 → 选择安装位置 → 附加任务），构建脚本
/// `build_installer.dart` 现在调 ISCC 而不再编这个文件。
///
/// **为啥还留着它**：存量 —— 已经装过老版的机器上，安装目录里的卸载程序就是它；
/// 关于页「卸载恩信」按它的参数（`--silent`）拉起来的那条路要有人接着
/// （`lib/core/platform/app_uninstaller.dart` 先找 Inno 的 `unins000.exe`，
/// 找不到才回落到这个）。Inno 那版升级时会把它连同它的卸载项一起清掉
/// （`gracelink.iss` 里 [Code] 的 ssInstall）。
///
/// ---
///
/// **Windows 单文件安装器**（2026-10-08 用户要求：别再发一个文件夹，发一个 exe）。
///
/// 它自己就是「安装程序 + 安装包」：exe 尾巴上挂着整个 `Release` 目录的 zip
/// （见 [marker]，构建脚本 `build_installer.dart` 负责拼上去）。运行时：
///
/// 1. 把自己尾巴上那段 zip 抠出来（不整份读进内存，边读边写临时文件）；
/// 2. 停掉正在跑的 App（升级时它在运行，文件被占用换不掉）；
/// 3. 解压到安装目录（默认 `%LOCALAPPDATA%\Programs\Gracelink`，**用户目录、
///    不要管理员权限** —— 静默升级才不会弹 UAC）；
/// 4. 建开始菜单 / 桌面快捷方式、写控制面板的卸载项；
/// 5. 启动 App。
///
/// 用法：
/// * 双击 / `Gracelink-Setup-1.0.0.exe`              —— 装完就启动
/// * `--silent`                                      —— 静默升级（App 自己拉起来的那种）
/// * `--dir=D:\xxx`                                  —— 换安装目录
/// * `--no-launch`                                   —— 装完不启动（自检用）
/// * `--keep-app`                                    —— 不结束正在运行的 App
/// * 双击 `uninstall.exe`（或 `--uninstall`）         —— 卸载：干完弹一句「已卸载完成」
/// * `uninstall.exe --silent`                        —— 静默卸载（App 里「卸载恩信」用的，不弹框）
///
/// 「装」还是「卸」看两样：命令行开关，**或自己的文件名是不是 `uninstall.exe`**
/// —— 双击时没人传参，只认开关的话它会当成安装跑（用户看到的只有“点了没反应”）。
///
/// 卸载**不再问「确定吗」**（2026-10-08 用户报「点 uninstall.exe 根本没反应」）：
/// 确认框全靠 PowerShell 弹系统框，而那东西在不同环境下会**秒返回**或者
/// **创建一个隐藏窗口然后永远卡住**（实测都有），任何基于它的判断都会变成
/// 「什么都没发生」。改为：双击就卸，完事弹一句（弹不出来也不影响已经卸完）。
/// 「确定卸载吗」这道问由 **App 里那一栏「卸载恩信」**负责（见 `about_page.dart`）。
///
/// 为什么没有安装向导窗口：这个 exe 被编成 **Windows GUI 子系统**（构建脚本改的
/// PE 头），所以不会有黑框一闪；进度/确认借系统消息框弹（见 `_messageBox`）——
/// 卸载那一下必须让用户看得见。出问题时看 `%TEMP%\gracelink-setup.log`，退出码
/// 非 0 就是失败。要花哨的向导得上 Inno Setup / NSIS，那要先装外部工具。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// 版本号由构建脚本 -D 传进来（`pubspec.yaml` 的 version）
const String appVersion = String.fromEnvironment(
  'APP_VERSION',
  defaultValue: '0.0.0',
);

/// exe 尾巴上那段 zip 的分隔标记
const String marker = '~~GRACELINK-PAYLOAD-ZIP-V1~~';

const String appExeName = 'gracelinkim.exe';
const String uninstallExeName = 'uninstall.exe';
const String appDisplayName = 'Gracelink';
const String registryKey =
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\Gracelink';

Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  final log = _Log();
  final self = File(Platform.resolvedExecutable);
  final uninstall = options.uninstall || _baseName(self.path) == uninstallExeName;
  log.writeln('=== $appVersion ${uninstall ? '卸载' : '安装'}开始 ===');
  try {
    if (uninstall) {
      await _uninstall(options, self, log);
    } else {
      await _install(options, log);
    }
    log.writeln('=== 完成 ===');
    exit(0);
  } on Object catch (error, stack) {
    log.writeln('!!! 失败：$error\n$stack');
    // 静默模式不出声（App 那边自己会提示）；用户亲手点的要给个说法
    if (!options.silent) await _messageBox('操作没成功：$error', log);
    exit(1);
  }
}

// ---------------------------------------------------------------- 安装

Future<void> _install(_Options options, _Log log) async {
  final dir = options.dir ?? _defaultInstallDir();
  log.writeln('安装目录：$dir');

  if (!options.keepApp) await _killRunning(log);

  final self = File(Platform.resolvedExecutable);
  final payloadStart = await _findPayloadStart(self, log);
  final payload = await _spillPayloadToTemp(self, payloadStart, log);

  // 目录里全是我们自己的文件（用户数据在 AppData 里），所以先清空再解压 ——
  // 只覆盖不清理的话，上一版删掉的 DLL 会一直留着。
  final target = Directory(dir);
  if (target.existsSync()) {
    await _emptyDirectory(target, log);
  } else {
    target.createSync(recursive: true);
  }

  await _expandArchive(payload, dir, log);
  if (!File('$dir\\$appExeName').existsSync()) {
    throw StateError('解压完没看到 $appExeName，这个安装包不完整');
  }
  log.writeln('文件已就位');

  await _writeUninstaller(self, dir, payloadStart, log);
  await _createShortcut(_startMenuLinkPath(appDisplayName), dir, log);
  await _createShortcut(_desktopLinkPath(appDisplayName), dir, log);
  await _writeRegistry(dir, log);

  payload.deleteSync();

  if (!options.noLaunch) {
    log.writeln('启动 App');
    await Process.start(
      '$dir\\$appExeName',
      const <String>[],
      workingDirectory: dir,
      mode: ProcessStartMode.detached,
    );
  }
}

/// 把自己尾巴上那段 zip 抠到临时文件，返回它（边读边写，不整份进内存）。
Future<File> _spillPayloadToTemp(File self, int start, _Log log) async {
  final temp = File('${Directory.systemTemp.path}\\gracelink-payload-$pid.zip');
  final sink = temp.openWrite();
  await sink.addStream(self.openRead(start));
  await sink.flush();
  await sink.close();
  log.writeln('安装包已取出：${temp.path}（${temp.lengthSync()} 字节）');
  return temp;
}

/// 在**自己的可执行文件**里找那个标记，返回 zip 的第一个字节位置。
///
/// 有个坑：这个标记在文件里会出现**不止一次** —— `marker` 是编进去的字符串常量，
/// 它本身就躺在 stub 里（跟在后面的是字符串结尾，不是 zip）。所以这里要的是
/// 「最后一个、且后面紧接着 zip 头（`PK\x03\x04`）的那个」，那才是安装包的起点。
///
/// 分块扫描（块间留点重叠）：安装包几十兆，不该整份读进内存。
Future<int> _findPayloadStart(File self, _Log log) async {
  final needle = utf8.encode(marker);
  final magic = utf8.encode('PK\x03\x04');
  final raf = await self.open();
  try {
    final total = await raf.length();
    const chunk = 1 << 20;
    const overlap = 64;
    var start = -1;
    var offset = 0;
    while (offset < total) {
      await raf.setPosition(offset);
      final bytes = await raf.read(math.min(chunk + overlap, total - offset));
      if (bytes.length <= overlap) break;
      for (var i = 0; i + needle.length + magic.length <= bytes.length; i++) {
        if (!_matchesAt(bytes, i, needle)) continue;
        final tail = i + needle.length;
        if (!_matchesAt(bytes, tail, magic)) continue;
        start = offset + tail; // 记住最后一个（真安装包在文件尾巴上）
      }
      offset += bytes.length - overlap;
    }
    if (start >= 0) {
      log.writeln('安装包起点：$start（自己共 $total 字节）');
      return start;
    }
  } finally {
    await raf.close();
  }
  throw StateError('这个 exe 里没有安装包（它是从安装器里抠出来的 uninstaller？）');
}

bool _matchesAt(List<int> hay, int index, List<int> needle) {
  if (hay[index] != needle[0]) return false;
  for (var j = 1; j < needle.length; j++) {
    if (hay[index + j] != needle[j]) return false;
  }
  return true;
}

/// 结束正在跑的 App：升级的时候它占着要替换的 DLL，不换掉就会解压失败。
Future<void> _killRunning(_Log log) async {
  final result = await Process.run('taskkill', <String>[
    '/IM',
    appExeName,
    '/T',
    '/F',
  ]);
  log.writeln('taskkill：${result.exitCode}');
  // 文件锁不是立刻释放的，睡一下再解压
  await Future<void>.delayed(const Duration(milliseconds: 800));
}

/// 清空目录内容（删不掉的——比如还占用的文件——记一笔就算了）
Future<void> _emptyDirectory(Directory dir, _Log log) async {
  await for (final entity in dir.list(followLinks: false)) {
    try {
      entity.deleteSync(recursive: true);
    } on Object catch (error) {
      log.writeln('旧文件没删掉（忽略）：${entity.path} —— $error');
    }
  }
}

/// 解压（交给系统自带的 PowerShell `Expand-Archive`）。
///
/// 为什么不用 Dart 的 zip 库：这样这个安装器**不依赖任何外部工具包**，
/// 也不用往 App 的依赖里塞东西；49 个文件解压一两秒的事。
Future<void> _expandArchive(File zip, String dir, _Log log) async {
  await _runPowerShell(
    'Expand-Archive -LiteralPath ${_ps(zip.path)} '
    '-DestinationPath ${_ps(dir)} -Force',
    log,
  );
}

Future<void> _createShortcut(String link, String dir, _Log log) async {
  if (link.isEmpty) return;
  await _runPowerShell(
    r'$s = (New-Object -ComObject WScript.Shell).CreateShortcut(' +
        _ps(link) +
        r'); $s.TargetPath = ' +
        _ps('$dir\\$appExeName') +
        r'; $s.WorkingDirectory = ' +
        _ps(dir) +
        r'; $s.IconLocation = ' +
        _ps('$dir\\$appExeName,0') +
        r'; $s.Save()',
    log,
  );
}

/// 安装目录里那个卸载程序：就是**去掉尾巴的自己**（几十兆的安装包不用跟着走）
Future<void> _writeUninstaller(
  File self,
  String dir,
  int payloadStart,
  _Log log,
) async {
  final sink = File('$dir\\$uninstallExeName').openWrite();
  await sink.addStream(self.openRead(0, payloadStart));
  await sink.flush();
  await sink.close();
  log.writeln('卸载程序已写入');
}

/// 控制面板 › 程序和功能 里的那一行（写 HKCU，所以同样不用管理员）。
///
/// 用系统自带的 `reg.exe` 一条条写。为什么不走 PowerShell：注册表路径要写成
/// `HKCU:\Software\...`（带冒号的驱动器写法），写成 `HKCU\Software\...` 会被
/// 当成相对的文件路径，属性一个都写不进去（踩过）。
Future<void> _writeRegistry(String dir, _Log log) async {
  final exe = '$dir\\$appExeName';
  final values = <String, String>{
    'DisplayName': appDisplayName,
    'DisplayVersion': appVersion,
    'Publisher': appDisplayName,
    'InstallLocation': dir,
    'DisplayIcon': exe,
    'UninstallString': '"$dir\\$uninstallExeName" --uninstall',
    'QuietUninstallString': '"$dir\\$uninstallExeName" --uninstall',
    'NoModify': '1',
    'NoRepair': '1',
  };
  for (final entry in values.entries) {
    await _run('reg', <String>[
      'add',
      registryKey,
      '/v', entry.key,
      '/t', 'REG_SZ',
      '/d', entry.value,
      '/f',
    ], log);
  }
  log.writeln('卸载项已登记：$registryKey');
}

// ---------------------------------------------------------------- 卸载

/// 卸载：关 App → 删快捷方式 + 卸载项 + 目录里的文件 → 说声「已完成」→
/// 最后一个临时脚本把目录（含我们自己）删干净。
///
/// 为什么自己不整目录删掉：**Windows 不让删「正在运行的程序」所在的目录**，
/// 所以把自己那份留给收尾脚本。早先试过「先把自己拷到 TEMP 再接着卸」，
/// 但那种后台进程在有些环境里会被冻结在半路（踩过）——自己干完就退最稳。
Future<void> _uninstall(_Options options, File self, _Log log) async {
  // 装到 `--dir` 以外的地方时，卸载程序自己所在的目录就是安装目录
  final dir = options.dir ?? self.parent.path;
  log.writeln('卸载目录：$dir');

  if (!options.keepApp) await _killRunning(log);
  _deleteShortcuts(log);
  await _deleteRegistry(log);
  await _emptyOtherFiles(Directory(dir), self, log);

  if (!options.silent) await _messageBox('$appDisplayName 已卸载完成。', log);
  await _scheduleCleanup(dir, log);
}

/// 把安装目录里的东西删干净，**除开正在运行的自己**
Future<void> _emptyOtherFiles(Directory dir, File self, _Log log) async {
  if (!dir.existsSync()) return;
  final selfPath = self.path.toLowerCase();
  var left = 0;
  await for (final entity in dir.list(followLinks: false)) {
    if (entity.path.toLowerCase() == selfPath) continue;
    try {
      entity.deleteSync(recursive: true);
    } on Object catch (error) {
      left++;
      log.writeln('这个先没删掉（留给收尾脚本）：${entity.path} —— $error');
    }
  }
  log.writeln(left == 0 ? '文件已清空（只剩卸载程序自己）' : '还剩 $left 项，交给收尾脚本');
}

/// 让一个小脚本在我们退出、文件锁松开之后，把安装目录（含我们自己）删掉。
///
/// 两条要点都是踩出来的：
/// * 命令写成**脚本文件**，不是 `cmd /c` 的命令串（那种引号嵌套会让 cmd 自己
///   把引号吃掉，`rmdir` 什么都没删）；
/// * 它（以及它的 `wscript` 兄弟）的**工作目录必须挪到 TEMP**：双击时资源管理器
///   把当前目录设成安装目录，而 Windows 不允许删掉「某个进程的当前目录」——
///   两条腿都会静默失败，目录就永远留在那儿。
Future<void> _scheduleCleanup(String dir, _Log log) async {
  final clean = dir.replaceAll(RegExp(r'\\+$'), ''); // 结尾的 \ 会把引号转义掉
  final script = File('${Directory.systemTemp.path}\\gracelink-cleanup-$pid.cmd');
  script.writeAsStringSync(
    <String>[
      '@echo off',
      'ping -n 3 127.0.0.1 >nul', // 等卸载程序退出、文件锁松开
      'rmdir /s /q "${clean.replaceAll('"', '')}"',
      'del /f /q "%~f0" >nul 2>&1', // 删脚本自己
    ].join('\r\n'),
    flush: true,
  );
  log.writeln('收尾脚本：${script.path}');
  await Process.start(
    'cmd',
    <String>['/c', script.path],
    workingDirectory: Directory.systemTemp.path,
  );
}

void _deleteShortcuts(_Log log) {
  for (final link in <String>[
    _startMenuLinkPath(appDisplayName),
    _desktopLinkPath(appDisplayName),
  ]) {
    if (link.isEmpty) continue;
    try {
      File(link).deleteSync();
      log.writeln('快捷方式已删：$link');
    } on Object catch (error) {
      log.writeln('快捷方式没删掉（忽略）：$link —— $error');
    }
  }
}

Future<void> _deleteRegistry(_Log log) async {
  try {
    await _run('reg', <String>['delete', registryKey, '/f'], log);
    log.writeln('卸载项已删除');
  } on Object catch (error) {
    log.writeln('卸载项没删掉（忽略）：$error');
  }
}

// ---------------------------------------------------------------- 小工具

/// 弹一个系统消息框（没有窗口的安装器只能借 PowerShell）
///
/// 用 `WScript.Shell.Popup` 而不是 WPF 的 `MessageBox`：它有**自带超时**
/// （秒数到了自己关），所以即使没人点（或这个环境根本显示不了）也不会留下
/// 一个永远挂着的进程。这里是「通知」，不等它。
Future<void> _messageBox(String text, _Log log) async {
  try {
    await Process.start('powershell', <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      '\$w = New-Object -ComObject WScript.Shell; '
      '\$w.Popup(${_ps(text)}, 120, ${_ps(appDisplayName)}, 0) | Out-Null',
    ]);
  } on Object catch (error) {
    log.writeln('提示框没弹出来：$error');
  }
}

String _baseName(String path) => path.split(RegExp(r'[\\/]')).last;

String _defaultInstallDir() =>
    '${Platform.environment['LOCALAPPDATA']}\\Programs\\$appDisplayName';

String _startMenuLinkPath(String name) {
  final appData = Platform.environment['APPDATA'];
  if (appData == null || appData.isEmpty) return '';
  return '$appData\\Microsoft\\Windows\\Start Menu\\Programs\\$name.lnk';
}

String _desktopLinkPath(String name) {
  final profile = Platform.environment['USERPROFILE'];
  if (profile == null || profile.isEmpty) return '';
  return '$profile\\Desktop\\$name.lnk';
}

Future<void> _runPowerShell(String script, _Log log) async {
  await _run('powershell', <String>[
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-Command',
    // PowerShell 默认只「报错」不中断，退出码照样是 0 —— 装的时候就这样静默失败
    // 过一次（解压没干活，日志上却写着成功）。强制 Stop，让错误变成非零退出码。
    r"$ErrorActionPreference = 'Stop'; " + script,
  ], log);
}

/// 跑个外部命令，非 0 就抛（输出记进日志）
Future<void> _run(String exe, List<String> args, _Log log) async {
  final result = await Process.run(exe, args);
  final output = '${result.stdout}${result.stderr}'.trim();
  if (result.exitCode == 0) {
    if (output.isNotEmpty) log.writeln('$exe：$output');
    return;
  }
  log.writeln('$exe 出错（退出码 ${result.exitCode}）：\n$output');
  throw ProcessException(
    exe,
    args,
    '退出码 ${result.exitCode}',
    result.exitCode,
  );
}

/// PowerShell 单引号字符串：里面的单引号要写两遍
String _ps(String value) => "'${value.replaceAll("'", "''")}'";

/// 命令行参数
class _Options {
  const _Options({
    required this.silent,
    required this.uninstall,
    required this.noLaunch,
    required this.keepApp,
    this.dir,
  });

  final bool silent;
  final bool uninstall;
  final bool noLaunch;
  final bool keepApp;
  final String? dir;

  static _Options parse(List<String> args) {
    var silent = false;
    var uninstall = false;
    var noLaunch = false;
    var keepApp = false;
    String? dir;
    for (final arg in args) {
      final lower = arg.toLowerCase();
      if (lower == '--silent' || lower == '/s' || lower == '-s') {
        silent = true;
      } else if (lower == '--uninstall') {
        // 注意：**不**顺手置成静默 —— 控制面板点「卸载」跟双击一样，
        // 都该弹确认框与完成提示；要静默得明写 `--silent`
        uninstall = true;
      } else if (lower == '--no-launch') {
        noLaunch = true;
      } else if (lower == '--keep-app') {
        keepApp = true;
      } else if (lower.startsWith('--dir=')) {
        dir = arg.substring('--dir='.length).trim();
      }
    }
    return _Options(
      silent: silent,
      uninstall: uninstall,
      noLaunch: noLaunch,
      keepApp: keepApp,
      dir: dir == null || dir.isEmpty ? null : dir,
    );
  }
}

/// 往 `%TEMP%\gracelink-setup.log` 写一行行日志（没有窗口，出问题只能看它）
class _Log {
  late final File _file = File(
    '${Directory.systemTemp.path}\\gracelink-setup.log',
  );

  void writeln(String line) {
    final stamp = DateTime.now().toIso8601String();
    final text = '$stamp  $line';
    // **只写文件，绝不碰 stdout**（2026-10-08 的「双击没反应」就是因为这个）：
    // 这个 exe 是 GUI 子系统，从资源管理器双击时**没有控制台**，stdout 是个无效
    // 句柄；一往它写东西，失败是**异步**冒出来的（try 拦不住）—— 进程在启动后
    // 几百毫秒内被自己莫名带走，日志只留下两行。从终端跑就有 stdout，所以那种
    // 情况一直看起来是好的。
    try {
      _file.writeAsStringSync('$text\n', mode: FileMode.append, flush: true);
    } on Object {
      // 日志写不进去就算了，不能因为日志把安装弄挂
    }
  }
}
