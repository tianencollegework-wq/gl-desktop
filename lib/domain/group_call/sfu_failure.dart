import '../../core/net/api_exception.dart';

/// 我们信封里的群通话错误码（`docs/protocol/sfu-group-call.md` 第五节）。
///
/// 不用 HTTP 状态码本身当业务码：老端那套信封的 code 是自定义小整数，
/// 4xx 直接拿来当业务码会和网关/框架的行为混淆。
abstract final class SfuCodes {
  static const int ok = 0;
  static const int badRequest = 4001;
  static const int sessionGone = 4002;
  static const int sessionConflict = 4003;
  static const int upstreamAuth = 4004;
  static const int upstreamUnreachable = 4005;
  static const int notMember = 4006;
  static const int roomFull = 4007;
}

/// 一次 SFU 操作失败的性质。
///
/// 分类的依据不是"错在哪"，而是**这条会话还能不能继续用**：
/// CF 的合约里"结果不确定"和"明确被拒"是两种完全不同的处理（见 [SfuFailureKindX.sessionIsDead]）。
enum SfuFailureKind {
  /// 服务端明确拒绝了这次操作：**什么都没发生**，会话仍然可用，
  /// 修好触发条件（比如队列顺序）之后可以重新发起。
  rejected,

  /// 会话不存在 / 已经过期（CF 的 `410 session_error`）。
  sessionGone,

  /// 同一会话并发改动被拒（CF 的 `406`）。
  ///
  /// 按「明确被拒」处理，不是「结果未知」：官方文档举的例子是
  /// 「B 加入时 A 还在入会，第二次 tracks/new 在第一次 offer/answer 结束前到达」——
  /// 那种情形下 CF 没有应用任何东西。修法是让改动串行（[SfuSessionQueue]），
  /// 而不是重建会话。
  sessionConflict,

  /// **结果不确定**：超时、网络中断、上游 5xx。
  ///
  /// 这种必须按"可能已经生效"处理 —— 官方原话：应用层的去重判断
  /// 并不能让一个 SFU 请求变成可安全重放的；重复 `tracks/new` 会**重复分配**订阅。
  /// 所以处理方式是**换一条新会话重建**，不是重试（见 [SfuFailureKindX.sessionIsDead]）。
  unknownOutcome,

  /// 登录态失效或上游鉴权失败（我方 App Secret / 配置问题）。
  unauthorized,
}

extension SfuFailureKindX on SfuFailureKind {
  /// 这条会话已经不能再用：必须换一条新会话、重新发布、重新订阅。
  bool get sessionIsDead =>
      this == SfuFailureKind.sessionGone ||
      this == SfuFailureKind.unknownOutcome;

  /// 要不要让用户重新登录
  bool get needsRelogin => this == SfuFailureKind.unauthorized;
}

/// 群通话里一次操作的失败。
///
/// 之所以不直接抛 [ApiException]：调用方需要的是"**要不要重建会话**"这个判断，
/// 而不是"服务端说了什么"。翻译集中在这里（[SfuFailure.fromApiException]）。
class SfuFailure implements Exception {
  const SfuFailure({
    required this.kind,
    required this.message,
    this.code,
    this.label,
  });

  final SfuFailureKind kind;

  /// 给人看的原因（进日志与诊断时间线）
  final String message;

  /// 我们的信封 code（[SfuCodes]；非业务失败时为 null）
  final int? code;

  /// 哪一步操作触发的（用于日志，比如 `subscribe`）
  final String? label;

  /// 必须换一条新会话重建
  bool get requiresRebuild => kind.sessionIsDead;

  bool get needsRelogin => kind.needsRelogin;

  /// 把业务码翻成失败性质。纯函数，便于单测。
  static SfuFailure fromCode(int code, String message, {String? label}) =>
      SfuFailure(
        kind: _kindOfCode(code),
        message: message,
        code: code,
        label: label,
      );

  static SfuFailureKind _kindOfCode(int code) => switch (code) {
    SfuCodes.sessionGone => SfuFailureKind.sessionGone,
    SfuCodes.sessionConflict => SfuFailureKind.sessionConflict,
    SfuCodes.upstreamUnreachable => SfuFailureKind.unknownOutcome,
    SfuCodes.upstreamAuth => SfuFailureKind.unauthorized,
    _ => SfuFailureKind.rejected,
  };

  /// HTTP/网络层异常 → 失败性质。
  ///
  /// 只有"服务端明确回话"的才算被拒；**超时、断网、5xx 一律算结果未知**：
  /// 请求可能已经到达 CF 并生效了，重试会造成重复分配。
  static SfuFailure fromApiException(ApiException error, {String? label}) {
    final kind = switch (error) {
      BusinessException() => _kindOfCode(error.code),
      NetworkUnavailableException() => SfuFailureKind.unknownOutcome,
      ServerException() => SfuFailureKind.unknownOutcome,
      UnknownApiException() => SfuFailureKind.unknownOutcome,
      UnauthorizedException() => SfuFailureKind.unauthorized,
      SessionExpiredException() => SfuFailureKind.unauthorized,
    };
    return SfuFailure(
      kind: kind,
      message: error.message,
      code: error is BusinessException ? error.code : null,
      label: label,
    );
  }

  @override
  String toString() =>
      'SfuFailure(${kind.name}${code == null ? '' : ', code=$code'}'
      '${label == null ? '' : ', $label'}): $message';
}
