import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 更新清单的地址（2026-10-08 起）。
///
/// **不是** `ApiClient` 那条路：那是给 `/enterprise`、`/common/pub` 那些接口用的
/// （带上登录态、认 `{code, msg, data}` 信封），而这是一份**公开的静态 JSON**，
/// 谁都能 GET。换地方（换域名、换文件名）只改这一行。
const String updateManifestUrl = 'https://message.gracelink.cc/update.json';

/// 抓更新清单（`updateManifestUrl`），对应「检查更新」的第一步。
///
/// 单独一条 [Dio]（不共用 `ApiClient` 那份）的理由：地址在别的域名上、响应体
/// 就是清单本身（没有信封），也不需要任何登录态 —— 共用那份反而要跟它的
/// 拦截器与鉴权规则打交道。
class UpdateApi {
  /// [dio] 只为用例注入（生产用默认那份），与 `SystemAppInstaller` 一个套路。
  UpdateApi([Dio? dio])
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
              responseType: ResponseType.json,
            ),
          );

  final Dio _dio;

  /// 拉清单并解析成 JSON 对象。失败（网络 / 非 2xx / 不是 JSON）**抛异常**，
  /// 由界面决定说不说话（手动点才提示，启动时那次静默）。
  Future<Map<String, dynamic>> fetchManifest() async {
    final response = await _dio.get<dynamic>(updateManifestUrl);
    final data = response.data;
    // 有的服务器/CDN 会把 `.json` 当 `text/plain` 发回来，Dio 就不替我们解了
    final decoded = data is String ? jsonDecode(data) : data;
    if (decoded is Map) return decoded.cast<String, dynamic>();
    throw const FormatException('更新清单不是 JSON 对象');
  }
}

final updateApiProvider = Provider<UpdateApi>((ref) => UpdateApi());
