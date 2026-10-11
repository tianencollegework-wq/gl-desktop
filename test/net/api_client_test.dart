import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/config/app_config.dart';
import 'package:gracelinkim/core/net/api_client.dart';
import 'package:gracelinkim/core/net/api_exception.dart';
import 'package:gracelinkim/core/store/credential_store.dart';
import 'package:gracelinkim/core/ui/notice_bus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const AppConfig _config = AppConfig(
  env: AppEnv.dev,
  scheme: 'https',
  host: 'example.test',
  hostToken: 'sha-hidden-bi',
);

/// 假 adapter：按预设状态码/报文返回，并记录最后一次请求，便于断言请求头与 body
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({required this.statusCode, required this.body});

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

String _envelope(int code, {String msg = '', dynamic data}) =>
    json.encode(<String, dynamic>{'code': code, 'msg': msg, 'data': data});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late CredentialStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      CredentialStore.keyAuthToken: 'token-abc',
      CredentialStore.keyClientId: 'client-123',
      CredentialStore.keyCid: 'cid-9',
      CredentialStore.keyLanguage: 'en',
    });
    store = await CredentialStore.init();
  });

  ApiClient clientWith(_FakeAdapter adapter) {
    final dio = Dio();
    dio.httpClientAdapter = adapter;
    return ApiClient(config: _config, credentials: store, dio: dio);
  }

  group('normalizePath', () {
    test('补上缺失的前导斜杠（老端 enterprise/im/searchUser 就是这种情况）', () {
      expect(
        ApiClient.normalizePath('enterprise/im/searchUser'),
        '/enterprise/im/searchUser',
      );
      expect(
        ApiClient.normalizePath('/enterprise/im/searchUser'),
        '/enterprise/im/searchUser',
      );
    });

    test('完整 URL 原样通过（上传接口用的是完整地址）', () {
      expect(
        ApiClient.normalizePath(
          'https://example.test/common/upload/uploadFile',
        ),
        'https://example.test/common/upload/uploadFile',
      );
    });
  });

  group('请求头', () {
    test('四项与老端一致', () {
      final headers = clientWith(
        _FakeAdapter(statusCode: 200, body: '{}'),
      ).buildHeaders();
      expect(headers['Authorization'], 'token-abc');
      expect(headers['clientId'], 'client-123');
      expect(headers['cid'], 'cid-9');
      expect(headers['accept-language'], 'en');
      expect(headers['Content-Type'], 'application/json');
    });

    test('未登录时不带 Authorization，但仍带语言', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        CredentialStore.keyLanguage: 'zh-Hans',
      });
      final freshStore = await CredentialStore.init();
      final client = ApiClient(
        config: _config,
        credentials: freshStore,
        dio: Dio(),
      );
      expect(client.buildHeaders().containsKey('Authorization'), isFalse);
      expect(client.buildHeaders()['accept-language'], 'zh-Hans');
    });
  });

  group('按请求的超时', () {
    test('不传 → 全局那 10 秒（普通接口还是失败得快）', () async {
      final adapter = _FakeAdapter(
        statusCode: 200,
        body: _envelope(0, data: <String, dynamic>{}),
      );
      await clientWith(adapter).postMap('/enterprise/im/getContacts');

      expect(adapter.lastRequest?.connectTimeout, const Duration(seconds: 10));
      expect(adapter.lastRequest?.receiveTimeout, const Duration(seconds: 10));
      expect(adapter.lastRequest?.sendTimeout, const Duration(seconds: 10));
    });

    test('传了 → 连接/收/发三样都跟这条请求走（群通话那几个接口要 30s）', () async {
      final adapter = _FakeAdapter(
        statusCode: 200,
        body: _envelope(0, data: <String, dynamic>{}),
      );
      await clientWith(
        adapter,
      ).postMap('/enterprise/sfu/room', timeout: const Duration(seconds: 30));

      expect(adapter.lastRequest?.connectTimeout, const Duration(seconds: 30));
      expect(adapter.lastRequest?.receiveTimeout, const Duration(seconds: 30));
      expect(adapter.lastRequest?.sendTimeout, const Duration(seconds: 30));
    });
  });

  group('响应语义', () {
    test('code 0 → 拿到 data', () async {
      final client = clientWith(
        _FakeAdapter(
          statusCode: 200,
          body: _envelope(0, data: <String, dynamic>{'id': 7}),
        ),
      );
      final data = await client.postMap('/enterprise/im/getContacts');
      expect(data['id'], 7);
    });

    test('code -1 → SessionExpired 并发出重登通知', () async {
      final client = clientWith(
        _FakeAdapter(statusCode: 200, body: _envelope(-1, msg: '登录已过期')),
      );

      AppNotice? received;
      final subscription = noticeBus.stream.listen(
        (notice) => received = notice,
      );

      await expectLater(
        client.postMap('/enterprise/im/getContacts'),
        throwsA(isA<SessionExpiredException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(received, isA<ReloginNotice>());
      expect(received!.message, '登录已过期');

      await subscription.cancel();
    });

    test('code 500 → BusinessException 并弹提示', () async {
      final client = clientWith(
        _FakeAdapter(statusCode: 200, body: _envelope(500, msg: '服务器炸了')),
      );

      AppNotice? received;
      final subscription = noticeBus.stream.listen(
        (notice) => received = notice,
      );

      await expectLater(
        client.postMap('/enterprise/im/getContacts'),
        throwsA(isA<BusinessException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(received, isA<ToastNotice>());

      await subscription.cancel();
    });

    test('notify: false 时不弹提示', () async {
      final client = clientWith(
        _FakeAdapter(statusCode: 200, body: _envelope(500, msg: '服务器炸了')),
      );

      AppNotice? received;
      final subscription = noticeBus.stream.listen(
        (notice) => received = notice,
      );

      await expectLater(
        client.postMap('/enterprise/im/setMsgIsRead', notify: false),
        throwsA(isA<BusinessException>()),
      );
      await Future<void>.delayed(Duration.zero);
      expect(received, isNull);

      await subscription.cancel();
    });

    test('HTTP 401 → Unauthorized（要求重登）', () async {
      final client = clientWith(_FakeAdapter(statusCode: 401, body: '{}'));
      await expectLater(
        client.postMap('/enterprise/im/getContacts'),
        throwsA(isA<UnauthorizedException>()),
      );
    });

    test('HTTP 500 → ServerException', () async {
      final client = clientWith(_FakeAdapter(statusCode: 500, body: 'boom'));
      await expectLater(
        client.postMap('/enterprise/im/getContacts'),
        throwsA(isA<ServerException>()),
      );
    });

    test('请求头真的带上了 Authorization（不是只在 buildHeaders 里）', () async {
      final adapter = _FakeAdapter(
        statusCode: 200,
        body: _envelope(0, data: <String, dynamic>{}),
      );
      await clientWith(adapter).postMap('/enterprise/im/getContacts');
      expect(adapter.lastRequest!.headers['Authorization'], 'token-abc');
      expect(adapter.lastRequest!.headers['clientId'], 'client-123');
    });
  });
}
