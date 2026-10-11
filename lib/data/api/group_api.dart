import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_client.dart';
import 'endpoints.dart';

/// 群组相关，对应老端 `api/message.js` 里 `/enterprise/group/*` 那批。
class GroupApi {
  const GroupApi(this._client);

  final ApiClient _client;

  /// 群资料。
  ///
  /// **只给群成员**（服务端 `checkGroupMember` 不过就回「您没有操作权限！」），
  /// 所以扫群二维码进来的那条路上会**预期之内地失败**一次 —— 那种调用方传
  /// `notify: false`，因为前面扫码那一步服务端已经把群资料给过一遍了
  /// （见 `GroupAdminRepository.joinInfo`）。
  Future<Map<String, dynamic>> groupInfo(
    Map<String, dynamic> params, {
    bool notify = true,
  }) => _client.postMap(GroupPaths.info, data: params, notify: notify);

  Future<Map<String, dynamic>> groupSetting(Map<String, dynamic> params) =>
      _client.postMap(GroupPaths.setting, data: params);

  Future<Map<String, dynamic>> userList(Map<String, dynamic> params) =>
      _client.postMap(GroupPaths.userList, data: params);

  /// 群成员列表。
  ///
  /// 老端 `user-select.vue::getGroupUser` 直接对 `res.data` 做 `filter/forEach`，
  /// 说明返回的是**数组**——用 [userList]（按 Map 解析）会拿到空 map。
  Future<List<Map<String, dynamic>>> userListMaps(
    Map<String, dynamic> params,
  ) => _client.postListMaps(GroupPaths.userList, data: params);

  /// 群成员列表 + 总数。
  ///
  /// 群成员页要显示「查看全部群成员 N 人」，而 `N` 是**信封里的 `count`**
  /// （不是本页条数）——所以这一份走 [ApiClient.postPage] 把 `count` 一起取回来。
  Future<({List<Map<String, dynamic>> rows, int count})> userListPage(
    Map<String, dynamic> params,
  ) => _client.postPage(GroupPaths.userList, data: params);

  Future<Map<String, dynamic>> allUser([
    Map<String, dynamic> params = const {},
  ]) => _client.postMap(GroupPaths.allUser, data: params);

  /// 创建群聊。
  ///
  /// [notify] 默认跟其它接口一样由接口层弹提示；创建这条路上页面会自己按同一套
  /// 规则提示（见 `ApiClient.notifyError`），所以调用方传 `false` 免得弹两次。
  Future<Map<String, dynamic>> add(
    Map<String, dynamic> params, {
    bool notify = true,
  }) => _client.postMap(GroupPaths.add, data: params, notify: notify);

  Future<Map<String, dynamic>> joinGroup(Map<String, dynamic> params) =>
      _client.postMap(GroupPaths.joinGroup, data: params);

  Future<void> bindGroup(Map<String, dynamic> params) =>
      _client.postVoid(GroupPaths.bindGroup, data: params, notify: false);

  Future<void> setNotice(Map<String, dynamic> params) =>
      _client.postVoid(GroupPaths.setNotice, data: params);

  Future<void> editName(Map<String, dynamic> params) =>
      _client.postVoid(GroupPaths.editName, data: params);

  Future<void> addUser(Map<String, dynamic> params) =>
      _client.postVoid(GroupPaths.addUser, data: params);

  Future<void> removeUser(Map<String, dynamic> params) =>
      _client.postVoid(GroupPaths.removeUser, data: params);

  Future<void> removeGroup(Map<String, dynamic> params) =>
      _client.postVoid(GroupPaths.removeGroup, data: params);

  Future<void> clearMessage(Map<String, dynamic> params) =>
      _client.postVoid(GroupPaths.clearMessage, data: params);

  Future<void> setManager(Map<String, dynamic> params) =>
      _client.postVoid(GroupPaths.setManager, data: params);

  Future<void> setNoSpeak(Map<String, dynamic> params) =>
      _client.postVoid(GroupPaths.setNoSpeak, data: params);

  Future<void> changeOwner(Map<String, dynamic> params) =>
      _client.postVoid(GroupPaths.changeOwner, data: params);
}

final groupApiProvider = Provider<GroupApi>(
  (ref) => GroupApi(ref.watch(apiClientProvider)),
);
