import 'dart:async';

import 'package:gracelinkim/core/net/geo_ip.dart';

/// 假的归属地查询：直接给一个结果，不碰网络。
///
/// 密码登陆那道地域闸门（`features/login/password_login_policy.dart`）就是靠它
/// 在用例里钉住的 —— 真实现（[HttpGeoIpService]）要联网，单测里不能跑。
class FakeGeoIp implements GeoIpService {
  FakeGeoIp(this.country, {this.error});

  /// 交给调用方的国家代码（`US` / `DE` / null = 查不到）
  final String? country;

  /// 给了就抛出来（模拟「查询本身炸了」那条路）
  final Object? error;

  /// 被问了几次（钉子：一次运行只查一次）
  int calls = 0;

  @override
  Future<String?> countryCode() async {
    calls++;
    final failure = error;
    if (failure != null) throw failure;
    return country;
  }
}

/// 假的归属地查询，但**答复的时机由用例控制**（想验「正在查」那一帧时用）。
class GatedGeoIp implements GeoIpService {
  final Completer<String?> _completer = Completer<String?>();

  int calls = 0;

  /// 用例里调它把结果放出去
  void answer(String? country) => _completer.complete(country);

  @override
  Future<String?> countryCode() {
    calls++;
    return _completer.future;
  }
}
