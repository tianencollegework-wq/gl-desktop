/// Cloudflare Realtime TURN 的短时凭据（S6.9，2026-09-26 新增）。
///
/// 老端没有这一层：它只吃站点后台填的那个 `stun` 字符串，两边都躲在对称 NAT /
/// 运营商大内网后面时**就是打不通**（规划书风险 #1）。TURN 是那条兜底路，而
/// Cloudflare 只发**短时凭据**（一条最长 48 小时）——密钥不能进客户端，
/// 所以凭据由我们的服务端签发（`POST /enterprise/im/turnCredentials`），
/// 客户端只负责**取 + 缓存**。
///
/// 三条纪律（测试里逐条钉住，见 `test/call/turn_credentials_test.dart`）：
/// 1. **绝不抛**：取不到就返回空列表，ICE 列表退回「只有 STUN」——一次取凭据
///    失败不该让一通电话打不出去；
/// 2. **不每次都问**：凭据是短时的，缓存到过期前（服务端会告诉我们 `expiresIn`）；
/// 3. **并发只发一次**：拨号与被叫同时点、同一通电话里反复建连接，不能一人一次。
// ignore_for_file: prefer_initializing_formals —— 可注入的构造参数与私有字段不同名（单测要替掉它们），
// 上面那条 `dart format` 会把行尾的 `// ignore` 挪到初始化列表上从而失效，所以用文件级忽略
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/json_value.dart';
import '../../data/api/chat_api.dart';
import 'call_media_config.dart';

/// 服务端没给 `expiresIn` 时，这条凭据在客户端这边缓存多久。
const Duration kTurnCredentialDefaultTtl = Duration(minutes: 30);

/// 取凭据的超时。
///
/// 比网络层那份 10 秒短得多：它挂在**拨号路径**上，而且 TURN 只是兜底 ——
/// 为了兜底让用户多等十秒是划不来的。
const Duration kTurnCredentialTimeout = Duration(seconds: 4);

/// 失败之后过多久才再试一次（见 [TurnCredentialService.failureRetryDelay]）
const Duration kTurnCredentialRetryDelay = Duration(minutes: 5);

/// 备用端口 53 —— 浏览器与系统普遍拦它，留着只会在收集候选时白等一次超时。
final RegExp _blockedPort = RegExp(r':53(\?|$)');

/// 把服务端返回的报文解析成 `RTCPeerConnection` 认的 `iceServers`。
///
/// 认两种形状：`{'iceServers': [...]}`（Cloudflare 原样返回、服务端透传的那份）
/// 与直接一个数组。其它输入（null / 字符串 / 空 map）与没有可用地址的条目
/// 一律**丢掉**，不抛。
///
/// 每条里的 `urls` 会挨个补齐协议头（[CallMediaConfig.normalizeIceUrl]：站点后台
/// 少写 `stun:` 前缀那个坑在真机上踩过）、丢掉 53 端口，重复地址只留一份。
List<Map<String, dynamic>> parseTurnIceServers(Object? payload) {
  final raw = payload is Map ? payload['iceServers'] : payload;
  if (raw is! List) return const <Map<String, dynamic>>[];

  final servers = <Map<String, dynamic>>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final urls = <String>[];
    final rawUrls = entry['urls'];
    for (final url in rawUrls is List ? rawUrls : <Object?>[rawUrls]) {
      final normalized = CallMediaConfig.normalizeIceUrl(asText(url));
      if (normalized.isEmpty || _blockedPort.hasMatch(normalized)) continue;
      if (!urls.contains(normalized)) urls.add(normalized);
    }
    if (urls.isEmpty) continue;

    final server = <String, dynamic>{'urls': urls};
    // Cloudflare 给的那条 `stun:` 没有账号；TURN 那条才有。空串**不发这两个键**，
    // 理由与 [CallMediaConfig.iceServers] 里那段一样（会让它变成「带鉴权的 STUN」）。
    final username = asText(entry['username']);
    final credential = asText(entry['credential']);
    if (username.isNotEmpty) server['username'] = username;
    if (credential.isNotEmpty) server['credential'] = credential;
    servers.add(server);
  }
  return servers;
}

/// 凭据的取用与缓存（进程内一份，跟着登录会话走）。
///
/// 只依赖一个 `fetch` 回调 + 一个时钟，所以**整个类都能跑单测**（不碰网络、
/// 不碰插件）。
class TurnCredentialService {
  TurnCredentialService({
    required Future<Object?> Function() fetch,
    DateTime Function()? now,
    this.timeout = kTurnCredentialTimeout,
    this.defaultTtl = kTurnCredentialDefaultTtl,
    this.failureRetryDelay = kTurnCredentialRetryDelay,
  }) : _fetch = fetch,
       _now = now ?? DateTime.now;

  final Future<Object?> Function() _fetch;
  final DateTime Function() _now;

  /// 取一次凭据最多等多久
  final Duration timeout;

  /// 服务端没给 `expiresIn` 时的缓存时长
  final Duration defaultTtl;

  /// 取失败之后多久才再试一次。
  ///
  /// 为什么要有它：站点没配密钥时服务端秒回空列表（不受影响），但站点**配了而
  /// Cloudflare 连不上**时，服务端要等它自己的 curl 超时（默认 5 秒）——
  /// 客户端这里是 4 秒封顶，那也是一通电话白等 4 秒。有了这条退避，
  /// 坏配置只让**每 5 分钟里的第一通**电话慢一次。
  final Duration failureRetryDelay;

  List<Map<String, dynamic>> _cached = const <Map<String, dynamic>>[];
  DateTime? _expiresAt;
  Future<List<Map<String, dynamic>>>? _inFlight;

  /// 上次失败之后的重试时间点（见 [failureRetryDelay]）
  DateTime? _retryAfter;

  /// 当前能用的 TURN 服务器；没有（没配 / 取失败）就是空列表。
  Future<List<Map<String, dynamic>>> iceServers() {
    final expiresAt = _expiresAt;
    if (_cached.isNotEmpty && expiresAt != null && _now().isBefore(expiresAt)) {
      return Future<List<Map<String, dynamic>>>.value(_cached);
    }
    final retryAfter = _retryAfter;
    if (retryAfter != null && _now().isBefore(retryAfter)) {
      // 刚失败过：这一次直接当「没有 TURN」，别让拨号再等一遍超时
      return Future<List<Map<String, dynamic>>>.value(
        const <Map<String, dynamic>>[],
      );
    }
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    late final Future<List<Map<String, dynamic>>> future;
    future = _load().whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
    _inFlight = future;
    return future;
  }

  /// 丢掉缓存（登出、换账号，或测试里模拟过期）。
  void invalidate() {
    _cached = const <Map<String, dynamic>>[];
    _expiresAt = null;
    _inFlight = null;
    _retryAfter = null;
  }

  Future<List<Map<String, dynamic>>> _load() async {
    try {
      final payload = await _fetch().timeout(timeout);
      final servers = parseTurnIceServers(payload);
      if (servers.isEmpty) {
        // 没配（空列表）也是一种答案：不缓存、不报错，下次通话再问一遍
        return const <Map<String, dynamic>>[];
      }
      _cached = servers;
      _expiresAt = _now().add(_ttlOf(payload));
      _retryAfter = null;
      return servers;
    } catch (error) {
      // 刻意吞掉：TURN 只是兜底，取不到就按「只有 STUN」跑（与今天一样）
      debugPrint('[通话] 取 TURN 凭据失败（改用只有 STUN 的列表）：$error');
      _retryAfter = _now().add(failureRetryDelay);
      return const <Map<String, dynamic>>[];
    }
  }

  /// 缓存多久：服务端给的 `expiresIn` 打八折（留出时差与建连时间）；
  /// 没有或异常就用 [defaultTtl]，下限 30 秒（免得报文不对时每通电话都去取一次）。
  Duration _ttlOf(Object? payload) {
    final seconds = payload is Map ? asInt(payload['expiresIn'], 0) : 0;
    if (seconds <= 0) return defaultTtl;
    final scaled = Duration(milliseconds: seconds * 800);
    return scaled < const Duration(seconds: 30)
        ? const Duration(seconds: 30)
        : scaled;
  }
}

/// 进程内那份凭据。
///
/// 这里 `watch` 的是 `chatApiProvider`：登录 / 登出会重建它（顺手丢掉缓存），
/// 这正是我们要的。但**引擎不能 watch 它** —— 引擎一被重建，正在进行的通话
/// 会被整个拆掉（那次事故记在 `data/media/call_media_engine.dart` 里
/// `callMediaEngineProvider` 上面的长注释）。
final turnCredentialServiceProvider = Provider<TurnCredentialService>((ref) {
  final api = ref.watch(chatApiProvider);
  return TurnCredentialService(fetch: api.turnCredentials);
});
