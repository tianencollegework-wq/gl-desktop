import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_client.dart';
import '../../core/net/api_response.dart';
import 'endpoints.dart';

/// 文件 / 头像 / 自定义表情上传。
///
/// 老端把完整 URL 拼好交给 uploader 直传（`msgApi.uploadUrl` 等），
/// 这里统一走 `ApiClient.upload`，错误处理与普通接口一致。
///
/// ⚠️ 表单字段名（`field`）与老端 uploader 的实际字段尚未核对——老端用的是
/// uni-app 的 `uni.uploadFile`，字段名在调用处指定。抓到真实请求后校正。
class UploadApi {
  const UploadApi(this._client);

  final ApiClient _client;

  Future<Map<String, dynamic>> uploadFile(
    File file, {
    String field = 'file',
    Map<String, dynamic> extra = const {},
    bool notify = true,
  }) => _upload(
    UploadPaths.file,
    file,
    field: field,
    extra: extra,
    notify: notify,
  );

  /// 头像上传。
  ///
  /// 返回值是信封里的 `data` **原样**：这个接口的 `data` 就是图片 URL 字符串
  /// （老端 `this.userInfo.avatar = res.data; loginStore.login(data)`），
  /// 用 `dataAsMap` 解析会拿到空 map（S5.5 才发现）。
  Future<Object?> uploadAvatar(
    File file, {
    String field = 'file',
    Map<String, dynamic> extra = const {},
    bool notify = true,
  }) async => (await _uploadEnvelope(
    UploadPaths.avatar,
    file,
    field: field,
    extra: extra,
    notify: notify,
  )).data;

  Future<Map<String, dynamic>> uploadEmoji(
    File file, {
    String field = 'file',
    Map<String, dynamic> extra = const {},
    bool notify = true,
  }) => _upload(
    UploadPaths.emoji,
    file,
    field: field,
    extra: extra,
    notify: notify,
  );

  Future<Map<String, dynamic>> _upload(
    String path,
    File file, {
    required String field,
    required Map<String, dynamic> extra,
    required bool notify,
  }) async => (await _uploadEnvelope(
    path,
    file,
    field: field,
    extra: extra,
    notify: notify,
  )).dataAsMap;

  Future<ApiResponse> _uploadEnvelope(
    String path,
    File file, {
    required String field,
    required Map<String, dynamic> extra,
    required bool notify,
  }) async {
    final form = FormData.fromMap(<String, dynamic>{
      ...extra,
      field: await MultipartFile.fromFile(file.path),
    });
    return _client.uploadEnvelope(path, form, notify: notify);
  }
}

final uploadApiProvider = Provider<UploadApi>(
  (ref) => UploadApi(ref.watch(apiClientProvider)),
);
