/// 电脑端「密码登陆」的地域规矩（用户 2026-10-08 定）。
///
/// * 出口 IP 在**美国** → 放行，切到账号密码表单；
/// * 在任何其他地方（含查不到） → 弹一句「您当前的位置不支持密码登陆」，
///   把人引导回扫码登录（手机扫码那条路不受地域限制）。
///
/// 「查不到也不放行」是刻意的：这是一道限制，不是便利功能。归属地查不清时，
/// 宁可让人用扫码登录，也不要破例放进来。
///
/// **这只是客户端自己的一道闸门**：拦得住正常使用的人，拦不住改客户端、
/// 挂代理的人。要真的限制住，服务端得按请求来源再判一次 —— 本仓库只有客户端，
/// 那一步在服务端那个仓库里。
library;

/// 允许密码登陆的地方（ISO 3166-1 alpha-2；国务院口径的「美国」）
const String kPasswordLoginCountry = 'US';

/// 出口 IP 在不在允许密码登陆的地方。
///
/// [countryCode] 传 null（查不到）按**不允许**处理（理由见文件头）。
bool passwordLoginAllowedIn(String? countryCode) =>
    countryCode != null && countryCode.toUpperCase() == kPasswordLoginCountry;
