import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/release/signing.dart';

/// 代码签名那条流水线的**配置与参数**（`tool/release/signing.dart`）。
///
/// 为什么盯这个而不是盯「签完的结果」：真正签一次要一张证书 + Windows SDK，
/// 而这条链里最容易写错、也最不容易被发现的就是**拼出来的命令行**（少一个
/// `/fd sha256`、时间戳服务器写错、两个证书来源同时给）—— 那些错误在签名那一步
/// 会静悄悄地「看起来成功了」，或者在别人机器上才炸。这里把它们钉死在用例里。
///
/// 端到端那一段（真拿证书签出来、再核验签名）用自签证书手动跑过，
/// 步骤见 `docs/release/windows-release.md`。
void main() {
  group('没配证书：走未签名那条路', () {
    test('环境变量干干净净 → 返回 null（调用方打印「未签名」提示）', () {
      expect(resolveSigning(<String, String>{}, signTool: 'signtool.exe'), isNull);
    });

    test('只给了口令没给证书 → 报错（不然会静悄悄打出个未签名的包）', () {
      expect(
        () => resolveSigning(<String, String>{
          'GRACELINK_SIGN_PFX_PASSWORD': 'hunter2',
        }, signTool: 'signtool.exe'),
        throwsA(isA<SigningConfigError>()),
      );
    });

    test('空白字符串当没给', () {
      expect(
        resolveSigning(<String, String>{'GRACELINK_SIGN_PFX': '   '},
            signTool: 'signtool.exe'),
        isNull,
      );
    });
  });

  group('配了证书：读进配置', () {
    late Directory temp;
    late File pfx;
    late String pfxPath;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('gracelink-sign');
      pfx = File('${temp.path}/gracelink.pfx')..writeAsStringSync('fake');
      pfxPath = pfx.path;
    });

    tearDown(() => temp.deleteSync(recursive: true));

    test('.pfx 那一套：路径、口令、时间戳、严格模式都读进来', () {
      final config = resolveSigning(<String, String>{
        'GRACELINK_SIGN_PFX': pfxPath,
        'GRACELINK_SIGN_PFX_PASSWORD': 'hunter2',
        'GRACELINK_SIGN_STRICT': '1',
      }, signTool: 'C:\\sdk\\signtool.exe')!;

      expect(config.enabled, isTrue);
      expect(config.pfxPath, pfxPath);
      expect(config.pfxPassword, 'hunter2');
      expect(config.timestampUrl, defaultTimestampUrl);
      expect(config.strict, isTrue);
      expect(config.source, contains('.pfx'));
    });

    test('签名库里的证书：给指纹那条路', () {
      final config = resolveSigning(<String, String>{
        'GRACELINK_SIGN_CERT_SHA1': ' ABCDEF0123 ',
        'GRACELINK_SIGN_TIMESTAMP_URL': 'http://ts.example.test',
      }, signTool: 'signtool.exe')!;

      expect(config.certSha1, 'ABCDEF0123', reason: '两边空白要去掉');
      expect(config.timestampUrl, 'http://ts.example.test');
      expect(config.pfxPath, isNull);
      expect(config.strict, isFalse, reason: '没写就是宽松');
    });

    test('证书文件不存在 → 报错（路径写错了不该拖到签名那一步）', () {
      expect(
        () => resolveSigning(<String, String>{
          'GRACELINK_SIGN_PFX': r'D:\没这个文件.pfx',
        }, signTool: 'signtool.exe'),
        throwsA(isA<SigningConfigError>()),
      );
    });

    test('两个来源同时给 → 报错（签的是哪张说不清）', () {
      expect(
        () => resolveSigning(<String, String>{
          'GRACELINK_SIGN_PFX': pfxPath,
          'GRACELINK_SIGN_CERT_SHA1': 'ABCDEF',
        }, signTool: 'signtool.exe'),
        throwsA(isA<SigningConfigError>()),
      );
    });

    test('没有 signtool 也没给云签名命令 → 报错（并告诉去哪装）', () {
      expect(
        () => resolveSigning(<String, String>{
          'GRACELINK_SIGN_PFX': pfxPath,
        }),
        throwsA(
          isA<SigningConfigError>().having(
            (error) => error.message,
            'message',
            contains('signtool'),
          ),
        ),
      );
    });

    test('云签名命令：给了它就不需要 signtool', () {
      final command = File('${temp.path}/sign-azure.cmd')
        ..writeAsStringSync('@echo off');
      final config = resolveSigning(<String, String>{
        'GRACELINK_SIGN_COMMAND': command.path,
      })!;

      expect(config.enabled, isTrue);
      expect(config.signTool, isEmpty);
      expect(config.source, contains('云签名'));
    });
  });

  group('signtool 的命令行', () {
    const config = SigningConfig(
      signTool: 'signtool.exe',
      pfxPath: r'D:\secrets\gracelink.pfx',
      pfxPassword: 'pw',
    );

    test('.pfx：摘要算法 + 证书 + 时间戳，一个都不能少', () {
      expect(config.signArgs(r'D:\dist\Gracelink-Setup-1.0.0.exe'), <String>[
        'sign',
        '/fd',
        'sha256',
        '/d',
        'Gracelink',
        '/f',
        r'D:\secrets\gracelink.pfx',
        '/p',
        'pw',
        '/tr',
        defaultTimestampUrl,
        '/td',
        'sha256',
        r'D:\dist\Gracelink-Setup-1.0.0.exe',
      ]);
    });

    test('证书库指纹：用 /sha1，不出现 /f', () {
      const byDigest = SigningConfig(
        signTool: 'signtool.exe',
        certSha1: 'ABCDEF',
      );
      final args = byDigest.signArgs('setup.exe');
      expect(args, contains('/sha1'));
      expect(args, contains('ABCDEF'));
      expect(args, isNot(contains('/f')));
      expect(args.last, 'setup.exe');
    });

    test('/d 那行描述就是产品名（UAC 上显示它）', () {
      expect(config.signArgs('a.exe'), contains('Gracelink'));
    });

    test('验签用 /pa（默认策略会放过一些不该过的）', () {
      expect(config.verifyArgs('setup.exe'), <String>[
        'verify',
        '/pa',
        '/v',
        'setup.exe',
      ]);
    });

    test('云签名：{file} 会被替换；没有占位符就追加在尾巴上', () {
      const withPlaceholder = SigningConfig(
        signTool: '',
        signCommand: 'sign.cmd /in={file} /out={file}',
      );
      expect(withPlaceholder.commandArgsFor('a.exe'), <String>[
        'sign.cmd /in=a.exe /out=a.exe',
      ]);
      const without = SigningConfig(signTool: '', signCommand: 'sign.cmd');
      expect(without.commandArgsFor('a.exe'), <String>['sign.cmd', 'a.exe']);
    });
  });

  group('找 signtool.exe', () {
    late Directory kits;

    setUp(() {
      kits = Directory.systemTemp.createTempSync('gracelink-kits');
    });

    tearDown(() => kits.deleteSync(recursive: true));

    void fakeKits(String version) {
      final dir = Directory('${kits.path}/$version/x64')..createSync(recursive: true);
      File('${dir.path}/signtool.exe').writeAsStringSync('');
    }

    test('GRACELINK_SIGNTOOL 指了就用它（不看 SDK）', () {
      expect(
        findSignTool(
          <String, String>{'GRACELINK_SIGNTOOL': r'D:\tools\signtool.exe'},
          kitsRoot: kits.path,
          which: () => null,
        ),
        r'D:\tools\signtool.exe',
      );
    });

    test('没指就扫 SDK，取版本号最大的那个（10.0.9 > 10.0.10 那种要比数字）', () {
      fakeKits('10.0.26100.0');
      fakeKits('10.0.9999.0');
      fakeKits('10.0.22621.0');
      expect(
        findSignTool(<String, String>{}, kitsRoot: kits.path, which: () => null),
        contains('10.0.26100.0'),
      );
    });

    test('SDK 里没有就问 where；都没有给 null（那时只有真的配了证书才报错）', () {
      expect(
        findSignTool(
          <String, String>{},
          kitsRoot: '${kits.path}/空的',
          which: () => r'C:\from\path\signtool.exe',
        ),
        r'C:\from\path\signtool.exe',
      );
      expect(
        findSignTool(
          <String, String>{},
          kitsRoot: '${kits.path}/空的',
          which: () => null,
        ),
        isNull,
      );
    });
  });
}
