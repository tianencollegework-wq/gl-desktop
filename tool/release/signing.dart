/// Windows **代码签名**（Authenticode）—— 打包脚本与用例共用这一份。
///
/// 为什么需要它：未签名的安装包在别人机器上双击，Windows 会拦一句
/// 「**未知发布者**」—— 那不是 bug，是 SmartScreen 对「没有任何品牌背书」的包
/// 的默认态度。签过名之后，那个位置显示的是证书上的公司名，下载也不再被拦
/// （EV 证书 / 云签名服务还能立刻拿到信誉，OV 证书要跑一段时间）。
///
/// 证书**不是代码能生成的东西**，得自己去 CA 买或走云签名服务；这个文件只负责
/// 「拿到证书之后怎么签」。怎么拿证书、大概多少钱、哪种适合我们，见
/// `docs/release/windows-release.md`。
///
/// 三种给证书的方式（**环境变量**，别写进仓库）：
///
/// ```bash
/// # 1) .pfx 文件 + 口令（OV 证书最常见的形态）
/// GRACELINK_SIGN_PFX=D:\secrets\gracelink.pfx
/// GRACELINK_SIGN_PFX_PASSWORD=...
/// # 2) 证书已装进证书库：给指纹（EV 的硬件令牌插着时也走这条）
/// GRACELINK_SIGN_CERT_SHA1=0123456789ABCDEF...
/// # 3) 云签名服务（Azure Trusted Signing 那种）：给一条包装命令
/// GRACELINK_SIGN_COMMAND=D:\tools\sign-with-azure.cmd {file}
/// ```
///
/// 另外三个可选项：`GRACELINK_SIGNTOOL`（signtool.exe 路径，默认自己找）、
/// `GRACELINK_SIGN_TIMESTAMP_URL`（时间戳服务器）、`GRACELINK_SIGN_STRICT=1`
/// （验签不过就当构建失败 —— **公开发布的那次一定要开**）。
library;

import 'dart:io';

/// 默认时间戳服务器。
///
/// 为什么必须打时间戳：不打的话，「签名有效」只到证书到期那一刻 —— 证书一过期，
/// 所有**已经发出去的旧包**签名一起失效（用户那边突然冒「签名已过期」）。
/// 打了时间戳，签名在时间戳那一瞬就算数了，证书过期不影响旧包。
const String defaultTimestampUrl = 'http://timestamp.digicert.com';

/// 配置不对（比如两个证书来源都给了、指了个不存在的 .pfx）时抛这个：
/// 这类问题必须在**打包时**当场炸掉，不能悄悄打出个未签名的包。
class SigningConfigError implements Exception {
  const SigningConfigError(this.message);

  final String message;

  @override
  String toString() => '签名配置有问题：$message';
}

/// 一次打包要怎么签。`enabled` 是 false 时调用方应打印「未签名」的提示并继续
/// （内部测试包不需要签名）。
class SigningConfig {
  const SigningConfig({
    this.signTool = '',
    this.pfxPath,
    this.pfxPassword,
    this.certSha1,
    this.signCommand,
    this.timestampUrl = defaultTimestampUrl,
    this.strict = false,
  });

  /// signtool.exe 的路径（走 [signCommand] 时用不上）
  final String signTool;

  /// .pfx 证书文件路径（给证书 + 私钥，最常见）
  final String? pfxPath;

  /// .pfx 的口令（有些 pfx 没口令，那就留空）
  final String? pfxPassword;

  /// 证书库里那张证书的指纹（证书装在「当前用户 / 本机」证书库时用）
  final String? certSha1;

  /// 云签名服务的包装命令：`{file}` 会被替换成待签文件。
  ///
  /// 为什么留这条口子：Azure Trusted Signing / DigiCert KeyLocker 这类服务的
  /// 签名动作不是一条 `signtool sign`，而是它们自己的命令（内部再调 signtool）。
  /// 钉死 signtool 的话这些走的都是死路。
  final String? signCommand;

  /// 时间戳服务器
  final String timestampUrl;

  /// 验签不过是否算构建失败（公开发布那次请打开）
  final bool strict;

  /// 配了证书吗。false = 走「未签名」那条路
  bool get enabled =>
      (pfxPath != null && pfxPath!.isNotEmpty) ||
      (certSha1 != null && certSha1!.isNotEmpty) ||
      (signCommand != null && signCommand!.isNotEmpty);

  /// 这次用的是哪种来源（打印给人看的一句话）
  String get source => switch (true) {
    _ when signCommand != null && signCommand!.isNotEmpty => '云签名服务命令',
    _ when pfxPath != null && pfxPath!.isNotEmpty => '.pfx 证书文件',
    _ => '证书库里的证书（指纹 $certSha1）',
  };

  /// `signtool sign …` 的参数（不含可执行文件本身）。
  ///
  /// 顺序与开关都是有讲究的：
  /// * `/fd sha256` 摘要算法（SHA-1 已经不被接受）；
  /// * `/tr` + `/td sha256` 时间戳（见 [defaultTimestampUrl] 那段说明）；
  /// * `/f` + `/p` 给 .pfx；`/sha1` 给出证书库里那张的指纹 —— **两者只能有一个**，
  ///   同时给 signtool 会用 `/f` 那份，容易让人以为签的是另一张；
  /// * `/d Gracelink` 是 UAC / 属性页上那行描述（不写就只显示证书主体名）。
  List<String> signArgs(String file) => <String>[
    'sign',
    '/fd',
    'sha256',
    '/d',
    'Gracelink',
    if (pfxPath != null && pfxPath!.isNotEmpty) ...<String>[
      '/f',
      pfxPath!,
      if (pfxPassword != null && pfxPassword!.isNotEmpty) ...<String>[
        '/p',
        pfxPassword!,
      ],
    ] else if (certSha1 != null && certSha1!.isNotEmpty) ...<String>[
      '/sha1',
      certSha1!,
    ],
    '/tr',
    timestampUrl,
    '/td',
    'sha256',
    file,
  ];

  /// 云签名服务那条包装命令（`{file}` 已替换）
  List<String> commandArgsFor(String file) {
    final template = signCommand!;
    if (template.contains('{file}')) {
      return <String>[template.replaceAll('{file}', file)];
    }
    return <String>[template, file];
  }

  /// `signtool verify /pa /v <file>`：验签。
  ///
  /// `/pa` = 用「Authenticode 策略」验（默认策略会放过一些不该放过的证书）。
  /// 自签证书在这条路上**一定失败**（链子回不到受信任的根）—— 那不是 bug，
  /// 见 [strict] 的用法：内测包只看「签上了没」，公开包才要求全绿。
  List<String> verifyArgs(String file) =>
      <String>['verify', '/pa', '/v', file];
}

/// 从环境变量里解析签名配置。没配任何证书时 **返回 null**（调用方走未签名的路）。
///
/// [signTool] 是预先找到的 signtool 路径（没找到给 null，只有真的要用 signtool
/// 时才会报错——云签名那条路不需要它）。
SigningConfig? resolveSigning(
  Map<String, String> env, {
  String? signTool,
}) {
  String? read(String name) {
    final value = env[name]?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  final pfx = read('GRACELINK_SIGN_PFX');
  final password = read('GRACELINK_SIGN_PFX_PASSWORD');
  final sha1 = read('GRACELINK_SIGN_CERT_SHA1');
  final command = read('GRACELINK_SIGN_COMMAND');

  final sources = <String>[
    if (pfx != null) 'GRACELINK_SIGN_PFX',
    if (sha1 != null) 'GRACELINK_SIGN_CERT_SHA1',
    if (command != null) 'GRACELINK_SIGN_COMMAND',
  ];
  if (sources.isEmpty) {
    if (password != null) {
      throw const SigningConfigError(
        '只给了 GRACELINK_SIGN_PFX_PASSWORD，没给证书（GRACELINK_SIGN_PFX）',
      );
    }
    return null;
  }
  if (sources.length > 1) {
    throw SigningConfigError(
      '同时给了 ${sources.join(' 和 ')}：证书来源只能有一个（不然签的是哪个说不清）',
    );
  }
  if (pfx != null && !File(pfx).existsSync()) {
    throw SigningConfigError('GRACELINK_SIGN_PFX 指的证书文件不存在：$pfx');
  }
  if (command == null && (signTool == null || signTool.isEmpty)) {
    throw const SigningConfigError(
      '没找到 signtool.exe：装 Windows SDK（含「Windows SDK Signing Tools」）'
      '或把 GRACELINK_SIGNTOOL 指到它上面',
    );
  }
  if (command != null && !File(command).existsSync() && !_isOnPath(command)) {
    throw SigningConfigError('GRACELINK_SIGN_COMMAND 指的脚本不存在：$command');
  }

  return SigningConfig(
    signTool: signTool ?? '',
    pfxPath: pfx,
    pfxPassword: password,
    certSha1: sha1,
    signCommand: command,
    timestampUrl: read('GRACELINK_SIGN_TIMESTAMP_URL') ?? defaultTimestampUrl,
    strict: _isTruthy(read('GRACELINK_SIGN_STRICT')),
  );
}

bool _isTruthy(String? value) {
  if (value == null) return false;
  return const <String>{
    '1',
    'true',
    'yes',
    'on',
  }.contains(value.toLowerCase());
}

bool _isOnPath(String exe) =>
    exe.contains('\\') || exe.contains('/') ? File(exe).existsSync() : true;

/// 找 signtool.exe：先看 `GRACELINK_SIGNTOOL`，再扫 Windows SDK 的各个版本
/// （取版本号最大的那个），最后问一遍 `where`。
///
/// 找不到返回 null —— 由 [resolveSigning] 决定这算不算错（只有真要签的时候才错）。
String? findSignTool(
  Map<String, String> env, {
  String? kitsRoot,
  String? Function()? which,
}) {
  final configured = env['GRACELINK_SIGNTOOL']?.trim();
  if (configured != null && configured.isNotEmpty) return configured;

  final dir = Directory(
    kitsRoot ?? r'C:\Program Files (x86)\Windows Kits\10\bin',
  );
  if (dir.existsSync()) {
    final candidates = <String, String>{};
    for (final entry in dir.listSync()) {
      if (entry is! Directory) continue;
      // 用 pathSeparator 拼，别写死 `\x64\`：entry.path 在 macOS 那边是
      // `/var/…/10.0.26100.0`，拼上反斜杠之后整串会被当成**一个文件名**，
      // 于是永远 existsSync()==false、回 null。Windows 上混用分隔符反而照样能过 ——
      // 2026-10-14 的 iOS 首绿就差这一条：全量用例里唯一挂的就是它
      // （`test/release/signing_test.dart` 的「10.0.9 > 10.0.10 那种要比数字」）。
      final exe = File(
        <String>[entry.path, 'x64', 'signtool.exe'].join(Platform.pathSeparator),
      );
      if (!exe.existsSync()) continue;
      candidates[entry.path.split(RegExp(r'[\\/]')).last] = exe.path;
    }
    if (candidates.isNotEmpty) {
      final versions = candidates.keys.toList()
        ..sort(_compareVersionStrings);
      return candidates[versions.last]!;
    }
  }

  final fromPath = which == null ? _whereSigntool() : which();
  if (fromPath != null && fromPath.isNotEmpty) return fromPath;
  return null;
}

/// 版本号比大小（`10.0.9.0 > 10.0.10.0` 这种字符串比不了，逐段比数字）
int _compareVersionStrings(String a, String b) {
  final left = a.split('.').map((part) => int.tryParse(part) ?? 0).toList();
  final right = b.split('.').map((part) => int.tryParse(part) ?? 0).toList();
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final x = i < left.length ? left[i] : 0;
    final y = i < right.length ? right[i] : 0;
    if (x != y) return x - y;
  }
  return 0;
}

String? _whereSigntool() {
  try {
    final result = Process.runSync('where', <String>['signtool.exe']);
    if (result.exitCode != 0) return null;
    final first = (result.stdout as String)
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    return first.isEmpty ? null : first;
  } on Object {
    return null;
  }
}
