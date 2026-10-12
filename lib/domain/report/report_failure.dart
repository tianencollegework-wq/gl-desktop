import '../../core/net/api_exception.dart';

/// 举报接口的业务码（与 `app/enterprise/controller/Report.php` 那一侧一一对应，
/// 那边的常量在 `ReportInput` 里）：
///
/// | 码 | 意思 | 界面上的话 |
/// | --- | --- | --- |
/// | 4101 | 参数不对（原因不在白名单、说明太长…） | `report.errBadParam` |
/// | 4102 | 不能举报自己 | `report.errSelf` |
/// | 4103 | 24 小时内报过同一条 | `report.errDuplicate` |
/// | 4104 | 每人每天 20 条的上限到了 | `report.errTooMany` |
/// | 4105 | 这条消息不在你的会话里 | `report.errNotMine` |
/// | 4106 | 消息已经被撤回/删除 | `report.errGone` |
///
/// 为什么客户端要认码、而不是直接显示服务端那句话：那些话是**中文写死的**
/// （服务端没有举报相关的语言包），而 App 有七种语言；认码才能出各自的文案。
/// 认不出来的码（服务端以后加的）退回显示服务端原话，不会变成一句「失败」。
abstract final class ReportCodes {
  static const int badParam = 4101;
  static const int self = 4102;
  static const int duplicate = 4103;
  static const int tooMany = 4104;
  static const int notMine = 4105;
  static const int gone = 4106;

  /// 业务码 → 文案 key（认不出来的返回 null）
  static String? labelKeyOf(int? code) => switch (code) {
    badParam => 'report.errBadParam',
    self => 'report.errSelf',
    duplicate => 'report.errDuplicate',
    tooMany => 'report.errTooMany',
    notMine => 'report.errNotMine',
    gone => 'report.errGone',
    _ => null,
  };
}

/// 一次举报提交的结果。
///
/// 做成三种**密封**的结局而不是「抛异常 + 拿字符串」：弹层只需要知道
/// 「说过什么话、要不要重登」，这三件事各自是哪种情况一眼可见（与
/// `SfuFailure` 同一个道理）。
sealed class ReportOutcome {
  const ReportOutcome();

  /// 说给用户听的话（`labelKey` 有值时优先用它）
  String get message;

  /// 文案 key（null = 用 [message] 这句话本身）
  String? get labelKey;

  /// 要不要把用户赶去重新登录
  bool get needsRelogin => false;

  /// 把一次 `ApiException` 翻成结果。纯函数，便于单测。
  ///
  /// 只有「服务端明确回话」的算被拒（[ReportRejected]，业务码能对上文案）；
  /// 网络、超时、HTTP 5xx 归 [ReportUnavailable] —— 那种情况我们并不知道
  /// 服务端收没收到，跟用户说「你已经举报过了」就是撒谎。
  static ReportOutcome fromApiException(ApiException error) {
    if (error is BusinessException) {
      return ReportRejected(
        error.code,
        error.message,
        labelKey: ReportCodes.labelKeyOf(error.code),
      );
    }
    return ReportUnavailable(error.message, needsRelogin: error.needsRelogin);
  }
}

/// 提交成功（带上服务端给的记录 id，目前只用于日志）
class ReportAccepted extends ReportOutcome {
  const ReportAccepted(this.reportId);

  final int reportId;

  @override
  String get message => '';

  @override
  String? get labelKey => null;
}

/// 服务端明确拒绝（业务码）—— 这些是**能对上我方文案**的
class ReportRejected extends ReportOutcome {
  const ReportRejected(this.code, this.message, {this.labelKey});

  /// 服务端业务码（[ReportCodes]；认不出来时为 null）
  final int? code;

  @override
  final String message;

  @override
  final String? labelKey;
}

/// 没提交成（网络、超时、服务端 5xx、登录态过期）
class ReportUnavailable extends ReportOutcome {
  const ReportUnavailable(this.message, {this.needsRelogin = false});

  @override
  final String message;

  @override
  final bool needsRelogin;

  @override
  String? get labelKey => null;
}
