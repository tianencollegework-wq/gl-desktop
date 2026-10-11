import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gracelinkim/core/audio/speech_to_text.dart';

/// 语音转文字（S4.4c）。
///
/// 钉住的是**和自建 Worker 的契约**：字段名 `audio`（不是 `file`）、
/// 带 `x-api-key`、响应取 `{"text": ...}`，以及各种失败都变成
/// [SpeechToTextException]（上层只需要「失败 + 一句话」）。
///
/// 这里**不用** `StubAdapter`：那是给业务接口用的，会把回包包成
/// `{code,msg,data}` 信封，而 Worker 返回的是裸的 `{"text": ...}`。
void main() {
  late _RawAdapter adapter;
  late Directory temp;
  late File sample;

  setUp(() async {
    adapter = _RawAdapter();
    temp = await Directory.systemTemp.createTemp('gl_stt_test');
    sample = File('${temp.path}/gl_voice_test.m4a')
      ..writeAsBytesSync(<int>[0, 1, 2, 3]);
  });

  tearDown(() async {
    if (temp.existsSync()) {
      try {
        await temp.delete(recursive: true);
      } on FileSystemException {
        // Windows 上文件句柄可能还没放掉，测试目录留着无所谓
      }
    }
  });

  SpeechToTextService service() =>
      SpeechToTextService(dio: Dio()..httpClientAdapter = adapter);

  test('成功：字段名是 audio，带 x-api-key，取 text', () async {
    adapter.body = json.encode(<String, dynamic>{'text': '  明天下午三点开会  '});

    final text = await service().transcribe(sample.path);

    expect(text, '明天下午三点开会');
    final request = adapter.requests.single;
    expect(request.headers['x-api-key'], SpeechToTextService.apiKey);

    // 字段名：Worker 约定是 `audio`，写成 `file` 会 400
    final body = request.data;
    expect(body, isA<FormData>());
    final form = body as FormData;
    expect(form.fields, isEmpty);
    expect(form.files.length, 1);
    expect(form.files.single.key, 'audio');
    expect(form.files.single.value.filename, 'gl_voice_test.m4a');
    expect(form.files.single.value.contentType?.mimeType, 'audio/mp4');
  });

  test('Worker 的地址就是 stillnooot 那一个（可用 dart-define 覆盖）', () {
    expect(
      SpeechToTextService.workerUrl,
      'https://my-whisper-worker.29dliu.workers.dev',
    );
  });

  test('401（key 不对）→ 抛异常并带上状态码与响应体', () async {
    adapter.statusCode = 401;
    adapter.body = json.encode(<String, dynamic>{'error': 'unauthorized'});

    await expectLater(
      service().transcribe(sample.path),
      throwsA(
        isA<SpeechToTextException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having(
              (e) => e.responseBody,
              'responseBody',
              contains('unauthorized'),
            ),
      ),
    );
  });

  test('响应里没有 text → 抛异常（不能把 null 当文字填进输入框）', () async {
    adapter.body = json.encode(<String, dynamic>{'ok': 1});

    await expectLater(
      service().transcribe(sample.path),
      throwsA(
        isA<SpeechToTextException>().having(
          (e) => e.message,
          'message',
          'missing text field',
        ),
      ),
    );
  });

  test('文件不在（录音失败）→ 直接抛，不发请求', () async {
    await expectLater(
      service().transcribe('${temp.path}/没有这个文件.m4a'),
      throwsA(
        isA<SpeechToTextException>().having(
          (e) => e.message,
          'message',
          'audio file missing',
        ),
      ),
    );
    expect(adapter.requests, isEmpty);
  });

  test('网络炸了（连接被拒）→ network error，不是崩', () async {
    final dio = Dio()..httpClientAdapter = _ThrowingAdapter();
    await expectLater(
      SpeechToTextService(dio: dio).transcribe(sample.path),
      throwsA(
        isA<SpeechToTextException>().having(
          (e) => e.message,
          'message',
          contains('network error'),
        ),
      ),
    );
  });
}

/// 原样返回一段文本的假 adapter（记录请求，便于断言 multipart 字段与请求头）
class _RawAdapter implements HttpClientAdapter {
  int statusCode = 200;
  String body = '{}';
  final List<RequestOptions> requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    // 把上传流读干净，模拟真实发送（也能把文件句柄放掉）
    await requestStream?.drain<void>();
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

/// 直接抛连接错误的 adapter（模拟断网/DNS 失败）
class _ThrowingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    throw DioException.connectionError(
      requestOptions: options,
      reason: 'connection refused',
    );
  }

  @override
  void close({bool force = false}) {}
}
