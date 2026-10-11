import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/chat_api.dart';

/// 通话信令的通道（S6.1）。
///
/// 老端就一行：`this.$api.msgApi.sendToMsg({...十个字段})`，服务端落库后推给对端。
/// 新端把它单独放一层，是为了让 S6.3 的控制器（消费 [CallEffect] 的那个）
/// 能注入假实现做整链路测试——媒体层（S6.2）与界面（S6.3）都不该直接摸 HTTP。
///
/// 返回的是信封里的 `data`：主叫发 `calling` 时要拿它的 `msg_id`
/// （老端 `this.wsData = res.data`），并且服务端会用 `data.extends.code == 907`
/// 告诉我们「对方不在线」。
class CallRepository {
  const CallRepository(this._api);

  final ChatApi _api;

  Future<Map<String, dynamic>> sendSignal(Map<String, dynamic> request) =>
      _api.sendToMsg(request);
}

final callRepositoryProvider = Provider<CallRepository>(
  (ref) => CallRepository(ref.watch(chatApiProvider)),
);
