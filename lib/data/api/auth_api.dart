import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_client.dart';
import 'endpoints.dart';

/// 登录 / 注册 / 全局配置，对应老端 `api/login.js`。
///
/// 参数一律用 map 透传：老端的调用点参数名尚未逐一核对（要等实现对应页面时对照
/// `pages/login/*.vue` 的调用处），这里不猜字段名，避免写出"看起来对但传错 key"的接口。
class AuthApi {
  const AuthApi(this._client);

  final ApiClient _client;

  Future<Map<String, dynamic>> login([
    Map<String, dynamic> params = const {},
  ]) => _client.postMap(AuthPaths.login, data: params);

  Future<Map<String, dynamic>> logout([
    Map<String, dynamic> params = const {},
  ]) => _client.postMap(AuthPaths.logout, data: params, notify: false);

  Future<Map<String, dynamic>> register([
    Map<String, dynamic> params = const {},
  ]) => _client.postMap(AuthPaths.register, data: params);

  /// 发送验证码并返回服务端的 `msg`。
  ///
  /// 老端拿到回执后弹的就是 `res.msg`（「发送成功」之类），所以不能只吞掉成功与否。
  /// 代价：走 [ApiClient.send] 没有「失败自动提示」，提示由调用方自己弹
  /// （与 `FriendApi` 那几个写接口同一套口径）。
  Future<String> sendCodeMessage(Map<String, dynamic> params) async {
    final envelope = await _client.send(AuthPaths.sendCode, data: params);
    return envelope.msg ?? '';
  }

  Future<Map<String, dynamic>> sendCode([
    Map<String, dynamic> params = const {},
  ]) => _client.postMap(AuthPaths.sendCode, data: params);

  /// 绑定 client_id：`{client_id, user_id, cid}`
  Future<void> bindUid(Map<String, dynamic> params) =>
      _client.postVoid(AuthPaths.bindUid, data: params, notify: false);

  /// 绑定群聊：`{client_id, group_id}`
  Future<void> bindGroup(Map<String, dynamic> params) =>
      _client.postVoid(AuthPaths.bindGroup, data: params, notify: false);

  /// 全局配置，对应老端 `store/login.js` 的 `getGlobalConfig()`
  Future<Map<String, dynamic>> getSystemInfo() =>
      _client.postMap(AuthPaths.systemInfo, notify: false);
}

final authApiProvider = Provider<AuthApi>(
  (ref) => AuthApi(ref.watch(apiClientProvider)),
);
