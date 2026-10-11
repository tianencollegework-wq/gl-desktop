import 'dart:async';

import 'package:flutter/foundation.dart';

import 'sfu_failure.dart';

/// 一次会话改动（发布 / 订阅 / 重协商 / 收尾）。
typedef SfuMutation<T> = Future<T> Function();

/// **一条 SFU 会话的改动队列。**
///
/// 为什么需要它（官方文档的硬要求，写错就是偶发怪话）：
///
/// 1. **同一个 session 的改动必须串行**。CF 的一条 session 只有**一个** offer/answer
///    状态机；并发提交会被拒（HTTP 406）。文档举的反例正是我们会遇到的场景：
///    "A 还在入会，B 就加入了" —— 初始房间快照触发的订阅与"有人加入"触发的订阅同时
///    改 A 的接收会话。
/// 2. **一次改动要跨越完整的 SDP 交换才算完成**：发 offer 要等到 CF 的 answer 应用完；
///    CF 回 offer 时要等到端点的 answer 通过 `renegotiate` 交回去。所以队列占用的
///    粒度是「整个操作」，不是「一次 HTTP 请求」——`operation` 里自己做完整套交换。
/// 3. **结果不确定时必须换会话重建，不能重试**（见 [SfuFailureKind.unknownOutcome]）。
///    这种情况下队列把自己"毒化"：之后的改动立刻失败，逼调用方建新会话，
///    而不是让一堆请求继续往一个已经不可信的会话上堆。
///
/// 与 `call_controller` 里那条 ICE 候选队列的区别值得强调：候选是**幂等无害**的，
/// 所以那里失败重试；SFU 的 `tracks/new` **不幂等**（重复会重复分配订阅），
/// 所以这里失败即毒化 + 重建。两处策略相反，别互相抄。
class SfuSessionQueue {
  SfuSessionQueue({required this.sessionId});

  /// Cloudflare 分配（经我们服务端转发）的会话 id
  final String sessionId;

  Future<void> _chain = Future<void>.value();
  SfuFailure? _poisoned;
  String? _poisonedBy;
  int _pending = 0;

  /// 队列被毒化（这条会话不能再用了）时回调一次。
  ///
  /// 房间状态机靠它立刻去建新会话，而不是等下一次操作失败才发现。
  void Function(SfuFailure failure)? onPoisoned;

  /// 这条会话还能不能用
  bool get isPoisoned => _poisoned != null;

  /// 毒化的原因（没毒化时为 null）
  SfuFailure? get poisonReason => _poisoned;

  /// 毒化是在哪一步发生的（日志用）
  String? get poisonedBy => _poisonedBy;

  /// 排队中（含正在跑的那一个）
  int get pending => _pending;

  /// 排一个改动进去。返回的 future 完成 = **这次改动连同它的 SDP 交换都结束了**。
  ///
  /// * 严格按提交顺序执行，同一时刻只有一个在跑；
  /// * [SfuFailure.requiresRebuild] 为真的失败会毒化队列并触发 [onPoisoned]；
  /// * 非 [SfuFailure] 的异常（多半是代码 bug）不毒化会话，也不会把队列卡死。
  Future<T> run<T>(String label, SfuMutation<T> operation) {
    final poison = _poisoned;
    if (poison != null) {
      // 已经毒化：立刻失败，别让调用方白等，也别再往死会话上发请求
      return Future<T>.error(_rebuildRequired(poison));
    }

    _pending += 1;
    final completer = Completer<T>();
    _chain = _chain.then((_) async {
      final current = _poisoned;
      if (current != null) {
        completer.completeError(_rebuildRequired(current));
        return;
      }
      try {
        completer.complete(await operation());
      } on SfuFailure catch (failure) {
        if (failure.requiresRebuild) _poison(failure, label);
        completer.completeError(failure);
      } catch (error, stack) {
        // 非 SfuFailure：不毒化（不是"结果未知"，更像是我们的 bug），
        // 但必须把错误交出去，同时让队列继续能用。
        completer.completeError(error, stack);
      } finally {
        _pending -= 1;
      }
    });
    return completer.future;
  }

  void _poison(SfuFailure failure, String label) {
    if (_poisoned != null) return;
    _poisoned = SfuFailure(
      kind: failure.kind,
      message: failure.message,
      code: failure.code,
      label: failure.label ?? label,
    );
    _poisonedBy = label;
    debugPrint(
      '[群通话] 会话 $sessionId 判定为不可用（$label：${failure.kind.name}），'
      '需要换新会话重建',
    );
    onPoisoned?.call(_poisoned!);
  }

  /// 毒化之后拿到的失败：语义是"这条会话要重建"。
  SfuFailure _rebuildRequired(SfuFailure poison) => SfuFailure(
    kind: poison.kind,
    message: '会话已失效，需要重建：${poison.message}',
    code: poison.code,
    label: poison.label,
  );
}
