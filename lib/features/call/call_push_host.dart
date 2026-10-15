import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/notify/message_notification_presenter.dart';
import '../../core/platform/callkit.dart';
import '../../core/store/session_store.dart';
import '../../core/util/json_value.dart';
import '../../domain/call/call_controller.dart';
import '../../domain/call/call_machine.dart';
import '../../domain/call/call_sync_service.dart';
import '../../domain/call/incoming_call_push.dart';
import '../../domain/notify/push_registrar.dart';

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
///
/// ── iOS 那半边：系统来电界面（CallKit，2026-10-15 加）──────────────────────
/// iPhone 上「锁屏来电」不是我们能画出来的东西，只有 CallKit 能给。所以这里多干
/// 两件事（都只在 iOS 上，`CallKit.supported` 为假时整段是空操作）：
///
/// 1. **把来电交给系统**：App **不在屏幕上**时收到一通来电，就告诉原生上报给
///    CallKit（锁屏上弹出那个系统界面）。前台**不报** —— 那时我们有自己那张通话页，
///    再叠一层系统界面等于同一通电话响两次、还有两个接听键；
/// 2. **接住系统那一侧的动作**：用户在锁屏上按了接听/拒接，真正接电话的是**这套
///    状态机**（`accept()` / `hangup()`），不是原生。
///
/// 还有第三种入口：App 被 PushKit 的 VoIP 推送**叫醒**（进程当时已经没了）——
/// 报文原生替我们存着，这里在挂载时取一次（与「读冷启动那条通知」同一个道理）。
class CallPushHost extends ConsumerStatefulWidget {
  const CallPushHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<CallPushHost> createState() => _CallPushHostState();
}

class _CallPushHostState extends ConsumerState<CallPushHost>
    with WidgetsBindingObserver {
  /// 已经处理过的通话 id：冷启动与「点击」两条入口可能各来一次同一条
  final Set<String> _handled = <String>{};

  /// 通知栏里那条来电还没收掉
  bool _noticeShown = false;

  /// 正在被盯着的通话控制器（收通知的监听挂在它身上）
  CallController? _watched;

  /// `_syncSystemCall` 挂在哪个控制器上了（换控制器时要重挂）
  CallController? _systemAttachedTo;

  /// iOS：已经交给系统（CallKit）的那一通。非 iOS 上一直是 null。
  ///
  /// 记的是**通话 id**（`CallSession.messageId`）而不是对方的 uid：
  /// 「同一通电话」的判据只能是它 —— 同一个人前后打两通电话是两通。
  String? _systemCallId;

  /// 拿到的那条通道（`dispose` 里要从它身上摘监听，那时不该再动 `ref`）
  CallKit? _callKit;

  /// PushKit 发下来的 VoIP token（服务端要拿它发 VoIP 推送）。
  ///
  /// 它的去向：启动时与原生回调里各取一次 → `PushRegistrar.applyVoip()` →
  /// 落盘成 `apns_voip:xxx` 并上报服务端（详 `lib/core/platform/push_token.dart`
  /// 与 `lib/domain/notify/push_registrar.dart`）。**没拿到它的话，App 被划掉之后
  /// 服务端叫不醒这台机器**，所以日志里要写出来（见 [_reportIncoming]）。
  String _voipToken = '';

  @override
  void initState() {
    super.initState();
    // 盯生命周期：响铃期间「锁屏 / 切走」也要把这通交给系统（见
    // [didChangeAppLifecycleState]）
    WidgetsBinding.instance.addObserver(this);
    unawaited(_start());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // **响铃期间锁屏 / 切走**：会话状态一点没变，变的只是「App 还在不在屏幕上」，
    // 而那正是这条路要管的时刻。
    //
    // 只在状态变化时才评估的话（以前就是这样），「来电响着、用户按下电源键」
    // 这一幕永远不会走到 [CallKit.reportIncomingCall]：我们自己那张通话页
    // 在锁屏上画不出来，于是通话就那么响着、锁屏上什么都没有。
    if (state == AppLifecycleState.resumed) return;
    _syncSystemCall();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _watched?.view.removeListener(_syncIncomingNotice);
    _watched?.view.removeListener(_syncSystemCall);
    _callKit?.removeActionListener(_onSystemAction);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ⚠️ **必须每帧盯当前那个控制器**（而不是 `initState` 里挂一次）：
    // `callControllerProvider` 会随**登录 / 登出重建**（它自己的注释里写着），
    // 而挂在旧实例上的监听从此再也不会响 —— 表现是「登录之后收到来电，
    // 系统界面不弹、通知也收不掉」，而这条链上每一段单看都是对的。
    _attach(ref.watch(callControllerProvider));
    return widget.child;
  }

  /// 把手挂在**当前**那个通话控制器上（幂等：同一个控制器调几次都没事）。
  void _attach(CallController controller) {
    if (!identical(_watched, controller)) {
      _watched?.view.removeListener(_syncIncomingNotice);
      _watched?.view.removeListener(_syncSystemCall);
      _systemAttachedTo = null;
      _watched = controller;
      controller.view.addListener(_syncIncomingNotice);
    }
    // 系统那一个等 `_callKit` 就绪之后才挂（它比第一帧晚）
    if (_callKit != null && !identical(_systemAttachedTo, controller)) {
      controller.view.addListener(_syncSystemCall);
      _systemAttachedTo = controller;
    }
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
    // ⚠️ 上面那一跳是**平台通道**（几十毫秒起），而整条链是 `unawaited` 甩出来的：
    // 等回来时这一层可能已经不在了（真机上是「刚起来就被划掉 / 切走」，CI 上就是
    // 那条启动自检用例跑完）。那时再碰 `ref` 就会直接抛（Riverpod 原话：
    // Using "ref" when a widget is about to or has been unmounted is unsafe.），
    // 而这个异常**没人接** —— 表现是「用例早就过了，报告里却又多一条失败」。
    // 2026-10-15 第十跑 iOS 那条「从零启动：能跑到登录页」报的正是这个：
    // failed after test completion（用例本体是过的，异常在它结束后才掉出来）。
    if (!mounted) return;
    await _startSystemCalls();
  }

  /// iOS 那一半：系统来电界面（CallKit）。其它平台这里是空操作。
  Future<void> _startSystemCalls() async {
    // 被拆掉了就一律不碰：见 [_start] 那段注释
    if (!mounted) return;
    final callKit = ref.read(callKitProvider);
    if (!callKit.supported) return;
    _callKit = callKit;
    callKit.addActionListener(_onSystemAction);
    // 会话状态一直盯着：来电要交给系统，结束要告诉系统收尾
    //（`_attach` 里挂，这里再叫一次是为了把 `_syncSystemCall` 补上 ——
    //  第一帧那次 `_callKit` 还没就绪，它不会被挂上去）
    _attach(ref.read(callControllerProvider));
    try {
      // 冷启动：App 可能是被 PushKit 那条 VoIP 推送叫醒的（进程当时已经没了），
      // 报文原生替我们存着 —— 取一次就清掉了
      final pending = await callKit.takePendingCall();
      if (pending.isNotEmpty && mounted) await _deliver(pending);
      _voipToken = await callKit.voipToken();
      await _reportVoipToken(_voipToken);
      final error = await callKit.lastError();
      if (error.isNotEmpty) {
        debugPrint('[来电] 系统那侧最近一次失败：$error');
      }
    } on Object catch (error) {
      debugPrint('[来电] 读 CallKit 那边的状态失败：$error');
    }
  }

  /// 系统那一侧的动作：用户在系统来电界面上按了键 / PushKit 送来一通 / token 到位。
  void _onSystemAction(CallKitAction action) {
    // 原生回调可能比界面活得久（这一层是随 App 起停的，但回调不保证时序）
    if (!mounted) return;
    switch (action.kind) {
      case CallKitActionKind.answer:
        if (!_isAboutCurrentCall(action)) return;
        // **接电话的是这套状态机**（发 acceptRtc、取麦克风、建连），原生只管那个界面
        debugPrint('[来电] 用户在系统界面上接了：${action.callId}');
        unawaited(ref.read(callControllerProvider).accept());

      case CallKitActionKind.end:
        if (!_isAboutCurrentCall(action)) return;
        debugPrint('[来电] 用户在系统界面上挂了：${action.callId}');
        unawaited(ref.read(callControllerProvider).hangup());

      case CallKitActionKind.incoming:
        // 已经活着的这一侧马上处理（与被推醒那条路同一入口，靠通话 id 去重）
        unawaited(_deliver(action.payload));

      case CallKitActionKind.token:
        _voipToken = action.token;
        debugPrint('[推送] VoIP token 到了（${action.token.length} 位十六进制）');
        unawaited(_reportVoipToken(action.token));
    }
  }

  /// 系统那一侧这条动作，说的是**当前这一通**吗。
  ///
  /// 原生把我们的通话 id 一并带回来了（`CallKitBridge` 里那张 `uuid → callId` 的
  /// 对照表），所以这里能核对。为什么要核对：用户在锁屏上按接听 / 挂断时，系统
  /// 那个界面可能已经过期（那通电话刚被换掉或刚结束），而 `accept()` / `hangup()`
  /// 动的是**现在**这一通 —— 不核对就成了「按的是 A，接起来的是 B」，
  /// 而那种错在真机上看起来完全像「网络抽风」。
  ///
  /// 空 id 是原生没给出对应关系（旧包 / 表里已经清掉），那就按原样放行。
  bool _isAboutCurrentCall(CallKitAction action) {
    final id = action.callId;
    if (id.isEmpty) return true;
    final current = _watched?.view.value.session.messageId ?? '';
    if (id == current) return true;
    debugPrint('[来电] 系统界面上这条动作不是当前这一通（$id ≠ $current），忽略');
    return false;
  }

  /// App 现在在不在屏幕上。
  ///
  /// `null`（还没报过状态）当成**在**：那时界面刚起来，用户正看着它。
  bool get _onScreen {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  /// 把「有一通来电」这件事交给 iOS 的系统来电界面（CallKit）。
  ///
  /// 判据只有一条：**App 不在屏幕上**。前台我们自己有通话页，再叠一层系统界面
  /// 等于同一通电话响两次；而后台 / 锁屏正是我们画不出来的那一半 ——
  /// 那才是这条路存在的全部理由。
  void _syncSystemCall() {
    final callKit = _callKit;
    if (callKit == null) return;
    final session = _watched?.view.value.session;
    if (session == null) return;

    final reported = _systemCallId;
    if (reported != null) {
      // 还是那一通、而且这通还活着 → 什么都不用做。
      // **其余情况都要收尾**：通话结束了（`ended` / 回到 `idle`）或被换成了另一通 ——
      // 不收的话锁屏上那个界面会一直挂着（“对方还在打”），
      // 而那正是用户最容易被误导的一种状态。
      final stillThisOne = session.isActive && session.messageId == reported;
      if (!stillThisOne) {
        _systemCallId = null;
        unawaited(callKit.reportEnded(callId: reported));
      }
    }

    if (!session.isActive) return;
    // 没有通话 id 就没法去重（报两次会在锁屏上变成两条一模一样的来电）
    if (session.messageId.isEmpty) return;
    if (_systemCallId == session.messageId) return;
    if (session.phase != CallPhase.incoming) return;
    if (_onScreen) return;

    _systemCallId = session.messageId;
    unawaited(_reportIncoming(callKit, session));
  }

  Future<void> _reportIncoming(CallKit callKit, CallSession session) async {
    final report = await callKit.reportIncomingCall(
      callId: session.messageId,
      peerId: session.peerId,
      peerName: session.peerName,
      video: session.isVideo,
    );
    if (report.accepted) {
      debugPrint(
        '[来电] 已交给系统来电界面：${session.peerName}'
        '${report.alreadyReported ? '（原生说已经报过了）' : ''}'
        // 没 token 就得说出来：那种情况下 App 一旦被划掉，服务端**叫不醒**这台机器
        //（那时系统界面再好看也没机会弹）
        '${_voipToken.isEmpty ? '｜⚠ 还没有 VoIP token（被划掉之后叫不醒）' : ''}',
      );
      return;
    }
    // 没接住（模拟器上必然如此 —— CallKit 不在模拟器上跑）：把记账清掉，
    // 免得后面「收尾」去收一通系统上根本不存在的电话
    debugPrint('[来电] 系统没接住这通来电：${report.reason}');
    if (_systemCallId == session.messageId) _systemCallId = null;
  }

  /// 把 PushKit 的标识登记给服务端（S8.2）：**只有它能让锁屏来电生效**。
  ///
  /// 服务端按 `apns_voip:` 前缀把这条标识与普通推送那条（`fcm_ios:`）分开存，
  /// 一通新来电只从这条走（详 `lib/core/platform/push_token.dart` 末尾的说明）。
  ///
  /// 空 token（模拟器、没配推送权限、原生还没拿到）直接跳过；上报失败的后果只是
  /// 「锁屏来电不弹」，所以整段只记一行日志，绝不往外抛。
  Future<void> _reportVoipToken(String token) async {
    // 拆掉了就没人可登记了（`ref` 这时候不能用）：见 [_start] 那段注释
    if (!mounted) return;
    if (token.trim().isEmpty) return;
    try {
      await ref.read(pushRegistrarProvider).applyVoip(token);
    } on Object catch (error) {
      debugPrint('[来电] 上报 VoIP 标识失败：$error');
    }
  }

  /// 会话可能还没从本地恢复完（冷启动那一瞬间）：那时状态机认不出「这通电话是找我的」
  /// （`myUserId` 还是空串），会把它当成别人的电话丢掉。正常情况第一帧就已经好了 ——
  /// 这里最多等 2 秒只是保险。
  Future<void> _awaitSession() async {
    for (var i = 0; i < 20; i++) {
      // 这两秒里界面可能就已经被拆了（同 [_start] 那段注释）：不用再等
      if (!mounted) return;
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
    debugPrint(
      '[来电] 推送里的来电接进通话链路：${call.peerId}'
      '（${call.isVideo ? '视频' : '语音'}）',
    );
    await ref.read(callSyncServiceProvider).handlePushedCalling(call.signal);
  }

  /// 还在响铃就留着；一旦接听（connecting / talking）或结束，通知栏那条就收掉
  ///
  /// 为什么挂在**会话状态**上而不是某个具体动作上：结束的路径太多了（接听 / 拒接 /
  /// 对方挂断 / 响铃超时），只有状态这一条是它们共同的终点。通告栏那条不该比电话
  /// 活得更久（不然接听完它还挂着，得等那个 45 秒的兜底超时才消失）。
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
}
