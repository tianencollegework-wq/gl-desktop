/// 桌面「系统级独立窗口」（第二颗 Flutter 引擎）之间那点约定。
///
/// 主窗口开窗口时把「这颗窗口是干什么的」编成一个字符串交给
/// `desktop_multi_window`，它原样递给新引擎的 `main()`；子引擎起来先解这个串，
/// 解不出来就说明这颗引擎不是窗口（正常启动的主窗口就是这种情况）。
///
/// 为什么用 URI 而不是 JSON：要带文章标题、卡片正文这些自由文本，
/// `Uri` 顺手把转义做了（`Uri(queryParameters:)` 自己就百分号编码），
/// 解析也只有一份实现，不用自己拼引号。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../domain/news/news_card.dart';

/// 窗口是干什么用的。
///
/// 一个 kind 只开一颗窗口：再点就把它抬到最前（顺便换内容），
/// 不叠第二颗 —— 每颗窗口都是一整颗引擎，省着点用。
enum DesktopWindowKind {
  /// 资讯文章（从聊天卡片点进来）
  article,

  /// 灵听（音乐频道整条）
  lingting,

  /// 媒体号（资讯列表整条）：窗里就是那张列表，点进去的文章在**这颗窗口里**往下推
  /// —— 用户 2026-10-04：「为啥我这看到的媒体号还是这样的不是独立窗口？」
  news,

  /// 网页（内嵌浏览器的独立窗口，2026-10-04）：窗里顶上一条标签栏、下面当前
  /// 那一页真 webview（多标签，2026-10-04；界面见 `desktop_web_window.dart`），
  /// 用户要的是微信 PC 那种「点开链接弹一个自己的浏览器窗口」，而不是每次都
  /// 交给系统浏览器。
  ///
  /// 一个 kind 一颗窗口：连着点两篇不同的外链，也是把这颗窗口抬起来、
  /// 让它自己**多开一个标签**（`open_url`，见 `desktop_window_service.dart`；
  /// 同一条地址点了两遍不了叠，切过去就是了）。
  web,

  /// 通话（2026-10-04）：用户原话「请将通话做到新开一个独立窗口」。
  ///
  /// 与另外几个 kind 不同的是，这颗窗口**不只是界面**：WebRTC 那套媒体引擎
  /// 也在这颗引擎里（`MediaStream` 过不了引擎边界，画面必须在拿流的那颗引擎里
  /// 渲染）。主窗口那份状态机/信令照旧，两边靠 `gracelink/window/call`
  /// 与 `gracelink/call/events` 两条线说话（见 `call_window_bridge.dart`）。
  call,
}

/// 一颗子窗口的启动参数。
class DesktopWindowArgs {
  const DesktopWindowArgs({
    required this.kind,
    this.id = '',
    this.title = '',
    this.url = '',
    this.avatar = '',
    this.video = false,
    this.isCaller = false,
    this.iceServers = const <Map<String, dynamic>>[],
    this.shared,
  });

  const DesktopWindowArgs.article({
    required String id,
    required String title,
    NewsCard? shared,
  }) : this(
         kind: DesktopWindowKind.article,
         id: id,
         title: title,
         shared: shared,
       );

  const DesktopWindowArgs.lingting({required String title})
    : this(kind: DesktopWindowKind.lingting, title: title);

  const DesktopWindowArgs.news({required String title})
    : this(kind: DesktopWindowKind.news, title: title);

  const DesktopWindowArgs.web({required String url, String title = ''})
    : this(kind: DesktopWindowKind.web, url: url, title: title);

  /// 通话窗：对端是谁、语音还是视频、是不是本端发起，外加这份 ICE 列表
  /// （站点那栏 + 服务端签发的 TURN 凭据都已算好 —— 子引擎里没有会话配置，
  /// 自己算不出来）。
  const DesktopWindowArgs.call({
    required String peerId,
    required String peerName,
    String peerAvatar = '',
    required bool video,
    required bool isCaller,
    List<Map<String, dynamic>> iceServers = const <Map<String, dynamic>>[],
  }) : this(
         kind: DesktopWindowKind.call,
         id: peerId,
         title: peerName,
         avatar: peerAvatar,
         video: video,
         isCaller: isCaller,
         iceServers: iceServers,
       );

  final DesktopWindowKind kind;

  /// 文章 id（灵听不用）
  final String id;

  /// 网页窗要打开的地址（只有 [DesktopWindowKind.web] 用）
  final String url;

  /// 对端头像（只有 [DesktopWindowKind.call] 用）
  final String avatar;

  /// 视频通话（只有 [DesktopWindowKind.call] 用）
  final bool video;

  /// 本端发起（只有 [DesktopWindowKind.call] 用；来电那一屏的按钮不一样）
  final bool isCaller;

  /// 这通电话实际用的 ICE 列表（只有 [DesktopWindowKind.call] 用）
  final List<Map<String, dynamic>> iceServers;

  /// 原生标题栏上那行字
  final String title;

  /// 从聊天卡片点进来的那份本体：子引擎那边本机没有这一篇时详情页用它合成
  /// （和手机版整页推时走 `extra` 的那一份是同一个东西）。
  final NewsCard? shared;

  Uri toUri() => Uri(
    scheme: 'gracelink',
    host: kind.name,
    queryParameters: <String, String>{
      if (id.isNotEmpty) 'id': id,
      if (title.isNotEmpty) 'title': title,
      if (url.isNotEmpty) 'url': url,
      if (avatar.isNotEmpty) 'avatar': avatar,
      if (video) 'video': '1',
      if (isCaller) 'caller': '1',
      if (iceServers.isNotEmpty) 'ice': jsonEncode(iceServers),
      if (shared != null) 'card': jsonEncode(shared!.toExt()),
    },
  );

  String encode() => toUri().toString();

  /// 子引擎侧解析；认不出来就返回 null。
  static DesktopWindowArgs? decode(String raw) {
    if (raw.isEmpty || !raw.startsWith('gracelink://')) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    DesktopWindowKind? kind;
    for (final item in DesktopWindowKind.values) {
      if (item.name == uri.host) kind = item;
    }
    if (kind == null) return null;

    final query = uri.queryParameters;
    return DesktopWindowArgs(
      kind: kind,
      id: query['id'] ?? '',
      title: query['title'] ?? '',
      url: query['url'] ?? '',
      avatar: query['avatar'] ?? '',
      video: query['video'] == '1',
      isCaller: query['caller'] == '1',
      iceServers: _decodeIce(query['ice']),
      shared: _decodeCard(query['card']),
    );
  }

  /// 参数串里的 ICE 列表：坏了就当空，那边的引擎会退回「只有 STUN」那条路
  /// （比整扇窗起不来强）。
  static List<Map<String, dynamic>> _decodeIce(String? raw) {
    if (raw == null || raw.isEmpty) return const <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return <Map<String, dynamic>>[
          for (final item in decoded)
            if (item is Map) Map<String, dynamic>.from(item),
        ];
      }
    } on Object catch (error) {
      debugPrint('[窗口] ICE 参数解析失败，当空：$error');
    }
    return const <Map<String, dynamic>>[];
  }

  /// 参数串里的卡片：坏了就当没有（详情页自己会去本机列表里找那一条）
  static NewsCard? _decodeCard(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return NewsCard.fromExt(decoded);
    } on Object catch (error) {
      debugPrint('[窗口] 卡片参数解析失败，当没有：$error');
    }
    return null;
  }
}

/// 网页窗的标题：就是域名（微信 PC 那个浏览器窗口顶上也是域名）。
///
/// 拿不到域名时给空串 —— 子窗口那边会退回它自己的默认标题，不写「unknown」这种
/// 给用户看的话。
String webWindowTitleOf(String url) => Uri.tryParse(url)?.host ?? '';

/// 从一个进程的启动参数里挑出窗口参数（子引擎的 `main(args)` 里就有）。
///
/// `desktop_multi_window` 递给子引擎的是
/// `['multi_window', <窗口 id>, <窗口参数>]`，所以这里逐个试过去。
DesktopWindowArgs? windowArgsOf(List<String> args) {
  for (final arg in args) {
    final parsed = DesktopWindowArgs.decode(arg);
    if (parsed != null) return parsed;
  }
  return null;
}
