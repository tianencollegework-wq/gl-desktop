import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/notify/message_notification_presenter.dart';
import '../../core/store/session_store.dart';
import '../../core/util/json_value.dart';
import '../../domain/call/call_controller.dart';
import '../../domain/call/call_machine.dart';
import '../../domain/call/call_sync_service.dart';
import '../../domain/call/incoming_call_push.dart';

/// 「推送来的来电」在主 isolate 里的落点（S8.1h）。
///
/// 后台 isolate（`push_background.dart`）只能把屏幕点亮、响铃、把报文留在通知里；
/// **真正把电话建起来**需要界面、需要长连接，只能在主 isolate 做 —— 就是这个类。
///
/// 两条入口都要接住：
/// * **冷启动**：App 是被来电通知拉起来的（进程当时已经没了）→ 找通知要那条报文；
/// * **点击**：App 还在跑，用户点了来电通知 → 回调里给那条报文。
///
/// 接住之后**一律交给 [CallSyncService.handlePushedCalling]** —— 和长连接走同一个
/// 入口（落库 + 状态机），不另开第二条路。
///
/// 挂在 `MaterialApp.builder` 上（与 [CallHost] / `NotificationHost` 同一层）：
/// 它在任何页面上都要活着，而且要在通话页被推上来之前就已经就位。
class CallPushHost extends ConsumerStatefulWidget {
  const CallPushHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<CallPushHost> createState() => _CallPushHostState();
}

class _CallPushHostState extends ConsumerState<CallPushHost> {
  /// 已经处理过的通话 id：冷启动与「点击」两条入口可能各来一次同一条
  final Set<String> _handled = <String>{};

  /// 通知栏里那条来电还没收掉
  bool _noticeShown = false;

  /// 正在被盯着的通话控制器（收通知的监听挂在它身上）
  CallController? _watched;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _watched?.view.removeListener(_syncIncomingNotice);
    super.dispose();
  }

  Future<void> _start() async {
    final presenter = ref.read(messageNotificationPresenterProvider);
    // 用户点开那条来电通知（App 还活着）
    presenter.onIncomingCallOpen((payload) => unawaited(_deliver(payload)));
    // 冷启动：App 就是被这条来电通知拉起来的
    try {
      final launch = await presenter.takeLaunchIncomingCall();
      if (launch != null && launch.isNotEmpty) await _deliver(launch);
    } on Object catch (error) {
      debugPrint('[来电] 读冷启动的来电报文失败：$error');
    }
  }

  /// 会话可能还没从本地恢复完（冷启动那一瞬间）：那时状态机认不出「这通电话是找我的」
  /// （`myUserId` 还是空串），会把它当成别人的电话丢掉。正常情况第一帧就已经好了 ——
  /// 这里最多等 2 秒只是保险。
  Future<void> _awaitSession() async {
    for (var i = 0; i < 20; i++) {
      if (ref.read(sessionStoreProvider).userId.isNotEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    debugPrint('[来电] 等了 2 秒还没恢复出登录用户，仍然试着接这通电话');
  }

  /// 一条来电通知带来的 payload（整条 `calling` 报文的 JSON）
  Future<void> _deliver(String payload) async {
    await _awaitSession();
    if (!mounted) return;
    // 通知里存的是**整条 `calling` 报文**（不是推送数据那张表，也不是会话 id）
    final frame = _decode(payload);
    final call = incomingCallFromSignal(
      frame,
      myUserId: ref.read(sessionStoreProvider).userId,
    );
    if (call == null) {
      debugPrint('[来电] 通知里的 payload 不是一通来电，忽略');
      return;
    }

    final id = asText(frame?['id']);
    if (id.isNotEmpty && !_handled.add(id)) {
      debugPrint('[来电] 同一通电话已经处理过：$id');
      return;
    }
    // 超龄就只当没发生：主叫 60 秒就挂了，这时才把来电页推出来只会
    // 「响一下就断」，比不响更烦人
    if (!call.isFresh(DateTime.now())) {
      debugPrint('[来电] 通知里的这通电话已超龄：$id');
      return;
    }
    if (!call.canRebuildSession) {
      // 服务端只在报文超长时才会丢掉 payload（来电报文很短，几乎不会发生）；
      // 真丢了就没法重建会话，只能留条日志
      debugPrint('[来电] payload 不完整，无法重建会话：${call.peerId}');
      return;
    }

    _noticeShown = true;
    _watchSession();
    debugPrint(
      '[来电] 推送里的来电接进通话链路：${call.peerId}'
      '（${call.isVideo ? '视频' : '语音'}）',
    );
    await ref.read(callSyncServiceProvider).handlePushedCalling(call.signal);
  }

  /// 接听 / 拒接 / 对方挂断 / 响铃超时 —— 这四种都会让「通知栏那条来电」过时，
  /// 所以要盯着会话，一不再响铃就把它收掉。
  ///
  /// 挂在**会话状态**上而不是某个具体动作上：结束的路径太多了，只有状态这一条是
  /// 它们共同的终点。通告栏那条不该比电话活得更久（不然接听完它还挂着，得等
  /// 那个 45 秒的兜底超时才消失）。
  void _watchSession() {
    if (_watched != null) return;
    final controller = ref.read(callControllerProvider);
    _watched = controller;
    controller.view.addListener(_syncIncomingNotice);
  }

  /// 还在响铃就留着；一旦接听（connecting / talking）或结束，通知栏那条就收掉
  void _syncIncomingNotice() {
    final controller = _watched;
    if (controller == null || !_noticeShown) return;
    if (controller.view.value.session.phase == CallPhase.incoming) return;
    _noticeShown = false;
    unawaited(
      ref.read(messageNotificationPresenterProvider).cancelIncomingCall(),
    );
  }

  static Map<String, dynamic>? _decode(String payload) {
    try {
      final decoded = json.decode(payload);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
