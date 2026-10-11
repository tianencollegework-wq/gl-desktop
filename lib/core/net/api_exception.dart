/// 接口异常层次。
///
/// 刻意做成 `sealed`：调用方可以用 `switch` 穷举，避免漏处理"被顶下线"这类分支。
sealed class ApiException implements Exception {
  const ApiException(this.message);

  final String message;

  /// 是否应该弹提示（老端 `request.js` 里对 400/401/402/403/404/405/500/502 都弹 toast）
  bool get shouldToast => true;

  /// 是否需要重新登录
  bool get needsRelogin => false;

  @override
  String toString() => '$runtimeType($message)';
}

/// 没有网络（老端请求拦截器里 `getNetworkType == 'none'` 时直接中断请求）
class NetworkUnavailableException extends ApiException {
  const NetworkUnavailableException([super.message = '当前网络不可用，请检查网络设置']);
}

/// HTTP 401：鉴权过期
class UnauthorizedException extends ApiException {
  const UnauthorizedException([super.message = '登录状态已过期，请重新登录']);

  @override
  bool get needsRelogin => true;
}

/// 业务码 `-1`：需要重新登录
class SessionExpiredException extends ApiException {
  const SessionExpiredException([super.message = '登录状态已失效，请重新登录']);

  @override
  bool get needsRelogin => true;
}

/// 业务码非 0：业务失败
class BusinessException extends ApiException {
  const BusinessException(this.code, String message) : super(message);

  final int code;

  @override
  String toString() => 'BusinessException($code, $message)';
}

/// HTTP 5xx
class ServerException extends ApiException {
  const ServerException([super.message = '服务器繁忙，请稍后再试']);
}

/// 兜底
class UnknownApiException extends ApiException {
  const UnknownApiException([super.message = '请求失败，请稍后再试']);
}

/// 业务响应码 → 异常。纯函数，便于单测。
///
/// 依据老端 `utils/request.js`：
/// * `code == 0` 成功（业务代码直接取 `res.data`）
/// * `code == -1` 提示后 `reLaunch` 到登录页
/// * `400/401/402/403/404/405/500/502` 弹 toast
///
/// 注：老端拦截器在 `code == 0` 且 `msg` 非空时**也会**弹 toast，与"0 即成功"的用法冲突。
/// 这里按"0 即成功"实现，待真实报文确认（见 `docs/protocol/README.md`）。
ApiException? mapBusinessCode(int code, String? msg) {
  if (code == 0) return null;
  final message = (msg == null || msg.isEmpty) ? null : msg;
  if (code == -1) {
    return SessionExpiredException(message ?? '登录状态已失效，请重新登录');
  }
  if (const <int>[400, 401, 402, 403, 404, 405, 500, 502].contains(code)) {
    return BusinessException(code, message ?? '请求失败（$code）');
  }
  return BusinessException(code, message ?? '请求失败（$code）');
}
