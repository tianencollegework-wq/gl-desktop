import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/util/json_value.dart';
import '../../core/ws/ws_event.dart';
import '../../core/ws/ws_handlers.dart';
import '../../core/ws/ws_service.dart';
import '../chat/chat_sync_service.dart';
import '../lingting/lingting_player.dart';
import 'call_controller.dart';
import 'call_signal.dart';

/// 通话链路（S6.3）：把服务端推来的 `webrtc` 信令接进 [CallController]。
///
/// 老端这一段的两个入口：
/// * `App.vue` 的 `case 'webrtc'`：判自己发的 / 判多端锁 / `calling` 时落一条消息
///   （`appendMessage(res)`）并跳通话页 / 其余信令 `uni.$emit('webrtcConn', data)`
///   丢给 `call.vue` 塞进 WebView；
/// * `call.vue` 的 `uni.$on('webrtcConn')`：判忙线（`main_id != e.id` 就回 907）。
///
/// 新端两处合成一层：**解析 → 落库（只有 `calling`）→ 交给状态机**。
/// 状态机自己会判忙线、判多端、判是不是自己那条（见 `call_machine.dart`），
/// 所以这里不做任何业务判断，只是把报文变成信令。
class CallSyncService {
  CallSyncService(this._ref, this._ws, this._chat);

  final Ref _ref;
  final WsService _ws;
  final ChatSyncService _chat;

  bool _started = false;

  /// 每次现取控制器：登录 / 登出会重建它（`callControllerProvider` 盯 `user_id`）
  CallController get _controller => _ref.read(callControllerProvider);

  /// 注册 WS 处理器（在 `main()` 里启动一次）
  void start() {
    if (_started) return;
    _started = true;
    _ws.router.register(WsEvents.webrtc, _onSignal);
  }

  /// 收到一条 `webrtc` 事件。
  ///
  /// 落库只做 `calling` 这一条，理由与老端一致：通话中每一帧信令都是一个
  /// `webrtc` 消息，全落库的话 ICE 候选会往聊天里灌几十条。老端是
  /// `if (data.extends.event == 'calling') this.appendMessage(res)`，
  /// 自己那条回显也算（`fromUser.id == 我` 的那个分支里同样只认 `calling`）。
  ///
  /// 不响消息提示音 [ChatSyncService.handleIncoming] 那条链上的 `alert`：
  /// 这一通电话自己会响铃（老端也只有 App 在后台时才建通知栏）。
  Future<void> _onSignal(WsEvent event) async {
    final data = event.data;
    if (data.isEmpty) {
      debugPrint('[通话] webrtc 事件没有 data：${event.raw}');
      return;
    }

    final signal = parseCallSignal(data);
    if (signal.event.isEmpty) {
      debugPrint('[通话] 信令没有 event，已忽略：$data');
      return;
    }

    if (signal.event == CallEvent.calling) {
      // 来电 / 拨出那一刻先把灵听的音乐暂停：同一副喇叭，
      // 通话不可能等一首歌播完（切歌时机与微信一致：铃声一起，音乐就停）
      unawaited(_ref.read(lingtingPlayerProvider.notifier).pause());
      await _chat.handleIncoming(event, alert: false);
    }
    await _controller.remote(signal, pageActive: _controller.pageActive);
  }

  /// 把一条**推送里带来的** `calling` 接进通话链路（S8.1h，冷启动那条路）。
  ///
  /// 为什么要有它：对方 App 被杀时长连接是断的，`calling` 帧根本到不了他，
  /// 全靠离线推送把人叫醒。所以「被推送叫醒」也得能建出同一通电话 ——
  /// 而做法就是**走和 WS 完全一样的入口**（落库 + 交给状态机），
  /// 不另开第二条路径（否则「推送来的来电」和「长连接来的来电」迟早会长成两套）。
  ///
  /// 两件事已经在别处挡过了，这里不重复：
  /// * **时效**：超龄的来电在后台 isolate 那一步就被丢掉（`IncomingCallPush.isFresh`）；
  /// * **重复**：长连接那条路先到的话，这里看到会话已经起来就直接忽略 ——
  ///   否则会当成「又打进来一通」而给对方回一条忙线，等于把自己这通电话拒了。
  Future<void> handlePushedCalling(Map<String, dynamic> data) async {
    if (data.isEmpty) return;
    final signal = parseCallSignal(data);
    if (signal.event != CallEvent.calling) return;

    final controller = _controller;
    if (controller.session.isActive || controller.pageActive) {
      debugPrint('[通话] 推送里的这通来电已有会话（长连接先到），只把通话页叫出来');
      return;
    }
    await _chat.handleIncoming(
      WsEvent(
        type: WsEvents.webrtc,
        data: data,
        raw: <String, dynamic>{'type': WsEvents.webrtc, 'data': data},
      ),
      alert: false,
    );
    await controller.remote(signal, pageActive: controller.pageActive);
  }
}

/// 把一条 `webrtc` 事件的 `data` 解析成 [CallSignal]。
///
/// 字段分工照老端：事件/码/SDP/候选在 `data.extends` 里，外层是
/// `id`（通话 id，主叫生成的 uuid）/ `msg_id` / `fromUser` / `toContactId`。
/// `fromUser` 里读 `id` 或 `user_id`（老端两处写法都用过）。
CallSignal parseCallSignal(Map<String, dynamic> data) {
  final fromUser = asMap(data['fromUser']);
  return CallSignal.fromExtends(
    data['extends'],
    messageId: asText(data['id']),
    serverId: asText(data['msg_id']),
    fromUserId: asText(fromUser['id'] ?? fromUser['user_id']),
    fromUserName: asText(fromUser['displayName'] ?? fromUser['realname']),
    fromUserAvatar: asText(fromUser['avatar']),
    toContactId: asText(data['toContactId']),
  );
}

final callSyncServiceProvider = Provider<CallSyncService>((ref) {
  return CallSyncService(
    ref,
    ref.watch(wsServiceProvider),
    ref.watch(chatSyncServiceProvider),
  );
});
