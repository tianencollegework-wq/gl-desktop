import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_exception.dart';
import '../../domain/report/report_failure.dart';
import '../../domain/report/report_reasons.dart';
import '../api/report_api.dart';

/// 举报（S13.1，2026-10-11）。
///
/// 这一层薄，但**不是没用的中间层**：它把「提交一次举报」这件事收敛成
/// **不抛异常**的一个结果（`ReportOutcome` 三种结局），于是三个入口
/// （聊天信息页 / 长按消息 / 关于页）与弹层不用各自写一套 try/catch，
/// 也就不会出现「三个地方三套错话」。
///
/// 请求体的形状在 [ReportTarget.toParams]（纯函数，`test/report/report_target_test.php`
/// 那种用例盯得住），这里只负责发出去与翻译结果。
class ReportRepository {
  ReportRepository(this._api);

  final ReportApi _api;

  /// 提交一条举报。
  ///
  /// [reason] 用 [ReportReason] 而不是字符串：码表在服务端有一份白名单，
  /// 拼错一个码的代价是用户看到「举报原因不对」。
  Future<ReportOutcome> submit(
    ReportTarget target, {
    required ReportReason reason,
    String detail = '',
  }) async {
    try {
      final reportId = await _api.submit(
        target.toParams(reason: reason.code, detail: detail.trim()),
      );
      return ReportAccepted(reportId);
    } on ApiException catch (error) {
      return ReportOutcome.fromApiException(error);
    }
  }
}

final reportRepositoryProvider = Provider<ReportRepository>(
  (ref) => ReportRepository(ref.watch(reportApiProvider)),
);
