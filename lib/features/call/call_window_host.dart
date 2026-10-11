/// 主窗口这一侧：把通话开到（或唤回）独立窗口里（2026-10-04）。
///
/// 用户原话：「请将通话做到新开一个独立窗口」。这里管三件事：
///
/// * **开/复用那颗窗**：一个 kind 一颗（与文章/网页那几颗同一个规矩），
///   窗口活着就不盖第二颗（与 `desktop_window_service.dart` 里那套办法一样，
///   但通话窗的生命周期短 —— 一通电话一颗，挂断就关，所以不用扫 `getAll()`，
///   手里那个句柄 + 一次 `ping` 就够）；
/// * **把「这通电话是谁」记下来**：媒体代理（`CallWindowMediaEngine`）手里的
///   `open()` 只知道自己要不要视频，对端信息在主窗口的会话里 —— 所以由
///   `CallHost` 在会话起来时先 `plan()` 一下；
/// * **两条线的收发**：状态/媒体指令出去，事件/界面动作回来。
library;

import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/desktop_shell.dart';
import '../../data/media/call_media_engine.dart';
import 'call_window_bridge.dart';
import '../desktop_window/window_args.dart';

/// 通话窗**回了话**，但那条媒体指令没做成（不是「叫不应」）。
///
/// 单独一个类型就是为了跟「叫不应」严格分开 —— 见 [isCallWindowUnreachable]。
/// 抛它的地方只有 [MultiWindowCallWindowTransport.invokeMedia]。
class CallWindowCommandFailed implements Exception {
  const CallWindowCommandFailed(this.method, this.cause);

  /// 没做成的那条指令
  final String method;

  /// 通话窗那颗引擎报上来的错（跨通道之后是字符串化的）
  final Object cause;

  @override
  String toString() => 'CallWindowCommandFailed($method: $cause)';
}

/// 那颗窗**起来过、又被关掉了**（用户按了 ✕）。
///
/// 为什么非要与「还没起来」分开（两者在通道层长得一模一样）：
///
/// * **还没起来过**（冷启动那几百毫秒）：媒体**还没**在那颗引擎里建起来，退回
///   主窗口里的引擎是**真的能打**（S12.26 就有的兜底）；
/// * **起来过又没了**：这一通的本机轨道 + `PeerConnection` 全在那颗已经销毁的引擎
///   里，**收不回来**。这时退回主窗只会画出一张「还在通话中」的空壳页 ——
///   没声音、没画面、而且用户连「挂断」都点不到。正确动作是**结束这一通**
///   （微信 PC 上关掉通话窗也是挂断）。
///
/// 抛它的地方只有 [MultiWindowCallWindowTransport.invokeMedia]（当 `alive` 探到
/// 那颗窗已经不在时），收尾由媒体代理的 `onWindowLost` 接（见
/// `call_window_media_engine.dart`）。
class CallWindowLost implements Exception {
  const CallWindowLost(this.method);

  /// 探到它没了的那条指令
  final String method;

  @override
  String toString() => 'CallWindowLost($method)';
}

/// 这条媒体通道**叫不应**了吗？（窗口还没起来 / 已经关了）
///
/// 为什么非要分开：通道层这两种情况长得几乎一样（都是一次 `invokeMethod` 抛
/// 异常），但处理方式完全相反 ——
///
/// * **叫不应**：正确的动作是**重试**（子引擎冷启动那几百毫秒里一律
///   `CHANNEL_UNREGISTERED`，见 [MultiWindowCallWindowTransport.invokeMedia]），
///   重试到底还不行就退回主窗口里的引擎；
/// * **窗口回了话**（它那颗引擎跑起来了，只是这一条指令失败，比如桌面上
///   「切换扬声器」没这条路由）：那就是 `WindowChannelException('error', …)`
///   这种「业务失败」。**重试一万次也是同一个错** —— 2026-10-05 真机上它白等了
///   15 秒，然后把整通电话判成「窗口没应答」退回主窗口，通话窗就变成一具空壳。
bool isCallWindowUnreachable(Object error) {
  // 窗口回了话：明确不是「叫不应」
  if (error is CallWindowCommandFailed) return false;
  // 窗起来过又被关掉（✕）：当然叫不应（只是它的收尾比普通「叫不应」重一步，
  // 见 [CallWindowLost]）
  if (error is CallWindowLost) return true;
  // 等回话超时也算「没答上来」（子引擎正忙 / 刚起）—— 值得再试
  if (error is TimeoutException) return true;
  if (error is MissingPluginException) return true;
  // `CallMediaException` 在媒体代理那一侧只有一个来源：`invokeMedia` 转完
  // 「一直叫不应」（以及 `_ensureOpen` 找不到对端）之后包的。所以它意味着
  // 「这扇窗用不了」，该退回主窗口里的引擎。
  if (error is CallMediaException) return true;
  final code = switch (error) {
    WindowChannelException(:final code) => code,
    PlatformException(:final code) => code,
    _ => null,
  };
  return code == 'CHANNEL_UNREGISTERED' ||
      code == 'CHANNEL_NOT_FOUND' ||
      code == 'NO_HANDLER';
}

/// 这通电话的对端信息（主窗口知道，通话窗要用来起标题/画头像）。
class CallWindowSpec {
  const CallWindowSpec({
    required this.peerId,
    required this.peerName,
    this.peerAvatar = '',
    required this.video,
    required this.isCaller,
    this.iceServers = const <Map<String, dynamic>>[],
  });

  final String peerId;
  final String peerName;
  final String peerAvatar;
  final bool video;
  final bool isCaller;

  /// 站点那栏 + 服务端签发的 TURN 凭据（子引擎里没有会话配置，自己算不出来）
  final List<Map<String, dynamic>> iceServers;

  DesktopWindowArgs toArgs() => DesktopWindowArgs.call(
    peerId: peerId,
    peerName: peerName,
    peerAvatar: peerAvatar,
    video: video,
    isCaller: isCaller,
    iceServers: iceServers,
  );
}

/// 主窗口 ↔ 通话窗那两条线的「句柄」。
///
/// 抽成接口是为了**能在组件测试里替掉**：真开一颗引擎要几百毫秒、还要原生窗口，
/// 而「状态推没推过去、动作有没有接到控制器上、挂断有没有让窗自己关掉」这几件事
/// 必须能在单测里钉住（见 `test/features/call_window_test.dart`）。
abstract class CallWindowTransport {
  /// 记下这通电话的对端（不立刻开窗：真正要开的那一刻是媒体那第一枪）
  void plan(CallWindowSpec spec);

  /// 把这通电话的对端信息交给通话窗（会话状态一变就调）
  Future<void> pushState(Map<String, dynamic> state);

  /// 发一条媒体指令并等回话（`CallMediaEngine` 上那些方法，见 [callWindowMedia]）
  Future<Object?> invokeMedia(String method, [Map<String, dynamic>? args]);

  /// 通话结束了：让通话窗自己关掉（关窗只有窗口自己做得干净）
  Future<void> closeWindow();

  /// 那颗窗现在还真活着（✕ 关掉之后句柄还在，要 ping 一次才知道）
  Future<bool> alive();
}

final callWindowTransportProvider = Provider<CallWindowTransport>(
  (ref) => MultiWindowCallWindowTransport(),
);

/// 「通话是不是走独立窗口」的总开关（媒体引擎那份 provider 看它）。
///
/// 为什么不用 `desktopFeaturesProvider`：那一条**桌面版式的用例会 override 成开**
/// （它们验的就是桌面横屏三栏、右键菜单那些），而通话窗是要真开一颗原生引擎的
/// —— 那些用例里既没有原生窗口，也会留下一堆 pending 的轮询计时器
/// （真实跑过：几十条桌面用例播报「A Timer is still pending」）。
///
/// 所以这条默认值取 `desktopFeaturesEnabled`（桌面且**不是** `flutter test`），
/// 与「桌面版式」解耦：想验通话窗的用例自己 override。
final callWindowEnabledProvider = Provider<bool>(
  (ref) => desktopFeaturesEnabled,
);

/// 真去跟 `desktop_multi_window` 打交道的那一份。
class MultiWindowCallWindowTransport implements CallWindowTransport {
  /// [retryBudget] 是「等子窗把那条线挂上」的总预算（默认 15 秒，见
  /// [invokeMedia]）；测试里调小 —— 组件测试的时钟是假时钟，真等 15 秒没意义。
  MultiWindowCallWindowTransport({
    this.retryBudget = const Duration(seconds: 15),
  });

  final Duration retryBudget;

  static const WindowMethodChannel _channel = WindowMethodChannel(
    callWindowChannelName,
    mode: ChannelMode.unidirectional,
  );

  /// 「这通电话是谁」——`plan()` 记下来，开窗时编进窗口参数
  CallWindowSpec? _spec;

  /// 这颗窗口的句柄（关了之后置空）
  WindowController? _window;

  /// 正在开的那一次（媒体第一枪与状态推送可能同时要它）
  Future<void>? _opening;

  /// 这颗窗**答过话**没有（答过一次就说明它真的起来过）。
  ///
  /// 为什么需要这个标记："叫不应"这件事有两种原因，长得一模一样，处理方式却相反 ——
  ///
  /// * **冷启动**（还没答过话）：子引擎起来要几百毫秒，这期间一律
  ///   `CHANNEL_UNREGISTERED`，**必须重试**；
  /// * **用户按 ✕ 把窗关了**（答过话之后又叫不应）：重试一万次也是同一个错，
  ///   而重试到底要花满 15 秒 —— 这 15 秒里用户既没有画面也没有声音（媒体全卡在
  ///   这条指令上）。2026-10-05 复查时确认的。
  ///
  /// `_create()`（新的一颗窗）会把它清回 false；`closeWindow()` **刻意不清** ——
  /// 那通电话已经服务过了，之后的残余指令该立刻失败（见 [_ensureOpen]）。
  bool _everAnswered = false;

  @override
  void plan(CallWindowSpec spec) {
    _spec = spec;
    // 提前开：窗口冷启动要几百毫秒，等媒体那一枪再开就晚了
    // （`open()` 里会 await 这次开窗，用户看到的只是「点了之后稍微等一下」）。
    unawaited(
      _ensureOpen().catchError((Object error) {
        debugPrint('[通话窗口] 提前开窗失败（第一枪媒体指令会再试一次）：$error');
      }),
    );
  }

  @override
  Future<void> pushState(Map<String, dynamic> state) async {
    try {
      await _channel
          .invokeMethod<Object?>(callWindowState, state)
          .timeout(const Duration(milliseconds: 1500));
    } on Object catch (error) {
      // 状态推送是「尽力而为」：窗口还没起来 / 刚关了都不该影响通话本身，
      // 窗口那条线挂上来时会自己来要一次（`callEventReady`）。
      debugPrint('[通话窗口] 推状态没推过去（忽略）：$error');
    }
  }

  @override
  Future<Object?> invokeMedia(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    await _ensureOpen();
    Object? lastError;
    // ⚠️ 子引擎是**冷启动**：窗口句柄一拿到手，那条线往往还没挂上（它在
    // `_setup()` 里注册），这段空档里调它一律 `CHANNEL_UNREGISTERED`。
    //
    // 等多久：真机实测（debug 版）`open` 那一枪打出去时子引擎还在起，3.6 秒
    // 的预算不够（自检里当场报了 CHANNEL_UNREGISTERED，日志里连子窗的
    // 「窗口就绪」都还没印）。release 下快得多，但这条预算得按住**最慢**那一档：
    // 子窗自己起不来时也别把用户卡在这儿 —— 过不去就退回本引擎（那份代理自己
    // 会退，通话照样打），所以给了 15 秒封顶。
    //
    // 另外：这里**绝不重开窗**（重开会留下一颗没人管的引擎）。
    final deadline = DateTime.now().add(retryBudget);
    // 那次「起来过又叫不应」：那颗窗被用户关掉了（见 [CallWindowLost]）
    var lost = false;
    while (true) {
      try {
        final result = await _channel
            .invokeMethod<Object?>(callWindowMedia, <String, dynamic>{
              'method': method,
              'args': args ?? const <String, dynamic>{},
            })
            // 取摄像头（1~3 秒）/ 等对方描述都可能有几秒，给足
            .timeout(const Duration(seconds: 10));
        // 这条窗答了话：它确实起来过（后面再叫不应就不是冷启动了）
        _everAnswered = true;
        return result;
      } on Object catch (error) {
        lastError = error;
        // 窗口**回了话**（只是这条指令失败）：重试没有意义，把原样抛出去，
        // 别让调用方白等这 15 秒（见 [isCallWindowUnreachable]）
        if (!isCallWindowUnreachable(error)) break;
        // 起来过、现在却叫不应 = 用户把窗关掉了（见 [_everAnswered]）：
        // 先确认一次它还在不在 —— 真没了就立刻认输，把 15 秒省下来
        // （[alive] 顺手把那个已经死掉的句柄清掉）。窗还活着就别乱认输，
        // 老老实实重试到预算用完。
        // ⚠️ **超时不算**：子引擎那一刻正忙（取摄像头/设描述都可能卡几秒）也会
        // 让上面那条 `.timeout` 报超时，而窗口其实好好的 —— 那种情况错判成
        // 「窗没了」会把一通好电话挂掉。只有「通道明说这条线不在」才算。
        if (_everAnswered && error is! TimeoutException && !await alive()) {
          lost = true;
          break;
        }
        if (DateTime.now().isAfter(deadline)) break;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    if (lost) {
      debugPrint('[通话窗口] 媒体指令 $method：那颗窗已经被关掉了（✕）');
      throw CallWindowLost(method);
    }
    final error = lastError;
    if (!isCallWindowUnreachable(error)) {
      // 窗口回了话（业务失败）：包成 [CallWindowCommandFailed] 抛出去 ——
      // 让媒体代理分得清「这条指令没做成」与「这扇窗用不了」，
      // 不至于把整通电话退回主窗口（原因见 [isCallWindowUnreachable]）
      throw CallWindowCommandFailed(method, error);
    }
    debugPrint('[通话窗口] 媒体指令 $method 一直没送到：$error');
    throw CallMediaException('通话窗口没有应答（$method）', error);
  }

  @override
  Future<void> closeWindow() async {
    final window = _window;
    _window = null;
    _spec = null;
    _opening = null;
    // ⚠️ `_everAnswered` 刻意**不清**：这通电话已经服务过了，之后再有残余指令
    // （统计采样的尾巴那类）落到这里，该**立刻**失败而不是白等一轮预算
    // （见 [_ensureOpen]）。下一通电话的 `_create()` 会把它清回 false。
    if (window == null) return;
    try {
      await _channel
          .invokeMethod<Object?>(callWindowBye, <String, dynamic>{})
          .timeout(const Duration(milliseconds: 1200));
    } on Object catch (error) {
      // 窗口自己关不掉也没关系：下次开窗是**新的一颗**（旧的那颗引擎已经
      // 随窗口销毁了），不会顶着一扇僵尸窗
      debugPrint('[通话窗口] 说再见没送到（忽略）：$error');
    }
  }

  /// 那颗窗现在还真活着（✕ 关掉之后句柄还在，要 ping 一次才知道）。
  ///
  /// 2026-10-05 起它有了真正的消费者：`invokeMedia` 在「起来过又叫不应」时
  /// 用它区分「窗被关了」与「一次抖动」（见 [_everAnswered]）。
  @override
  Future<bool> alive() async {
    if (_window == null) return false;
    try {
      await _channel
          .invokeMethod<Object?>(callWindowPing)
          .timeout(const Duration(milliseconds: 800));
      return true;
    } on Object catch (error) {
      debugPrint('[通话窗口] 那颗窗叫不出来了，当作已经关掉：$error');
      _window = null;
      return false;
    }
  }

  /// 开（或确认还开着）那颗窗；窗口参数就是 `plan()` 记下的那份。
  Future<void> _ensureOpen() async {
    final spec = _spec;
    if (spec == null) {
      // 这扇窗**服务过**一通电话，现在却又没有目标：只可能是上一通已经挂断
      // （`closeWindow()` 把目标清掉了），而这中间漏过来一条残余指令（统计采样
      // 的尾巴那类）。那种情况等一下纯属白等。
      if (_everAnswered) {
        throw const CallMediaException('这通电话已经结束了（窗口目标已清空）');
      }
      // 正常的顺序是「状态先到（会话里已经有对端）、媒体后到」，但真机上
      // 万一反了，就等一等 —— 比直接把这通电话判死强。
      //
      // ⚠️ 等多久**不能拍一个 2 秒**：主窗口那边算这份 ICE 列表（站点那栏 +
      // 服务端签发的 TURN 凭据，见 `call_host.dart::_plan`）最长要 4 秒
      // （凭据请求自己的超时，见 `turn_credentials.dart`），而**这通电话的第一枪**
      // 媒体指令（`open`）就落在这段窗口里 —— 2 秒等不到目标就把整通电话判成
      // 「窗口来不了」退回主窗（2026-10-05 复查发现的）。这里跟重试预算用同一个
      // 上限：它本来就是「愿意为这扇窗等多久」的总预算。
      final deadline = DateTime.now().add(retryBudget);
      while (_spec == null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (_spec == null) {
        throw const CallMediaException('还没有通话窗口的目标（对端信息没到）');
      }
    }
    // 句柄还在就当作还在（✕ 关掉之后仍然会走到这儿 —— 那时那条线叫不应，
    // 媒体那份代理自己会退回本引擎；下一次通话 `closeWindow()` 会把句柄清掉）
    if (_window != null) return;
    final opening = _opening;
    if (opening != null) {
      await opening;
      return;
    }
    final future = _create();
    _opening = future;
    try {
      await future;
    } finally {
      if (identical(_opening, future)) _opening = null;
    }
  }

  Future<void> _create() async {
    final spec = _spec;
    if (spec == null) {
      throw const CallMediaException('还没有通话窗口的目标（对端信息没到）');
    }
    // 新的一颗窗：它还没答过任何一条话（冷启动那几百毫秒里一律叫不应，
    // 那一段必须肯重试，见 [_everAnswered] / [invokeMedia]）
    _everAnswered = false;
    final window = await WindowController.create(
      WindowConfiguration(
        arguments: spec.toArgs().encode(),
        // 窗口自己那边：设好标题/大小/居中再 show（不然先闪一下 800×600）
        hiddenAtLaunch: true,
      ),
    );
    _window = window;
    debugPrint('[通话窗口] 开了通话窗：${spec.peerName}（视频=${spec.video}）');
    // 窗口参数里已经带了「对端是谁」，状态那一份等它伸手来要（`ready`）——
    // 这中间它用参数自己先画一屏，不会是白的。
  }
}

/// 主窗口收到的那两条线（由 `CallHost` 挂上）。
///
/// 单独抽出来是为了让「窗口说的话 → 谁接」这一层不跟界面绑死：宿主组件只管
/// 把这两个回调接到控制器上。
class CallWindowSink {
  const CallWindowSink({required this.onEvent, required this.onAction});

  /// 媒体事件（本机流/远端流/候选/连通/失败/家底）
  final void Function(String event, Map<String, dynamic> data) onEvent;

  /// 界面上点的：accept / hangup / mic / camera / layout / diagnostics / screenShare。
  ///
  /// 第二个参数是这一下的**附件**（现在只有 `screenShare` 用得上：它在
  /// `sourceId` 里带着「共享哪一块屏幕」）。没有附件的那些就是空 map。
  final void Function(String action, Map<String, dynamic> data) onAction;
}

/// 收话的那一半：注册 `gracelink/call/events`，把窗口说的话分下去。
class CallWindowListener {
  CallWindowListener(this.sink);

  final CallWindowSink sink;

  static const WindowMethodChannel _channel = WindowMethodChannel(
    callWindowEventChannelName,
    mode: ChannelMode.unidirectional,
  );

  Future<void> attach() async {
    await _channel.setMethodCallHandler(_onCall);
  }

  Future<void> detach() async {
    try {
      await _channel.setMethodCallHandler(null);
    } on Object catch (error) {
      debugPrint('[通话窗口] 摘线失败（忽略）：$error');
    }
  }

  Future<Object?> _onCall(MethodCall call) async {
    final data = call.arguments is Map
        ? Map<String, dynamic>.from(call.arguments as Map)
        : <String, dynamic>{};
    switch (call.method) {
      case callWindowEvent:
        final event = (data['event'] as String?) ?? '';
        if (event.isNotEmpty) sink.onEvent(event, data);
        return <String, dynamic>{'ok': true};
      case callWindowAction:
        final action = (data['action'] as String?) ?? '';
        if (action.isNotEmpty) sink.onAction(action, data);
        return <String, dynamic>{'ok': true};
      default:
        throw MissingPluginException('主窗口不认识这个调用：${call.method}');
    }
  }
}
