import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_exception.dart';
import '../../core/platform/push_token.dart';
import '../../core/store/credential_store.dart';
import '../../core/store/session_store.dart';
import '../../data/api/auth_api.dart';

/// 设备标识的登记（S8.1 客户端那半）：拿到推送标识 → 落盘成 `cid` → 上报服务端。
///
/// 为什么要单独一层：`cid` 是**两个方向**都在用的东西 ——
/// 1. 客户端每次请求都带 `cid` 头（`ApiClient`），登录/绑定也会把它带上；
/// 2. 服务端要拿它找到这台设备去下发推送。
/// 中间任何一步早一点/晚一点（Firebase 初始化慢、token 轮换）都会让「推送发不出去」
/// 而**界面完全看不出问题**，所以这一层要能单测。
///
/// 刻意做成**不依赖 Riverpod / 网络 / 真机**：来源、落盘、上报三件事都是注入的
/// 回调，单测里全换成假的。
///
/// ── iOS 那条**另外算账**（S8.2）─────────────────────────────────────────
/// iPhone 上要登记**两条**标识，它们不是同一件事：
///   * `fcm_ios:xxx` —— 这一层管的（普通消息通知，走 FCM 经 APNs）；
///   * `apns_voip:xxx` —— PushKit 给的那条，**只有它能弹出锁屏来电界面**、
///     也只有它能在 App 被划掉之后把进程叫醒。它就是 [applyVoip]。
/// 服务端把它们当两台设备，各走各的下发通道。
class PushRegistrar {
  PushRegistrar({
    required this.source,
    required this.readCid,
    required this.saveCid,
    required this.report,
    this.readVoipCid,
    this.saveVoipCid,
    this.readVoipReported,
    this.saveVoipReported,
    void Function(String message)? log,
  }) : _log = log ?? ((message) => debugPrint('[推送] $message'));

  final PushTokenSource source;
  final String? Function() readCid;
  final Future<void> Function(String cid) saveCid;

  /// 把标识交给服务端。**返回值 = 服务端这次真的收下了**
  /// （没登录 / 没有 client_id / 网络失败都是 false）——
  /// `false` 必须能分辨出来，否则「本地存过了」会被误当成「服务端收下了」，
  /// 而这两件事在这条链上差得很远（见 [_reportVoip]）。
  final Future<bool> Function(String cid) report;

  /// VoIP 标识的读写（**可不给**：不给就不登记这条 —— 桌面 / 安卓 / 单测里用不上它）
  final String? Function()? readVoipCid;
  final Future<void> Function(String cid)? saveVoipCid;

  /// 「服务端**已经收下过**的那条 VoIP 标识」（可不给）。
  ///
  /// 与 [readVoipCid]（本地存下的那条）**不能合并成一条**：PushKit 的标识通常
  /// 比登录**先到**，那一次上报会被跳过（那时还没有 user / client_id），可本地
  /// 已经落了盘。只看本地值的话，之后每次启动拿到的还是同一个值 → 永远不再上报，
  /// 服务端设备表里始终没有 `apns_voip:` 那一行（现象是「别的都对、锁屏就是不弹」，
  /// 而日志里只有一行「暂不上报设备标识」）。
  final String? Function()? readVoipReported;
  final Future<void> Function(String cid)? saveVoipReported;

  final void Function(String message) _log;

  StreamSubscription<PushToken>? _refresh;

  /// 同一时刻只跑一次（启动时 `bootstrap` 与登录/连接就绪都会调）
  Future<void>? _ensuring;

  /// 监听标识轮换。多次调用是空操作；没有推送通道的平台直接跳过。
  void start() {
    if (_refresh != null) return;
    if (!source.supported) {
      _log('这台设备没有推送通道，跳过设备标识登记');
      return;
    }
    _refresh = source.onRefresh.listen(
      (token) => unawaited(apply(token.cid)),
      onError: (Object error) => _log('标识轮换的监听出错：$error'),
    );
  }

  Future<void> stop() async {
    await _refresh?.cancel();
    _refresh = null;
  }

  /// 让本机的 `cid` 与设备当前标识一致（启动、登录、连接就绪时调）。
  ///
  /// **不抛异常**：推送登记失败绝不能让登录/绑定的主流程失败。
  Future<void> ensure() => _ensuring ??= _ensure().whenComplete(() {
    _ensuring = null;
  });

  Future<void> _ensure() async {
    // 先把 VoIP 那条补一次：它与 FCM 那条互不依赖（Firebase 没配好、token 还没来
    // 都不该妨碍「锁屏来电」那条标识登记上去），而登录 / 连接就绪正是补报的时机。
    await retryVoip();
    try {
      final token = await source.current();
      if (token == null || !token.isValid) {
        _log('没拿到设备标识（推送通道不可用？），这次不登记');
        return;
      }
      await apply(token.cid);
    } on Object catch (error) {
      _log('读取设备标识失败：$error');
    }
  }

  /// iOS：把 **VoIP 推送标识**（PushKit 给的那串）登记上去（S8.2）。
  ///
  /// 来电那条路只有它：[token] 空串（没拿到）直接跳过 —— PushKit 的标识比 FCM
  /// 略早到位，而且它到了之后**不会**自己再变（除非重装 App）。
  ///
  /// 整段吞异常：登记失败只是「锁屏来电弹不出来」，绝不能影响通话本身。
  Future<void> applyVoip(String token) async {
    final trimmed = token.trim();
    if (trimmed.isEmpty) return;
    final read = readVoipCid;
    final save = saveVoipCid;
    if (read == null || save == null) return;
    final cid = voipCidOf(trimmed);
    try {
      // 先落盘再上报（与 [apply] 同一个理由：上报失败时本地已经记下了，下次能给）
      if (read() != cid) await save(cid);
      await _reportVoip(cid);
    } on Object catch (error) {
      _log('登记 VoIP 标识失败：$error');
    }
  }

  /// 把**本地存着**的那条 VoIP 标识再报一次（登录 / 连接就绪时调，见 [ensure]）。
  ///
  /// 这是 [applyVoip] 的补网：标识在登录之前就到了的话，那一次上报会被跳过，
  /// 而 PushKit 的标识除了重装不会再变 —— 没有这一步，那台 iPhone 就永远拿不到
  /// VoIP 推送（用户看到的是「电话响过我这边一点反应都没有」，日志里也不像出错）。
  Future<void> retryVoip() async {
    final read = readVoipCid;
    if (read == null) return;
    final stored = read();
    if (stored == null || stored.isEmpty) return;
    try {
      await _reportVoip(stored);
    } on Object catch (error) {
      _log('登记 VoIP 标识失败：$error');
    }
  }

  /// 交出去一次，并**只在服务端真的收下时**记账 —— 没报成（未登录 / 网络失败）
  /// 就留着，下一次登录或连接就绪还会再试。
  Future<void> _reportVoip(String cid) async {
    if (cid == readVoipReported?.call()) {
      _log('VoIP 标识服务端已经收过了，不用重新上报');
      return;
    }
    final accepted = await report(cid);
    if (!accepted) {
      _log('VoIP 标识这次没报成（未登录 / 网络），下次登录或连接时再试');
      return;
    }
    await saveVoipReported?.call(cid);
  }

  /// 标识变了才落盘 + 上报。没变就不打扰服务端 ——
  /// 每次启动都上报一遍没有意义（服务端设备表是按标识去重的）。
  Future<void> apply(String cid) async {
    if (cid.isEmpty) return;
    try {
      if (readCid() == cid) {
        _log('设备标识没变，不用重新上报');
        return;
      }
      // 先落盘再上报：上报请求本身也要带 `cid` 头，而且服务端可能更新设备行
      await saveCid(cid);
      await report(cid);
    } on Object catch (error) {
      _log('登记设备标识失败：$error');
    }
  }
}

/// 真机上的组装：来源 = FCM（平台默认），落盘 = `CredentialStore`，
/// 上报 = 老端那个 `bindUid({client_id, user_id, cid})`（后端按前缀存进设备表）。
final pushRegistrarProvider = Provider<PushRegistrar>((ref) {
  final registrar = PushRegistrar(
    source: ref.watch(pushTokenSourceProvider),
    readCid: () => CredentialStore.instance.cid,
    saveCid: (cid) => CredentialStore.instance.saveCid(cid),
    readVoipCid: () => CredentialStore.instance.cidVoip,
    saveVoipCid: (cid) => CredentialStore.instance.saveCidVoip(cid),
    readVoipReported: () => CredentialStore.instance.cidVoipReported,
    saveVoipReported: (cid) => CredentialStore.instance.saveCidVoipReported(cid),
    report: (cid) async {
      final user = ref.read(sessionStoreProvider).user;
      final clientId = CredentialStore.instance.clientId ?? '';
      // 未登录 / 还没拿到 client_id：本地已经存下了，等下一次 bindUid 会带上。
      // （client_id 为空时服务端那一步会先建 Gateway 绑定、抛错后就不再处理 cid）
      if (user == null || clientId.isEmpty) {
        debugPrint('[推送] 暂不上报设备标识（未登录或 client_id 未就绪）');
        // 回 false = 「这次没交出去」：调用方**别记账**，否则那条标识就再也不会重报
        return false;
      }
      try {
        await ref.read(authApiProvider).bindUid(<String, dynamic>{
          'client_id': clientId,
          'user_id': user.userId,
          'cid': cid,
        });
        debugPrint('[推送] 设备标识已上报：${pushTokenShort(cid)}');
        return true;
      } on ApiException catch (error) {
        // 上报失败不弹提示：下一次连接就绪/登录会再试一遍
        debugPrint('[推送] 设备标识上报失败：${error.message}');
        return false;
      }
    },
  );
  ref.onDispose(registrar.stop);
  return registrar;
});

/// 把 `fcm:xxxx` 缩短成能写进日志的样子（完整 token 不写日志）
String pushTokenShort(String cid) {
  final index = cid.indexOf(':');
  if (index < 0) return cid.length <= 8 ? cid : '${cid.substring(0, 8)}…';
  final provider = cid.substring(0, index);
  final token = cid.substring(index + 1);
  return '$provider:${token.length <= 8 ? token : token.substring(0, 8)}…';
}
