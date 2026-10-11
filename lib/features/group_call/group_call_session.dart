import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/call/call_controller.dart';
import '../../domain/group_call/group_call_hub.dart';
import '../../domain/group_call/group_call_presence.dart';
import '../../domain/group_call/sfu_room.dart';
import 'group_call_controller.dart';
import 'group_call_sync.dart' show groupCallPresenceProvider;

/// 一场**还在进行**的群通话（S6.17）：把「通话」与「通话页」拆开。
///
/// 为什么要有它：S6.11 那版把房间对象挂在通话页上 —— 页面一关就 `dispose()`，
/// 于是「退出页面 = 挂断」。微信不是这样：退出来还能听、还能说，群里那条
/// 「正在通话 · 回到通话」留着，通话一直开着，直到有人点挂断（或人都走光了）。
///
/// 所以房间、控制器、保活、对账登记从页面搬到这里，**由它常驻**：
///
/// * 通话页进来只是「看着它」（[GroupCallSessionHost.openPage] / `closePage`），
///   关掉页面不再收尾 —— 声音照旧从系统放，对账靠 [hub] 那条 `sfuRoom` 推送与
///   20 秒一次的心跳、以及 5 秒一次的**状态回查**（都不依赖界面。回查是界面
///   不迟钝的硬保证：推送丢了、服务端漏了通知，最多 5 秒自己纠回来）；
/// * 「挂断」只剩两条路：通话页那颗红按钮，以及小窗上的挂断
///   （[GroupCallSessionHost.end]）；
/// * **一次只有一通**：换个群再进，会先把这一通挂干净（一条链路一只麦克风）。
class GroupCallSession extends ChangeNotifier {
  GroupCallSession({
    required this.conversationId,
    required this.name,
    required this.controller,
    required this.hub,
    required this.presence,
  }) {
    controller.view.addListener(_sync);
  }

  /// 群会话 id（`group-100`）：与路由参数、聊天页那条提示同一把钥匙
  final String conversationId;

  /// 群名（挂断记录、保活通知、小窗上都用它）
  final String name;

  /// 这一通话的控制器（房间状态机 + 名单 + 本机开关，见 `GroupCallController`）
  final GroupCallController controller;

  /// 「正在进行的那个房间」登记处：留在这里就不必依赖界面（页面关着也能对账）
  final GroupCallHub hub;

  /// 「谁在开群语音」那本账：我进来了就得把这一通的邀请收掉
  final GroupCallPresenceTracker presence;

  /// 进房间成功的时刻（小窗与通话页的计时都从它算，**不是**页面进出的时刻 ——
  /// 页面重进一次时间就该接着往下走）
  DateTime? joinedAt;

  bool _ending = false;

  /// 界面要看的全部状态（房间状态机 + 名单 + 本机开关）
  GroupCallView get view => controller.view.value;

  /// 进不去（重试/返回那两块界面靠它）
  bool get failed => view.phase == SfuRoomPhase.failed;

  /// 通话中的人（小窗上那个「N 人」用它）
  int get memberCount => view.inCallMembers.length;

  /// 这一通打了多久（还没进房间就是 0）
  Duration get elapsed {
    final start = joinedAt;
    if (start == null) return Duration.zero;
    final value = DateTime.now().difference(start);
    return value.isNegative ? Duration.zero : value;
  }

  /// 收尾：关两条会话、停保活、必要时往群里落记录（幂等）。
  ///
  /// 从前的收尾是「页面 `dispose` → 控制器 `dispose`」；现在只有它，
  /// 页面关掉**不**走到这里。
  Future<void> end() async {
    if (_ending) return;
    _ending = true;
    controller.view.removeListener(_sync);
    // 先跟登记处脱钩：这一通已经不算「我人在里面」，对账不该再理它
    hub.detach(controller.room);
    try {
      await controller.hangup();
    } on Object catch (error) {
      debugPrint('[群通话] 挂断失败（继续收尾）：$error');
    }
    await controller.dispose();
    dispose();
  }

  void _sync() {
    if (_ending) return;
    // 进房间成功那一刻开始计时（要等的那一串在 `start()` 里，界面只认这个时刻）
    if (joinedAt == null && view.phase == SfuRoomPhase.joined) {
      joinedAt = DateTime.now();
    }
    notifyListeners();
  }
}

/// 「现在这一通群通话」的登记处（S6.17）。
///
/// 全进程一份，喂给三处界面：通话页（就在里头的）、群聊页顶上那条（在我这个群的，
/// 显示「回到通话」）、以及**小窗**（页面关掉之后还看得见的那颗药丸）。
///
/// 几条刻意的取舍，各自都有用例钉住：
///
/// * **同一个群再进来，还是那一通**：不重新加入（重开会多建两条会话，还会把
///   别人那边跟着重协商一次），只是「页面又打开了」；
/// * **换一个群进来 = 先把上一通挂干净**：一次只能有一通（一条链路一只麦克风），
///   与 1:1 那边同一个道理；
/// * **页面关掉不等于结束**：只有 [end]（挂断钮 / 小窗上的挂断 / 登出）才收尾；
/// * **进不去又没人看着就收掉**：`failed` 且页面不在时留着它没有任何意义，
///   反而会变成一颗看不见的僵尸（小窗不显示、也没法挂断）。
class GroupCallSessionHost extends ChangeNotifier {
  GroupCallSessionHost({
    required this._factory,
    required this._hub,
    required this._presence,
    // 公开参数对上私有字段（依赖注入的老写法，与 `AndroidCallPip` 那处一致）：
    // 别人不需要拿到这两样，单测却要能塞替身
    Listenable? oneToOne,
    bool Function()? oneToOneActive,
  }) : _oneToOne = oneToOne, // ignore: prefer_initializing_formals
       // ignore: prefer_initializing_formals
       _oneToOneActive = oneToOneActive {
    _oneToOne?.addListener(_onOneToOneChanged);
  }

  final GroupCallControllerFactory _factory;
  final GroupCallHub _hub;
  final GroupCallPresenceTracker _presence;

  /// 1:1 通话那台控制器的 `view`（不传就是不联动：单测里不需要造一整条媒体链）
  final Listenable? _oneToOne;

  /// 「1:1 现在算不算在通话中」
  final bool Function()? _oneToOneActive;

  GroupCallSession? _active;
  bool _pageOpen = false;
  bool _notifyScheduled = false;

  /// 当前这一通（没有就是 null）
  GroupCallSession? get active => _active;

  /// 通话页正开着吗（小窗据此让位 —— 页面上已经有一样的四颗钮了）
  bool get pageOpen => _pageOpen;

  /// 这个群的通话（不是它开的就返回 null）
  GroupCallSession? sessionFor(String conversationId) =>
      _active?.conversationId == conversationId ? _active : null;

  /// 进这个群的群通话页：已经在通话里就把那一份还回来（**不重新加入**）
  Future<GroupCallSession> openPage({
    required String conversationId,
    required String name,
  }) async {
    if (!_pageOpen) {
      _pageOpen = true;
      _notifySoon();
    }
    return join(conversationId: conversationId, name: name);
  }

  /// 通话页关掉了（**不是**挂断）：通话继续，小窗与群聊页那条提示接手。
  void closePage() {
    if (!_pageOpen) return;
    _pageOpen = false;
    _notifySoon();
    _endIfNobodyWatching();
  }

  /// 加入（或复用）这个群的通话
  Future<GroupCallSession> join({
    required String conversationId,
    required String name,
  }) async {
    final existing = sessionFor(conversationId);
    if (existing != null) return existing;
    // 换了一个群：先把上一通挂干净（一次只有一通）
    if (_active != null) await end();

    final session = GroupCallSession(
      conversationId: conversationId,
      name: name,
      controller: _factory(conversationId: conversationId, name: name),
      hub: _hub,
      presence: _presence,
    )..addListener(_onSessionChanged);
    _active = session;
    _notifySoon();
    // 进来这一串要花几秒（采媒体、建会话、订阅全屋）：界面不阻塞，
    // 状态从会话自己的 `view` 里长出来（「正在加入」→ 头像墙 / 「进不去」）
    unawaited(session.controller.start());
    return session;
  }

  /// 挂断（通话页那颗红钮、小窗上的挂断、登出都走它）
  Future<void> end() async {
    final session = _active;
    _active = null;
    // 这一通没了，「页面还开着这一通」也就无从谈起（页面那边会自己 pop）。
    // 不清的话：登出时页面上正好开着通话页，这个 ``true`` 会一直留着 ——
    // 下一次进通话页时「小窗」就不画了，也再也收不掉一个进不去的会话。
    _pageOpen = false;
    if (session == null) return;
    session.removeListener(_onSessionChanged);
    _notifySoon();
    await session.end();
  }

  /// 登出：换账号接着用时不该还挂着上一个账号的群（与在线标记那本账同一处）
  Future<void> reset() => end();

  @override
  void dispose() {
    _disposed = true;
    _oneToOne?.removeListener(_onOneToOneChanged);
    _active?.removeListener(_onSessionChanged);
    _active = null;
    super.dispose();
  }

  /// 1:1 电话**接通那一刻**，这一通让路（挂断收尾）。
  ///
  /// 为什么必须让，而不是「两通一起开着」：一条链路只有一只麦克风、一块屏幕，
  /// 而且**前台服务只有一份** —— 1:1 挂断时那句 `stop()` 会把群通话那条常驻通知
  /// 一起停掉，群语音从此切到后台就被冻结（声音断、对账停）；反过来群通话那条
  /// 通知也会被 1:1 的文案顶掉。
  ///
  /// 只在「1:1 真的活跃」时才动：来电响铃那一刻不动（那时只是响铃，还没接）。
  void _onOneToOneChanged() {
    final active = _oneToOneActive;
    if (active == null || _active == null || !active()) return;
    unawaited(end());
  }

  bool _disposed = false;

  void _onSessionChanged() {
    _endIfNobodyWatching();
    _notifySoon();
  }

  /// 通知界面，但**推到当前这一帧之后**。
  ///
  /// 为什么不是直接 `notifyListeners()`：这个登记处会被两处**在构建/拆除过程中**
  /// 碰到 —— 通话页在 `initState` 里 `openPage`（进入房间）、在 `dispose` 里
  /// `closePage`（退出页面），那两刻正是 widget 树锁定的时候，当场通知监听者
  /// 会撞上 `setState() called during build` / 「widget tree was locked」
  /// （`group_call_page_test` 两个用例都抓到了）。
  /// 一个微任务就落在这一帧的构建与布局之后，界面看不到任何延迟；
  /// 顺带还能把「同一帧里变了好几次」合成一次通知。
  void _notifySoon() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      if (_disposed) return;
      notifyListeners();
    });
  }

  /// 进不去、页面又不在：别留一颗看不见的僵尸（小窗不显示，也没地方挂断）
  void _endIfNobodyWatching() {
    final session = _active;
    if (session == null || _pageOpen || !session.failed) return;
    unawaited(end());
  }
}

/// 全进程一份的群通话登记处（S6.17）
final groupCallSessionProvider = Provider<GroupCallSessionHost>(
  (ref) => GroupCallSessionHost(
    factory: ref.watch(groupCallControllerFactoryProvider),
    hub: ref.watch(groupCallHubProvider),
    presence: ref.watch(groupCallPresenceProvider),
    // 1:1 电话优先（S6.20）：那条控制器的 `view` 一变"通话中"，这一通就让路
    // （每次现读，登录/登出换过控制器也一样拿得到当前那份）
    oneToOne: ref.read(callControllerProvider).view,
    oneToOneActive: () => ref.read(callControllerProvider).view.value.isActive,
  ),
);

/// 「现在有没有一场群通话在跑」—— 与 `callBusyProvider` 对称的那一份（S6.20）。
///
/// 1:1 通话的入口要过这一道：正在群语音里再拨一通，两套通话都要麦克风，
/// 而前台服务只有一份（先拨的那一通的常驻通知会被顶掉、并在一方挂断时被一起
/// 停掉）。所以这时只提示一声，不把人推进第二通电话。
///
/// 做成 provider 而不是就地判空：界面 `ref.watch` 能跟着变，测试里也能直接换掉
/// （造一个"正在群语音"的真会话要一整条 SFU 假件，见 `group_call_page_test`）。
class GroupCallBusyNotifier extends Notifier<bool> {
  @override
  bool build() {
    final host = ref.watch(groupCallSessionProvider);
    void sync() => state = host.active != null;
    host.addListener(sync);
    ref.onDispose(() => host.removeListener(sync));
    return host.active != null;
  }
}

final groupCallBusyProvider = NotifierProvider<GroupCallBusyNotifier, bool>(
  GroupCallBusyNotifier.new,
);
