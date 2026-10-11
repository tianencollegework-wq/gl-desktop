import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_client.dart';
import '../../domain/scan/scan_target.dart';

/// 扫码验证，对应老端 `common/scan.js::verifyQr`。
///
/// 这一条**路径是扫码内容里带出来的**（`POST <扫到的站内路径>`，body 只有
/// `{realToken: 路径最后一段}`），所以不能像其它接口那样写常量路径。
class ScanApi {
  const ScanApi(this._client);

  final ApiClient _client;

  /// `notify: false`：扫码是人盯着屏幕操作，提示由页面按场景给
  /// （扫到不认识的码要弹「已识别内容」，不能糊一句接口错误上去）。
  Future<ScanVerdict> verify({
    required String path,
    required String token,
  }) async {
    final data = await _client.postMap(
      path,
      data: <String, dynamic>{'realToken': token},
      notify: false,
    );
    return ScanVerdict.fromJson(data);
  }
}

final scanApiProvider = Provider<ScanApi>(
  (ref) => ScanApi(ref.watch(apiClientProvider)),
);
