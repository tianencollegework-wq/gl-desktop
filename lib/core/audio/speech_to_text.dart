import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 语音转文字（S4.4c「滑到这里 转文字」）。
///
/// 走的是**自建的 Cloudflare Worker**（和 stillnooot 那个 App 同一套，
/// 用户 2026-09-20 的要求）：
///
/// * `POST {workerUrl}`，`multipart/form-data`，音频字段名 `audio`；
/// * 请求头 `x-api-key`（Worker 侧校验，防滥用；缺了返回 401）；
/// * 响应 `{"text": "识别出来的文字"}` —— **纯转写**，没有别的字段。
///
/// 两个刻意的选择：
/// 1. **不做本地语义解析**：识别到什么就是什么，直接填进输入框
///    （stillnooot 那边还要跑一遍本地规则库抽提醒时间，我们没有那个需求）；
/// 2. **录的什么就传什么**：我们录音本来就是 16kHz 单声道 AAC（`.m4a`，24kbps），
///    真机实测 Worker 能吃（同一段话 WAV 与 m4a 识别结果一字不差），
///    所以不为转文字单独再录一份别的格式。
///
/// 密钥/地址可以打包时覆盖：
/// `--dart-define=VOICE_WORKER_URL=... --dart-define=VOICE_API_KEY=...`
class SpeechToTextService {
  SpeechToTextService({Dio? dio}) : _dio = dio ?? _buildDio();

  /// 转写服务地址
  static const String workerUrl = String.fromEnvironment(
    'VOICE_WORKER_URL',
    defaultValue: 'https://my-whisper-worker.29dliu.workers.dev',
  );

  /// Worker 鉴权密钥（请求头 `x-api-key`）。
  ///
  /// 默认值就是 stillnooot 那个 Worker 在用的那把；**它写在客户端里迟早能被扒出来**，
  /// 所以它是「可轮换」的：真要防滥用就在 Worker 侧限流，换密钥时改这里
  /// 或用 `--dart-define=VOICE_API_KEY=` 覆盖。
  static const String apiKey = String.fromEnvironment(
    'VOICE_API_KEY',
    defaultValue:
        '6d417d065f09e4bb191e33c549785696ebe5e7f496bb1a968ffb48a9934dffe2',
  );

  /// 上传 + 识别总超时（一段 60 秒的语音在弱网下也就几秒）
  static const Duration timeout = Duration(seconds: 30);

  final Dio _dio;

  static Dio _buildDio() => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 30),
      receiveTimeout: timeout,
      // 转写服务不是我们的业务接口，不要把业务请求头（token 之类）带过去
      headers: const <String, String>{},
      // 401/500 的响应体要留给上层展示，别被 dio 抛成空消息
      validateStatus: (status) => status != null && status < 500,
    ),
  );

  /// 把一段录音转成文字。返回的可能是空串（没听清/纯静音），由调用方决定提示什么。
  Future<String> transcribe(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw const SpeechToTextException('audio file missing');
    }

    final Response<dynamic> response;
    try {
      response = await _dio.post<dynamic>(
        workerUrl,
        data: FormData.fromMap(<String, dynamic>{
          'audio': await MultipartFile.fromFile(
            filePath,
            filename: _fileNameOf(filePath),
            contentType: _contentTypeOf(filePath),
          ),
        }),
        options: Options(
          headers: <String, String>{'x-api-key': apiKey},
          responseType: ResponseType.json,
        ),
      );
    } on DioException catch (error) {
      // 超时/断网/DNS 都收敛成同一类失败，调用方只需要「失败」+ 一句能看的原因
      throw SpeechToTextException(
        _reasonOf(error),
        statusCode: error.response?.statusCode,
        responseBody: _bodyOf(error.response),
      );
    }

    final status = response.statusCode ?? 0;
    final body = response.data;
    final raw = body is String ? body : (body == null ? '' : '$body');
    if (status != 200) {
      throw SpeechToTextException(
        'HTTP $status',
        statusCode: status,
        responseBody: _truncate(raw),
      );
    }
    if (body is! Map) {
      throw SpeechToTextException(
        'unexpected response shape',
        responseBody: _truncate(raw),
      );
    }
    final text = body['text'];
    if (text is! String) {
      throw SpeechToTextException(
        'missing text field',
        responseBody: _truncate(raw),
      );
    }
    return text.trim();
  }

  static String _fileNameOf(String path) {
    final index = path.lastIndexOf(RegExp(r'[/\\]'));
    return index == -1 ? path : path.substring(index + 1);
  }

  /// 按后缀给个像样的 MIME —— Worker 那边（以及它后面的 whisper）会看这个
  static DioMediaType _contentTypeOf(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.wav')) return DioMediaType('audio', 'wav');
    if (lower.endsWith('.mp3')) return DioMediaType('audio', 'mpeg');
    if (lower.endsWith('.aac')) return DioMediaType('audio', 'aac');
    if (lower.endsWith('.amr')) return DioMediaType('audio', 'amr');
    // `.m4a` 就是 mp4 容器里的 AAC
    return DioMediaType('audio', 'mp4');
  }

  static String _reasonOf(DioException error) => switch (error.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout => 'request timed out',
    _ => 'network error: ${_truncate('${error.message ?? error}')}',
  };

  static String? _bodyOf(Response<dynamic>? response) {
    final data = response?.data;
    if (data == null) return null;
    return _truncate(data is String ? data : '$data');
  }

  static String _truncate(String value, [int max = 300]) =>
      value.length <= max ? value : '${value.substring(0, max)}…';
}

/// 转写失败（非 200 / 超时 / 响应里没有 `text` / 文件不在）。
@immutable
class SpeechToTextException implements Exception {
  const SpeechToTextException(
    this.message, {
    this.statusCode,
    this.responseBody,
  });

  final String message;

  /// HTTP 状态码（非 200 时）
  final int? statusCode;

  /// 服务器返回的原始响应体（截断后，便于弹诊断）
  final String? responseBody;

  @override
  String toString() =>
      'SpeechToTextException: $message'
      '${statusCode == null ? '' : ' (HTTP $statusCode)'}';
}

final speechToTextProvider = Provider<SpeechToTextService>(
  (ref) => SpeechToTextService(),
);
