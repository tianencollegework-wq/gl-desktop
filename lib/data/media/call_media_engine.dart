import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
// 只取这一个：`flutter/services.dart` 里其它名字与 `flutter_webrtc` 有重名
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../core/store/session_store.dart';
import '../../features/call/call_window_host.dart';
import '../../features/call/call_window_media_engine.dart';
import '../../core/util/uuid.dart';
import '../../domain/call/call_diagnostics.dart';
import '../../domain/call/call_media_config.dart';
import '../../domain/call/turn_credentials.dart';
import 'desktop_screen_capture.dart';
import 'remote_stream_choice.dart';
import 'shared_window_watch.dart';

/// 媒体层出错（拿不到麦克风/摄像头、SDP 协商失败、原生层报错）。
///
/// 把插件抛出来的各种类型（`PlatformException`、`String`、`StateError`…）收成一个，
/// 上层只认这一种——老端那边就是 WebView 抛东西然后走 `catch` 发 `mediaDevices`。
class CallMediaException implements Exception {
  const CallMediaException(
    this.message, [
    this.cause,
    this.failure = CallMediaFailure.unknown,
  ]);

  final String message;
  final Object? cause;

  /// 拿不到本机媒体的具体原因（只有 [CallMediaEngine.open] 那一路会填）
  final CallMediaFailure failure;

  @override
  String toString() =>
      'CallMediaException($message${cause == null ? '' : ': $cause'})';
}

/// 拿不到本机媒体的原因。
///
/// 老端这一路只有一句笼统的 `message.checkWebtc`（「请检查通话设置」），用户
/// 根本看不出是麦克风被拒、摄像头被拒，还是压根没设备。安卓上这两个权限是
/// **分开弹**的，而且第二次被拒之后系统不再弹框，必须自己进设置里开 ——
/// 所以提示里必须说清是哪一个。
enum CallMediaFailure {
  /// 麦克风权限被拒
  microphone,

  /// 摄像头权限被拒
  camera,

  /// 视频通话时两个都被拒（分不出是哪一个）
  both,

  /// 权限没问题，是没设备 / 设备被别的应用占着
  device,

  /// 认不出来（原生层报的其它东西）；提示继续用老端那句笼统文案
  unknown,
}

/// 把原生层的报错翻译成 [CallMediaFailure]。
///
/// 安卓上插件抛的是 `PlatformException(code: 'GetUserMedia', message:
/// 'Permission denied' / 'NotAllowedError' / 'NotFoundError')` 这类文本，iOS 上
/// 又是另一套，所以只能按关键词认。**认错的代价只是提示语不准**，不影响任何
/// 控制流（该结束的通话照样结束）。
CallMediaFailure classifyMediaFailure(Object? error, {required bool video}) {
  final text = '$error'.toLowerCase();

  final noDevice =
      text.contains('notfound') ||
      text.contains('not found') ||
      text.contains('no device') ||
      text.contains('overconstrained');
  if (noDevice) return CallMediaFailure.device;

  final permission =
      text.contains('permission') ||
      text.contains('notallowed') ||
      text.contains('not allowed') ||
      text.contains('denied') ||
      text.contains('authoriz') ||
      text.contains('权限');
  if (!permission) return CallMediaFailure.unknown;

  final camera =
      text.contains('video') || text.contains('camera') || text.contains('摄像头');
  final microphone =
      text.contains('audio') ||
      text.contains('microphone') ||
      text.contains('麦克风');
  if (camera && !microphone) return CallMediaFailure.camera;
  if (microphone && !camera) return CallMediaFailure.microphone;
  // 文本里分不出来：按这通电话真正需要的设备算（语音只要麦克风）
  return video ? CallMediaFailure.both : CallMediaFailure.microphone;
}

/// 通话的媒体层（S6.2）。
///
/// 老端这一层是 `hybrid/html/index.html` 里那整套 WebRTC 代码：建 `RTCPeerConnection`、
/// `getUserMedia`、`addTrack`、`createOffer/Answer`、收发 ICE 候选、开关麦克风摄像头。
/// 新端换成 `flutter_webrtc`，但**每个方法都能在老端找到对应的那一段**（注释里都标了）。
///
/// 抽成接口的理由与 [MediaPicker] / [VoicePlayerNotifier] 一样：真机的
/// `getUserMedia` 与 ICE 只有设备能跑，所以状态机 + 控制器那条链路要在测试里
/// 用一个**内存里的假引擎**验完（见 `test/support/fake_call_media.dart`）。
///
/// 回调（`onXxx`）都只有一个消费者：`CallController`。
/// 共享屏幕时那一路**电脑声音**最后是怎么发出去的（[CallMediaEngine.startScreenShare] 的返回值）。
///
/// 为什么要区分：发出去的方式有两种，用户体验不一样，界面得知道该不该提一嘴。
enum ScreenShareAudioRoute {
  /// 这次没要声音（用户没勾那座开关，或平台不支持）
  off,

  /// 走**单独那条音频轨**（通话建立时就预协商好的那条空音频 m-line，
  /// 见 [WebrtcCallMediaEngine.createOffer]）：对方同时听得到你的声音与电脑的声音。
  separate,

  /// 单独那条没有（对面客户端版本旧，它的 offer 里没有空音频轨）：退成
  /// **把麦克风那条轨换成电脑声音** —— 这期间对方听不到你说话，停共享自动换回。
  microphone,

  /// 要了声音但一条都没发出去（这台机器上取不到 loopback）：这次只共享画面。
  unavailable,
}

abstract interface class CallMediaEngine {
  /// 取本机媒体并挂到连接上（老端 `initLocalStream`）。
  ///
  /// 主叫在拨号时调、被叫在点接听后调；成功之后控制器才让状态机 `mediaReady()`。
  Future<void> open({required bool video});

  /// 造 offer（老端 `createOffer`：`createOffer` → `setLocalDescription` → 发 sdp）
  Future<String> createOffer({required bool video});

  /// 收到对方 offer：设远端 → 造 answer（老端 `case "offer"` → `createAnswer`）
  Future<String> acceptOffer(String sdp, {required bool video});

  /// 收到对方 answer：设远端（老端 `case "answer"`）
  Future<void> applyAnswer(String sdp);

  /// 加一条对方发来的 ICE 候选（老端 `case "iceCandidate"`，它延迟 100ms 再加）
  Future<void> addIceCandidate(Map<String, dynamic> candidate);

  /// 静音 / 取消静音（老端 `switchVoice`：把 audio track 的 `enabled` 取反）
  void setMicrophoneEnabled(bool enabled);

  /// 关 / 开摄像头（老端 `switchVideo`：把 video track 的 `enabled` 取反）
  void setCameraEnabled(bool enabled);

  /// 切前后置（老端 `exchangeVideo`）
  Future<void> toggleCamera();

  /// 免提开关（老端 `speakBtn`：`plus.audio.setRoute(ROUTE_SPEAKER / ROUTE_EARPIECE)`）。
  ///
  /// 只做「切换到扬声器 / 切回听筒」这一件事；蓝牙、音频会话与前台服务属于 S6.4，
  /// 到那一步再把这个方法换成完整的路由策略。
  Future<void> setSpeakerEnabled(bool enabled);

  /// 屏幕共享（S6.7）在这台设备上能不能用。
  ///
  /// 安卓（MediaProjection）与桌面（Windows/Linux/macOS，走原生的
  /// `getDisplayMedia`）都有；iOS 要 ReplayKit 的广播扩展，属于以后的事。
  /// 界面据此决定要不要画那颗「共享屏幕」按钮 —— 画一颗点不动的按钮比不画更糟。
  bool get supportsScreenShare;

  /// 请求投屏授权（系统那个「开始投屏 / 录制」框）。用户点了拒绝返回 false。
  ///
  /// ⚠️ 顺序是硬要求（Android 14）：**必须先拿到这份同意，再把前台服务类型升上
  /// `mediaProjection`，最后才 [startScreenShare]**。原因见 S6.7：`getMediaProjection()`
  /// 要求「取投影之前已经有一个 mediaProjection 类型的前台服务在跑」。
  /// 插件把这份同意存在自己内部，所以同意之后再取流**不会弹第二次框**。
  Future<bool> requestScreenSharePermission();

  /// 开始共享屏幕：取屏幕流，把**发出去的那一路画面**换成屏幕。
  ///
  /// 只换发送端（`replaceTrack`），**不重新协商 SDP** —— 对端只是「看到不同的画面」，
  /// 协议、服务端一行都不用改。
  ///
  /// [sourceId] 是桌面上「共享哪一块」的选择（整个屏幕 / 某个窗口）：它来自
  /// `desktopCapturer.getSources()`，直接当成 `deviceId.exact` 传给原生。
  /// 不传就是系统的默认源（Windows/Linux 下就是主屏）。安卓那条路不认它。
  /// [withAudio] = 同时把**电脑的声音**也发过去（桌面；Windows 上是 WASAPI 环路：
  /// 共享整个屏幕 = 全部系统声音，共享某个窗口 = 只抓那个程序的声音）。
  ///
  /// 返回「声音最后怎么发的」（[ScreenShareAudioRoute]）—— 界面据此提一嘴
  /// （比如退成了替换麦克风时要说不说话）。画面那条路任何时候都一样。
  Future<ScreenShareAudioRoute> startScreenShare({
    String? sourceId,
    bool withAudio = false,
  });

  /// 停止共享：把画面换回摄像头，放掉屏幕流。
  Future<void> stopScreenShare();

  /// 这次通话实际用的 ICE 服务器（一句话描述，诊断面板原样显示）。
  ///
  /// 站点后台那栏填错是**最容易发生也最难看出来**的问题（少个 `stun:` 前缀就
  /// 整条连接建不起来），所以把它一字不差地摆出来。
  List<String> get iceServersDescription;

  /// 取一次媒体统计（RTT / 丢包 / 码率 / 选中的候选对）。
  ///
  /// 诊断专用：**任何失败都返回空采样，绝不抛** —— 一个排查工具把通话搞崩
  /// 就本末倒置了。老端一次都没调过 `getStats`（所以它那边打不通只能靠猜）。
  Future<CallMediaSample> sampleStats();

  /// 当前本地流（界面拿它喂 `RTCVideoRenderer`）
  MediaStream? get localStream;

  /// 当前远端流
  MediaStream? get remoteStream;

  /// 本机有没有摄像头的那路 track（决定界面要不要画「切摄像头」按钮）
  bool get hasLocalVideo;

  /// 挂断后收尾：停本机媒体、关连接（老端 `closeLocalMedia` + `pc.close()`）
  Future<void> close();

  set onLocalStream(void Function(MediaStream stream)? handler);

  set onRemoteStream(void Function(MediaStream stream)? handler);

  set onIceCandidate(void Function(Map<String, dynamic> candidate)? handler);

  /// ICE 连通（老端是 WebView 里 `connectionState` 变化，它没监听——见刻意差异）
  set onConnected(void Function()? handler);

  /// 连接失败（老端完全不处理，通话就那么僵着）
  set onConnectionFailed(void Function(Object error)? handler);
}

/// 真机实现：`flutter_webrtc`。
///
/// 只做「把老端那套指令翻译成插件调用」，不含任何时序/状态判断（那些都在
/// `CallMachine` 与 `CallController` 里）。
class WebrtcCallMediaEngine implements CallMediaEngine {
  WebrtcCallMediaEngine({required List<Map<String, dynamic>> iceServers})
    : _iceServersSource = (() => iceServers),
      // 固定列表这条构造不接 TURN 凭据（测试与老用法用它）
      _turnIceServersSource = null;

  /// ICE 列表改成**要的时候再算**。
  ///
  /// 为什么需要这个构造：provider 那边过去是 `ref.watch(sessionStoreProvider)` ——
  /// 于是「配置热更新 / 多端标记 / 改设置」都会重建引擎，而 `callControllerProvider`
  /// 又 watch 了引擎，**正在进行的通话会被整个重建**（控制器被 dispose：铃声停、
  /// 通话页变孤儿、点接听抛「Ref … after it has been disposed」）。
  /// 改成惰性之后 provider 不再盯任何会变的东西，而「建连接时读当前配置」的效果
  /// 与原来那句「热更新对下一通电话生效」完全一致。
  WebrtcCallMediaEngine.withLazyIceServers({
    required List<Map<String, dynamic>> Function() iceServers,
    Future<List<Map<String, dynamic>>> Function()? turnIceServers,
  }) : _iceServersSource = iceServers,
       _turnIceServersSource = turnIceServers;

  final List<Map<String, dynamic>> Function() _iceServersSource;

  /// 服务端签发的 TURN 凭据（可选）。拿不到就返回空列表，见 [resolveIceServers]。
  final Future<List<Map<String, dynamic>>> Function()? _turnIceServersSource;

  /// `RTCPeerConnection` 的 `iceServers`（由 `CallMediaConfig.iceServers` 算出来）。
  ///
  /// 这只是**站内那份**（公共 STUN + 站点后台那栏）；真正建连接用的是
  /// [resolveIceServers]（还会把服务端签发的 TURN 凭据并进来）。
  List<Map<String, dynamic>> get iceServers => _iceServersSource();

  /// 这条连接实际用过的那份 ICE 列表（[resolveIceServers] 的结果）。
  /// 建完连接才有值；诊断面板靠它回答「TURN 到底有没有用上」。
  List<Map<String, dynamic>>? _activeIceServers;

  /// 建连接时真正交给插件的那份 ICE 列表：站点那份 + 服务端签发的 TURN 凭据。
  ///
  /// 单独抽成一个方法是为了**能测**：`_open()` 里那几行都要平台通道，
  /// 而「哪些服务器进了这条连接」是纯逻辑。
  ///
  /// 凭据取不到（没配 / 网络错 / 报文不对）时**原样返回站点那份** ——
  /// TURN 只是兜底，不能因为它让一通电话打不出去。
  Future<List<Map<String, dynamic>>> resolveIceServers() async {
    final base = iceServers;
    final turn = _turnIceServersSource;
    if (turn == null) return base;
    List<Map<String, dynamic>> extra;
    try {
      extra = await turn();
    } catch (error) {
      debugPrint('[通话] 取 TURN 凭据失败（改用只有 STUN 的列表）：$error');
      return base;
    }
    if (extra.isEmpty) return base;
    return <Map<String, dynamic>>[...base, ...extra];
  }

  RTCPeerConnection? _pc;
  MediaStream? _local;
  MediaStream? _remote;

  /// 屏幕流（只在共享期间有）
  MediaStream? _display;

  /// 这一次共享的是哪个源（桌面才有；安卓上是 null）/ 要不要电脑的声音。
  /// 被共享的窗口最小化又回来时要**按同一份口径**重建采集（见
  /// `desktop_screen_capture.dart`）。
  String? _displaySourceId;
  bool _displayWithAudio = false;

  /// 盯着「被共享的那扇窗」：最小化 / 藏起来之后再回来 → 重建采集
  SharedWindowWatch? _windowWatch;

  /// 正在重建采集（防止两次重建叠在一起）
  bool _rebuildingDisplay = false;

  /// 换到屏幕之前的那条摄像头轨（停共享时换回来）
  MediaStreamTrack? _cameraTrack;

  /// 共享之前摄像头是开着还是关着（停共享时按原样恢复）
  bool _cameraWasEnabled = true;

  /// **预协商出来的那条空音频 m-line**上的发送端（S12.32）。
  ///
  /// 「共享电脑的声音」要能**在通话中**发出去，而通话中加一条轨就得再走一轮
  /// offer/answer（信号 + 两端都得接）—— 所以改成**建立连接时就多摆一条空音频
  /// m-line**（只有主叫摆得出来：answer 里不允许加 m-line，被叫是把 offer 里
  /// 这条的方向改成 sendrecv，见 [acceptOffer]），之后共享时只要 `replaceTrack`
  /// 把 loopback 挂上去就行：**协议一行不改，也不用重新协商**。
  ///
  /// 对面客户端版本旧（它的 offer 里没这条空轨）时它是 null —— 那时退成
  /// 「把麦克风那条换成电脑声音」（见 [_attachShareAudio]）。
  RTCRtpSender? _spareAudioSender;

  /// 退成「替换麦克风」时替下来的那条麦克风轨（停共享时换回去）
  MediaStreamTrack? _micTrack;

  /// 正在进行的取流。并发调 [open] 会等这一次，而不是各自再建一条连接
  /// （“媒体就绪”与“对方信令”是两条独立的线，重复调很容易发生）。
  Future<void>? _opening;

  /// 远端描述（offer / answer）还没设上时先攒着的远端候选。
  ///
  /// ⚠️ 时序上这些候选**一定会早到**：对端在自己 `setLocalDescription` 之后就开始
  /// 一条条发候选，而我们要等它的 SDP 到了才能 `setRemoteDescription`。
  /// 原来早到的候选是**直接丢掉**的 —— 真机上表现为「候选发给对方了、对方也发了，
  /// 却怎么都连不上」（缺的往往就是最管用的那几条直连候选）。
  final List<RTCIceCandidate> _pendingRemoteCandidates = <RTCIceCandidate>[];

  /// 远端描述设好了没（`addCandidate` 必须在它之后才有效）
  bool _remoteDescriptionSet = false;

  void Function(MediaStream stream)? _onLocalStream;
  void Function(MediaStream stream)? _onRemoteStream;
  void Function(Map<String, dynamic> candidate)? _onIceCandidate;
  void Function()? _onConnected;
  void Function(Object error)? _onConnectionFailed;

  @override
  set onLocalStream(void Function(MediaStream stream)? handler) =>
      _onLocalStream = handler;

  @override
  set onRemoteStream(void Function(MediaStream stream)? handler) =>
      _onRemoteStream = handler;

  @override
  set onIceCandidate(void Function(Map<String, dynamic> candidate)? handler) =>
      _onIceCandidate = handler;

  @override
  set onConnected(void Function()? handler) => _onConnected = handler;

  @override
  set onConnectionFailed(void Function(Object error)? handler) =>
      _onConnectionFailed = handler;

  /// 本机画面。
  ///
  /// 共享屏幕期间给的是**屏幕流**：自己屏幕上看到的那个小窗就是发出去的内容
  /// （微信也一样），不然用户没法确认「对方看到的是不是这块屏」。
  @override
  MediaStream? get localStream => _display ?? _local;

  @override
  MediaStream? get remoteStream => _remote;

  @override
  bool get hasLocalVideo =>
      _local?.getVideoTracks().any((track) => track.enabled) ?? false;

  @override
  Future<void> open({required bool video}) {
    final opening = _opening;
    if (opening != null) return opening;
    if (_pc != null) {
      // 已经开过（重复回调）就别再建一条连接，老端 WebView 也只会建一次
      return Future<void>.value();
    }
    late final Future<void> future;
    future = _open(video: video).whenComplete(() {
      if (identical(_opening, future)) _opening = null;
    });
    _opening = future;
    return future;
  }

  Future<void> _open({required bool video}) async {
    RTCPeerConnection? pc;
    MediaStream? stream;
    try {
      // 站内那份 + 服务端签发的 TURN 凭据（拿不到就是站内那份，见 resolveIceServers）
      final servers = await resolveIceServers();
      // 记住实际用的这份：诊断面板显示它（建完连接才知道 TURN 有没有用上）
      _activeIceServers = servers;
      pc = await createPeerConnection(<String, dynamic>{
        'iceServers': servers,
        // 与老端浏览器的默认一致（现代浏览器与插件都是 unified-plan，
        // 显式写出来是为了以后插件换默认值时行为不变）
        'sdpSemantics': 'unified-plan',
      });
      // **建完先确认它真的活着**（这一步能救命，见下）。
      await _ensureAlive(pc);
      pc.onIceCandidate = _handleIceCandidate;
      pc.onTrack = _handleTrack;
      pc.onConnectionState = _handleConnectionState;
      // **连接一把建出来就先摆到 [_pc] 上**：对端的候选与 SDP 都可能来得比本机
      // 媒体还早（视频取摄像头要 1~3 秒），连接不摆出来它们就没地方落。
      _pc = pc;

      stream = await navigator.mediaDevices.getUserMedia(
        CallMediaConfig.localMediaConstraints(
          video: video,
          facingMode: CameraFacing.front,
        ),
      );
      if (!identical(_pc, pc)) {
        // 取流途中这通电话已经结束了（`close()` 把连接关掉了）：别往一条已经关掉的
        // 连接上挂轨道，把流放掉、按「取不到媒体」收尾（那条错误路径是幂等的）。
        await _safeDispose(stream);
        throw const CallMediaException('取流途中通话已结束');
      }
      for (final track in stream.getTracks()) {
        await pc.addTrack(track, stream);
      }
    } catch (error) {
      // 拿不到媒体（没权限/没设备）或建连接失败：把半成品收干净再抛，
      // 不然下一次通话会拿到一条残废的连接。
      //
      // 清理都带「还是这条连接吗」的判断：取流很慢，这段窗口里可能已经有
      // **下一通电话**把 [_pc] 换成了一条新连接，不能把它的东西清掉。
      await _safeDispose(stream);
      final broken = pc;
      if (identical(_pc, broken)) {
        _pc = null;
        _remoteDescriptionSet = false;
        _pendingRemoteCandidates.clear();
      }
      await _safeClose(broken);
      // 自检那条（ICE 地址不合法）已经带了准确的原因，原样往上抛
      if (error is CallMediaException) rethrow;
      throw CallMediaException(
        '打开本机媒体失败',
        error,
        classifyMediaFailure(error, video: video),
      );
    }

    _local = stream;
    _onLocalStream?.call(stream);
  }

  @override
  Future<String> createOffer({required bool video}) async {
    final pc = _requireConnection();
    try {
      // 摆一条**空的音频 m-line**（见 [_spareAudioSender]）。必须在 createOffer
      // 之前摆：它得出现在这一份 offer 里 —— 错过这一次就只剩「重新协商」那条路了。
      await _prepareSpareAudio(pc);
      final offer = await pc.createOffer(
        CallMediaConfig.sdpConstraints(video: video),
      );
      await pc.setLocalDescription(offer);
      final sdp = offer.sdp;
      if (sdp == null || sdp.isEmpty) {
        throw const CallMediaException('本机 offer 是空的');
      }
      // 诊断（S12.34）：本机 offer 里每条 m-line 是发是收。方向不对的话，
      // 后面无论摄像头多正常都发不出去（事后 addTrack 不会自己生效）。
      debugPrint('[通话] 本机 offer：${describeSdpDirections(sdp)}');
      return sdp;
    } on CallMediaException {
      rethrow;
    } catch (error) {
      throw CallMediaException('创建 offer 失败', error);
    }
  }

  @override
  Future<String> acceptOffer(String sdp, {required bool video}) async {
    final pc = _requireConnection();
    try {
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      _remoteDescriptionSet = true;
      await _flushRemoteCandidates();
      // 对面（主叫）摆的那条空音频 m-line：把它接过来（见 [_spareAudioSender]）
      await _adoptSpareAudio(pc);
      final answer = await pc.createAnswer(
        CallMediaConfig.sdpConstraints(video: video),
      );
      await pc.setLocalDescription(answer);
      final text = answer.sdp;
      if (text == null || text.isEmpty) {
        throw const CallMediaException('本机 answer 是空的');
      }
      // 诊断（S12.34）：answer 里视频要是 `recvonly`，对方就永远看不到我们。
      debugPrint('[通话] 本机 answer：${describeSdpDirections(text)}');
      return text;
    } on CallMediaException {
      rethrow;
    } catch (error) {
      throw CallMediaException('响应 offer 失败', error);
    }
  }

  @override
  Future<void> applyAnswer(String sdp) async {
    final pc = _requireConnection();
    try {
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      _remoteDescriptionSet = true;
      // 诊断（S12.34）：对方 answer 里那几条 m-line 的方向（我们发得出去吗）
      debugPrint('[通话] 对方 answer：${describeSdpDirections(sdp)}');
      await _logSenders(pc, '正式协商后');
      await _flushRemoteCandidates();
    } catch (error) {
      throw CallMediaException('设置对方 answer 失败', error);
    }
  }

  @override
  Future<void> addIceCandidate(Map<String, dynamic> candidate) async {
    final pc = _pc;
    if (pc == null) return;
    final fields = pickIceCandidateFields(candidate);
    final raw = fields['candidate'];
    if (raw is! String || raw.isEmpty) return;
    final parsed = RTCIceCandidate(
      raw,
      fields['sdpMid'] as String?,
      fields['sdpMLineIndex'] as int?,
    );
    if (!_remoteDescriptionSet) {
      // 远端描述还没设上：先攒着（见 [_pendingRemoteCandidates]）
      _pendingRemoteCandidates.add(parsed);
      return;
    }
    await _addCandidate(pc, parsed);
  }

  /// 一条候选真的加进去（单条失败不该让整通话崩掉：对方可能发来已废弃的候选）
  Future<void> _addCandidate(
    RTCPeerConnection pc,
    RTCIceCandidate candidate,
  ) async {
    try {
      await pc.addCandidate(candidate);
    } catch (error) {
      debugPrint('[通话] 加 ICE 候选失败：$error');
    }
  }

  /// 远端描述设好之后，把先前攒下的候选按顺序补进去
  Future<void> _flushRemoteCandidates() async {
    final pc = _pc;
    if (pc == null || _pendingRemoteCandidates.isEmpty) return;
    final pending = List<RTCIceCandidate>.of(_pendingRemoteCandidates);
    _pendingRemoteCandidates.clear();
    for (final candidate in pending) {
      await _addCandidate(pc, candidate);
    }
  }

  @override
  void setMicrophoneEnabled(bool enabled) {
    // 老端 `switchVoice`：遍历 audio track 改 `enabled`
    for (final track
        in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
  }

  @override
  void setCameraEnabled(bool enabled) {
    for (final track
        in _local?.getVideoTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
  }

  @override
  Future<void> toggleCamera() async {
    final track = _local?.getVideoTracks().firstOrNull;
    if (track == null) {
      throw const CallMediaException('没有可切换的摄像头');
    }
    try {
      // 老端是「停掉旧 track → 重新 getUserMedia → replaceTrack」，新端用插件自带的
      // 切换（同一条 track 换摄像头源）。差异记在规划书 S6.2：省掉一次取流，
      // 也不会像老端那样把音频 track 一起换掉（那样静音状态会被重置）。
      await Helper.switchCamera(track);
    } catch (error) {
      throw CallMediaException('切换摄像头失败', error);
    }
  }

  /// 免提开关（听筒 ↔ 扬声器）。
  ///
  /// ⚠️ 桌面（Windows / Linux）**没有这条路由**：声音永远从系统输出走，而插件的
  /// `enableSpeakerphone` 只在 Apple 与 Android 那两份原生实现里接了方法
  /// （`common/darwin/Classes/FlutterWebRTCPlugin.m`），Windows/Linux 调它必抛
  /// `MissingPluginException`。
  ///
  /// 2026-10-05 真机踩到的后果**远不止**「少切一次路由」：独立通话窗里这颗钮一
  /// 抛错，主窗口那条媒体通道就把整通电话判成「窗口没应答」，退回主窗口里的引擎
  /// （`CallWindowMediaEngine.degraded`）—— 通话窗当场变成一具空壳、界面又跑回
  /// 主窗口，白开一扇窗。所以「平台没实现」在这里当**成功**：桌面这一档本来就
  /// 等于「外放」。
  @override
  Future<void> setSpeakerEnabled(bool enabled) async {
    try {
      await Helper.setSpeakerphoneOn(enabled);
    } on MissingPluginException {
      // 平台没有这条路由：不是错误，也不必报给上层（见上面的说明）
    } catch (error) {
      throw CallMediaException('切换扬声器失败', error);
    }
  }

  /// 屏幕共享（S6.7）：安卓的系统投屏；桌面走原生的 `getDisplayMedia`（不用授权框）
  @override
  bool get supportsScreenShare =>
      !kIsWeb &&
      (Platform.isAndroid ||
          Platform.isWindows ||
          Platform.isMacOS ||
          Platform.isLinux);

  @override
  Future<bool> requestScreenSharePermission() async {
    // 桌面（Windows/Linux）不需要任何授权：原生的桌面捕获直接就能取。
    // `Helper.requestCapturePermission` 只有 Android/macOS 接了
    // （在别的平台上它会抛「only support for Android/macOS」），所以这里
    // 先把它择出去 —— macOS 确实要系统那一下授权，依旧走插件。
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) return true;
    try {
      // 安卓/macOS 才有这条；`fullScreenOnly: false` = 保留系统默认的那个
      // 「整个屏幕 / 单个应用」选择框（Android 14 上用户可选只共享一个应用）
      return await Helper.requestCapturePermission(fullScreenOnly: false);
    } catch (error) {
      throw CallMediaException('请求投屏授权失败', error);
    }
  }

  @override
  Future<ScreenShareAudioRoute> startScreenShare({
    String? sourceId,
    bool withAudio = false,
  }) async {
    final pc = _requireConnection();
    final camera = _local?.getVideoTracks().firstOrNull;
    if (camera == null) {
      throw const CallMediaException('这通电话没有视频轨，不能共享屏幕');
    }
    final sender = await _videoSender(pc);
    if (sender == null) {
      throw const CallMediaException('找不到视频发送端，不能共享屏幕');
    }

    MediaStream? display;
    try {
      // 桌面（Windows/Linux）：带上选中的那个源。原生的 `getDisplayMedia` 读的是
      // `video -> deviceId -> exact`（见插件 `flutter_screen_capture.cc`），
      // 不给就是用默认源（主屏）。「选整个屏幕 / 选某个窗口」那一步见
      // `screen_share_picker.dart`（`desktopCapturer.getSources()` 拿列表）。
      //
      // `audio: withAudio` 是**电脑的声音**（S12.32）：Windows 上原生那套是
      // WASAPI 环路（`ApplicationLoopbackCapturer`）—— 共享整个屏幕 = 全部系统
      // 声音，共享某个窗口 = 按 PID 只抓那个程序的声音。拿到的那条音频轨怎么发
      // 出去见 [_attachShareAudio]。
      display = await captureDesktopScreen(
        sourceId: sourceId,
        withAudio: withAudio,
      );
      final screen = display.getVideoTracks().firstOrNull;
      if (screen == null) {
        throw const CallMediaException('屏幕流里没有画面');
      }
      await sender.replaceTrack(screen);
      // 诊断（S12.34）：共享那一刻，发送端上挂的到底是哪条轨（画面发不出去时看这一行）
      await _logSenders(pc, '换屏幕轨后');
      _cameraTrack = camera;
      _cameraWasEnabled = camera.enabled;
      // 共享期间把摄像头**停掉**（指示灯熄灭、也不再采画面）：这一刻发出去的只有屏幕，
      // 摄像头那路留着只会让用户以为「对方还能看到我的脸」（用户真机试出来的）
      camera.enabled = false;
      _display = display;
      _displaySourceId = sourceId;
      _displayWithAudio = withAudio;
      // 共享的是**某一个窗口**时盯住它：最小化 / 藏进托盘之后再回来，底层那条
      // GDI 采集回来之后也不再出画面，只能重建采集（见 [_rebuildScreenCapture]）。
      _watchShareWindow();
      // 声音那一路（要与不要、以及最后怎么发出去）—— 与画面无关，画面该发照发
      final audioRoute = withAudio
          ? await _attachShareAudio(pc, display)
          : ScreenShareAudioRoute.off;
      // 本机预览跟着换（见 [localStream] 的注释）
      _onLocalStream?.call(display);
      return audioRoute;
    } catch (error) {
      _cameraTrack = null;
      _display = null;
      await _safeDispose(display);
      if (error is CallMediaException) rethrow;
      throw CallMediaException('开始共享屏幕失败', error);
    }
  }

  @override
  Future<void> stopScreenShare() async {
    _windowWatch?.stop();
    final display = _display;
    final camera = _cameraTrack;
    _display = null;
    _cameraTrack = null;
    // 摄像头恢复共享前的开关状态（共享期间那颗钮是灰的，所以这个值就是用户的意思）
    if (camera != null) camera.enabled = _cameraWasEnabled;

    // 换回摄像头（失败也只是「对方那边停在最后一帧」，不该把通话弄断）
    final pc = _pc;
    if (pc != null) {
      if (camera != null) {
        try {
          final sender = await _videoSender(pc);
          await sender?.replaceTrack(camera);
        } catch (error) {
          debugPrint('[通话] 停共享时换回摄像头失败：$error');
        }
      }
      // 声音那一路也要还回去（单独那条摘下来 / 麦克风换回来）
      await _detachShareAudio(pc);
    }
    await _safeDispose(display);
    final local = _local;
    if (local != null) _onLocalStream?.call(local);
  }

  /// 盯住「被共享的那扇窗」（只对窗口源做，见 `shared_window_watch.dart`）
  void _watchShareWindow() {
    _windowWatch?.stop();
    _windowWatch = watchSharedWindow(
      sourceId: _displaySourceId,
      onRestored: () => unawaited(_rebuildScreenCapture()),
    );
  }

  /// 被共享的窗口回来了：**重建一次采集**，把新画面挂回**同一个发送端**上。
  ///
  /// 根因与「先放旧的再取新的」那个硬顺序见 `desktop_screen_capture.dart`：
  /// 采集器本体（预编译 libwebrtc 里的 `WindowCapturerWin`，没开 WGC）在窗口
  /// 最小化期间拿不到新表面，回来之后也不会自己恢复 —— 对方就永远停在最后一帧。
  ///
  /// 这里**不重新协商**：新轨只是 `replaceTrack` 挂到原来那条发送端上，协议与
  /// 对面客户端一行都不用改（1:1 与群通话两条路都是这个口径）。
  Future<void> _rebuildScreenCapture() async {
    final pc = _pc;
    final old = _display;
    if (pc == null || old == null || _rebuildingDisplay) return;
    _rebuildingDisplay = true;
    _windowWatch?.stop(); // 等新的取到了再重新盯
    try {
      final fresh = await recaptureDesktopScreen(
        sourceId: _displaySourceId,
        withAudio: _displayWithAudio,
        disposeOld: () async {
          _display = null;
          await _safeDispose(old);
        },
      );
      _display = fresh;
      final screen = fresh.getVideoTracks().firstOrNull;
      final sender = await _videoSender(pc);
      if (screen == null || sender == null) {
        throw StateError('新流里没有画面 / 找不到视频发送端');
      }
      await sender.replaceTrack(screen);
      await _logSenders(pc, '重建共享采集后');
      // 声音那一路：旧那条环路轨随旧采集停掉了，新流里那条要重新挂上去
      if (_displayWithAudio) await _attachShareAudio(pc, fresh);
      _watchShareWindow();
      // 本机预览跟着换（那个小窗里就是发出去的内容）
      _onLocalStream?.call(fresh);
      debugPrint('[通话] 共享窗口回来了，已重建采集（换到新轨）');
    } catch (error) {
      debugPrint('[通话] 共享窗口回来重建采集失败（画面停在最后一帧）：$error');
    } finally {
      _rebuildingDisplay = false;
    }
  }

  /// 打一行「现在哪几条轨挂在发送端上」（诊断用，**永不抛** —— 它绝不能让
  /// 共享屏幕这种正经动作失败）。S12.34
  Future<void> _logSenders(RTCPeerConnection pc, String tag) async {
    try {
      final senders = await pc.getSenders();
      final text = senders.isEmpty
          ? '（一个都没有）'
          : senders
                .map((sender) {
                  final track = sender.track;
                  if (track == null) return '空轨';
                  return '${track.kind}(enabled=${track.enabled})';
                })
                .join(' + ');
      debugPrint('[通话] $tag 的发送端：$text');
    } catch (error) {
      debugPrint('[通话] $tag 的发送端打不出来：$error');
    }
  }

  /// 找「发出去的那条视频轨」的发送端（换轨用）
  Future<RTCRtpSender?> _videoSender(RTCPeerConnection pc) async {
    for (final sender in await pc.getSenders()) {
      if (sender.track?.kind == 'video') return sender;
    }
    return null;
  }

  /// 找**麦克风**那条发送端（共享声音退成「替换麦克风」那条路时用）。
  ///
  /// 那条空音频 m-line 上的发送端（[_spareAudioSender]）要排掉：它也是音频
  /// 发送端，但不是麦克风那一条（插件每次 `getSenders()` 都给新对象，所以按
  /// `senderId` 而不是对象认）。
  Future<RTCRtpSender?> _audioSender(RTCPeerConnection pc) async {
    final spare = _spareAudioSender?.senderId;
    for (final sender in await pc.getSenders()) {
      if (sender.track?.kind != 'audio') continue;
      if (spare != null && sender.senderId == spare) continue;
      return sender;
    }
    return null;
  }

  /// 主叫：在 offer 里摆一条**空的音频 m-line**（见 [_spareAudioSender]）。
  /// 必须在 `createOffer` 之前叫 —— 它得出现在这一份 offer 里。
  Future<void> _prepareSpareAudio(RTCPeerConnection pc) async {
    if (_spareAudioSender != null) return;
    final stream = _local;
    try {
      final transceiver = await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(
          direction: TransceiverDirection.SendRecv,
          streams: stream == null ? null : <MediaStream>[stream],
        ),
      );
      _spareAudioSender = transceiver.sender;
      debugPrint('[通话] 摆了一条空音频轨（共享电脑声音以后走它）');
    } catch (error) {
      // 摆不上就算了：共享声音时退成「把麦克风换成电脑声音」（见 [_attachShareAudio]）
      debugPrint('[通话] 空音频轨没摆上（共享声音会退成替换麦克风）：$error');
    }
  }

  /// 被叫：把对面 offer 里那条空音频 m-line 接过来。
  ///
  /// answer 里不允许加 m-line，所以被叫只能给**现成的那条**改方向（`sendrecv`）
  /// —— 改完它双向都能用：对面能发，我们以后共享电脑声音时也能发。
  /// 「空的那条」= 还没挂轨道的音频 m-line（麦克风与摄像头那两条都挂着轨道）。
  Future<void> _adoptSpareAudio(RTCPeerConnection pc) async {
    if (_spareAudioSender != null) return;
    try {
      for (final transceiver in await pc.getTransceivers()) {
        if (transceiver.sender.track != null) continue;
        if (transceiver.receiver.track?.kind != 'audio') continue;
        await transceiver.setDirection(TransceiverDirection.SendRecv);
        _spareAudioSender = transceiver.sender;
        debugPrint('[通话] 接下了对面那条空音频轨（共享电脑声音走它）');
        return;
      }
      debugPrint('[通话] 对面 offer 里没有空音频轨（对面版本旧？共享声音会退成替换麦克风）');
    } catch (error) {
      debugPrint('[通话] 接那条空音频轨失败（共享声音会退成替换麦克风）：$error');
    }
  }

  /// 把屏幕流里那路**电脑声音**发出去（返回值见 [ScreenShareAudioRoute]）。
  ///
  /// 优先走那条预协商的空音频轨（[_spareAudioSender]）：麦克风照旧在发，对方
  /// **同时**听得到你的声音与电脑的声音。对面版本旧（它的 offer 里没空轨）时
  /// 退成「把麦克风那条换成电脑声音」—— 这阵子对方听不到你说话，停共享换回。
  Future<ScreenShareAudioRoute> _attachShareAudio(
    RTCPeerConnection pc,
    MediaStream display,
  ) async {
    final loopback = display.getAudioTracks().firstOrNull;
    if (loopback == null) {
      // 这台机器上取不到 loopback（音频设备被独占 / 系统挡住）：这次只共享画面
      debugPrint('[通话] 屏幕流里没有音频轨（这台机器上取不到电脑声音）');
      return ScreenShareAudioRoute.unavailable;
    }
    try {
      final spare = _spareAudioSender;
      if (spare != null) {
        await spare.replaceTrack(loopback);
        return ScreenShareAudioRoute.separate;
      }
      final mic = _local?.getAudioTracks().firstOrNull;
      final sender = await _audioSender(pc);
      if (mic == null || sender == null) {
        return ScreenShareAudioRoute.unavailable;
      }
      await sender.replaceTrack(loopback);
      _micTrack = mic;
      return ScreenShareAudioRoute.microphone;
    } catch (error) {
      debugPrint('[通话] 电脑声音没接上（这次只共享画面）：$error');
      return ScreenShareAudioRoute.unavailable;
    }
  }

  /// 停共享：声音那一路也还回去（单独那条摘下来；换了麦克风那条换回来）。
  ///
  /// 失败也只是「对方停在最后一段声音」，**不该把通话弄断**。
  Future<void> _detachShareAudio(RTCPeerConnection pc) async {
    final spare = _spareAudioSender;
    if (spare != null) {
      try {
        await spare.replaceTrack(null);
      } catch (error) {
        debugPrint('[通话] 摘下电脑声音失败（对方那边停在最后一段）：$error');
      }
    }
    final mic = _micTrack;
    _micTrack = null;
    if (mic == null) return;
    try {
      final sender = await _audioSender(pc);
      await sender?.replaceTrack(mic);
    } catch (error) {
      debugPrint('[通话] 换回麦克风失败（对方那边停在最后一段）：$error');
    }
  }

  @override
  List<String> get iceServersDescription =>
      describeIceServers(_activeIceServers ?? iceServers);

  @override
  Future<CallMediaSample> sampleStats() async {
    final pc = _pc;
    if (pc == null) return const CallMediaSample();
    try {
      return parseCallMediaSample(await pc.getStats());
    } catch (error) {
      debugPrint('[通话] 取媒体统计失败：$error');
      return const CallMediaSample();
    }
  }

  @override
  Future<void> close() async {
    _windowWatch?.stop();
    final pc = _pc;
    _pc = null;
    _remoteDescriptionSet = false;
    _pendingRemoteCandidates.clear();
    // 先把引用**摘下来再释放**（不能在 `await` 之后再置空）：`close()` 会被两条
    // 路叫到（媒体通道那条 `close` 与通话窗那条 `bye`），第二条路拿到的应该是
    // null，而不是同一个流再放一遍。
    final display = _display;
    final local = _local;
    _display = null;
    _local = null;
    _cameraTrack = null;
    // 会话结束：那条空音频 m-line 上的发送端引用与退路用的麦克风轨都放掉
    // （连接本身紧跟着就 `pc.close()` 了，这里只是别让下一通电话拿到旧对象）
    _spareAudioSender = null;
    _micTrack = null;
    // 屏幕流也要放掉，否则共享的那块屏会一直被投着（用户会看到「正在投屏」的标记）
    await _safeDispose(display);
    await _safeDispose(local);
    // ⚠️ **对方那一路不释放**（2026-10-05 真机）。它不属于本机：那是
    // `PeerConnection` 收到的流，原生侧只把它挂在连接上；而 `streamDispose`
    // 那条方法**只认本机流** —— Dart 的 `MediaStreamNative.dispose()` 只传
    // `streamId`，C++ 那边 `MediaStreamDispose` 拿不到 `ownerTag`，于是只查
    // `FlutterWebRTCBase::local_streams_`，对方那路永远查不到。
    //
    // 结果就是每通接过对方流的电话，挂断时日志里都有一条
    // `释放媒体流失败：PlatformException(MediaStreamDisposeFailed, stream [xxx]
    // not found!)`。对方那一路由紧跟着的 `pc.close()/dispose()` 一并收掉，
    // 这里再点一次纯属多此一举（只把 `_remote` 的引用放掉）。
    _remote = null;
    await _safeClose(pc);
  }

  // ------------------------------------------------------------------ 内部

  /// 建完连接之后摸一下，确认它不是个空壳。
  ///
  /// ⚠️ **2026-09-19 真机上踩出来的坑**：ICE 服务器地址不合法时（站点后台那栏
  /// 填了 `stun.cloudflare.com:3478`，**没带 `stun:` 前缀**），原生 WebRTC 直接
  /// 建不出连接，`createPeerConnection` 返回空对象 —— 但**插件不检查**，照旧回一个 id。
  /// 接着 `getUserMedia` 会遍历所有连接去查 track id，撞上这个空壳就是一个
  /// **不可捕获的 Java NPE**：应用当场闪退（日志里是
  /// `PeerConnectionObserver.getTransceiversTrack ... getTransceivers() on a null object reference`）。
  ///
  /// 所以这里主动花一次极便宜的调用把空壳揪出来，让它走「提示 + 结束这通电话」的
  /// 正常错误路径，而不是让整个应用死掉。
  /// （地址本体会在 `CallMediaConfig.normalizeIceUrl` 里补全，这里是道保险。）
  Future<void> _ensureAlive(RTCPeerConnection pc) async {
    try {
      await pc.getTransceivers();
    } catch (error) {
      throw CallMediaException('建连接失败（ICE 服务器地址可能不合法）', error);
    }
  }

  RTCPeerConnection _requireConnection() {
    final pc = _pc;
    if (pc == null) {
      throw const CallMediaException('PeerConnection 还没建立');
    }
    return pc;
  }

  void _handleIceCandidate(RTCIceCandidate candidate) {
    final raw = candidate.candidate;
    if (raw == null || raw.isEmpty) return; // 收集结束的那条空候选不用发
    _onIceCandidate?.call(<String, dynamic>{
      'candidate': raw,
      'sdpMid': candidate.sdpMid,
      'sdpMLineIndex': candidate.sdpMLineIndex,
    });
  }

  Future<void> _handleTrack(RTCTrackEvent event) async {
    final streams = event.streams;
    // 诊断（S12.34）：远端每一路轨到了就打一行 —— 「对方画面看不到」时
    // 第一件要分清的事就是「视频轨到底到了没有」。
    final track = event.track;
    debugPrint(
      '[通话] 远端轨到了：kind=${track.kind} id=${track.id} '
      'streams=${streams.isEmpty ? '（没有 stream）' : streams.map((s) => '${s.id}(${s.getTracks().length} 条)').join(' / ')}',
    );
    switch (chooseRemoteStreamAction(
      trackHasStream: streams.isNotEmpty,
      trackKind: track.kind ?? '',
      remoteHasVideo: _remoteHasVideo,
    )) {
      case RemoteStreamAction.adoptProvided:
        _remote = streams.first;
        _onRemoteStream?.call(streams.first);
      case RemoteStreamAction.ignore:
        // 没有 `msid`、又不是画面轨：多半是「多出来的那一路」（那条预留的
        // 空音频 m-line），或者是插件替没用上的 m-line 报的幻影轨。
        // ⚠️ **绝不能拿它盖掉 [_remote]** —— 那是界面「对方画面」的引用，
        // 盖上一份没有画面轨的空流，对方的画面会当场冻住（见
        // `remote_stream_choice.dart` 里记的那次真机事故）。
        debugPrint('[通话] 这一路远端轨不进画面（kind=${track.kind}，没有 stream）');
      case RemoteStreamAction.wrapTrack:
        // 极端情况：对方只推了 track 没推 stream，而且这就是画面、手里还没有。
        // 老端读 `event.streams[0]`，这里自己包一个流，不然对方的画面会整个丢。
        try {
          final stream = await createLocalMediaStream(uuidV4());
          await stream.addTrack(track);
          _remote = stream;
          _onRemoteStream?.call(stream);
        } catch (error) {
          debugPrint('[通话] 收远端流失败：$error');
        }
    }
  }

  /// 手里这份远端流有没有画面轨（决定新来的一路轨能不能顶掉它）
  bool get _remoteHasVideo => _remote?.getVideoTracks().isNotEmpty ?? false;

  void _handleConnectionState(RTCPeerConnectionState state) {
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _onConnected?.call();
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        _onConnectionFailed?.call(
          const CallMediaException('ICE 连接失败（可能要 TURN）'),
        );
      default:
        break;
    }
  }

  Future<void> _safeDispose(MediaStream? stream) async {
    if (stream == null) return;
    try {
      // 老端 `closeLocalMedia`：把每条 track 停掉（摄像头灯才会灭）
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
    } catch (error) {
      debugPrint('[通话] 释放媒体流失败：$error');
    }
  }

  Future<void> _safeClose(RTCPeerConnection? pc) async {
    if (pc == null) return;
    try {
      await pc.close();
      await pc.dispose();
    } catch (error) {
      debugPrint('[通话] 关闭连接失败：$error');
    }
  }
}

/// 站点配置变了（WS `updateConfig`）就重新算 ICE 列表 —— 引擎在**建连接时**才读它，
/// 所以热更新对下一通电话生效。
///
/// ⚠️ **这里刻意不 watch 会话状态**（以前是 `ref.watch(sessionStoreProvider)`）：
/// 那是 2026-09-20 真机上「被推送叫醒的来电：响一声就断、界面卡死、点接听没反应」
/// 的根因 —— 控制器会 watch 本 provider，于是**任何**会话变化（配置热更新、多端标记、
/// 设置写入）都会把正在进行的通话整个重建：控制器被 dispose（`dispose()` 里会
/// `tones.stopRing()`、关媒体、`view.dispose()`），而通话页挂在旧控制器上再也
/// 不会更新。惰性读取既没有这个副作用，语义也一模一样。
final callMediaEngineProvider = Provider<CallMediaEngine>((ref) {
  // 就在本引擎里建一份真引擎（手机一直是这一份；桌面是**兜底**那一份，
  // 见下面 `CallWindowMediaEngine` 的 `fallbackFactory`）。
  CallMediaEngine local() => WebrtcCallMediaEngine.withLazyIceServers(
    iceServers: () => CallMediaConfig.iceServers(
      ref.read(sessionStoreProvider).config.chatInfo,
    ),
    // 服务端签发的短时 TURN 凭据（2026-09-26）：拿不到就是空列表，
    // 这条连接就与过去完全一样（只有 STUN）。`read` 不 `watch` —— 理由见上。
    turnIceServers: () => ref.read(turnCredentialServiceProvider).iceServers(),
  );

  // 桌面（2026-10-04）：媒体引擎搬进**独立通话窗**——`MediaStream` 过不了引擎
  // 边界，画面只能在拿流的那颗引擎里渲染，所以那边才是真引擎；主窗口这边留一层
  // 代理，状态机与信令照旧在主窗口（见 `call_window_media_engine.dart`）。
  //
  // 开关是 `callWindowEnabledProvider`（桌面且不是测试；**不是**桌面版式那个
  // 开关 —— 理由写在它上面）。
  if (ref.watch(callWindowEnabledProvider)) {
    return CallWindowMediaEngine(
      transport: ref.watch(callWindowTransportProvider),
      fallbackFactory: local,
    );
  }
  return local();
});
