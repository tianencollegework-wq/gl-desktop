import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'sfu_room.dart';

/// **正在进行的那个群通话**。
///
/// 为什么需要它：群通话是"点进去才有"的（没有来电那套推送叫醒），房间对象挂在
/// 通话页上；而服务端推来的 `sfuRoom`（有人进来 / 走了 / 换了会话）落在 **WS 层**。
/// 两头不认识，中间要有个东西把它们接上 —— 就是它。
///
/// 它只做三件事，不含任何业务判断：
/// * [attach] / [detach]：通话页进出时登记（同一时刻最多一个，页面只有一份房间）；
/// * [onRoomChanged]：WS 说某个房间变了 → **只理我自己那个房间**对账
///   （推来的房间号与手里这个不一致就直接忽略：别的群的通话与这一页无关）；
/// * [onReconnected]：长连接恢复 → 重新对一次账（断线期间的进出全补上）。
///
/// ⚠️ 它**不建会话**：对账是"按快照补差集"（见 [SfuRoom.refreshRoomState]），
/// 已经离开房间时那次调用是空转 —— 不会有"早就退出了又被一条推送拉回去"这种事。
class GroupCallHub {
  SfuRoom? _active;

  /// 当前正在进行的房间（没有就是 null）。
  ///
  /// 两处用它：测试与诊断；以及 S6.15 那条「谁在开语音」的登记处 —— 推来的
  /// `sfuRoom` 里要忽略的正是**我人已经在里面**的那一间（不然会给自己弹邀请）。
  SfuRoom? get active => _active;

  void attach(SfuRoom room) => _active = room;

  void detach(SfuRoom room) {
    if (identical(_active, room)) _active = null;
  }

  /// WS 推来"这个房间变了"
  Future<void> onRoomChanged({required String roomId, int? epoch}) async {
    final room = _active;
    if (room == null || room.roomId != roomId) return;
    await _refresh(room, epoch: epoch);
  }

  /// 长连接恢复
  Future<void> onReconnected() async {
    final room = _active;
    if (room == null) return;
    await _refresh(room);
  }

  /// 对账是**读**：失败只记日志。
  ///
  /// 以前这里是裸 `await`：服务端一抖（2026-10-06 实测：一次快照 2.7~30s，
  /// 还能整路超时），一次 WS 推送就能甩出一条「没人接的异步异常」
  /// （真机日志里那串 `Unhandled Exception: BusinessException(4005 …)` 就是它），
  /// 而界面什么也没多知道。下一次推送 / 定期回查会自己再对一遍。
  Future<void> _refresh(SfuRoom room, {int? epoch}) async {
    try {
      await room.refreshRoomState(epoch: epoch);
    } on Object catch (error) {
      debugPrint('[群通话] 推送对账失败（忽略，回查会补）：$error');
    }
  }
}

final groupCallHubProvider = Provider<GroupCallHub>((ref) => GroupCallHub());
