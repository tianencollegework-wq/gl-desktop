/// 网址安全分级（用户 2026-09-25 的要求）。
///
/// 点了聊天里的一个链接之后走哪条路，全看这里：
/// * [LinkSafety.official] —— **我们自己的站点**（`gracelink.cc` 及其子域名，
///   如 `film.gracelink.cc`）：直接进应用内浏览器，不多问一句；
/// * [LinkSafety.blocked] —— 微信/腾讯那一系的地址（含字眼就拦）：跳到
///   「已停止访问该网页」那个红圈感叹号页，**不给访问**；
/// * [LinkSafety.thirdParty] —— 其它一切：先到「第三方网址，是否继续访问」那页，
///   用户点「继续访问」才真的加载。
library;

import '../config/app_config.dart';

/// 一律拦掉的字眼（大小写不敏感，**扫的是整条网址**）。
///
/// 要放宽/加严就改这一份清单：它只在这里用，其它地方没有第二份。
/// 注意 `qq.com` 也在其中 —— QQ 与微信同属腾讯，用户要的是「腾讯相关全部禁止」。
const List<String> blockedLinkKeywords = <String>[
  'weixin',
  'wechat',
  'tencent',
  'tenpay',
  'foxmail',
  'qq.com',
  'qq.cn',
  '微信',
  '腾讯',
  '财付通',
];

/// 官方站点根域（写死一份兜底）。
///
/// 接口域名是 `message.gracelink.cc`，所以根域就是它的最后两段；[officialRootDomains]
/// 会把两者合起来 —— 换域名时不用改代码，服务端换到哪儿，哪儿就是「官方直开」。
const String fallbackOfficialDomain = 'gracelink.cc';

/// 算一个域名是不是「我们的站点」时要认的根域集合。
Set<String> get officialRootDomains => <String>{
  fallbackOfficialDomain,
  _rootDomainOf(AppConfig.current.host),
};

/// 剥出域名最后两段（`message.gracelink.cc` → `gracelink.cc`）。
///
/// 拿不到（本地联调常见的 `192.168.1.5` / `localhost`）就把整串当根域，
/// 这样「本机地址」在原样访问时也算官方，不会被弹第三方确认页。
String _rootDomainOf(String host) {
  final labels = host
      .split('.')
      .where((label) => label.isNotEmpty)
      .toList(growable: false);
  if (labels.length <= 2) return host;
  return labels.sublist(labels.length - 2).join('.');
}

/// 一条链接该怎么处理
enum LinkSafety {
  /// 自己的站点：直接加载
  official,

  /// 微信/腾讯系：禁止访问
  blocked,

  /// 第三方：先让用户确认
  thirdParty,
}

/// 分级。[url] 可以是没有协议的裸域名 —— 判定不受协议影响。
LinkSafety linkSafetyOf(String url) {
  final normalized = url.trim().toLowerCase();
  if (normalized.isEmpty) return LinkSafety.thirdParty;

  for (final keyword in blockedLinkKeywords) {
    if (normalized.contains(keyword)) return LinkSafety.blocked;
  }

  if (isOfficialLink(url)) return LinkSafety.official;
  return LinkSafety.thirdParty;
}

/// 是不是我们自己的站点。
///
/// 只看**主机名**（不是整串包含）：`evil.com/?ref=gracelink.cc` 是别人的站点
/// 拿我们的域名当参数，不该当成官方链接直接放进去；反过来
/// `film.gracelink.cc`、`a.b.gracelink.cc` 这类子域名都算官方。
bool isOfficialLink(String url) {
  final host = _hostOf(url);
  if (host.isEmpty) return false;
  for (final root in officialRootDomains) {
    if (host == root || host.endsWith('.$root')) return true;
  }
  return false;
}

/// 取主机名：优先交给 [Uri]，它解析不了（没有协议、或带中文）时退回手写解析。
String _hostOf(String url) {
  final trimmed = url.trim();
  if (trimmed.isEmpty) return '';

  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.host.isNotEmpty) return uri.host.toLowerCase();

  // 没有协议时 `Uri.parse` 会把整串当成 path（`a.com/x` 的 host 是空的），
  // 所以自己切一刀：去协议、去 `www.`、取到第一个 `/` `?` `#` 之前那段。
  var rest = trimmed;
  final schemeEnd = rest.indexOf('://');
  if (schemeEnd >= 0) rest = rest.substring(schemeEnd + 3);
  final hostPart = RegExp(r'^[^/?#]*').firstMatch(rest)?.group(0);
  if (hostPart != null) rest = hostPart;
  // 去掉可能的用户名/密码与端口
  final at = rest.lastIndexOf('@');
  if (at >= 0) rest = rest.substring(at + 1);
  final colon = rest.lastIndexOf(':');
  if (colon >= 0) rest = rest.substring(0, colon);
  return rest.toLowerCase();
}
