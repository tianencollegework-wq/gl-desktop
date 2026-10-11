import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 一键卸载（桌面安装版）。
///
/// 抽成接口的理由与 `MediaSaver` / `AppInstaller` 一样：拉起外部程序、然后结束
/// 自己这件事在单测里跑不了，而「什么情况下能卸、卸不了怎么说话」必须能钉住。
///
/// 这东西为什么需要：卸载程序藏在安装目录里（
/// `%LOCALAPPDATA%\Programs\Gracelink`），普通用户根本找不到 —— 桌面端「关于」页
/// 给一个入口，用户 2026-10-08 要的「在版本更新下面再加一栏卸载恩信」。
///
/// **2026-10-09 起换成了 Inno 版安装器**（见 `tool/installer/gracelink.iss`），
/// 它的卸载程序叫 `unins000.exe`、参数是 Inno 那一套（`/SILENT` 等）；
/// 老自研安装器（`tool/installer/installer.dart`，已停用）装的那批用户目录里
/// 躺着的是 `uninstall.exe`、参数是 `--silent` —— 两个都认，谁在就用谁
/// （规则钉在 [pickUninstaller] 里）。
abstract interface class AppUninstaller {
  /// 这一份能不能一键卸载：**只有 Windows 安装版**能。
  ///
  /// 判定看脚下有没有卸载程序（开发目录里直接跑 `build\...\Release` 就没有，
  /// 那一栏也就不显示 —— 免得在开发机上把源码目录删了）。
  bool get isAvailable;

  /// 拉起卸载程序（它会关掉 App、删掉安装目录），返回是不是真的拉起来了。
  ///
  /// 拉起来之后**自己的进程很快就不在了**（实现里会退出），调用方不用管后续界面。
  Future<bool> uninstall();
}

/// Inno 版安装器（`tool/installer/gracelink.iss`）留下的卸载程序名
const String innoUninstallerName = 'unins000.exe';

/// 老自研安装器（`tool/installer/installer.dart`，已停用）留下的卸载程序名
const String legacyUninstallerName = 'uninstall.exe';

/// 选中的那个卸载程序：文件路径 + 该给它什么参数
class UninstallerChoice {
  const UninstallerChoice({required this.path, required this.args});

  final String path;
  final List<String> args;
}

/// 在 [dir] 里挑卸载程序：**Inno 那份优先**，其次是老自研那版；都没有 = null
/// （不是安装版，关于页那一栏不显示）。
///
/// 为什么抽成纯函数（不直接摸 `Platform.resolvedExecutable`）：这条「挑哪个 +
/// 给什么参数」是唯一容易错的地方 —— 挑错了要么卸不掉，要么参数给错
/// （Inno 认 `/SILENT`，老那份认 `--silent`），所以它得能在单测里钉住。
/// [fileExists] 是给用例的替身（默认问真的文件系统）。
UninstallerChoice? pickUninstaller(
  String dir, {
  bool Function(String path)? fileExists,
}) {
  final exists = fileExists ?? (String path) => File(path).existsSync();
  String under(String name) =>
      dir.endsWith('\\') || dir.endsWith('/') ? '$dir$name' : '$dir\\$name';

  // Inno 版：静默跑（App 自己已经问过「确定卸载吗」，不用再弹一次；
  // `/SUPPRESSMSGBOXES` 顺手把「已卸载完成」那个系统框也按下），但**留进度窗口** ——
  // 卸载要一两秒，什么都没发生会让人以为没卸掉。
  final inno = under(innoUninstallerName);
  if (exists(inno)) {
    return UninstallerChoice(
      path: inno,
      args: const <String>['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART'],
    );
  }

  // 老自研安装器那份（存量用户）：它自己的开关，不弹框
  final legacy = under(legacyUninstallerName);
  if (exists(legacy)) {
    return UninstallerChoice(path: legacy, args: const <String>['--silent']);
  }

  return null;
}

class SystemAppUninstaller implements AppUninstaller {
  /// 卸载程序就在自己旁边：与 App 主程序同一个目录
  UninstallerChoice? get _uninstaller {
    if (!Platform.isWindows) return null;
    return pickUninstaller(File(Platform.resolvedExecutable).parent.path);
  }

  @override
  bool get isAvailable => _uninstaller != null;

  @override
  Future<bool> uninstall() async {
    final found = _uninstaller;
    if (found == null) return false;
    try {
      await Process.start(
        found.path,
        found.args,
        mode: ProcessStartMode.detached,
      );
    } on Object catch (error) {
      debugPrint('[卸载] 卸载程序没能拉起来：$error');
      return false;
    }
    // 卸载程序会把我们关掉（Inno 那边是 [Code] 里的 taskkill；老那份是同样的做法）；
    // 自己体面地先退，别让它动手
    await Future<void>.delayed(const Duration(milliseconds: 900));
    exit(0);
  }
}

final appUninstallerProvider = Provider<AppUninstaller>(
  (ref) => SystemAppUninstaller(),
);
