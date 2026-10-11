import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:gracelinkim/core/config/app_config.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/data/db/app_database.dart';

/// 内存数据库：每个测试一套，互不干扰（真实文件库见 `AppDatabase()`）
AppDatabase memoryDatabase() => AppDatabase(NativeDatabase.memory());

/// 测试用的固定配置（不指向真实服务器）
const AppConfig testApiConfig = AppConfig(
  env: AppEnv.dev,
  scheme: 'https',
  host: 'example.test',
  hostToken: 'sha-hidden-bi',
);

/// 按路径返回预设报文的假 adapter，并记录每个请求。
///
/// 之所以不在测试里直接 mock 仓库，是因为参数名（`toContactId` / `last_id`
/// 这类）本身就是最容易写错的东西，必须让真实的 [ApiClient] 走一遍。
class StubAdapter implements HttpClientAdapter {
  /// 路径 → 响应体（JSON 字符串）。没配的路径返回 `{"code":0,"data":null}`
  final Map<String, String> responses = <String, String>{};

  /// 路径 → 状态码（默认 200）
  final Map<String, int> statusCodes = <String, int>{};

  final List<RequestOptions> requests = <RequestOptions>[];

  List<String> get paths => requests.map((request) => request.path).toList();

  RequestOptions requestTo(String path) =>
      requests.firstWhere((request) => request.path == path);

  Map<String, dynamic> bodyOf(String path) {
    final data = requestTo(path).data;
    if (data is Map) return data.cast<String, dynamic>();
    if (data is String) return json.decode(data) as Map<String, dynamic>;
    return <String, dynamic>{};
  }

  /// 取最后一次请求（同一个接口被调多次时用）
  Map<String, dynamic> lastBodyOf(String path) {
    final matched = requests.where((request) => request.path == path).toList();
    final data = matched.last.data;
    if (data is Map) return data.cast<String, dynamic>();
    if (data is String) return json.decode(data) as Map<String, dynamic>;
    return <String, dynamic>{};
  }

  /// 成功信封：`data` 可以是对象或数组。
  ///
  /// 分页接口（`postPage`）还要信封里的 `count`（总数），传了 [count] 才会带上。
  void ok(String path, {Object? data, int? count}) {
    responses[path] = json.encode(<String, dynamic>{
      'code': 0,
      'msg': 'ok',
      'data': data,
      'count': ?count,
    });
  }

  void fail(String path, {int code = 500, String msg = '炸了'}) {
    responses[path] = json.encode(<String, dynamic>{
      'code': code,
      'msg': msg,
      'data': null,
    });
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final body =
        responses[options.path] ??
        json.encode(<String, dynamic>{'code': 0, 'msg': 'ok', 'data': null});
    return ResponseBody.fromString(
      body,
      statusCodes[options.path] ?? 200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}

  /// 建一个走这个 adapter 的 [ApiClient]
  ApiClient apiClient({CredentialStore? credentials}) {
    final dio = Dio()..httpClientAdapter = this;
    return ApiClient(
      config: testApiConfig,
      credentials: credentials ?? CredentialStore.instance,
      dio: dio,
    );
  }
}
