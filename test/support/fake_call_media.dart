import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:gracelinkim/data/media/call_media_engine.dart';
import 'package:gracelinkim/domain/call/call_diagnostics.dart';

/// 一路假流。
///
/// 单测里跑不了原生 WebRTC（`createLocalMediaStream` 要平台通道），
/// 但「有没有拿到流」这件事必须能验，所以用一个 `noSuchMethod` 转发出来的空壳
/// 顶替 [MediaStream]。它的任何方法都不会被真正调用——控制器只把它交给界面。
class FakeMediaStream implements MediaStream {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 假媒体层：记调用轨迹、可以按需报错、可以让测试手动推进
/// 「连上了 / 收到远端流 / 连接失败」这几件事。
class FakeCallMediaEngine implements CallMediaEngine {
  FakeCallMediaEngine({this.label = 'media'});

  /// 出错时写在日志里的名字（两个对端的轨迹分开看）
  final String label;

  /// 调用轨迹，按调用顺序记（断言时序用）
  final List<String> calls = <String>[];

  /// `open` 要抛的错（模拟没权限 / 没设备）
  Object? openError;

  /// `createOffer` 要抛的错
  Object? offerError;

  /// `acceptOffer` 要抛的错
  Object? acceptError;

  bool? openedWithVideo;
  bool microphoneEnabled = true;
  bool cameraEnabled = true;

  /// 免提开关的当前值（初值同老端 `speaker: true`）
  bool speakerEnabled = true;

  /// 诊断面板采到的统计（测试里手动设）
  CallMediaSample statsSample = const CallMediaSample();

  /// 诊断面板显示用的 ICE 服务器描述
  List<String> iceServers = const <String>['stun:stun.example.com:3478（无账号）'];
  int cameraSwitches = 0;
  bool closed = false;
  String? appliedAnswer;

  /// 收到的候选（按顺序）
  final List<Map<String, dynamic>> addedCandidates = <Map<String, dynamic>>[];

  /// 产出的 offer sdp（带 label，方便断言「谁的 sdp」）
  final List<String> createdOffers = <String>[];

  MediaStream? _local;
  MediaStream? _remote;

  /// 让 `open` 卡住：真机上「视频取摄像头要 1~3 秒」，对端的信令往往就在这段
  /// 窗口里到达（见 `call_machine.dart` 里 `_pendingOffer` 的注释）。
  Completer<void>? _openGate;

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

  @override
  MediaStream? get localStream => _local;

  @override
  MediaStream? get remoteStream => _remote;

  @override
  bool get hasLocalVideo => cameraEnabled && _local != null;

  @override
  Future<void> open({required bool video}) async {
    calls.add('open(video=$video)');
    final gate = _openGate;
    if (gate != null) await gate.future;
    if (openError != null) {
      // 与真引擎一致：把原生报错翻译成「是哪个设备被拒了」
      throw CallMediaException(
        '打开本机媒体失败',
        openError,
        classifyMediaFailure(openError, video: video),
      );
    }
    openedWithVideo = video;
    _local = FakeMediaStream();
    _onLocalStream?.call(_local!);
  }

  @override
  Future<String> createOffer({required bool video}) async {
    calls.add('createOffer(video=$video)');
    if (offerError != null) {
      throw CallMediaException('创建 offer 失败', offerError);
    }
    final sdp = 'offer-sdp-$label';
    createdOffers.add(sdp);
    return sdp;
  }

  @override
  Future<String> acceptOffer(String sdp, {required bool video}) async {
    calls.add('acceptOffer(video=$video, sdp=$sdp)');
    if (acceptError != null) {
      throw CallMediaException('响应 offer 失败', acceptError);
    }
    return 'answer-sdp-$label';
  }

  @override
  Future<void> applyAnswer(String sdp) async {
    calls.add('applyAnswer(sdp=$sdp)');
    appliedAnswer = sdp;
  }

  @override
  Future<void> addIceCandidate(Map<String, dynamic> candidate) async {
    calls.add('addIceCandidate(${candidate['candidate']})');
    addedCandidates.add(candidate);
  }

  @override
  void setMicrophoneEnabled(bool enabled) {
    calls.add('setMicrophoneEnabled($enabled)');
    microphoneEnabled = enabled;
  }

  @override
  void setCameraEnabled(bool enabled) {
    calls.add('setCameraEnabled($enabled)');
    cameraEnabled = enabled;
  }

  @override
  Future<void> toggleCamera() async {
    calls.add('toggleCamera()');
    cameraSwitches += 1;
  }

  @override
  Future<void> setSpeakerEnabled(bool enabled) async {
    calls.add('setSpeakerEnabled($enabled)');
    speakerEnabled = enabled;
  }

  /// 这台设备支不支持共享屏幕（S6.7；iOS 为 false，界面就不画那颗钮）
  bool screenShareSupported = true;

  /// 用户在系统投屏框里点了什么（默认同意）
  bool screenShareGranted = true;

  /// `requestScreenSharePermission` 要抛的错
  Object? screenSharePermissionError;

  /// `startScreenShare` 要抛的错（模拟取屏幕流失败）
  Object? screenShareError;

  /// `stopScreenShare` 要抛的错
  Object? stopScreenShareError;

  /// 现在共不共享屏幕
  bool screenSharing = false;

  /// 最近一次 `startScreenShare` 选的源（桌面）：null = 系统默认源（主屏）
  String? lastScreenShareSourceId;

  /// 最近一次 `startScreenShare` 有没有要**电脑的声音**（S12.32）
  bool? lastScreenShareWithAudio;

  /// 共享声音时媒体层回报哪一种发法（真机上由引擎/插件说了算）
  ScreenShareAudioRoute screenShareAudioRoute = ScreenShareAudioRoute.separate;

  /// 可选的「跨层调用轨迹」（与 [FakeCallKeepAlive.trace] 同一条列表）：
  /// 控制器里那个硬顺序（授权 → 升服务类型 → 取屏幕流）就靠它钉住
  List<String>? trace;

  @override
  bool get supportsScreenShare => screenShareSupported;

  @override
  Future<bool> requestScreenSharePermission() async {
    calls.add('requestScreenSharePermission()');
    trace?.add('media.requestScreenSharePermission()');
    final error = screenSharePermissionError;
    if (error != null) {
      throw CallMediaException('请求投屏授权失败', error);
    }
    return screenShareGranted;
  }

  @override
  Future<ScreenShareAudioRoute> startScreenShare({
    String? sourceId,
    bool withAudio = false,
  }) async {
    calls.add(
      'startScreenShare('
      '${sourceId == null ? '' : '$sourceId,'}'
      'audio=${withAudio ? 'on' : 'off'})',
    );
    lastScreenShareSourceId = sourceId;
    lastScreenShareWithAudio = withAudio;
    trace?.add('media.startScreenShare()');
    final error = screenShareError;
    if (error != null) {
      throw CallMediaException('开始共享屏幕失败', error);
    }
    screenSharing = true;
    return withAudio ? screenShareAudioRoute : ScreenShareAudioRoute.off;
  }

  @override
  Future<void> stopScreenShare() async {
    calls.add('stopScreenShare()');
    trace?.add('media.stopScreenShare()');
    final error = stopScreenShareError;
    if (error != null) {
      throw CallMediaException('停止共享屏幕失败', error);
    }
    screenSharing = false;
  }

  @override
  List<String> get iceServersDescription => iceServers;

  @override
  Future<CallMediaSample> sampleStats() async {
    calls.add('sampleStats()');
    return statsSample;
  }

  @override
  Future<void> close() async {
    calls.add('close()');
    closed = true;
    screenSharing = false;
    _local = null;
    _remote = null;
  }

  // ------------------------------------------------------- 测试手动推进的入口

  /// 把 `open` 卡住（模拟「还在取摄像头」）
  void holdOpen() => _openGate = Completer<void>();

  /// 放开 `open`（流取到了）
  void releaseOpen() {
    final gate = _openGate;
    _openGate = null;
    gate?.complete();
  }

  /// 媒体层收集到一条本机候选（老端 `onicecandidate`）
  void emitIceCandidate(Map<String, dynamic> candidate) =>
      _onIceCandidate?.call(candidate);

  /// 收到的远端流（老端 `pc.ontrack`）
  void emitRemoteStream() {
    _remote = FakeMediaStream();
    _onRemoteStream?.call(_remote!);
  }

  /// ICE 连通（老端没监听这个，新端用它标记「通话中」）
  void emitConnected() => _onConnected?.call();

  /// 连接失败（打不通，通常是没有 TURN）
  void emitConnectionFailed(Object error) => _onConnectionFailed?.call(error);
}
