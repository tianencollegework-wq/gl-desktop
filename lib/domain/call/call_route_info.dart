import 'package:flutter/foundation.dart';

import '../../data/model/global_config.dart';
import 'call_media_config.dart';

/// 「设置 › 音视频通话 › 通话线路」要显示的那份东西。
///
/// **为什么有这个页面**（2026-10-10 用户：「电脑端设置的音视频通话点开是啥都没有
/// 的这体验很不好，要么有东西，要么就不要有这一栏」）：那一页原来只有两行**安卓
/// 专属**开关（通话保活通知 / 来电全屏显示），各自的 `supported == false` 时都
/// `SizedBox.shrink()` 掉，桌面上就是一张白纸。而这一页的入口在桌面上是照常显示的。
///
/// 现在这一页有一行**两端都成立**的真东西：把这台设备实际会用的 ICE 线路列出来
/// （也就是「打不通 / 没声音」时最该先看的那份配置）。数据全部来自 [ChatInfo]，
/// 不碰任何插件，所以能整体跑单测。
@immutable
class CallRouteInfo {
  const CallRouteInfo({
    required this.siteLines,
    required this.siteUsesFallback,
    required this.siteHasCredentials,
    required this.suspiciousTurnLines,
    required this.builtInTurnLines,
  });

  /// 从站点配置算出要展示的线路。
  ///
  /// 口径与真正建连接时**完全一致**（都走 [CallMediaConfig]）：站点那一栏的地址
  /// 补协议头、空则用兜底地址。显示的东西和实际用的东西不一样的话，这个页面
  /// 就只剩误导。
  factory CallRouteInfo.of(ChatInfo chatInfo) {
    final raws = _rawSiteEntries(chatInfo.stun);
    final lines = <String>[
      for (final raw in raws) CallMediaConfig.normalizeIceUrl(raw),
    ];
    return CallRouteInfo(
      siteLines: lines.isEmpty
          ? const <String>[CallMediaConfig.fallbackStunUrl]
          : lines,
      siteUsesFallback: lines.isEmpty,
      // 与 [CallMediaConfig.iceServers] 同一个判断：TURN 要靠账号鉴权
      siteHasCredentials:
          chatInfo.stunUser.isNotEmpty || chatInfo.stunPass.isNotEmpty,
      suspiciousTurnLines: <String>[
        for (var i = 0; i < raws.length; i++)
          if (_looksLikeTurnWithoutScheme(raws[i], lines[i])) raws[i],
      ],
      builtInTurnLines: <String>[
        for (final server in CallMediaConfig.ownTurnServers) ..._urlsOf(server),
      ],
    );
  }

  /// 客户端固定带的公共 STUN（一个都不能省，见 [CallMediaConfig.publicStunUrls]）
  static const List<String> publicStun = CallMediaConfig.publicStunUrls;

  /// 站点配的那一台实际会发出的地址（站点没配时 = 兜底地址那一条）
  final List<String> siteLines;

  /// [siteLines] 是客户端兜底（站点那一栏是空的）
  final bool siteUsesFallback;

  /// 站点那台带账号密码吗（**只显示有没有，绝不显示值本身**）
  final bool siteHasCredentials;

  /// 站点那些**想当 TURN 却会被当成 STUN 发出去**的写法（原样保留，给页面指出问题）。
  ///
  /// 真机上抓出来的坑：`normalizeIceUrl` 对没写协议头的地址一律当 STUN，而站点
  /// 后台那栏填 `turn.example.com:3478`（漏了 `turn:`）是很容易发生的事 —— 那样
  /// 一台 TURN 就静默地变成一台 STUN，双方都在严格 NAT 后面时打不通，而界面
  /// 上看不出任何异常。所以「通话线路」把这种写法单独标出来。
  ///
  /// 判断很窄：**没写协议头、主机名又以 `turn` 开头**（`turnserver.local:3478` 这种
  /// 也算）—— 正常 STUN 主机名不会这么起头，不会误报。
  final List<String> suspiciousTurnLines;

  /// 客户端内置的 TURN（[CallMediaConfig.ownTurnServers]，现在是空的）
  final List<String> builtInTurnLines;

  /// 有 TURN 可用吗：站点那条或者客户端内置的，有一条就够
  bool get hasTurn =>
      <String>[...siteLines, ...builtInTurnLines].any(_isTurnUrl);

  /// 复制出去的那份清单，顺序就是建连接时的顺序（公共 → 站点 → 内置）
  List<String> get copyLines => <String>[
    ...publicStun,
    ...siteLines,
    ...builtInTurnLines,
  ];

  String get copyText => copyLines.join('\n');

  static bool _isTurnUrl(String url) {
    final lower = url.toLowerCase();
    return lower.startsWith('turn:') || lower.startsWith('turns:');
  }

  /// 站点那一栏的原样写法（拆分口径与 [CallMediaConfig.splitIceUrls] 一致）
  static List<String> _rawSiteEntries(String raw) => raw
      .split(RegExp(r'[,\s]+'))
      .map((entry) => entry.trim())
      .where((entry) => entry.isNotEmpty)
      .toList();

  /// 「想当 TURN 但会被当 STUN 发」：没写协议头、主机名又是 turn 开头的
  static bool _looksLikeTurnWithoutScheme(String raw, String normalized) =>
      raw.toLowerCase().startsWith('turn') &&
      !CallMediaConfig.hasIceScheme(raw) &&
      normalized.toLowerCase().startsWith('stun:');

  /// `urls` 可能是字符串也可能是数组（内置那份的注释里两种写法都有）
  static List<String> _urlsOf(Map<String, dynamic> server) {
    final urls = server['urls'];
    if (urls is List) return <String>[for (final url in urls) url.toString()];
    if (urls != null) return <String>[urls.toString()];
    return const <String>[];
  }

  @override
  bool operator ==(Object other) =>
      other is CallRouteInfo &&
      listEquals(other.siteLines, siteLines) &&
      other.siteUsesFallback == siteUsesFallback &&
      other.siteHasCredentials == siteHasCredentials &&
      listEquals(other.suspiciousTurnLines, suspiciousTurnLines) &&
      listEquals(other.builtInTurnLines, builtInTurnLines);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(siteLines),
    siteUsesFallback,
    siteHasCredentials,
    Object.hashAll(suspiciousTurnLines),
    Object.hashAll(builtInTurnLines),
  );

  @override
  String toString() =>
      'CallRouteInfo(site: $siteLines, fallback: $siteUsesFallback, '
      'turn: $hasTurn)';
}
