import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/store/session_store.dart';
import '../../domain/chat/group_members.dart';
import '../api/group_api.dart';

/// 群成员（S4.4c 的 @ 用）。
///
/// 只读不存：老端 `user-select.vue` 每次打开选择器都重新请求一次，
/// 这里也用 `FutureProvider.autoDispose`，关掉选择器就丢缓存。
class GroupMemberRepository {
  const GroupMemberRepository(this._api);

  final GroupApi _api;

  Future<List<GroupMember>> members(String groupId, {String? meId}) async {
    final raw = await _api.userListMaps(<String, dynamic>{'group_id': groupId});
    return parseGroupMembers(raw, excludeUserId: meId);
  }
}

final groupMemberRepositoryProvider = Provider<GroupMemberRepository>(
  (ref) => GroupMemberRepository(ref.watch(groupApiProvider)),
);

/// 某个群的成员列表（不含自己）
final groupMembersProvider = FutureProvider.autoDispose
    .family<List<GroupMember>, String>((ref, groupId) {
      final me = ref.watch(sessionStoreProvider).user;
      return ref
          .watch(groupMemberRepositoryProvider)
          .members(groupId, meId: me?.userId);
    });
