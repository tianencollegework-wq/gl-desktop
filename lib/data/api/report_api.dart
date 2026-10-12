import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_client.dart';
import '../../core/util/json_value.dart';
import 'endpoints.dart';

/// 举报（`/enterprise/report/submit`，2026-10-11 新增）。
///
/// 服务端那一侧：`app/enterprise/controller/Report.php`（入参校验与表结构分别在
/// `app/enterprise/service/ReportInput.php` 与 `ReportSchema.php`）。
///
/// 这里刻意**不走 `postMap` 那种「失败自动弹 toast」的路径**：
/// 举报失败要说哪句话是界面的决定（业务码 → 七种语言各自一句），
/// 而且「已经举报过了」这种回话不该按错误的样子弹出来（见
/// `ReportRejected`）。所以用最底层的 [ApiClient.send]，异常自己接。
class ReportApi {
  const ReportApi(this._client);

  final ApiClient _client;

  /// 提交一条举报，返回服务端给的记录 id（拿不到就 0，不影响提交成功这件事）。
  ///
  /// 失败（业务码 / 网络）一律抛 [ApiException]，由 `ReportRepository` 翻成
  /// `ReportOutcome` —— 页面只认那个。
  Future<int> submit(Map<String, dynamic> params) async {
    final envelope = await _client.send(ReportPaths.submit, data: params);
    return asInt(envelope.dataAsMap['report_id'], 0);
  }
}

final reportApiProvider = Provider<ReportApi>(
  (ref) => ReportApi(ref.watch(apiClientProvider)),
);
