import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/platform/app_uninstaller.dart';

/// 一键卸载「挑哪个卸载程序、给什么参数」那条规则（2026-10-09 换 Inno 安装器时加的）。
///
/// 必须钉死三件事：
/// * **Inno 优先**：新版装的目录里有 `unins000.exe`，参数是 Inno 那一套；
/// * **老那份还能用**：存量用户目录里只有 `uninstall.exe`，参数是它自己的 `--silent`
///   （给错参数 = 点了没反应）；
/// * **都没有就不是安装版**：开发目录里直接跑 `build\...\Release` 要落到 null
///   （关于页那一栏不显示，免得在开发机上把源码目录删了）。
void main() {
  /// 一个「目录里有哪些文件」的替身：只认列出来的名字，大小写按 Windows 那样不分
  bool Function(String) onlyThese(Set<String> names) =>
      (path) => names
          .map((name) => name.toLowerCase())
          .contains(path.split(RegExp(r'[\\/]')).last.toLowerCase());

  group('挑哪一份', () {
    test('新装的（Inno）：用 unins000.exe + Inno 那套参数', () {
      final choice = pickUninstaller(
        r'C:\Users\me\AppData\Local\Programs\Gracelink',
        fileExists: onlyThese(<String>{'unins000.exe', 'gracelinkim.exe'}),
      );

      expect(
        choice!.path,
        r'C:\Users\me\AppData\Local\Programs\Gracelink\unins000.exe',
      );
      expect(choice.args, <String>['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART']);
    });

    test('老自研安装器装的：回落 uninstall.exe + --silent', () {
      final choice = pickUninstaller(
        r'C:\Users\me\AppData\Local\Programs\Gracelink',
        fileExists: onlyThese(<String>{'uninstall.exe', 'gracelinkim.exe'}),
      );

      expect(
        choice!.path,
        r'C:\Users\me\AppData\Local\Programs\Gracelink\uninstall.exe',
      );
      expect(choice.args, <String>['--silent']);
    });

    test('两个都在（升级装到一半的目录）：Inno 那个说了算', () {
      final choice = pickUninstaller(
        r'C:\Programs\Gracelink',
        fileExists: onlyThese(<String>{'unins000.exe', 'uninstall.exe'}),
      );

      expect(choice!.path, endsWith('unins000.exe'));
      expect(choice.args.first, '/SILENT');
    });

    test('都没有（开发目录 / 绿色版）：null —— 关于页那一栏不显示', () {
      expect(
        pickUninstaller(
          r'D:\coding\flutter\gracelinkim\build\windows\x64\runner\Release',
          fileExists: onlyThese(<String>{'gracelinkim.exe', 'flutter_windows.dll'}),
        ),
        isNull,
      );
    });

    test('目录末尾带反斜杠也不拼出双斜杠', () {
      final choice = pickUninstaller(
        r'C:\Programs\Gracelink\',
        fileExists: onlyThese(<String>{'unins000.exe'}),
      );

      expect(choice!.path, r'C:\Programs\Gracelink\unins000.exe');
    });
  });
}
