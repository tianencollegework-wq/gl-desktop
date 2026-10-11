import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/i18n/app_i18n.dart';
import '../../core/notify/message_notification_presenter.dart';
import '../../core/router/app_router.dart';
import '../../core/store/session_store.dart';
import '../../core/ui/notice_bus.dart';
import '../../domain/call/call_busy.dart';
import '../../domain/group_call/group_call_push.dart';

/// 「推送来的群通话邀请」在主 isolate 里的落点（S6.14）。
///
/// 后台 isolate（`push_background.dart`）只能把屏幕点亮、响铃、把整条报文留在通知里；
/// **真正进那个群通话页**需要界面与路由，只能在主 isolate 做 —— 就是这个类。
/// 与 1:1 那条（[CallPushHost]）分工一样，区别只在落点：
///
/// * 1:1 来电 → `CallSyncService.handlePushedCalling`（建通话会话，要接听）；
/// * 群通话邀请 → 直接 push **群通话页**：那一页进去就是加入房间
///   （与在群资料页点「群通话」完全同一条路，不另开一条建链的路）。
///
/// 两条入口都要接住：
/// * **冷启动**：App 是被这条邀请拉起来的（进程当时已经没了）→ 找通知要那条报文；
/// * **点击**：App 还在跑，用户点了那条通知 → 回调里给那条报文。
///
/// 挂在 `MaterialApp.builder` 上（与 [CallPushHost] / `NotificationHost` 同一层）：
/// 它在任何页面上都要活着。
class GroupCallPushHost extends ConsumerStatefulWidget {
  const GroupCallPushHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<GroupCallPushHost> createState() => _GroupCallPushHostState();
}

class _GroupCallPushHostState extends ConsumerState<GroupCallPushHost> {
  /// 已经处理过的邀请 id：冷启动与「点击」两条入口可能各来一次同一条
  final Set<String> _handled = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    final presenter = ref.read(messageNotificationPresenterProvider);
    // 用户点开那条邀请（App 还活着）
    presenter.onGroupCallOpen((payload) => unawaited(_deliver(payload)));
    // 冷启动：App 就是被这条邀请拉起来的
    try {
      final launch = await presenter.takeLaunchGroupCall();
      if (launch != null && launch.isNotEmpty) await _deliver(launch);
    } on Object catch (error) {
      debugPrint('[群通话] 读冷启动的邀请报文失败：$error');
    }
  }

  /// 会话刚恢复完之前 `sessionStore` 还是空的：路由守卫（未登录会被拦到登录页）
  /// 与页面里的「我是谁」都还没就绪，等最多 2 秒（与 1:1 那条同一个理由）。
  Future<void> _awaitSession() async {
    for (var i = 0; i < 20; i++) {
      if (ref.read(sessionStoreProvider).userId.isNotEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    debugPrint('[群通话] 等了 2 秒还没恢复出登录用户，仍然试着进那个群通话页');
  }

  /// 一条邀请通知带来的 payload（整条群通话报文的 JSON）
  Future<void> _deliver(String payload) async {
    await _awaitSession();
    if (!mounted) return;
    final invite = groupCallFromSignal(_decode(payload));
    if (invite == null) {
      debugPrint('[群通话] 通知里的 payload 不是一条群通话邀请，忽略');
      return;
    }
    final id = invite.callId.isNotEmpty ? invite.callId : invite.conversationId;
    if (!_handled.add(id)) {
      debugPrint('[群通话] 同一条邀请已经处理过：$id');
      return;
    }
    // 超龄就只当没发生：群里那通可能早就散了
    if (!invite.isFresh(DateTime.now())) {
      debugPrint('[群通话] 通知里的这条邀请已超龄：$id');
      return;
    }
    if (!invite.canOpen) {
      debugPrint('[群通话] 邀请里没有群会话 id，无法进群通话页');
      return;
    }
    // 人已经要进来了：先把通知收掉（它不该比这个动作活得更久）
    try {
      await ref
          .read(messageNotificationPresenterProvider)
          .cancelGroupCallRing();
    } on Object catch (error) {
      debugPrint('[群通话] 收掉邀请通知失败：$error');
    }
    if (!mounted) return;
    // 正在打 1:1 电话时不进（S6.15）：推送是**冷启动/后台**那条路，
    // 它同样不该在已经占着麦克风的时候把群通话页推上来
    //（与群资料页那颗入口、应用内横幅用的是同一个判据）
    if (ref.read(callBusyProvider)) {
      noticeBus.toast(ref.read(appI18nProvider).t('group.callBusy'));
      return;
    }
    _open(invite);
  }

  /// 进那个群的群通话页。
  ///
  /// **不另开一条建链的路**：与在群资料页点「群通话」走的是同一个路由、同一个页面
  /// ——进去就是加入房间，页面那边全套（采媒体、建会话、订阅、保活）照旧。
  ///
  /// 不在这里判「我是不是已经在这一页了」：那种情况下那条通知根本不存在
  /// （在房间里的人是**在线**的，服务端不会给他推邀请；而真进来的人又会在
  /// `GroupCallPage.initState` 里把通知收掉），硬判反而要跟路由的内部状态打交道。
  void _open(GroupCallPush invite) {
    final target =
        '${AppRoutes.groupCall}?id=${Uri.encodeComponent(invite.conversationId)}'
        '&name=${Uri.encodeComponent(invite.groupName)}';
    debugPrint('[群通话] 推送来的邀请进群通话页：${invite.conversationId}');
    ref.read(appRouterProvider).push(target);
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
