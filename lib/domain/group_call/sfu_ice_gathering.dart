import 'dart:async';

/// 等 ICE 候选收齐（**非 trickle**，Cloudflare SFU 的硬要求）。
///
/// CF 那条路没有单独的候选通道：每次发给服务端的 SDP 必须是「候选已经全在里面」
/// 的那一份（`docs/protocol/sfu-group-call.md`）。所以每次
/// `setLocalDescription` 之后都要先等 gathering 结束，再把 SDP 发出去。
///
/// ⚠️ **必须封顶**。这次等待发生在**会话队列内部**（队列要占着整轮 SDP 交换才算
/// 一次改动结束），一次迟迟不来的 gathering 回调会把这条会话上所有改动全部堵死。
/// 超时后放行已经收到的那些候选 —— 与浏览器「等一会儿就发」的老做法一致：
/// 宁可少几条候选（还能靠 TURN 与重连补上），也不能把整个房间卡住。
///
/// 于是它被单独抽出来：这是**纯逻辑**（一个 Completer + 一个定时器），可以脱离
/// 真机测到底（`test/group_call/sfu_ice_gathering_test.dart`）。
class IceGatherBarrier {
  IceGatherBarrier({
    this.timeout = const Duration(seconds: 5),
    this.alreadyComplete,
  });

  /// 等多久就放行
  final Duration timeout;

  /// 「其实已经收齐了」的快速判断（gathering 回调可能在 [wait] 之前就到了）
  final bool Function()? alreadyComplete;

  Completer<bool>? _pending;

  /// 开始等：`true` = 收齐了；`false` = 超时放行（调用方可以记一笔日志）
  Future<bool> wait() async {
    if (_isComplete()) return true;
    final completer = Completer<bool>();
    _pending = completer;
    // 登记之后再查一次：`onIceGatheringState` 完全可能就在上面那两行之间到了，
    // 那一趟 [complete] 会因为我们还没登记而丢掉 —— 接着就只能干等满整个超时
    // （真机上每一次 SDP 交换都白等 5 秒）。
    if (_isComplete()) {
      _pending = null;
      return true;
    }
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(false);
    });
    try {
      return await completer.future;
    } finally {
      timer.cancel();
      if (identical(_pending, completer)) _pending = null;
    }
  }

  bool _isComplete() => alreadyComplete?.call() ?? false;

  /// gathering 结束（`onIceGatheringState == complete`）时调用
  void complete() {
    final pending = _pending;
    if (pending == null || pending.isCompleted) return;
    pending.complete(true);
  }
}
