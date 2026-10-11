// ignore_for_file: prefer_initializing_formals —— 可注入的构造参数与私有字段不同名（单测要替掉它们），
// 上面那条 `dart format` 会把行尾的 `// ignore` 挪到初始化列表上从而失效，所以用文件级忽略
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;

import '../../core/audio/call_tones.dart';
import '../../core/i18n/app_i18n.dart';
import '../../core/platform/app_settings.dart';
import '../../core/platform/call_keep_alive.dart';
import '../../core/platform/call_pip.dart';
import '../../core/platform/call_window.dart';
import '../../core/store/session_store.dart';
import '../../core/ui/notice_bus.dart';
import '../../core/ws/ws_client.dart' show WsStatus;
import '../../core/ws/ws_service.dart';
import '../../data/media/call_media_engine.dart';
import '../../data/repo/call_repository.dart';
import 'call_diagnostics.dart';
import 'call_machine.dart';
import 'call_signal.dart';

/// 弹一句提示（值是 i18n key）。UI 层接 `NoticeBus`，测试里接列表。
typedef CallNotifier = void Function(String messageKey);

/// 弹一句**带按钮**的提示（按钮是「去授权」，值是 i18n key）。
///
/// 专门给「权限被拒」那条用：安卓上第二次拒绝之后系统就不再弹授权框，
/// 提示旁边必须有一颗能直接跳到系统设置的按钮（见 `core/platform/app_settings.dart`）。
typedef CallPermissionNotifier = void Function(String messageKey);

/// 一秒一跳的计时器。
///
/// 老端这个活在 WebView 里（`setInterval`）：拨号 40 秒倒计时一个、通话时长一个。
/// 抽成接口是为了测试能手动推进（组件测试里跑真 `Timer` 会让 `pumpAndSettle` 等到超时）。
///
/// 生产用的是 [TimerCallTicker]（挂在 [callTickerProvider] 上），
/// 测试覆盖那个 provider 换成手动推进的替身。
abstract interface class CallTicker {
  void start(void Function() onTick);

  void stop();
}

class TimerCallTicker implements CallTicker {
  Timer? _timer;

  @override
  void start(void Function() onTick) {
    stop();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => onTick());
  }

  @override
  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

/// 计时器来源。单独做成 provider 是为了让组件测试能换成手动推进的替身
/// （真的 `Timer.periodic` 会让 `pumpAndSettle` 一直等不到静止）。
final callTickerProvider = Provider<CallTicker>((ref) => TimerCallTicker());

/// 通话界面要看的全部状态（S6.3 的页面只 watch 它）。
@immutable
class CallViewState {
  const CallViewState({
    this.session = const CallSession(),
    this.microphoneEnabled = true,
    this.cameraEnabled = true,
    this.speakerEnabled = true,
    this.hasLocalStream = false,
    this.hasRemoteStream = false,
    this.remoteBig = false,
    this.inPip = false,
    this.canShareScreen = false,
    this.screenSharing = false,
  });

  final CallSession session;

  /// 麦克风开着（老端 `voiceStatus`）
  final bool microphoneEnabled;

  /// 摄像头开着（老端 `videoStatus`）
  final bool cameraEnabled;

  /// 免提开着（老端 `speaker`，初值也是 true）
  final bool speakerEnabled;

  /// 本机流已经取到了（界面据此挂本地 `RTCVideoRenderer`）
  final bool hasLocalStream;

  /// 对方的流已经收到了
  final bool hasRemoteStream;

  /// 老端那个 `streamType`：true = 远端占大窗。
  ///
  /// 老端收到远端流 50ms 后就把大窗切成对方（`mounted` 里那个 `setTimeout`），
  /// 点一下画面再换回来。
  final bool remoteBig;

  /// 正缩在小窗里（画中画）。
  ///
  /// 小窗里**只画内容、不画任何按钮**：进了 PiP 之后触摸被系统接管
  /// （点一下是「展开 / 菜单」，不是我们的界面），按钮画上去也点不到。
  /// 微信那个小窗也是这样，这是产品要求。
  final bool inPip;

  /// 这台设备能不能共享屏幕（安卓可以；iOS 没有这条路 —— 见 S6.7）。
  ///
  /// 界面据此决定底部左边那颗画不画：画一颗点不动的按钮比不画更糟。
  final bool canShareScreen;

  /// 正在共享屏幕（S6.7）。
  ///
  /// 共享期间发出去的那路画面就是屏幕（不再有摄像头），所以界面会把
  /// 「摄像头」「翻转摄像头」两颗弄灰，底部左边那颗变成「停止共享」。
  final bool screenSharing;

  bool get isActive => session.isActive;
  bool get isVideo => session.isVideo;
  bool get isEnded => session.phase == CallPhase.ended;

  /// 视频通话才画画面（语音通话没有流）
  bool get showRemoteVideo => isVideo && hasRemoteStream;
  bool get showLocalVideo => isVideo && hasLocalStream;

  CallViewState copyWith({
    CallSession? session,
    bool? microphoneEnabled,
    bool? cameraEnabled,
    bool? speakerEnabled,
    bool? hasLocalStream,
    bool? hasRemoteStream,
    bool? remoteBig,
    bool? inPip,
    bool? canShareScreen,
    bool? screenSharing,
  }) => CallViewState(
    session: session ?? this.session,
    microphoneEnabled: microphoneEnabled ?? this.microphoneEnabled,
    cameraEnabled: cameraEnabled ?? this.cameraEnabled,
    speakerEnabled: speakerEnabled ?? this.speakerEnabled,
    hasLocalStream: hasLocalStream ?? this.hasLocalStream,
    hasRemoteStream: hasRemoteStream ?? this.hasRemoteStream,
    remoteBig: remoteBig ?? this.remoteBig,
    inPip: inPip ?? this.inPip,
    canShareScreen: canShareScreen ?? this.canShareScreen,
    screenSharing: screenSharing ?? this.screenSharing,
  );

  @override
  String toString() =>
      'CallViewState(${session.phase.name}, mic=$microphoneEnabled, '
      'cam=$cameraEnabled, speaker=$speakerEnabled, local=$hasLocalStream, '
      'remote=$hasRemoteStream)';
}

/// 通话控制器（S6.2）：把 [CallMachine] 的「该做的事」落到真实世界。
///
/// 数据流是单向的：
/// ```
/// 用户动作 / 远程信令 / 媒体回调
///        ↓
///   CallMachine（纯逻辑，产出 CallEffect）
///        ↓
///   CallController（本类：发信令、响铃、计时、取流、关页）
///        ↓
///   媒体引擎 / 信令通道 / 铃声 / 界面状态
/// ```
///
/// **它不做判断**：谁来挂断、发什么码、忙不忙，全在状态机里；这里只负责执行与转发。
/// 唯一的判断是「拨号 40 秒超时」（老端在 WebView 里数，新端在这里数）。
class CallController {
  CallController({
    required this.machine,
    required this.media,
    required this.tones,
    required Future<Map<String, dynamic>> Function(Map<String, dynamic> request)
    send,
    CallNotifier? notify,
    CallPermissionNotifier? notifyPermission,
    CallKeepAlive? keepAlive,
    CallPip? pip,
    CallWindow? callWindow,
    CallTicker? ticker,
    Future<bool> Function(Duration timeout)? awaitSignalChannel,
  }) : _send = send,
       _awaitSignalChannel = awaitSignalChannel,
       _notify = notify,
       _notifyPermission = notifyPermission,
       _keepAlive = keepAlive,
       _pip = pip,
       _callWindow = callWindow,
       _ticker = ticker ?? TimerCallTicker() {
    // 进了 / 出了小窗：原生说了算（界面据此切成「只有内容」的样子）
    pip?.addModeListener(_onPipModeChanged);
    media.onIceCandidate = (candidate) {
      // 媒体层每收集到一条候选就发一条消息（老端也是逐条发）
      _recorder.localCandidate('${candidate['candidate'] ?? ''}');
      _syncDiagnostics();
      unawaited(_dispatch(machine.localIceCandidate(candidate)));
    };
    media.onConnected = () {
      _recorder.setConnected(true);
      _syncDiagnostics();
      unawaited(_dispatch(machine.mediaConnected()));
    };
    media.onConnectionFailed = (error) {
      _recorder.setConnected(false);
      _record('连接失败：$error');
      unawaited(_handleConnectionFailed(error));
    };
    media.onLocalStream = (_) => _publish(hasLocalStream: true);
    media.onRemoteStream = (_) =>
        _publish(hasRemoteStream: true, remoteBig: true);
  }

  /// 状态机（纯逻辑）
  final CallMachine machine;

  /// 媒体层
  final CallMediaEngine media;

  /// 铃声与挂断音
  final CallTones tones;

  final Future<Map<String, dynamic>> Function(Map<String, dynamic> request)
  _send;
  final CallNotifier? _notify;
  final CallPermissionNotifier? _notifyPermission;

  /// 通话期间的保活（S6.5）：安卓是前台服务，其它平台是空实现
  final CallKeepAlive? _keepAlive;

  /// 保活是不是已经起了（幂等：挂断、reset、dispose 都会调 stop，但只该发一次）
  bool _keepAliveStarted = false;

  /// 正在共享屏幕（S6.7）。
  ///
  /// 与 [CallViewState.screenSharing] 同步维护，但要**另存一份**：通话结束那一刻
  /// `_publish` 会把界面状态里的共享标记一起清掉（本机媒体都放了），而
  /// 「先停投影、再撤前台服务」这个顺序（Android 14 的硬要求）必须在清掉之后
  /// 还知道刚才在共享。
  bool _screenSharing = false;

  /// 等信令通道（长连接）就绪（S8.1h）。只有真机接线会传它。
  ///
  /// 为什么接听前要等：被叫可能是被**离线推送**叫醒的，App 刚起来、长连接还在连。
  /// 这时用户点得很快，我们发出的 `acceptRtc` 会让主叫开始造 offer，而那条 offer
  /// 要经服务端推给**我们** —— 我们还没连上就会丢（服务端不给离线的人补投信令），
  /// 于是两边各自卡住。等一下就避开这个窗口。
  final Future<bool> Function(Duration timeout)? _awaitSignalChannel;

  /// 接听前最多等多久（等不到也让用户接，只是记一条诊断）
  static const Duration signalChannelWait = Duration(seconds: 5);

  /// 被叫响铃的兜底计时器（见 [CallMachine.incomingRingTimeoutSeconds]）
  Timer? _ringTimer;

  /// 上一次同步响铃计时器时的阶段（阶段变了才重建，不然会被反复重置）
  CallPhase? _ringPhase;

  /// ICE 候选信令的**串行队列**（见 [_queueLocalCandidate]）
  Future<void> _candidateChain = Future<void>.value();

  /// 这一通已经结束（或控制器已放掉）：队列里还没发的候选不再发
  bool _candidatesClosed = false;

  /// 一条候选取几次放弃
  ///
  /// 不设「重试间隔」：上一条已经排队串行过了，这里的失败本身就意味着一次
  /// 超时（秒级），再等只会把候选积得更久。
  static const int _candidateAttempts = 3;

  /// 通话小窗（S6.6）：安卓是画中画，其它平台是空实现
  final CallPip? _pip;

  /// 通话界面能不能盖在锁屏之上（S8.1n）。
  ///
  /// 离线叫醒的来电靠全屏通知拉起 Activity，而**能不能盖住锁屏是 Activity
  /// 自己的事**（`setShowWhenLocked` / `setTurnScreenOn`）—— 不声明的话
  /// 用户看到的还是锁屏（系统退回成一条横幅），这正是「全屏通知为什么没弹」。
  final CallWindow? _callWindow;

  /// 锁屏显示现在是开着的吗（幂等用：`_publish` 调得很频繁）
  bool _callScreenOn = false;

  /// 上一次交给系统的缩窗参数（阶段 / 比例 / 标题），没变就不重复打通道
  /// 这一通是否已经把参数交给过系统（用来做幂等：只在「有→无」的那一次收尾）
  bool _pipEngaged = false;
  bool _pipVideo = false;
  String _pipTitle = '';

  final CallTicker _ticker;

  /// 界面看的状态
  final ValueNotifier<CallViewState> view = ValueNotifier<CallViewState>(
    const CallViewState(),
  );

  /// 诊断采集器（S6.5 之前的排查工具）。
  ///
  /// 它只负责「记」：候选的类型与条数、信令收发、ICE 状态、`getStats` 采样、
  /// 时间线。结论（打不通是哪一类原因）由 [CallDiagnostics.hint] 算，面板与
  /// 导出的文本都是它。
  final CallDiagnosticsRecorder _recorder = CallDiagnosticsRecorder();

  /// 诊断快照。面板 watch 它；通话结束后**不会被清掉**，所以能在
  /// 「设置 → 通话诊断」里回看上一通（拨号前是空快照）。
  final ValueNotifier<CallDiagnostics> diagnostics =
      ValueNotifier<CallDiagnostics>(const CallDiagnostics.empty());

  /// 拨号已经过去的秒数（老端 WebView 里的 `cutdown` 反过来数）
  int _dialSeconds = 0;

  /// 从「接通中」算起的秒数（决定什么时候取一次媒体统计）
  int _talkSeconds = 0;

  /// 每隔这么多秒采一次 `getStats`（3 秒够画出码率趋势，又不会搅扰通话）
  static const int statsSampleEverySeconds = 3;

  /// 通话页是不是正开着（老端判忙线用的是「当前路由 == pages/message/call」）。
  ///
  /// 由 [CallPage] 在 `initState` / `dispose` 里置位；状态机只看它，不碰路由。
  bool pageActive = false;

  /// 控制器是不是已经放掉了。
  ///
  /// 通话链路上到处是 `unawaited`（信令回执、媒体回调、计时器），
  /// 登出 / 换账号会把控制器整个换掉（见 [callControllerProvider]），
  /// 那些还在飞的续点必须闭嘴 —— 否则 `view.value = ...` 会撞上
  /// 「A ValueNotifier was used after being disposed」（组件测试当场抓出来的）。
  bool _disposed = false;

  CallSession get session => machine.session;

  /// 本机流 / 对方流（界面拿去喂 [RTCVideoRenderer]）。
  ///
  /// 界面什么时候重建由 [view] 上的 `hasLocalStream` / `hasRemoteStream` 驱动，
  /// 真正取流时再问引擎要——流是可变对象，塞进不可变的 [CallViewState] 反而别扭。
  MediaStream? get localStream => media.localStream;

  MediaStream? get remoteStream => media.remoteStream;

  /// 主叫：点「语音/视频通话」。
  ///
  /// 三道检查（服务端开关、私聊开关、是否已有一通电话）都在状态机里，
  /// 这里只负责在真的开始拨号时把 40 秒倒计时跑起来。
  Future<void> start({
    required String peerId,
    required String peerName,
    String peerAvatar = '',
    required int type,
    required bool webrtcEnabled,
    required bool simpleChatEnabled,
  }) async {
    final outcome = machine.start(
      peerId: peerId,
      peerName: peerName,
      peerAvatar: peerAvatar,
      type: type,
      webrtcEnabled: webrtcEnabled,
      simpleChatEnabled: simpleChatEnabled,
    );
    await _dispatch(outcome);
  }

  /// 被叫：点接听。
  ///
  /// 先等信令通道就绪（见 [_awaitSignalChannel]）—— 被推送叫醒时急着发 `acceptRtc`
  /// 会把主叫随后的那份 offer 丢掉，两边一起卡住。等不到也不阻止用户接
  /// （也许几秒后就通上了，不能把电话扣在这里），只留一条日志/诊断。
  Future<void> accept() async {
    // 已经放掉的控制器不许再动手（见 [_disposed]）：真机上「点接听毫无反应 +
    // 控制台一条 Unhandled Exception」就是这么来的 —— 页面上那颗按钮属于旧控制器。
    if (_disposed) return;
    final wait = _awaitSignalChannel;
    if (wait != null && !await wait(signalChannelWait)) {
      _record('接听时信令通道还没就绪，仍然继续');
      _syncDiagnostics();
    }
    await _dispatch(machine.accept());
  }

  /// 点挂断 / 拒接 / 取消（码由状态机按阶段算）
  Future<void> hangup() {
    if (_disposed) return Future<void>.value();
    debugPrint('[通话] 本机挂断（阶段=${machine.session.phase.name}）');
    return _dispatch(machine.hangup());
  }

  /// 收到一条远程通话信令。[pageActive] = 通话页正开着（老端用它判忙线）
  Future<void> remote(CallSignal signal, {bool pageActive = false}) {
    if (signal.event != CallEvent.iceCandidate) {
      // 真机上「到底收到了哪一条、哪一条没到、是谁先挂的」只有这行日志能看出来
      // （ICE 候选太吵，逐条记在 `remoteCandidate` 里）
      debugPrint(
        '[通话] 收到信令：${signal.event} code=${signal.code} '
        'id=${signal.messageId} sdp=${signal.sdp.length}',
      );
      _record('收到信令：${signal.event}（code=${signal.code}）');
    }
    return _dispatch(machine.remote(signal, pageActive: pageActive));
  }

  /// 对方下线（老端 `App.vue` 的在线状态分支）
  Future<void> peerOffline(String peerId) =>
      _dispatch(machine.peerOffline(peerId));

  /// 对方上线了（S8.1h / S8.1o）：还在响就重喊整帧 `calling`，已接听就补发 offer
  /// （两件事都在 `CallMachine.peerOnline` 里，看我们停在哪一步）。
  ///
  /// 场景：对方被离线推送叫醒后按下接听，而他那一刻长连接还没建好，
  /// 我们收到 `acceptRtc` 随即发出的那份 offer 就丢了 —— 两边从此各自卡住。
  Future<void> peerOnline(String peerId) =>
      _dispatch(machine.peerOnline(peerId));

  /// 静音 / 取消静音
  Future<void> toggleMicrophone() async {
    final enabled = !view.value.microphoneEnabled;
    media.setMicrophoneEnabled(enabled);
    _publish(microphoneEnabled: enabled);
  }

  /// 关 / 开摄像头
  Future<void> toggleCamera() async {
    final enabled = !view.value.cameraEnabled;
    media.setCameraEnabled(enabled);
    _publish(cameraEnabled: enabled);
  }

  /// 免提开关（老端 `speakBtn`：扬声器 ↔ 听筒），通话页上那颗按钮
  Future<void> toggleSpeaker() async {
    final enabled = !view.value.speakerEnabled;
    try {
      await media.setSpeakerEnabled(enabled);
    } catch (error) {
      // 路由切不过去也不能把界面状态弄拧：不翻状态，只提示
      debugPrint('[通话] 切换扬声器失败：$error');
      _notify?.call('message.checkWebtc');
      return;
    }
    _publish(speakerEnabled: enabled);
  }

  /// 切前后置
  Future<void> switchCamera() async {
    try {
      await media.toggleCamera();
    } catch (error) {
      // 没有摄像头/切不过去都只提示一句，不影响通话
      _notify?.call('message.checkWebtc');
    }
  }

  /// 大小窗互换（纯界面状态，老端 `changeVideo()`）
  void toggleLayout() => _publish(remoteBig: !view.value.remoteBig);

  /// 通话页左下角/左上角那颗「缩成小窗」：**立刻**进画中画（不用按 Home）。
  ///
  /// 进不进得去由系统决定（部分 ROM 关掉了画中画），所以失败只记一行诊断，
  /// 绝不影响通话。进小窗之后界面会收到 `onModeChanged`，自己切成「只有内容」。
  Future<void> minimizeToPip() async {
    final pip = _pip;
    if (pip == null || !pip.supported) return;
    try {
      final entered = await pip.enter();
      _record(entered ? '手动缩成小窗' : '想缩成小窗，但系统没接受');
    } catch (error) {
      _record('缩成小窗失败：$error');
    }
  }

  /// 共享屏幕（S6.7）：视频通话底部左边那颗——**微信在这个位置是「模糊背景」**，
  /// 那需要逐帧处理本机画面，`flutter_webrtc` 不给这个口子（结论见 S6.7），
  /// 所以这个位置换成一件真能做到的事：把屏幕共享给对方。
  ///
  /// ⚠️ **顺序是硬要求**（Android 14）：
  /// ① 先让用户在系统那个「开始投屏」框里同意 →
  /// ② 再把前台服务类型升上 `mediaProjection` →
  /// ③ 最后才取屏幕流。
  /// 写反的话 `getMediaProjection()` 直接抛 SecurityException（系统要求「取投影之前
  /// 已经有一个该类型的前台服务在跑」），而插件把用户的同意存在自己内部，
  /// 所以这三步的顺序也正好让它**不弹第二次框**。
  ///
  /// 失败一律只提示 + 记诊断，**绝不影响这一通电话本身**。
  ///
  /// [sourceId]：桌面上共享哪一块（整个屏幕 / 某个窗口）。取屏幕流的是**通话窗**
  /// 那颗引擎（`getDisplayMedia` 与源列表都只在那颗引擎里有），所以这个选择
  /// 从界面一路带下去：通话窗 → 动作 → 主窗口控制器 → 媒体指令 → 通话窗引擎。
  ///
  /// [withAudio]：**连电脑的声音一起发**（桌面，S12.32）。发出去的方式有两种，
  /// 媒体层会回报实际用了哪一种（[ScreenShareAudioRoute]）—— 退成「换麦克风」
  /// 或一条都没发出去时这里各提一嘴（那时对方的听感与预期差得远）。
  Future<void> toggleScreenShare({
    String? sourceId,
    bool withAudio = false,
  }) async {
    if (!machine.session.isActive || !machine.session.isVideo) return;
    if (_screenSharing) {
      await _stopScreenShare();
      return;
    }
    if (!media.supportsScreenShare) return;

    // ① 系统投屏授权（这一步会弹系统框，App 会被顶到后台 —— 但取投影不是
    //    「前台服务类型」那种 while-in-use 校验，所以没有翻车风险）
    final bool granted;
    try {
      granted = await media.requestScreenSharePermission();
    } catch (error) {
      debugPrint('[通话] 请求投屏授权失败：$error');
      _record('共享屏幕失败（没能弹出投屏授权）：$error');
      _notify?.call('call.shareFailed');
      return;
    }
    if (!granted) {
      _record('用户拒绝了共享屏幕');
      _notify?.call('call.shareRefused');
      return;
    }
    // 弹框那几秒里通话可能已经结束/挂掉了
    if (!machine.session.isActive) return;

    // ② 前台服务带上 mediaProjection 类型（Android 14 取投影的前置条件）
    if (!await _setServiceScreenSharing(true)) {
      _record('共享屏幕失败（前台服务类型没升上去）');
      _notify?.call('call.shareFailed');
      return;
    }

    // ③ 取屏幕流并替换掉发出去的那一路画面（要电脑声音的话连声音一起）
    final ScreenShareAudioRoute route;
    try {
      route = await media.startScreenShare(
        sourceId: sourceId,
        withAudio: withAudio,
      );
    } catch (error) {
      debugPrint('[通话] 共享屏幕失败：$error');
      _record('共享屏幕失败：$error');
      await _setServiceScreenSharing(false); // 回滚类型位
      _notify?.call('call.shareFailed');
      return;
    }
    _screenSharing = true;
    _publish(screenSharing: true, hasLocalStream: media.localStream != null);
    _record(withAudio ? '已开始共享屏幕（电脑声音：${route.name}）' : '已开始共享屏幕');
    // 电脑声音那两种「不太顺」都要说一声：退成换麦克风 = 这阵子对方听不到你说话；
    // 一条都没发出去 = 插件的环路采集在这台机器上起不来，这次只有画面
    switch (route) {
      case ScreenShareAudioRoute.microphone:
        _notify?.call('call.shareAudioFallback');
      case ScreenShareAudioRoute.unavailable:
        _notify?.call('call.shareAudioNone');
      case ScreenShareAudioRoute.off || ScreenShareAudioRoute.separate:
        break;
    }
  }

  Future<void> _stopScreenShare() async {
    _screenSharing = false;
    try {
      await media.stopScreenShare();
    } catch (error) {
      // 换不回摄像头也只是「对方那边停在最后一帧」，不该把通话弄断
      debugPrint('[通话] 停止共享屏幕失败：$error');
      _record('停止共享屏幕失败：$error');
    }
    _publish(screenSharing: false, hasLocalStream: media.localStream != null);
    _record('已停止共享屏幕');
    await _setServiceScreenSharing(false);
  }

  /// 共享期间把前台服务的类型加上/去掉 `mediaProjection`（返回是否成功）。
  ///
  /// 同一个服务、同一颗通知，只是多一个类型位（安卓允许一个前台服务带多个类型），
  /// 所以用户不会看到第二条通知。服务本来没在跑就跳过（那时取流会自己报错）。
  Future<bool> _setServiceScreenSharing(bool enabled) async {
    final keepAlive = _keepAlive;
    if (keepAlive == null || !keepAlive.supported || !_keepAliveStarted) {
      return true;
    }
    try {
      await keepAlive.setScreenSharing(enabled: enabled);
      return true;
    } catch (error) {
      debugPrint('[通话] 设置前台服务共享类型失败：$error');
      return false;
    }
  }

  /// 通话页关掉之后调：清回空闲、放掉本机媒体。
  ///
  /// 老端对应的动作是 `onUnload`：`wsData = null; main_id = null` + 停铃。
  Future<void> reset() async {
    if (_disposed) return;
    _ticker.stop();
    _syncRingTimer(CallPhase.idle);
    _dialSeconds = 0;
    _talkSeconds = 0;
    // 保活兜底（正常路径上 `EndCall` 已经停过，这里防抛异常那种半途而废）
    await _stopKeepAlive();
    // 通话页关掉时补一条结束记录（正常路径上 `EndCall` 已经记过，这里是保险）
    if (_recorder.isRecording) {
      _recorder.finish(callTimeSeconds: machine.session.callTime);
      _syncDiagnostics();
    }
    await tones.stopRing();
    // 共享屏幕的状态跟着这一通一起没了（屏幕流由 media.close 放掉）
    _screenSharing = false;
    await media.close();
    final outcome = machine.reset();
    _publish(
      session: outcome.session,
      hasLocalStream: false,
      hasRemoteStream: false,
      remoteBig: false,
      microphoneEnabled: true,
      cameraEnabled: true,
      speakerEnabled: true,
      canShareScreen: false,
      screenSharing: false,
    );
  }

  Future<void> dispose() async {
    _disposed = true;
    _ticker.stop();
    // 响铃兑底计时器也得停：它回调里会 `_dispatch`，而 view 马上要 dispose
    _ringTimer?.cancel();
    _ringTimer = null;
    // 登出/换账号会把控制器整个换掉：保活也必须跟着停，否则会留一条幽灵通知
    await _stopKeepAlive();
    // 小窗同理：登出/换账号时把已经打开的小窗收掉，不然它会留在那儿
    final pip = _pip;
    if (pip != null) {
      pip.removeModeListener(_onPipModeChanged);
      _pipEngaged = false;
      unawaited(_exitPip());
    }
    // 登出 / 换账号也要把锁屏显示关掉：留着一个「能盖住锁屏」的窗口，
    // 下一通无关的通知点进来时也会被它盖住锁屏
    _syncCallWindow(false);
    view.dispose();
    diagnostics.dispose();
    _screenSharing = false;
    await tones.stopRing();
    await media.close();
  }

  // ------------------------------------------------------------------ 内部

  /// 执行状态机给的一串副作用
  Future<void> _dispatch(CallOutcome outcome) async {
    // 已经放掉的控制器不再执行任何副作用（界面上那颗按钮可能属于旧控制器）。
    // 这里是**总闸**：统一堵住「登出/重建之后还在飞的续点」（信令回执、媒体回调、
    // 计时器、推送叫醒的来电），堵在其他地方总会漏掉一条。
    if (_disposed) return;
    _publish(session: outcome.session);
    _syncRingTimer(outcome.session.phase);
    for (final effect in outcome.effects) {
      await _apply(effect);
    }
  }

  /// 来的时候起个兜底计时器，走的时候收掉（S8.1h）。
  ///
  /// 为什么不用每秒的 [CallTicker]：那个只在「拨号中 / 接通后」跑，
  /// 而**响铃期间**（`incoming`）它还没起 —— 被叫这条上限得有自己的计时器。
  void _syncRingTimer(CallPhase phase) {
    if (phase == _ringPhase) return;
    _ringPhase = phase;
    _ringTimer?.cancel();
    _ringTimer = null;
    if (phase != CallPhase.incoming) return;
    _ringTimer = Timer(
      const Duration(seconds: CallMachine.incomingRingTimeoutSeconds),
      () {
        if (_disposed) return;
        unawaited(_dispatch(machine.ringTimeout()));
      },
    );
  }

  Future<void> _apply(CallEffect effect) async {
    switch (effect) {
      case SendSignal():
        if (effect.request['event'] == CallEvent.iceCandidate) {
          // 候选**不 await**：它们是媒体层一次回调就一整批，而且不该堵住
          // 任何关键信令（见 `_queueLocalCandidate`）。
          _queueLocalCandidate(effect.request);
        } else {
          await _sendSignal(effect.request);
        }
      case ShowToast():
        _notify?.call(effect.messageKey);
      case PlayRingtone():
        await tones.startRing();
      case StopRingtone():
        await tones.stopRing();
      case StartCallTimer():
        _ticker.start(_onTick);
      case StopCallTimer():
        _ticker.stop();
      case RequestLocalMedia():
        _record('取本机媒体（${effect.type == CallType.video ? '视频' : '语音'}）');
        await _openMedia(effect.type == CallType.video);
      case CreateOffer():
        _record('生成 offer');
        await _createOffer();
      case AcceptRemoteOffer():
        _record('准备响应对方 offer（${effect.sdp.length} 字节）');
        await _acceptRemoteOffer(effect.sdp);
      case ApplyRemoteAnswer():
        _record('应用对方 answer（${effect.sdp.length} 字节）');
        await _applyRemoteAnswer(effect.sdp);
      case AddIceCandidate():
        _recorder.remoteCandidate('${effect.candidate['candidate'] ?? ''}');
        _syncDiagnostics();
        await media.addIceCandidate(effect.candidate);
      case EndCall():
        // 结束码进时间线：真机上「谁挂的、为什么挂」全靠这一行 + 上面那条信令日志
        _record('通话结束：${_describeEndCode(machine.session.code)}');
        _recorder.finish(callTimeSeconds: machine.session.callTime);
        _syncDiagnostics();
        await _endCall();
    }
  }

  /// 发一条信令。
  ///
  /// 老端 `sendToMsg(...).then((res) => ...)` 里只做两件事：记下 `msg_id`、
  /// 看服务端是不是用 `extends.code == 907` 说「对方不在线」。两件都在状态机的
  /// `signalAccepted` 里。**发失败不处理**（老端 `.then` 没有 `catch`）：
  /// 拨号会一直转到 40 秒超时，与老端一致。
  ///
  /// **`busy` 那一枪不看回执**：老端两个发忙线的地方（`App.vue` 与 `call.vue`）
  /// 都是裸的 `sendToMsg`，后面**没有 `.then`** —— 而服务端回执的 `extends` 里就是
  /// 我们刚发的那份报文，忙线报文里 `code` 正好是 907，一解析就会把自己当成
  /// 「对方不在线」把自己挂掉（这个坑是单测当场抓出来的）。
  Future<void> _sendSignal(Map<String, dynamic> request) async {
    final isBusyReply = request['event'] == CallEvent.busy;
    final name = '${request['event']}';
    _recorder.signalSent(name);
    _syncDiagnostics();
    try {
      final data = await _send(request);
      if (isBusyReply) return;
      await _dispatch(machine.signalAccepted(data));
    } catch (error) {
      // 弱网下「关键信令丢一条就整通话僵住」在这里看得出来（面板的失败计数）
      _recorder.signalFailed(name, error);
      _syncDiagnostics();
      debugPrint('[通话] 信令发送失败：$error');
    }
  }

  /// ICE 候选：**排队串行发**，失败重试。
  ///
  /// 为什么不能像老端那样逐条并发发：候选是媒体层一次回调就给一整批，一批
  /// 10~15 条 `sendToMsg` 同时打出去，在（手机关 WiFi 走流量的）弱网下会
  /// **集体撞 10 秒超时**。2026-09-26 真机实测：`iceCandidate` 发出 15 条、
  /// 13 条失败，时间线里 13 条 `NetworkUnavailableException(请求超时)` 全挤在
  /// `+14.29s ~ +15.66s` 一秒多里（那条通话在 `+6.54s` 已经连上，所以没砸掉，
  /// 但**中继候选正是靠这些信令发出去的** —— 真要兜底时丢的就是它）。
  ///
  /// 串行之后每条候选只占一个短请求（几百字节），整体晚一两秒；
  /// 关键信令（calling / acceptRtc / offer / answer / 挂断 / 忙线）不走这条队列，
  /// 所以不会被候选拖慢。
  void _queueLocalCandidate(Map<String, dynamic> request) {
    if (_candidatesClosed || _disposed) return;
    _candidateChain = _candidateChain.then((_) => _sendCandidate(request));
  }

  Future<void> _sendCandidate(Map<String, dynamic> request) async {
    if (_candidatesClosed || _disposed) return;
    final name = '${request['event']}';
    _recorder.signalSent(name);
    _syncDiagnostics();

    for (var attempt = 1; attempt <= _candidateAttempts; attempt++) {
      try {
        final data = await _send(request);
        // 与 [_sendSignal] 一致：回执要交给状态机（`msg_id`、907 忙线）
        await _dispatch(machine.signalAccepted(data));
        return;
      } catch (error) {
        if (attempt >= _candidateAttempts) {
          _recorder.signalFailed(name, error);
          _syncDiagnostics();
          debugPrint('[通话] $name 发送失败（已重试 $_candidateAttempts 次）：$error');
          return;
        }
        // 重试只进时间线，不进失败计数：面板那句「信令：iceCandidate 15」
        // 要一直表示「想发 15 条」，否则数字没法解释。
        _recorder.signalRetried(name, attempt, error);
        _syncDiagnostics();
        if (_candidatesClosed || _disposed) return;
      }
    }
  }

  /// 取本机媒体；成功才让状态机发 `calling` / `acceptRtc`，失败就提示 + 关页
  /// （老端 `getUserMedia().catch` 里发 `mediaDevices`，页面提示后 `closeCall()`，
  /// **一条信令都不发**）。
  Future<void> _openMedia(bool video) async {
    try {
      await media.open(video: video);
      // 建完连接才知道这份 ICE 列表长什么样（服务端签发的 TURN 凭据就在
      // 建连接那一步才并进来，见 `call_media_engine.dart::resolveIceServers`）：
      // 把实际用的那组补记进诊断，不然面板上只看到站点那一栏。
      _recorder.updateIceServers(media.iceServersDescription);
      _syncDiagnostics();
      // 「共享屏幕」只给视频通话、而且平台得支持（安卓）：界面据 canShareScreen 画那颗
      _publish(
        hasLocalStream: media.localStream != null,
        canShareScreen: video && media.supportsScreenShare,
      );
      // 老端 `plusready` 里就把音频路由固定成扬声器（`ROUTE_SPEAKER`），
      // 这里在拿到媒体之后做同一件事；完整的路由策略（蓝牙/听筒）是 S6.4。
      await _applySpeaker(true);
      // 保活（S6.5）就在这里起 —— **本机媒体已经拿到**（真的在用麦克风了）、
      // App 还开着，这两条正是 Android 14 对 mic 类型前台服务的要求。
      // 失败只记诊断，绝不影响通话（不 await：起服务不该拖慢拨号）。
      unawaited(_startKeepAlive(video: video));
      // 40 秒倒计时从**媒体就绪之后**开始数：老端那个 `setInterval` 也是写在
      // `getUserMedia` 的成功回调里的（弹权限框那几秒不算在拨号里）。
      if (machine.session.phase == CallPhase.outgoing) {
        _dialSeconds = 0;
        _ticker.start(_onTick);
      }
      await _dispatch(machine.mediaReady());
    } catch (error) {
      debugPrint('[通话] 取本机媒体失败：$error');
      final failure = error is CallMediaException
          ? error.failure
          : classifyMediaFailure(error, video: video);
      _record('取本机媒体失败：$error');
      await _dispatch(machine.mediaFailed());
      // 状态机那条是笼统的「请检查通话设置」，这里补一条说得更明白的。
      // **放后面**：两条提示共用同一个 toast，后一条才会被看到。
      final key = _mediaFailureKey(failure);
      if (key != null) {
        // 权限那三条带一颗「去授权」按钮（跳系统设置）；没硬件那条不需要按钮。
        // 没接这颗按钮的环境（单测的默认构造）就退回普通提示，
        // 保证这句话总能到用户眼前。
        final notifyPermission = _notifyPermission;
        if (notifyPermission != null && _jumpToSettings(failure)) {
          notifyPermission(key);
        } else {
          _notify?.call(key);
        }
      }
    }
  }

  /// 「拿不到媒体」翻译成一句说得更明白的提示。
  ///
  /// 安卓上麦克风/摄像头是分开授权的，而且第二次拒绝后系统不再弹框，
  /// 必须自己进设置里开——所以要告诉用户到底是哪一个。
  /// 这条失败要不要给「去系统设置」的按钮（只有权限类的才给）
  bool _jumpToSettings(CallMediaFailure failure) => switch (failure) {
    CallMediaFailure.microphone ||
    CallMediaFailure.camera ||
    CallMediaFailure.both => true,
    CallMediaFailure.device || CallMediaFailure.unknown => false,
  };

  String? _mediaFailureKey(CallMediaFailure failure) => switch (failure) {
    CallMediaFailure.microphone => 'call.micAuth',
    CallMediaFailure.camera => 'call.cameraAuth',
    CallMediaFailure.both => 'call.micCameraAuth',
    CallMediaFailure.device => 'call.deviceMissing',
    // 认不出来就交给状态机那句笼统的（与老端一致）
    CallMediaFailure.unknown => null,
  };

  /// 把音频路由切到扬声器/听筒；失败只记日志（不影响通话本身）。
  ///
  /// 只在「刚拿到媒体」与「用户点免提」两处调，两处的失败处理不同：
  /// 前者不翻状态（默认就是扬声器），后者由 [toggleSpeaker] 决定。
  Future<void> _applySpeaker(bool enabled) async {
    try {
      await media.setSpeakerEnabled(enabled);
      _publish(speakerEnabled: enabled);
    } catch (error) {
      debugPrint('[通话] 设置音频路由失败：$error');
    }
  }

  Future<void> _createOffer() async {
    try {
      final sdp = await media.createOffer(video: machine.session.isVideo);
      await _dispatch(machine.localOffer(sdp));
    } catch (error) {
      await _failNegotiation('创建 offer', error);
    }
  }

  /// SDP 协商失败（造 offer / 响应 offer 出错）。
  ///
  /// 与老端的差异：老端这两个 `createOffer` / `createAnswer` 都是**没有 catch** 的
  /// 裸 promise —— 一失败就什么都不发，对方于是永远停在响铃/接通中（这里 caller
  /// 已经发过 `calling`，所以必须告诉对面）。新端补一枪挂断，码按当前阶段算（906）。
  ///
  /// **但只在「这通电话还在进行」时才提示 + 挂断**：过期的 offer（对端在我们挂断
  /// 之后才发出来，或服务端连带旧信令一起重推）也会走到这里，那时候弹一句
  /// 「请检查音视频」纯属吓人，挂断也是一次空操作。真机上就撞到过这个组合。
  Future<void> _failNegotiation(String what, Object error) async {
    debugPrint('[通话] $what失败：$error');
    if (!machine.session.isActive) return;
    _notify?.call('message.checkWebtc');
    await _dispatch(machine.hangup());
  }

  /// 结束码翻成人话（日志与诊断面板里读起来直接）
  static String _describeEndCode(int code) => switch (code) {
    0 => '无码（对端被动关页/多端处理）',
    CallCode.dialing => '901 本机发起',
    CallCode.cancel => '902 取消或拨号超时',
    CallCode.reject => '903 拒接',
    CallCode.accept => '904 已接听',
    CallCode.unknown => '905（老端从未发过）',
    CallCode.hangupInCall => '906 通话中挂断',
    CallCode.busy => '907 忙线',
    _ => 'code=$code',
  };

  Future<void> _acceptRemoteOffer(String sdp) async {
    try {
      final answer = await media.acceptOffer(
        sdp,
        video: machine.session.isVideo,
      );
      await _dispatch(machine.localAnswer(answer));
    } catch (error) {
      await _failNegotiation('响应 offer', error);
    }
  }

  Future<void> _applyRemoteAnswer(String sdp) async {
    try {
      await media.applyAnswer(sdp);
    } catch (error) {
      debugPrint('[通话] 设置远端 answer 失败：$error');
    }
  }

  /// 通话结束：停保活 + 放挂断音 + 停表。
  ///
  /// 「关掉通话页」这件事由界面做（它 watch `view.isEnded`），控制器不碰路由。
  Future<void> _endCall() async {
    // 这一通结束了，队列里还没发出去的候选没有意义了（对方也收不到了）
    _candidatesClosed = true;
    _ticker.stop();
    // 共享屏幕跟着这一通一起结束，而且**必须在撤前台服务之前**：Android 14 要求
    // 投影在带 mediaProjection 类型的服务停掉之前结束（屏幕流也在这里被放掉，
    // 不然屏幕会一直被投着）。
    if (_screenSharing) {
      await _stopScreenShare();
    }
    // 通话一结束就撤掉前台服务：留一个「麦克风正在使用」的常驻通知比什么都糟
    await _stopKeepAlive();
    await tones.stopRing();
    // 老端 `closeCall()`：`uni.createInnerAudioContext()` 播 guaduan.mp3
    unawaited(tones.playHangup());
  }

  /// ICE 怎么都连不上（老端完全不处理，通话会一直僵在「正在接通」）。
  ///
  /// 刻意的差异：直接提示网络问题并结束这一通——两分钟毫无反应的界面比明说更糟。
  Future<void> _handleConnectionFailed(Object error) async {
    debugPrint('[通话] 连接失败：$error');
    if (!machine.session.isActive) return;
    _notify?.call('network.disconnect');
    await _dispatch(machine.hangup());
  }

  /// 一秒一跳：拨号中数超时（老端 40 秒，新端 60 秒），
  /// 接通后数通话时长（一个是老端 WebView 的倒计时，一个是老端 `setInterval` 的 `callTime`）
  void _onTick() {
    final phase = machine.session.phase;
    if (phase == CallPhase.outgoing) {
      _dialSeconds += 1;
      if (_dialSeconds >= CallMachine.dialTimeoutSeconds) {
        unawaited(_dispatch(machine.timeout()));
      }
      return;
    }
    if (phase == CallPhase.connecting || phase == CallPhase.connected) {
      unawaited(_dispatch(machine.tick()));
      // 顺手采一次媒体统计（RTT / 丢包 / 码率），给诊断面板用。
      // 「接通中」也采：连不上的那几十秒正是最需要看到候选与丢包的时候。
      _talkSeconds += 1;
      if (_talkSeconds % statsSampleEverySeconds == 0) {
        unawaited(_sampleStats());
      }
    }
  }

  /// 起保活（S6.5）。
  ///
  /// 三件事：起服务、「确认它真的起来了」（读回由实现负责）写进诊断、
  /// 顺手看一眼通知权限（**只看不申请**：那个系统框会把 App 顶到后台，而那一瞬间
  /// 正是「从后台起 mic 前台服务」，必然被系统拒掉）。
  Future<void> _startKeepAlive({required bool video}) async {
    final keepAlive = _keepAlive;
    if (keepAlive == null || !keepAlive.supported || _keepAliveStarted) return;
    _keepAliveStarted = true;
    final peer = machine.session.peerName.isEmpty
        ? machine.session.peerId
        : machine.session.peerName;
    try {
      await keepAlive.start(video: video, peerName: peer);
      if (!_keepAliveStarted) {
        // 起服务那几百毫秒里通话已经结束（拨出去立刻挂断）：补一枪停，
        // 否则原生那边刚 foregound 起来，就留下一条幽灵通知
        await keepAlive.stop();
        return;
      }
      _record('后台保活已开启（前台服务：${video ? '麦克风+摄像头' : '麦克风'}）');
    } catch (error) {
      // 真机上典型的原因是 while-in-use 校验（见 CallKeepAliveException 的注释）
      debugPrint('[通话] 起前台服务失败：$error');
      _record('后台保活失败：$error');
    }
    final granted = await keepAlive.hasNotificationPermission();
    if (!granted) {
      _record('通知权限未给：保活照常，只是通知栏看不到「通话中」');
    }
  }

  /// 原生说「进了 / 出了小窗」（[addModeListener] 注册的就是这一个）。
  void _onPipModeChanged(bool inPip) => _publish(inPip: inPip);

  /// 通话小窗（画中画）的策略。
  ///
  /// **用户只想要「点按钮才缩窗」**（2026-09-19 明确要求）：回到桌面 / 划走 / 切到
  /// 别的应用都**不进小窗**，那几种情况只靠前台服务 + 常驻通知。所以这里只做两件事：
  ///
  /// 1. 这一通是小窗时把**比例与标题**交给系统（点按钮那一刻原生要用）；
  /// 2. 通话结束时把已经打开的小窗**收掉**（不留一个「小窗里是聊天列表」的怪状态）。
  void _syncPip() {
    final pip = _pip;
    if (pip == null || !pip.supported) return;
    final session = machine.session;

    // 通话结束（含被挂断、拒接、超时）：从「engaged」变成不 engaged 的那一次收尾
    if (!session.isActive) {
      if (!_pipEngaged) return; // 幂等：闲置时每次 publish 都会走到这里
      _pipEngaged = false;
      _pipVideo = false;
      _pipTitle = '';
      unawaited(_exitPip());
      return;
    }

    final title = session.peerName;
    if (_pipEngaged && session.isVideo == _pipVideo && title == _pipTitle) {
      return; // 参数没变：不打通道（通话里状态变化很频繁）
    }
    _pipEngaged = true;
    _pipVideo = session.isVideo;
    _pipTitle = title;
    unawaited(_applyPipParams(video: session.isVideo, title: title));
  }

  /// 把「比例 + 标题」交给系统（不开自动缩窗）。
  ///
  /// 失败只记诊断：小窗是体验，绝不能让通话因为小窗挂掉。
  Future<void> _applyPipParams({
    required bool video,
    required String title,
  }) async {
    final pip = _pip;
    if (pip == null) return;
    try {
      final applied = await pip.setParams(video: video, title: title);
      _record(
        applied
            ? '画中画参数就绪（${video ? '3:4' : '1:1'}，点「缩成小窗」才进）'
            : '画中画参数没设上（这个系统/机型可能关掉了小窗）',
      );
    } catch (error) {
      debugPrint('[通话] 设置画中画参数失败：$error');
      _record('画中画参数失败：$error');
    }
  }

  /// 通话结束时把小窗收掉（不在小窗里就什么都不发生）
  Future<void> _exitPip() async {
    final pip = _pip;
    if (pip == null) return;
    try {
      if (await pip.isInPip()) {
        await pip.exit();
        _record('通话结束，小窗已收起');
      }
    } catch (error) {
      debugPrint('[通话] 退出画中画失败：$error');
    }
  }

  /// 停保活（幂等：没起过就不发通道调用）
  Future<void> _stopKeepAlive() async {
    if (!_keepAliveStarted) return;
    _keepAliveStarted = false;
    try {
      await _keepAlive?.stop();
    } catch (error) {
      debugPrint('[通话] 停前台服务失败：$error');
    }
  }

  /// 取一次媒体统计并记进诊断（失败只记日志：统计拿不到不该影响通话）
  Future<void> _sampleStats() async {
    try {
      final sample = await media.sampleStats();
      if (_disposed) return;
      // 诊断（S12.34）：每 3 秒一行「视频发/收/解了多少帧 + RTT」。真机上
      // 「对方看不到画面」时分三种情况：没发出去 / 没到 / 到了解不出来 ——
      // 这三个数一摆就分清了（发送侧看 sent，接收侧看 recv/decoded）。
      debugPrint(
        '[通话·媒体] ${sample.videoFlowSummary} rtt=${sample.roundTripMs}ms',
      );
      _recorder.sample(sample);
      _syncDiagnostics();
    } catch (error) {
      debugPrint('[通话] 取媒体统计失败：$error');
    }
  }

  /// 记一条时间线事件（附一次快照）
  ///
  /// 除了进诊断面板，还**写一份到 logcat**（`adb logcat | grep 通话`）：
  /// 真机上排查「谁挂的、为什么挂」时，面板要用户自己进设置里翻一遍太慢，
  /// 而 `logcat` 里本来只有信令收发的几条。2026-09-20 那次「接通就闪退」
  /// 就是靠这几行一眼定位的。
  void _record(String label) {
    debugPrint('[通话·时间线] $label');
    _recorder.event(label);
    _syncDiagnostics();
  }

  /// 把采集器的最新状态推给界面（采集器本身不可变，界面拿到的是快照）
  void _syncDiagnostics() {
    if (_disposed) return;
    diagnostics.value = _recorder.snapshot();
  }

  /// 会话一起来就开始记录（主叫与被叫都走这里：状态机不关心诊断）
  void _trackRecording(CallSession session) {
    if (!session.isActive || _recorder.isRecording) return;
    if (session.phase != CallPhase.outgoing &&
        session.phase != CallPhase.incoming) {
      return;
    }
    _recorder.begin(
      video: session.isVideo,
      caller: session.phase == CallPhase.outgoing,
      peer: session.peerName.isEmpty ? session.peerId : session.peerName,
      iceServers: media.iceServersDescription,
    );
    // 新的一通：候选队列重新开门
    _candidatesClosed = false;
    _syncDiagnostics();
  }

  void _publish({
    CallSession? session,
    bool? microphoneEnabled,
    bool? cameraEnabled,
    bool? speakerEnabled,
    bool? hasLocalStream,
    bool? hasRemoteStream,
    bool? remoteBig,
    bool? inPip,
    bool? canShareScreen,
    bool? screenSharing,
  }) {
    if (_disposed) return;
    var next = view.value.copyWith(
      session: session,
      microphoneEnabled: microphoneEnabled,
      cameraEnabled: cameraEnabled,
      speakerEnabled: speakerEnabled,
      hasLocalStream: hasLocalStream,
      hasRemoteStream: hasRemoteStream,
      remoteBig: remoteBig,
      inPip: inPip,
      canShareScreen: canShareScreen,
      screenSharing: screenSharing,
    );
    // 通话结束之后本机媒体已经被放掉了，别再让界面以为还挂着画面
    if (session != null && !session.isActive) {
      next = next.copyWith(
        hasLocalStream: false,
        hasRemoteStream: false,
        remoteBig: false,
        canShareScreen: false,
        screenSharing: false,
      );
    }
    final wasInPip = view.value.inPip;
    view.value = next;
    // 诊断跟着会话走：会话一起来就开记（见 _trackRecording）
    _trackRecording(next.session);
    // 小窗进出也记一行：真机上「怎么没缩成小窗」只能靠它定位
    if (next.inPip != wasInPip) {
      _record(next.inPip ? '已缩成小窗' : '已回到通话页');
    }
    // 小窗的开关跟着阶段走（见 _syncPip）
    _syncPip();
    // 锁屏显示跟着「有没有通话」走（见 _syncCallWindow）
    _syncCallWindow(next.session.isActive);
  }

  /// 通话期间让界面能盖在锁屏之上（S8.1n）。
  ///
  /// 幂等：只在「关→开」「开→关」那一次打通道（`_publish` 每次都调）。
  /// 失败只记日志（实现里兜了），**绝不影响通话本身**。
  void _syncCallWindow(bool active) {
    final window = _callWindow;
    if (window == null || !window.supported || active == _callScreenOn) return;
    _callScreenOn = active;
    // 平台实现里自己也兜了异常，这里再兜一层：这条「体验类」的通道失败
    // 绝不能变成一个**未处理的异步异常**（真机上会污染 zone），
    // 更不能把通话拖下水；而且将来换实现时这道闸还在。
    unawaited(
      window.setCallScreenMode(enabled: active).catchError((Object error) {
        debugPrint('[通话] 设置锁屏显示失败：$error');
      }),
    );
  }
}

/// 全局唯一的通话控制器。
///
/// `myUserId` 用 `select` 只盯用户 id：登录/登出会重建控制器，
/// 而多端标记、配置热更新这类变化不会把正在进行的通话打掉。
final callControllerProvider = Provider<CallController>((ref) {
  // ⚠️ 信令服务在这里**取一次就存住**，绝不把 `ref` 带进回调里迟到才用。
  // 2026-09-20 真机上炸过一次：控制器被重建（旧的已 dispose）之后你才点「接听」，
  // 回调里的 `ref.read` 当场抛「Cannot use the Ref … after it has been disposed」，
  // 于是接听毫无反应、界面卡死在旧控制器上。用 `read` 而不是 `watch` 是故意的：
  // 信令服务换实例时不该把一通正在进行的电话重建（这条链只需要一个句柄）。
  final signalChannel = ref.read(wsServiceProvider);
  final controller = CallController(
    machine: CallMachine(
      myUserId: ref.watch(sessionStoreProvider.select((state) => state.userId)),
    ),
    media: ref.watch(callMediaEngineProvider),
    tones: ref.watch(callTonesProvider),
    // 接听前等长连接就绪（S8.1h）：被推送叫醒时，急着发 acceptRtc 会把
    // 主叫随后的 offer 丢掉（服务端不给离线的人补投信令）
    awaitSignalChannel: (timeout) async {
      if (signalChannel.isConnected) return true;
      try {
        await signalChannel.statusChanges
            .firstWhere((status) => status == WsStatus.connected)
            .timeout(timeout);
        return true;
      } on TimeoutException {
        return false;
      }
    },
    // 通话期间的保活（S6.5）：安卓是真前台服务，其它平台是空实现
    keepAlive: ref.watch(callKeepAliveProvider),
    // 通话小窗（S6.6）：安卓是画中画，其它平台是空实现
    pip: ref.watch(callPipProvider),
    // 通话界面盖在锁屏之上（S8.1n）：离线叫醒的来电要整屏弹出来靠它
    callWindow: ref.watch(callWindowProvider),
    ticker: ref.watch(callTickerProvider),
    send: ref.read(callRepositoryProvider).sendSignal,
    notify: (key) => noticeBus.toast(AppI18n.instance.t(key)),
    // 「需要麦克风权限」旁边那颗「去授权」：直接跳到应用详情页的权限开关
    notifyPermission: (key) => noticeBus.toastWithAction(
      AppI18n.instance.t(key),
      actionLabel: AppI18n.instance.t('common.gotoAuth'),
      onAction: openAppSettings,
    ),
  );
  ref.onDispose(controller.dispose);
  return controller;
});
