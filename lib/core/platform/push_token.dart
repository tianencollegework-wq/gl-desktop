import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 推送设备标识（S8.1）。
///
/// 老端把「推送客户端 id」放在 `cid` 字段里上报（登录与 `bindUid` 都会带），
/// 值来自 uniPush / 个推。新端沿用同一个字段，只是**值里带上服务商前缀**：
/// `fcm:xxxx` / `getui:xxxx`，服务端按前缀分流（`bindCid()` → 设备表 → 下发）。
/// 这样后端不用加字段、老端那套上报接口原样能用。
@immutable
class PushToken {
  const PushToken({required this.provider, required this.token});

  /// 服务商：`fcm` / `getui`（与后端 `PushManager` 的前缀一致）
  final String provider;

  /// 服务商给的设备标识（FCM registration token / 个推 cid）
  final String token;

  /// 上报给服务端的形态（就是那个 `cid`）
  String get cid => '$provider:$token';

  bool get isValid => provider.isNotEmpty && token.isNotEmpty;

  /// 日志里用的短形态：**完整标识不要写进日志**（它等于一把能给别人推送的钥匙）
  String get short =>
      '$provider:${token.length <= 8 ? token : token.substring(0, 8)}…';

  @override
  String toString() => 'PushToken($short)';
}

/// 设备标识的来源。抽成接口的理由与 `MessageNotificationPresenter` 一样：
/// 真机能力（Firebase）单测里跑不了，而上报规则必须能钉住。
abstract interface class PushTokenSource {
  /// 这台设备有没有推送通道（桌面/测试环境没有）
  bool get supported;

  /// 当前标识。拿不到（没配 Firebase、没网、服务商报错）返回 null，
  /// **不抛异常**：推送拿不到标识不该影响登录与收发消息。
  Future<PushToken?> current();

  /// 标识轮换（FCM 的 token 会不定期换：重装、清数据、长期不活跃）
  Stream<PushToken> get onRefresh;
}

/// 没有推送通道时的实现（桌面/测试）。
class NoopPushTokenSource implements PushTokenSource {
  const NoopPushTokenSource();

  @override
  bool get supported => false;

  @override
  Future<PushToken?> current() async => null;

  @override
  Stream<PushToken> get onRefresh => const Stream<PushToken>.empty();
}

/// Firebase Cloud Messaging。对应老端的 uniPush，但走的是 Google 那条长连接：
/// **进程被冻结/杀掉也能收到**（这是它相对「保活住 WS」的价值所在）。
///
/// 覆盖范围：海外 + 带 Google 服务的机器。没有 GMS 的国产机收不到，
/// 那条路是个推/厂商通道（同一套接口的另一个实现，见 [PushToken.provider]）。
class FcmPushTokenSource implements PushTokenSource {
  FcmPushTokenSource({this.messaging});

  /// 允许测试注入；真机上是 [FirebaseMessaging.instance]（在 Firebase 初始化之后才可用）
  final FirebaseMessaging? messaging;

  static const String providerId = 'fcm';

  /// 初始化结果：null = 还没试过。**失败也缓存**：缺 google-services.json 这类
  /// 问题不会自己变好，每次收到消息都重试一遍只会刷日志。
  bool? _ready;

  @override
  bool get supported => true;

  FirebaseMessaging get _fcm => messaging ?? FirebaseMessaging.instance;

  /// 后台 isolate 与主 isolate 各有一份：初始化要放在真正用到之前
  Future<bool> _ensure() async {
    final cached = _ready;
    if (cached != null) return cached;
    try {
      if (Firebase.apps.isEmpty) await Firebase.initializeApp();
      _ready = true;
    } on Object catch (error) {
      // 常见原因：构建时没带 google-services.json、包名与 Firebase 项目不一致
      debugPrint('[推送] Firebase 初始化失败，推送通道不可用：$error');
      _ready = false;
    }
    return _ready!;
  }

  @override
  Future<PushToken?> current() async {
    if (!await _ensure()) return null;
    try {
      final token = await _fcm.getToken();
      if (token == null || token.isEmpty) {
        // 真机上偶发（比如刚安装、还没跟 Google 建好连接），下次连上会自己好
        debugPrint('[推送] FCM 暂时没给 token');
        return null;
      }
      return PushToken(provider: providerId, token: token);
    } on Object catch (error) {
      debugPrint('[推送] 读取 FCM token 失败：$error');
      return null;
    }
  }

  @override
  Stream<PushToken> get onRefresh =>
      Stream<PushToken>.multi((controller) async {
        try {
          if (!await _ensure()) return;
          await for (final token in _fcm.onTokenRefresh) {
            if (token.isEmpty) continue;
            controller.add(PushToken(provider: providerId, token: token));
          }
        } on Object catch (error) {
          // 监听失败只影响「轮换后自动重新上报」，主流程不受影响
          debugPrint('[推送] 监听 token 轮换失败：$error');
        }
      });
}

/// 平台默认来源：手机用 FCM，其它平台没有推送通道。
///
/// 上层拿到的永远是 [PushTokenSource]，以后接个推就是在这里多一个分支
/// （按设备有没有 GMS 选），调用方一行都不用改。
PushTokenSource defaultPushTokenSource() =>
    (Platform.isAndroid || Platform.isIOS)
    ? FcmPushTokenSource()
    : const NoopPushTokenSource();

final pushTokenSourceProvider = Provider<PushTokenSource>(
  (ref) => defaultPushTokenSource(),
);
