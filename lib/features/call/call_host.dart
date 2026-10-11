import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/router/app_router.dart';
import '../../core/store/session_store.dart';
import '../../data/media/call_media_engine.dart';
import '../../domain/call/call_controller.dart';
import '../../domain/call/call_media_config.dart';
import '../../domain/call/call_machine.dart';
import '../../domain/call/turn_credentials.dart';
import 'call_diagnostics_sheet.dart';
import 'call_window_bridge.dart';
import 'call_window_host.dart';
import 'call_window_media_engine.dart';

/// 通话页的开关（S6.3）。
///
/// 老端是「收到 `calling` 就 `uni.navigateTo('/pages/message/call?...')`、
/// 挂断就 `navigateBack()`」，判断散在信令分支（`App.vue`）与 WebView 里。
/// 新端收成**一处**：会话一起来就打开通话页、一结束就关掉 ——
/// 不管是点出来的、别人打进来的、还是通话卡片回拨的，都走这条路。
///
/// 它挂在 `MaterialApp.builder` 上（在 Navigator 之上），因此：
/// * 任何页面上来电都能盖住（包括 pushed 的聊天页 / 资料页）；
/// * 直接用 `GoRouter` 实例 push/pop，不需要自己的 context 在栈顶。
///
/// **桌面（2026-10-04）**：界面改在**独立通话窗**里（用户原话「请将通话做到新开
/// 一个独立窗口」），这个组件顺带当那颗窗的宿主：
///
/// * 会话一起来就把「对端是谁 + 这份 ICE 列表」交给窗口（`plan`），之后状态一变
///   就推一份过去；
/// * 窗口那边说的话（媒体事件 / 界面动作）在这里接回控制器 —— 窗口里那颗引擎只
///   管媒体，状态机与信令是**主窗口这一份**（见 `call_window_bridge.dart`）；
/// * 通话结束让窗口自己关掉。窗口起不来时退回主窗口这张页
///   （媒体也跟着退回本引擎，见 `CallWindowMediaEngine.degraded`）。
class CallHost extends ConsumerStatefulWidget {
  const CallHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<CallHost> createState() => _CallHostState();
}

class _CallHostState extends ConsumerState<CallHost> {
  CallController? _controller;

  /// 通话页是不是我们推上去的。
  ///
  /// 用一个标记而不是去查当前路由：一来不依赖路由内部结构，
  /// 二来「一通电话里状态会变好多次」（拨号→接通→挂断），
  /// 有它才不会每次变化都往栈上叠一个通话页。
  bool _open = false;

  /// 桌面那条路：媒体代理（不是代理就说明这个平台/这次运行不走通话窗）
  CallWindowMediaEngine? _proxy;
  CallWindowTransport? _transport;
  CallWindowListener? _listener;

  /// 正在跑的那通电话的对端信息（窗口每次上线都要再给一份）
  CallWindowSpec? _spec;

  /// 已经为哪一通电话算过 ICE 了（键：对端+语音还是视频+谁发起）
  String? _plannedFor;

  /// 通话窗现在应不应该开着（挂断时据此让它自己关）
  bool _windowOpen = false;

  @override
  void initState() {
    super.initState();
    _attachWindowPath();
    _attach(ref.read(callControllerProvider));
  }

  @override
  Widget build(BuildContext context) {
    // 登录 / 登出会换掉控制器实例（`callControllerProvider` 盯 user_id）
    ref.listen<CallController>(
      callControllerProvider,
      (previous, next) => _attach(next),
    );
    return widget.child;
  }

  /// 桌面：把两条线挂上（媒体代理只会在这条路上存在）。
  void _attachWindowPath() {
    final engine = ref.read(callMediaEngineProvider);
    if (engine is! CallWindowMediaEngine) return;
    _proxy = engine;
    // 那颗窗被关掉（✕）时由代理报上来（它才知道）：媒体收不回来，该收尾
    engine.onWindowLost = _onWindowLost;
    _transport = ref.read(callWindowTransportProvider);
    final listener = CallWindowListener(
      CallWindowSink(onEvent: _onWindowEvent, onAction: _onWindowAction),
    );
    _listener = listener;
    unawaited(_attachListener(listener));
  }

  Future<void> _attachListener(CallWindowListener listener) async {
    try {
      await listener.attach();
    } on Object catch (error) {
      // 这条线挂不上：通话还是在主窗口里跑（媒体那份代理自己会退回本引擎）
      debugPrint('[通话窗口] 接窗口那条线失败：$error');
    }
  }

  /// 窗口说的话：媒体事件（给代理）+「我上线了，要一份状态」。
  void _onWindowEvent(String event, Map<String, dynamic> data) {
    if (event == callEventReady) {
      // 媒体已经退回主窗口里的引擎（这扇窗是具空壳，多半刚刚被我们收掉、
      // 而那条 `bye` 没送到）：绝不能再 `plan` 一次 —— 那会为它开第二扇窗。
      if (_proxy?.degraded ?? false) return;
      final spec = _spec;
      if (spec != null) _transport?.plan(spec);
      _pushState();
      return;
    }
    _proxy?.handleEvent(event, data);
  }

  /// 那颗通话窗**被关掉了**（✕）：这一通收尾（挂断）。
  ///
  /// 为什么不退回主窗口那张页：媒体（本机轨道 + `PeerConnection`）全在那颗已经
  /// 销毁的引擎里，退回主窗新建一份只会画出一张没声音没画面、连「挂断」都点不到
  /// 的空壳页 —— 电话其实已经断了。微信 PC 上关掉通话窗也是挂断。
  ///
  /// ⚠️ 与「窗口从来没起来过」要分清：那时媒体还没建，退回主窗口里的引擎是
  /// **真的能打**（`CallWindowMediaEngine` 里那条兜底，见 [CallWindowLost]）。
  void _onWindowLost() {
    if (!_windowOpen) return; // 幂等：已经收过尾了
    _windowOpen = false;
    _spec = null;
    _plannedFor = null;
    debugPrint('[通话窗口] 通话窗被关掉了，按挂断收尾');
    unawaited(_controller?.hangup() ?? Future<void>.value());
  }

  /// 窗口里点的那一下 → 控制器（接听/挂断/静音/摄像头/大小窗互换都只有它能做）。
  ///
  /// [data] 是这一下的附件：桌面版「共享屏幕」会把选中的那个源（整个屏幕 /
  /// 某个窗口）放在 `sourceId` 里带上来。
  void _onWindowAction(String action, Map<String, dynamic> data) {
    final controller = _controller;
    if (controller == null) return;
    switch (action) {
      case 'accept':
        unawaited(controller.accept());
      case 'hangup':
        unawaited(controller.hangup());
      case 'screenShare':
        // 共享哪一块屏幕、以及要不要连电脑声音一起发，都是通话窗那边选的
        // （它那颗引擎才看得到源列表与声音设备）
        unawaited(
          controller.toggleScreenShare(
            sourceId: data['sourceId'] as String?,
            withAudio: data['withAudio'] == true,
          ),
        );
      case 'mic':
        unawaited(controller.toggleMicrophone());
      case 'camera':
        unawaited(controller.toggleCamera());
      case 'layout':
        controller.toggleLayout();
      case 'diagnostics':
        // 诊断面板要 `controller.diagnostics` 与一个 overlay —— 两样都只存在
        // 主窗口里（窗口那颗引擎上没有通话状态机），所以用主窗口路由的根
        // Navigator 把同一张面板弹出来（与手机版/兜底页同一个入口函数）。
        final context = ref
            .read(appRouterProvider)
            .routerDelegate
            .navigatorKey
            .currentContext;
        if (context == null) {
          debugPrint('[通话窗口] 要诊断面板，但主窗口还没有可用的 Navigator');
          return;
        }
        unawaited(showCallDiagnosticsSheet(context, controller.diagnostics));
      default:
        debugPrint('[通话窗口] 不认识的动作：$action');
    }
  }

  void _attach(CallController controller) {
    if (identical(controller, _controller)) return;
    _controller?.view.removeListener(_sync);
    _controller = controller;
    // 换了控制器 = 换了登录态：上一通电话的目标作废
    _spec = null;
    _plannedFor = null;
    // 上一通那扇窗也得收掉：登录态一变那扇窗里的电话已经作废了（它那颗引擎
    // 还挂着自己的媒体），留着就是一块显示了上一通电话的僵尸窗。
    if (_windowOpen) {
      _windowOpen = false;
      unawaited(_transport?.closeWindow() ?? Future<void>.value());
    }
    controller.view.addListener(_sync);
    // 换了控制器说明登录态变了，上一通电话早就该结束了。
    //
    // ⚠️ 但不能只把标记清零就完事：**通话页是旧控制器推上去的**，新控制器根本没
    // 开过页，于是它永远不会去 pop —— 页面上那颗「接听/挂断」属于一个已经放掉的
    // 控制器（点了毫无反应），界面就这么卡在那儿。真机上 2026-09-20 遇到过。
    // 所以这里要顺手把旧页收掉。
    if (_open) {
      _open = false;
      final router = ref.read(appRouterProvider);
      if (router.canPop()) router.pop();
    }
  }

  /// 会话状态一变就同步通话页（老端的 `navigateTo` / `navigateBack`）
  void _sync() {
    final controller = _controller;
    if (controller == null || !mounted) return;
    final state = controller.view.value;
    final session = state.session;
    final active = state.isActive;
    final router = ref.read(appRouterProvider);

    if (active) {
      _planIfNeeded(session);
      _windowOpen = true;
      _pushState();
      // 桌面：界面在独立通话窗里（媒体代理退回了本地引擎时才用主窗口这张页）
      if (_proxy != null && !(_proxy!.degraded)) {
        return;
      }
    } else if (_windowOpen) {
      // 挂断：让通话窗自己关掉（关窗只有窗口自己做得干净）
      _windowOpen = false;
      _spec = null;
      _plannedFor = null;
      unawaited(_transport?.closeWindow() ?? Future<void>.value());
    }

    if (active && !_open) {
      _open = true;
      router.push(AppRoutes.call);
      return;
    }
    if (!active && _open) {
      _open = false;
      if (router.canPop()) router.pop();
    }
  }

  /// 把这通电话的目标算出来交给通话窗。
  ///
  /// ICE 列表要**主窗口**给：站点那栏来自会话配置（子引擎里没有这份会话），
  /// 服务端签发的 TURN 凭据也是这边拿的。凭据那条路要等一次网络（通常已经缓存），
  /// 所以先等它、再 `plan` —— 窗口早开几百毫秒没有意义，**少一档 TURN 可能要命**。
  void _planIfNeeded(CallSession session) {
    final transport = _transport;
    if (transport == null) return;
    final key =
        '${session.peerId}|${session.isVideo}|${session.isCaller}|'
        '${session.type}';
    if (_plannedFor == key) return;
    _plannedFor = key;
    unawaited(_plan(session, key));
  }

  Future<void> _plan(CallSession session, String key) async {
    final transport = _transport;
    if (transport == null) return;
    var iceServers = const <Map<String, dynamic>>[];
    try {
      iceServers = CallMediaConfig.iceServers(
        ref.read(sessionStoreProvider).config.chatInfo,
      );
      final extra = await ref.read(turnCredentialServiceProvider).iceServers();
      if (extra.isNotEmpty) {
        iceServers = <Map<String, dynamic>>[...iceServers, ...extra];
      }
    } on Object catch (error) {
      // 算不出来也得能打电话：这扇窗退回「只有 STUN」那条路（与引擎里同一套兜底）
      debugPrint('[通话窗口] 算 ICE 列表失败（先用只有 STUN 的那份）：$error');
    }
    if (!mounted || _plannedFor != key) return; // 这中间挂了 / 换了电话
    final spec = CallWindowSpec(
      peerId: session.peerId,
      peerName: session.peerName,
      peerAvatar: session.peerAvatar,
      video: session.isVideo,
      isCaller: session.isCaller,
      iceServers: iceServers,
    );
    _spec = spec;
    transport.plan(spec);
  }

  void _pushState() {
    final controller = _controller;
    final transport = _transport;
    if (controller == null || transport == null || !_windowOpen) return;
    unawaited(transport.pushState(callStatePayload(controller.view.value)));
  }

  @override
  void dispose() {
    _controller?.view.removeListener(_sync);
    unawaited(_listener?.detach() ?? Future<void>.value());
    super.dispose();
  }
}
