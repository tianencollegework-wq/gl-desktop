import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/net/geo_ip.dart';
import 'package:gracelinkim/features/login/password_login_policy.dart';

/// 出口 IP 归属地（`core/net/geo_ip.dart`）+ 密码登陆的地域规矩
/// （`features/login/password_login_policy.dart`）。
///
/// 这两件事都是 2026-10-08 用户提的：密码登陆只对美国开放。用例钉三件事 ——
/// 三个公开端点**依次试**、结果（含「查不到」）只查一次、判定表。
///
/// 注意这里不能真发请求：下面用一个按 **host** 找答案的假 adapter
/// （`test_database.dart` 里那个是按路径找的，这三个端点路径都是 `/`，
/// 分不开）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _HostAdapter adapter;

  setUp(() => adapter = _HostAdapter());

  /// 造一个走假 adapter 的服务
  HttpGeoIpService service() => HttpGeoIpService(
    dio: Dio()..httpClientAdapter = adapter,
    timeout: const Duration(seconds: 2),
  );

  test('第一家（api.country.is）答了就收工：国家代码统一成大写', () async {
    adapter.answer('api.country.is', '{"ip":"8.8.8.8","country":"us"}');

    expect(await service().countryCode(), 'US');
    expect(adapter.hosts, <String>['api.country.is'], reason: '一家答了就不该再问下一家');
  });

  test('第一家挂了就问第二家、再挂再问第三家', () async {
    // country.is 404（被墙 / 改接口都长这样），ipwho.is 给 DE…
    adapter.status('api.country.is', 404);
    adapter.answer('ipwho.is', '{"ip":"1.2.3.4","country_code":"DE"}');

    expect(await service().countryCode(), 'DE');
    expect(adapter.hosts, <String>['api.country.is', 'ipwho.is']);

    // 前两家都不行 → 第三家顶上（ipapi.co 的字段也是 country_code）
    adapter = _HostAdapter()
      ..status('api.country.is', 500)
      ..answer('ipwho.is', '{"success":false}')
      ..answer('ipapi.co', '{"ip":"1.2.3.4","country_code":"FR"}');

    expect(await service().countryCode(), 'FR');
    expect(adapter.hosts, <String>['api.country.is', 'ipwho.is', 'ipapi.co']);
  });

  test('三家都答不上来 → null；而且不再重问（结果含「查不到」都只查一次）', () async {
    adapter
      ..status('api.country.is', 404)
      ..answer('ipwho.is', '<html>502 Bad Gateway</html>')
      ..answer('ipapi.co', '{"country_code":"不"}');

    final geo = service();
    expect(await geo.countryCode(), isNull);
    expect(adapter.hosts.length, 3);

    // 第二次：直接吃缓存，不打任何请求
    expect(await geo.countryCode(), isNull);
    expect(adapter.hosts.length, 3, reason: '一次运行只查一次');
  });

  test('同时问两次共用同一次查询（登录页连点不该打两轮）', () async {
    adapter.answer('api.country.is', '{"country":"US"}');

    final geo = service();
    final first = geo.countryCode();
    final second = geo.countryCode();
    expect(await Future.wait<String?>(<Future<String?>>[first, second]), <String?>[
      'US',
      'US',
    ]);
    expect(adapter.hosts.length, 1);
  });

  test('判定表：只有 US 放行，null（查不到）也算不放行', () {
    expect(passwordLoginAllowedIn('US'), isTrue);
    expect(passwordLoginAllowedIn('us'), isTrue, reason: '大小写不该影响判定');
    expect(passwordLoginAllowedIn('DE'), isFalse);
    expect(passwordLoginAllowedIn('CN'), isFalse);
    expect(passwordLoginAllowedIn(''), isFalse);
    expect(passwordLoginAllowedIn('USA'), isFalse, reason: '不是两位国家码一律不算');
    expect(
      passwordLoginAllowedIn(null),
      isFalse,
      reason: '查不清就不放行 —— 这是一道限制，不是便利功能',
    );
  });
}

/// 按 **host** 找答案的假 adapter（三个归属地端点路径都是 `/`，按路径分不开）
class _HostAdapter implements HttpClientAdapter {
  /// host → 响应体
  final Map<String, String> bodies = <String, String>{};

  /// host → 状态码
  final Map<String, int> codes = <String, int>{};

  /// 按顺序记下每个被问到的 host
  final List<String> hosts = <String>[];

  void answer(String host, String body) => bodies[host] = body;

  void status(String host, int code) => codes[host] = code;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final host = options.uri.host;
    hosts.add(host);
    return ResponseBody.fromString(
      bodies[host] ?? 'not found',
      codes[host] ?? 200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
