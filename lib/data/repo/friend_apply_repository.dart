import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/net/api_exception.dart';
import '../../core/util/json_value.dart';
import '../../domain/contacts/friend_apply.dart';
import '../api/friend_api.dart';

/// 「新朋友」页的一页结果
class ApplyPageResult {
  const ApplyPageResult({
    required this.items,
    required this.total,
    required this.page,
  });

  final List<FriendApply> items;

  /// 信封里的 `count`（总数，不是本页条数）
  final int total;

  final int page;
}

/// 好友申请仓库（S5.1 的「新朋友」页）。
///
/// 老端这个页面**不落库**：每次进页面 / 换分段 / 翻页都现拉一次，处理器里
/// `this.getList()` 再拉一次。新端也照这个来——申请是「一次性」的数据，
/// 本地缓存它没什么意义（同意之后那条记录就不该再出现）。
class FriendApplyRepository {
  FriendApplyRepository(this._api);

  final FriendApi _api;

  /// 老端 `params.limit` 就是 10
  static const int pageSize = 10;

  Future<ApplyPageResult> page({required ApplyTab tab, int page = 1}) async {
    final result = await _api.applyPage(<String, dynamic>{
      'page': page,
      'limit': pageSize,
      'is_mine': tab.isMine,
    });
    return ApplyPageResult(
      items: parseApplyRows(result.rows),
      total: result.count,
      page: page,
    );
  }

  /// 同意 / 拒绝（老端 `acceptApply({friend_id, status})`）。
  ///
  /// 返回服务端的 `msg`，调用方拿它弹提示（老端 `showToast({title: e.msg})`）。
  Future<String> respond({
    required String friendId,
    required bool agree,
  }) async {
    if (friendId.isEmpty) {
      // 老端在这种情况下会给服务端发一个 `undefined`，静默失败；这里直接报出来
      throw const UnknownApiException('这条申请缺少 friend_id，无法处理');
    }
    return _api.acceptApply(<String, dynamic>{
      // 服务端原样是数字就发数字（老端发的是 JS 的 number）
      'friend_id': idValue(friendId),
      'status': agree ? ApplyStatus.accepted : ApplyStatus.refused,
    });
  }
}

final friendApplyRepositoryProvider = Provider<FriendApplyRepository>(
  (ref) => FriendApplyRepository(ref.watch(friendApiProvider)),
);
