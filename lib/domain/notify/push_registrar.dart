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
class PushRegistrar {
  PushRegistrar({
    required this.source,
    required this.readCid,
    required this.saveCid,
    required this.report,
    void Function(String message)? log,
  }) : _log = log ?? ((message) => debugPrint('[推送] $message'));

  final PushTokenSource source;
  final String? Function() readCid;
  final Future<void> Function(String cid) saveCid;
  final Future<void> Function(String cid) report;
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
    report: (cid) async {
      final user = ref.read(sessionStoreProvider).user;
      final clientId = CredentialStore.instance.clientId ?? '';
      // 未登录 / 还没拿到 client_id：本地已经存下了，等下一次 bindUid 会带上。
      // （client_id 为空时服务端那一步会先建 Gateway 绑定、抛错后就不再处理 cid）
      if (user == null || clientId.isEmpty) {
        debugPrint('[推送] 暂不上报设备标识（未登录或 client_id 未就绪）');
        return;
      }
      try {
        await ref.read(authApiProvider).bindUid(<String, dynamic>{
          'client_id': clientId,
          'user_id': user.userId,
          'cid': cid,
        });
        debugPrint('[推送] 设备标识已上报：${pushTokenShort(cid)}');
      } on ApiException catch (error) {
        // 上报失败不弹提示：下一次连接就绪/登录会再试一遍
        debugPrint('[推送] 设备标识上报失败：${error.message}');
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
