import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 运行环境。
///
/// 切换方式：
/// ```
/// flutter run --dart-define=ENV=dev --dart-define=API_HOST=127.0.0.1:8080 \
///   --dart-define=API_SCHEME=http
/// ```
enum AppEnv { prod, dev }

/// 全局配置，对应老端 `common/config.js`。
///
/// 两点与老端不同，都是刻意的：
///
/// 1. **hostToken 校验失败不阻断启动**。老端一旦算不对就把 `apiUrl` 置成字符串
///    `'false'`，整个 App 直接发不出请求；而本地这份配置的 token 与实际域名根本
///    对不上（见 `docs/protocol/README.md` 的「本轮排查中发现的问题」）。
///    Flutter 端只打印警告，继续用域名。
/// 2. host / scheme 支持通过 `--dart-define` 覆盖，方便本地联调。
@immutable
class AppConfig {
  const AppConfig({
    required this.env,
    required this.scheme,
    required this.host,
    required this.hostToken,
  });

  final AppEnv env;
  final String scheme;
  final String host;
  final String hostToken;

  static const String _envName = String.fromEnvironment(
    'ENV',
    defaultValue: 'prod',
  );

  static const AppConfig current = AppConfig(
    env: _envName == 'dev' ? AppEnv.dev : AppEnv.prod,
    scheme: String.fromEnvironment('API_SCHEME', defaultValue: 'https'),
    host: String.fromEnvironment(
      'API_HOST',
      defaultValue: 'message.gracelink.cc',
    ),
    hostToken: String.fromEnvironment(
      'HOST_TOKEN',
      defaultValue: 'sha740A9C7018B2CB55C7CC93D75BE0E8D9bi',
    ),
  );

  /// 老端：`scheme + '://' + host`
  String get apiUrl => '$scheme://$host';

  /// 老端：`(scheme == 'https' ? 'wss' : 'ws') + '://' + host + '/wss'`
  String get wssUrl => '${scheme == 'https' ? 'wss' : 'ws'}://$host/wss';

  /// 老端用 crypto-js 算的：`'sha' + md5(md5(host)) + 'bi'`，输出小写十六进制。
  String get expectedHostToken {
    final first = md5.convert(utf8.encode(host)).toString();
    return 'sha${md5.convert(utf8.encode(first))}bi';
  }

  bool get hostTokenMatches =>
      expectedHostToken.toLowerCase() == hostToken.toLowerCase();

  /// 启动自检，只警告不中断。
  void logSelfCheck() {
    if (hostTokenMatches) return;
    debugPrint(
      '[AppConfig] hostToken 与域名不匹配（老端同样存在这个问题）：\n'
      '  域名      : $host\n'
      '  期望 token: $expectedHostToken\n'
      '  配置 token: $hostToken\n'
      '  已按「失败放行」处理，请求仍指向 $apiUrl',
    );
  }

  @override
  String toString() => 'AppConfig(${env.name}, $apiUrl)';
}

final appConfigProvider = Provider<AppConfig>((ref) => AppConfig.current);
