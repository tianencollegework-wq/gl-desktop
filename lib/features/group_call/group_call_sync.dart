import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ws/ws_client.dart';
import '../../core/ws/ws_event.dart';
import '../../core/ws/ws_handlers.dart';
import '../../core/ws/ws_service.dart';
import '../../data/api/sfu_api.dart';
import '../../domain/group_call/group_call_hub.dart';
import '../../domain/group_call/group_call_presence.dart';

/// 群通话链路：把服务端推来的 `sfuRoom` 接进**正在进行的那个房间** +
/// **屋子外面的界面**（S6.12 / S6.15）。
///
/// 与 1:1 的 `CallSyncService` 是同一个位置的东西（在 `main()` 里启动一次），
/// 它做两件事：
///
/// * **对账**：注册表一变（有人进来 / 走了 / 掉线重建换了 sessionId）服务端就
///   `bumpEpoch` 并推一条 `sfuRoom`；没有它的话客户端只能等心跳比对版本号
///   （或 5 秒一次的定期回查）才发现 —— 别人进来了你要好一会儿才看见
///   （订阅也要那么久才建起来，别人听不到你的声音）。
/// * **谁在开语音**（[GroupCallPresenceTracker]）：同一条事件里还带着
///   `live` / `call_id` / 「刚开」那一次的发起人 —— 那是给**没在通话里的人**用的，
///   弹应用内横幅、在会话列表上挂「语音通话中」。两件事互不影响：
///   房间对账只关心我登记过的那一间，在线状态关心我所在的每一个群。
///
/// 服务端推的是**群频道**（客户端进群会话时已经 `joinGroup`），所以这条事件
/// 只要 App 在群里在线就能收到；重连后靠 [GroupCallHub.onReconnected] 补一次对账，
/// 顺手把界面上的标记也回查一遍（断线那段时间可能已经散场了）。
class GroupCallSyncService {
  GroupCallSyncService(this._hub, this._ws, [this._presence]);

  final GroupCallHub _hub;
  final WsService _ws;
  final GroupCallPresenceTracker? _presence;

  bool _started = false;

  /// 上一次的连接状态：只在「从非 connected 变成 connected」时补一次对账
  WsStatus _lastStatus = WsStatus.idle;

  void start() {
    if (_started) return;
    _started = true;
    _ws.router.register(WsEvents.sfuRoom, _onRoomChanged);
    // 订阅不取消：它挂在根作用域的 WsService 上，生命周期与容器一致
    _ws.statusChanges.listen(_onStatusChanged);
  }

  Future<void> _onRoomChanged(WsEvent event) async {
    final roomId = event.data['room_id']?.toString() ?? '';
    if (roomId.isEmpty) {
      debugPrint('[群通话] sfuRoom 事件没有 room_id：${event.raw}');
      return;
    }
    // 屋子外面的提示（横幅 / 会话列表标记）：不干扰正在进行的那个房间
    _presence?.onRoomEvent(event.data, inRoomId: _hub.active?.roomId ?? '');
    await _hub.onRoomChanged(roomId: roomId, epoch: event.intValue('epoch'));
  }

  void _onStatusChanged(WsStatus status) {
    final reconnected =
        status == WsStatus.connected && _lastStatus != WsStatus.connected;
    _lastStatus = status;
    if (!reconnected) return;
    unawaited(_hub.onReconnected());
    // 断线那段时间里散场的语音不会补推（事件只发给当时的在线者），
    // 所以重连后主动回查一次：会话列表那条标记不能挂着一条早就没有的语音
    final presence = _presence;
    if (presence != null) unawaited(presence.verify());
  }
}

final groupCallSyncServiceProvider = Provider<GroupCallSyncService>(
  (ref) => GroupCallSyncService(
    ref.watch(groupCallHubProvider),
    ref.watch(wsServiceProvider),
    ref.watch(groupCallPresenceProvider),
  ),
);

/// 「谁在开群语音」的登记处（S6.15）。
///
/// 回查用的是同一个 `Sfu::room` 快照接口：它带回房间里的人，顺带把服务端那边
/// 超时没动静的行清掉 —— 所以这一次回查不只是客户端自己纠偏，服务端也一起干净了。
final groupCallPresenceProvider = Provider<GroupCallPresenceTracker>((ref) {
  final api = ref.watch(sfuApiProvider);
  return GroupCallPresenceTracker(
    probe: (roomId) async {
      try {
        final state = await api.roomState(roomId: roomId);
        return state.members.isNotEmpty;
      } on Object catch (error) {
        // 拿不准就保持原状（宁可多挂 45 秒，也别把正在进行的语音抹掉）
        debugPrint('[群通话] 回查房间 $roomId 失败：$error');
        return null;
      }
    },
  );
});
