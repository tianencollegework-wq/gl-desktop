import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 出口 IP 的国家/地区代码（ISO 3166-1 alpha-2，大写，如 `US`）。
///
/// 为什么要有它：用户 2026-10-08 定的规矩 —— 电脑端的「密码登陆」只对美国开放，
/// 别处一律提示「您当前的位置不支持密码登陆」。判断依据是**出口 IP 落在哪个
/// 国家**，而 Flutter 本身拿不到这件事（`NetworkInterface` 只能看到内网地址），
/// 得问一个公开的 IP 归属地服务。
///
/// 抽成接口的理由与 `MediaSaver` / `AppInstaller` 一样：这是个外部依赖，单测里
/// 不能真去访问网络，而「查不到怎么办」这条分支必须能钉住。
abstract interface class GeoIpService {
  /// 查一次出口 IP 的国家代码；**查不到返回 null**（断网 / 服务挂了 / 格式变了）。
  ///
  /// null 该怎么算由调用方定：密码登陆那边按「不在美国」处理
  /// （见 `features/login/password_login_policy.dart`）。
  Future<String?> countryCode();
}

/// 问公开的归属地服务（不需要 API key 的那种）。
///
/// 为什么走外部服务而不是自家接口：本仓库只有客户端，服务端在另一个仓库里，
/// 要它给一个「你在哪个国家」的接口得先改服务端 —— 而这只是**客户端自己的一道
/// 体验闸门**（真正的限制只能由服务端把关，见
/// `features/login/password_login_policy.dart` 的说明）。
///
/// 三个端点**依次试**，谁先答出来用谁的：都是公开的 keyless 接口，
/// 单独一个总有被限流、被墙、改格式的时候。一次运行**只查一次**，
/// 结果（含「查不到」）在本进程里记住 —— 登录页上切来切去不必反复打它们。
class HttpGeoIpService implements GeoIpService {
  HttpGeoIpService({Dio? dio, this.timeout = const Duration(seconds: 5)})
    : _dio = dio ?? Dio() {
    _dio.options
      ..connectTimeout = timeout
      ..receiveTimeout = timeout
      // 自己解析 JSON（与 `ApiClient` 同一条口径）：网关返回 HTML 错误页时，
      // 让 Dio 的 transformer 去解会把异常抛得很远
      ..responseType = ResponseType.plain
      // 状态码自己判：一家挂了就换下一家，不该有异常一路抛上去
      ..validateStatus = (code) => code != null && code == 200;
  }

  final Dio _dio;

  /// 单个端点最多等多久（查不动就换下一家，别让人对着转圈干等）
  final Duration timeout;

  /// 端点表：地址 + 从返回的 JSON 里取国家代码的字段名
  static const List<({String url, String field})> endpoints =
      <({String url, String field})>[
        // 就是为这件事做的：`{"ip":"1.2.3.4","country":"US"}`
        (url: 'https://api.country.is/', field: 'country'),
        (url: 'https://ipwho.is/', field: 'country_code'),
        (url: 'https://ipapi.co/json/', field: 'country_code'),
      ];

  bool _asked = false;
  String? _cached;
  Future<String?>? _inflight;

  @override
  Future<String?> countryCode() {
    if (_asked) return Future<String?>.value(_cached);
    // 并发调用共用同一次查询：连点两次不该打两轮
    return _inflight ??= _query();
  }

  Future<String?> _query() async {
    String? found;
    for (final endpoint in endpoints) {
      found = await _ask(endpoint.url, endpoint.field);
      if (found != null) break;
    }
    _asked = true;
    _cached = found;
    _inflight = null;
    if (found == null) {
      debugPrint('[地域] 三个归属地服务都没答出来（按「不在美国」处理）');
    }
    return found;
  }

  /// 问一家。任何异常（超时、DNS、返回 HTML、字段改名）都只算「这家没答出来」
  Future<String?> _ask(String url, String field) async {
    try {
      final response = await _dio.get<String>(url);
      final text = response.data ?? '';
      final json = jsonDecode(text);
      if (json is! Map) {
        debugPrint('[地域] $url 返回的不是对象：$text');
        return null;
      }
      final raw = '${json[field] ?? ''}'.trim().toUpperCase();
      if (_countryCode.hasMatch(raw)) return raw;
      debugPrint('[地域] $url 没给出国家代码（$field = "$raw"）');
    } on Object catch (error) {
      debugPrint('[地域] $url 查询失败：$error');
    }
    return null;
  }

  static final RegExp _countryCode = RegExp(r'^[A-Z]{2}$');
}

/// 生产用的那一份。测试里 override 成假实现（见 `test/support/fake_geo_ip.dart`）
final geoIpProvider = Provider<GeoIpService>((ref) => HttpGeoIpService());
