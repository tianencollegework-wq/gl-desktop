import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/net/api_exception.dart';
import '../../../core/store/lingting_store.dart';
import '../../../core/util/json_value.dart';

/// 灵听（第三方音乐服务）的 HTTP 客户端。
///
/// 为什么**不复用** [ApiClient]：那是聊天后端的客户端，baseUrl、请求头
/// （`Authorization` / `clientId` / `cid`）、信封（`code == 0`）、
/// 失败即弹重登提示……全是聊天那套语义。灵听是另一个域名、另一套鉴权
/// （`memberId` + `token` 两个头）、另一种信封（`success` + `errorCode`），
/// 硬塞进同一个客户端只会让两边的语义互相污染。
///
/// 共同点只有「宽松解析 + 失败抛 [ApiException]」，那部分直接复用。
class LingtingClient {
  LingtingClient({LingtingStore? store, Dio? dio, String? baseUrl})
    : _store = store ?? LingtingStore.instance,
      _baseUrl = baseUrl ?? defaultBaseUrl,
      _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = _baseUrl
      ..connectTimeout = const Duration(seconds: 12)
      ..receiveTimeout = const Duration(seconds: 12)
      ..sendTimeout = const Duration(seconds: 12)
      ..contentType = Headers.jsonContentType
      // 与聊天客户端同一个理由：自己判状态码，别让 Dio 的 transformer
      // 在拿到 HTML 错误页时把状态码一起吞掉
      ..responseType = ResponseType.plain
      ..validateStatus = (code) => code != null && code < 600;
  }

  /// 灵听正式环境
  static const String defaultBaseUrl = 'https://check-api.lingtingmusic.com';

  final Dio _dio;
  final LingtingStore _store;
  final String _baseUrl;

  String get baseUrl => _baseUrl;

  /// 请求头：灵听认这两个（`memberId` 与 `token`）。
  ///
  /// 文档里说 `memberId: 0` 就是「匿名」——实测确实能调搜索/详情这类弱鉴权接口；
  /// 收藏、播放历史那些强鉴权接口则必须带上登录后拿到的 `token` 与真实
  /// `memberId`，否则 401。
  Map<String, String> buildHeaders() {
    final headers = <String, String>{'Content-Type': 'application/json'};
    headers['memberId'] = _store.memberId.toString();
    final token = _store.token;
    if (token != null && token.isNotEmpty) headers['token'] = token;
    return headers;
  }

  /// GET，返回信封里的 `data`（数组 / 对象 / 字符串都可能）
  Future<dynamic> get(
    String path, {
    Map<String, dynamic>? query,
    bool notify = false,
  }) => _send(path, query: query, method: 'GET', notify: notify);

  /// POST（灵听的写接口几乎都把参数放在 **query** 上，比如 `like?songId=27`）
  Future<dynamic> post(
    String path, {
    Map<String, dynamic>? query,
    Object? data,
    bool notify = false,
  }) => _send(path, query: query, data: data, method: 'POST', notify: notify);

  Future<dynamic> _send(
    String path, {
    Map<String, dynamic>? query,
    Object? data,
    required String method,
    required bool notify,
  }) async {
    try {
      final response = await _dio.request<dynamic>(
        path,
        data: data,
        queryParameters: query,
        options: Options(method: method),
      );
      return _parse(response.data, response.statusCode ?? 0);
    } on DioException catch (error) {
      final mapped = _mapDioException(error);
      if (notify) debugPrint('[灵听] $method $path 失败：${mapped.message}');
      throw mapped;
    }
  }

  /// 取一段**不在信封里**的内容：歌词是直接给一个 `.lrc` 静态文件地址，
  /// 那个地址返回的是纯文本，走这条路。
  ///
  /// 注意地址长这样（服务端原样给 COS 上的文件名，**不做转义**）：
  ///
  /// `https://listen-to-heart-….cos.ap-nanjing.myqcloud.com/music/voice/一粒麥子 (feat. 林婉容) [-yvFQ74Nwjs].lrc`
  ///
  /// 里面带空格、中文和方括号。**千万别**再自己转义一遍 —— `Uri.parse`
  /// （Dio 内部就是它）已经把该转的都转好了，手工 `encodeComponent` 会变成
  /// 二次转义（`%20` → `%2520`），COS 那边直接回 `NoSuchKey`。这一条是踩过的坑。
  Future<String> getPlainText(String url) async {
    try {
      final response = await _dio.get<dynamic>(
        url,
        options: Options(
          method: 'GET',
          responseType: ResponseType.plain,
          headers: const <String, String>{},
        ),
      );
      return asText(response.data);
    } on DioException catch (error) {
      throw _mapDioException(error);
    }
  }

  dynamic _parse(dynamic raw, int status) {
    if (status == 401) throw const UnauthorizedException('灵听登录状态已失效');
    if (status >= 500) throw const ServerException();

    // 歌词那种静态文件不走进来（走 [getPlainText]），这里一定是信封
    final envelope = asMap(
      raw is String && raw.isNotEmpty ? _tryDecode(raw) : raw,
    );
    if (envelope.isEmpty) {
      throw const UnknownApiException('灵听返回了无法解析的内容');
    }
    final success = asBool(envelope['success'], fallback: false);
    if (!success) {
      final message = asText(envelope['errorMessage'], '灵听请求失败');
      final code = asText(envelope['errorCode'], '');
      // `errorCode` 是字符串（成功是 "0"）；401 那种按需重登处理
      if (code == '401' || message.contains('认证') || message.contains('登录')) {
        throw UnauthorizedException(message);
      }
      throw BusinessException(asInt(envelope['errorCode'], -1), message);
    }
    return envelope['data'];
  }

  dynamic _tryDecode(String raw) {
    try {
      return json.decode(raw);
    } on FormatException {
      return const <String, dynamic>{};
    }
  }

  /// 与聊天客户端同一套映射（超时/断网/5xx）
  static ApiException _mapDioException(DioException error) {
    final status = error.response?.statusCode;
    if (status != null) {
      if (status == 401) return const UnauthorizedException('灵听登录状态已失效');
      if (status >= 500) return const ServerException();
    }
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const NetworkUnavailableException('请求超时，请检查网络后重试');
      case DioExceptionType.connectionError:
        return const NetworkUnavailableException();
      case DioExceptionType.badCertificate:
      case DioExceptionType.cancel:
      case DioExceptionType.transformTimeout:
      case DioExceptionType.unknown:
        return const UnknownApiException();
      case DioExceptionType.badResponse:
        return UnknownApiException('请求失败（HTTP ${status ?? 0}）');
    }
  }
}
