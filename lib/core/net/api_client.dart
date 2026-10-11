import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/app_config.dart';
import '../i18n/locale_controller.dart';
import '../store/credential_store.dart';
import '../ui/notice_bus.dart';
import '../util/json_value.dart';
import 'api_exception.dart';
import 'api_response.dart';
import 'protocol_log.dart';

/// HTTP 客户端，替代老端 `uni_modules/u-ajax` + `utils/request.js`。
///
/// 与老端保持一致的行为：
/// * 全部 POST + JSON；
/// * 请求头带 `Authorization` / `clientId` / `cid` / `accept-language`；
/// * `code == 0` 成功；`code == -1` 需要重登；HTTP 401 需要重登；
/// * 失败默认自动弹提示（老端在拦截器里做，这里在 [post] 里做）。
///
/// 与老端不同的两点（刻意的）：
/// 1. **不主动探测网络**。老端每个请求前都 `getNetworkType`，多一次系统调用且是异步竞态；
///    这里依赖 Dio 的超时/连接错误来判断，等价且更简单。
/// 2. 错误不再静默。老端拦截器里有些分支只 toast 不抛错，业务层拿不到失败信号。
class ApiClient {
  ApiClient({
    required AppConfig config,
    required CredentialStore credentials,
    Dio? dio,
  }) : _config = config,
       _store = credentials,
       _dio = dio ?? Dio() {
    _dio.options
      ..baseUrl = config.apiUrl
      ..connectTimeout = const Duration(seconds: 10)
      ..receiveTimeout = const Duration(seconds: 10)
      ..sendTimeout = const Duration(seconds: 10)
      ..contentType = Headers.jsonContentType
      // 自己解析 JSON，不让 Dio 的 transformer 插手。
      // 原因：网关/反代返回 HTML 错误页时，Dio 解码失败会把整个响应
      // （含状态码）吞掉，归为 unknown；明文拿回来我们自己判状态码更可靠。
      ..responseType = ResponseType.plain
      // 状态码交给这里判断，避免 Dio 在 401/500 时抛异常
      ..validateStatus = (code) => code != null && code < 600;

    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          options.headers.addAll(buildHeaders());
          handler.next(options);
        },
      ),
    );
  }

  final AppConfig _config;
  final CredentialStore _store;
  final Dio _dio;

  Dio get dio => _dio;

  String get apiUrl => _config.apiUrl;

  /// 请求头（公开出来是为了可测：老端这四项是最容易漏的）
  Map<String, String> buildHeaders() {
    final headers = <String, String>{'Content-Type': 'application/json'};
    final token = _store.authToken;
    if (token != null && token.isNotEmpty) headers['Authorization'] = token;
    final clientId = _store.clientId;
    if (clientId != null && clientId.isNotEmpty) headers['clientId'] = clientId;
    final cid = _store.cid;
    if (cid != null && cid.isNotEmpty) headers['cid'] = cid;
    // 手动选过就发他选的那个，没选过就发系统语言（对不上落英语）——
    // 与界面语言同一套口径（`LocaleController.systemLocaleCode`）
    headers['accept-language'] =
        _store.language ?? LocaleController.systemLocaleCode();
    return headers;
  }

  /// 路径归一化。
  ///
  /// 老端 `api/message.js` 里有些接口少了前导斜杠（`enterprise/im/searchUser`），
  /// 在 u-ajax 下能忍，在 Dio 下会按 URL 解析规则拼成 `https://hostenterprise/im/...`。
  static String normalizePath(String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) return path;
    return path.startsWith('/') ? path : '/$path';
  }

  /// 发一个请求，返回信封（不做自动提示）。
  /// [timeout] 是**这条请求**的超时（连接 / 收 / 发三样一起），不传就用全局那 10 秒。
  ///
  /// 为什么要能按请求给：全局 10 秒是按普通接口定的，而群通话那条链每一跳都要
  /// 我们的服务端再走一趟 Cloudflare（服务端自己那条上游超时是 5s），服务端一抖
  /// 就是十几秒起（见 `SfuApi.requestTimeout` 的注释）。给那几条单独放宽，
  /// 普通接口继续失败得快。
  Future<ApiResponse> send(
    String path, {
    Object? data,
    String method = 'POST',
    Duration? timeout,
  }) async {
    final normalized = normalizePath(path);
    ProtocolLog.httpRequest(method, normalized, data);

    try {
      final response = await _request(
        normalized,
        data: data,
        method: method,
        timeout: timeout,
      );
      final status = response.statusCode ?? 0;
      ProtocolLog.httpResponse(normalized, status, response.data);

      return _parse(normalized, status, response.data);
    } on DioException catch (error) {
      throw _mapDioException(error);
    }
  }

  /// 表单上传（头像 / 文件 / 自定义表情）。
  ///
  /// 老端把完整 URL 交给 uploader 直传，Flutter 端走同一个解析路径，
  /// 保证错误码语义与普通接口一致。
  Future<Map<String, dynamic>> upload(
    String path,
    FormData form, {
    bool notify = true,
  }) async => (await uploadEnvelope(path, form, notify: notify)).dataAsMap;

  /// 表单上传，但把**整个信封**交回调用方。
  ///
  /// 头像上传接口的 `data` 直接就是图片 URL（老端 `this.userInfo.avatar = res.data`），
  /// 用 [upload] 的 `dataAsMap` 会拿到空 map——所以单独留一个出口。
  Future<ApiResponse> uploadEnvelope(
    String path,
    FormData form, {
    bool notify = true,
  }) async {
    final normalized = normalizePath(path);
    ProtocolLog.httpRequest(
      'POST(form)',
      normalized,
      form.fields.map((entry) => '${entry.key}=${entry.value}').toList(),
    );

    try {
      final response = await _request(normalized, data: form);
      final status = response.statusCode ?? 0;
      ProtocolLog.httpResponse(normalized, status, response.data);
      return _parse(normalized, status, response.data);
    } on DioException catch (error) {
      final mapped = _mapDioException(error);
      if (notify) notifyError(mapped);
      throw mapped;
    } on ApiException catch (error) {
      if (notify) notifyError(error);
      rethrow;
    }
  }

  /// 连接层失败的重试次数。
  ///
  /// **只在 `connectionError`（连接根本没建起来）上重试**：那种失败下请求
  /// 一定没发出去，重试不会造成重复消息；超时/收包失败一律不重试（请求可能
  /// 已经到了服务端，重试会把消息发两遍）。冷启动时网络刚就绪、DNS 还没好的
  /// 那一下，靠这一下重试就能自愈，不用用户「关了再开」。
  static const int _connectRetries = 1;
  static const Duration _connectRetryDelay = Duration(milliseconds: 600);

  Future<Response<dynamic>> _request(
    String path, {
    required Object? data,
    String method = 'POST',
    Duration? timeout,
  }) async {
    var attempt = 0;
    while (true) {
      try {
        return await _dio.request<dynamic>(
          path,
          data: data,
          options: Options(
            method: method,
            // 三个都是 null 时 Dio 会用全局那份（10 秒），行为与从前一致
            connectTimeout: timeout,
            receiveTimeout: timeout,
            sendTimeout: timeout,
          ),
        );
      } on DioException catch (error) {
        if (error.type != DioExceptionType.connectionError ||
            attempt >= _connectRetries) {
          rethrow;
        }
        attempt += 1;
        debugPrint(
          '[网络] $method $path 连接失败，${_connectRetryDelay.inMilliseconds}ms 后重试（第 $attempt 次）',
        );
        await Future<void>.delayed(_connectRetryDelay);
      }
    }
  }

  ApiResponse _parse(String path, int status, dynamic data) {
    if (status == 401) throw const UnauthorizedException();
    if (status >= 500) throw const ServerException();

    final envelope = ApiResponse.fromJson(asStringKeyedMap(data));
    final error = envelope.toException();
    if (error != null) throw error;
    return envelope;
  }

  /// 发请求并解析 `data`。失败时按老端行为自动提示（可用 `notify: false` 关掉）。
  Future<T> post<T>(
    String path, {
    Object? data,
    required T Function(dynamic data) parse,
    bool notify = true,
    Duration? timeout,
  }) async {
    try {
      final envelope = await send(path, data: data, timeout: timeout);
      return parse(envelope.data);
    } on ApiException catch (error) {
      if (notify) notifyError(error);
      rethrow;
    }
  }

  /// 只关心成功与否的接口
  Future<void> postVoid(
    String path, {
    Object? data,
    bool notify = true,
    Duration? timeout,
  }) => post<void>(
    path,
    data: data,
    parse: (_) {},
    notify: notify,
    timeout: timeout,
  );

  /// `data` 是对象的接口
  Future<Map<String, dynamic>> postMap(
    String path, {
    Object? data,
    bool notify = true,
    Duration? timeout,
  }) => post<Map<String, dynamic>>(
    path,
    data: data,
    parse: asStringKeyedMap,
    notify: notify,
    timeout: timeout,
  );

  /// `data` 是数组的接口（会话列表、消息列表、群成员等）。
  ///
  /// 老端对这些接口直接 `res.data.forEach(...)`，所以 data 是数组；
  /// 用 [postMap] 读它们会拿到空 map（`asStringKeyedMap` 对数组返回 {}），
  /// 属于很容易踩的坑，所以单独开一个方法。
  Future<List<dynamic>> postList(
    String path, {
    Object? data,
    bool notify = true,
  }) => post<List<dynamic>>(path, data: data, parse: asList, notify: notify);

  /// 分页列表接口：`data` 是数组，信封里另外带一个 `count`（总数）。
  ///
  /// 老端的分页组件靠 `res.count` 算页数（好友申请、群成员等都这样），
  /// 所以这两样得一起给出来。
  Future<({List<Map<String, dynamic>> rows, int count})> postPage(
    String path, {
    Object? data,
    bool notify = true,
  }) async {
    try {
      final envelope = await send(path, data: data);
      final rows = envelope.dataAsList
          .whereType<Map<dynamic, dynamic>>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
      return (rows: rows, count: envelope.count);
    } on ApiException catch (error) {
      if (notify) notifyError(error);
      rethrow;
    }
  }

  /// 数组里每一项都是对象的接口，直接给出 `List<Map>`，省得调用方层层转型
  Future<List<Map<String, dynamic>>> postListMaps(
    String path, {
    Object? data,
    bool notify = true,
  }) => postList(path, data: data, notify: notify).then(
    (list) => list
        .whereType<Map<dynamic, dynamic>>()
        .map((item) => item.cast<String, dynamic>())
        .toList(),
  );

  static ApiException _mapDioException(DioException error) {
    // 先看 HTTP 状态码：网关/反代返回 HTML 错误页时，Dio 会因为解不出 JSON
    // 把 type 归为 unknown，这时只有状态码还靠得住（老端也没处理这种情况）。
    final status = error.response?.statusCode;
    if (status != null) {
      if (status == 401) return const UnauthorizedException();
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
        final code = error.response?.statusCode ?? 0;
        return UnknownApiException('请求失败（HTTP $code）');
    }
  }

  /// 统一的失败提示。老端是在拦截器里弹 toast / 重登。
  void notifyError(ApiException error) {
    if (error.needsRelogin) {
      noticeBus.requireRelogin(error.message);
    } else if (error.shouldToast) {
      noticeBus.toast(error.message);
    }
  }
}

final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(
    config: ref.watch(appConfigProvider),
    credentials: CredentialStore.instance,
  );
});
