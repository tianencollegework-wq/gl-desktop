import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_client.dart';
import 'endpoints.dart';

/// 好友相关，对应老端 `api/friend.js`。
class FriendApi {
  const FriendApi(this._client);

  final ApiClient _client;

  /// 新朋友列表（收到的 / 我发起的，用 `is_mine` 切）。
  ///
  /// **`data` 是数组**（老端 `friend.vue` 直接 `this.list = res.data`），
  /// 信封里另外带一个 `count` 是分页总数（`uni-pagination` 用它）。
  /// 用 `postMap` 读这个接口会静默得到空 map —— 与群成员列表同一个坑（M4 记过）。
  Future<({List<Map<String, dynamic>> rows, int count})> applyPage([
    Map<String, dynamic> params = const {},
  ]) => _client.postPage(FriendPaths.applyList, data: params);

  /// 添加好友（`{user_id, remark}`），返回服务端的 `msg`
  Future<String> add(Map<String, dynamic> params) =>
      _postMessage(FriendPaths.add, params);

  /// 删除好友（`{id, is_black}`），返回服务端的 `msg`
  Future<String> del(Map<String, dynamic> params) =>
      _postMessage(FriendPaths.del, params);

  /// 同意 / 拒绝好友申请（`{friend_id, status}`），返回服务端的 `msg`
  Future<String> acceptApply(Map<String, dynamic> params) =>
      _postMessage(FriendPaths.acceptApply, params);

  /// 设置好友备注（`{friend_id, nickname}`），返回服务端的 `msg`
  Future<String> setNickname(Map<String, dynamic> params) =>
      _postMessage(FriendPaths.setNickname, params);

  /// 好友那几个写接口，老端拿到回执后弹的都是 `e.msg`（服务端自己给的话术，
  /// 比如「操作成功」），所以不能只吞掉成功与否，得把 `msg` 带出来。
  ///
  /// 代价：走 [ApiClient.send] 就没有「失败自动弹 toast」了，
  /// 失败提示由调用方（页面）自己弹——这几个接口都是页面上点的，本来就该如此。
  Future<String> _postMessage(String path, Map<String, dynamic> params) async {
    final envelope = await _client.send(path, data: params);
    return envelope.msg ?? '';
  }
}

final friendApiProvider = Provider<FriendApi>(
  (ref) => FriendApi(ref.watch(apiClientProvider)),
);
