import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/config/app_config.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/data/api/report_api.dart';
import 'package:gracelinkim/data/repo/report_repository.dart';
import 'package:gracelinkim/domain/report/report_failure.dart';
import 'package:gracelinkim/domain/report/report_reasons.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// **部署顺序**上的兼容性（2026-10-11）。
///
/// 服务端那份补丁是**纯新增**（5 个文件线上都不存在、不改任何现有控制器与路由），
/// 所以「原来的客户端」不受影响：它根本不会调 `/enterprise/report/submit`。
/// 这里盯的是**反过来**的那一半 —— 客户端先更新、服务端还是旧的，
/// 也就是「用户点了投诉，但服务端没有这个接口」时会发生什么。
///
/// 旧服务端（ThinkPHP 6.0.15）对一个不存在的控制器回 **HTTP 404**，
/// 正文是什么取决于请求头里有没有 `Accept`：
///  * `Request::isJson()` 为真 → `{"code":0,"message":"页面错误！请稍后再试～"}`
///  * 否则 → HTML 错误页（`think_exception.tpl`）
/// 而 `ApiClient._parse` 只对 401 与 5xx 特殊处理，**404 会照常去读信封里的 code**
/// —— 于是「HTML 那一支」被读成 code 缺失（-999，用户看到一句失败），
/// 而「JSON 那一支」被读成 **code 0 = 成功**（用户看到「提交成功」，其实一条没存）。
///
/// 这一条链最容易在生产上踩的顺序坑就是它，所以两种正文都在这里钉一遍：
/// **先传服务端补丁，再发客户端新版本**。
const AppConfig _config = AppConfig(
  env: AppEnv.dev,
  scheme: 'https',
  host: 'example.test',
  hostToken: 'sha-hidden-bi',
);

/// 假 adapter：按给定状态码与正文回话，并把真实要发出去的请求记下来
class _Recorder implements HttpClientAdapter {
  _Recorder({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
  RequestOptions? lastRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// ThinkPHP `think_exception.tpl` 那种 HTML 错误页（截了前面一段）
const String _thinkPhpHtml404 =
    '<!DOCTYPE html>\n<html>\n<head>\n    <meta charset="UTF-8">\n'
    '    <title>系统发生错误</title>\n</head>\n<body>\n'
    '    <h1>控制器不存在:app\\enterprise\\controller\\Report</h1>\n'
    '</body>\n</html>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CredentialStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      CredentialStore.keyAuthToken: 'token-abc',
      CredentialStore.keyClientId: 'client-123',
      CredentialStore.keyCid: 'cid-9',
      CredentialStore.keyLanguage: 'zh-Hans',
    });
    store = await CredentialStore.init();
  });

  Future<ReportOutcome> submitThrough(_Recorder recorder) {
    final dio = Dio()..httpClientAdapter = recorder;
    final repo = ReportRepository(
      ReportApi(ApiClient(config: _config, credentials: store, dio: dio)),
    );
    return repo.submit(
      ReportTarget.user(userId: '11', userName: '张三', scene: ReportScene.chat),
      reason: ReportReason.harass,
      detail: '测试',
    );
  }

  test('我们发出去的请求头里没有 Accept —— 旧服务端走的是「HTML 错误页」那一支', () async {
    final recorder = _Recorder(statusCode: 404, body: _thinkPhpHtml404);
    await submitThrough(recorder);

    final headers = recorder.lastRequest!.headers;
    final accept = headers.entries
        .where((entry) => entry.key.toLowerCase() == 'accept')
        .toList();

    // `Request::isJson()` 读的就是 `HTTP_ACCEPT`（见 ThinkPHP 6.0.15 的
    // `think\Request::type()`），所以「有没有 Accept」直接决定旧服务端回 JSON 还是 HTML
    expect(
      accept,
      isEmpty,
      reason: '带了 Accept 的话，旧服务端会回 {"code":0} —— 那会被客户端读成「提交成功」',
    );
    // 但请求确实带上了鉴权与语言那几项（不是「什么都没带」）
    expect(headers['Authorization'], 'token-abc');
    expect(headers['accept-language'], 'zh-Hans');
  });

  test('旧服务端回 404 + HTML 错误页：用户看到的是失败，不是「提交成功」', () async {
    final outcome = await submitThrough(
      _Recorder(statusCode: 404, body: _thinkPhpHtml404),
    );

    expect(outcome, isA<ReportRejected>());
    expect(
      (outcome as ReportRejected).code,
      -999,
      reason: 'HTTP 404 的正文解不出信封，code 缺失 → -999（界面上是「请求失败（-999）」）',
    );
    expect(outcome.message, isNotEmpty);
  });

  test('已知陷阱：旧服务端若回 404 + {"code":0}（Accept 带 json 时就会），会被当成提交成功', () async {
    final outcome = await submitThrough(
      _Recorder(
        statusCode: 404,
        body: json.encode(<String, dynamic>{
          'code': 0,
          'message': '页面错误！请稍后再试～',
        }),
      ),
    );

    // 这里**如实记录现状**：`ApiClient._parse` 不看 404，只看信封里的 code。
    // 所以正确的做法是部署顺序 —— 先传服务端补丁，再发客户端新版本。
    expect(outcome, isA<ReportAccepted>());
    expect((outcome as ReportAccepted).reportId, 0);
  });
}
