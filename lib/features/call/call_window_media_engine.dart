/// 主窗口这一侧的**媒体代理**（2026-10-04）。
///
/// 为什么要这一层：`MediaStream` 过不了引擎边界，所以真媒体引擎（建连接、取麦克风
/// 摄像头、渲染画面）搬进了通话窗（见 `call_window_bridge.dart` 那段图）。而
/// **状态机与信令还在主窗口**：`CallMachine` 该收 `offer`/`answer`/候选，通话记录
/// 也该由主窗口那条唯一的 WS 写。两边于是靠这层代理接起来：
///
/// * 主窗口调 [open] / [createOffer] / [applyAnswer] / [addIceCandidate] … →
///   转成一条条媒体指令发给通话窗，原样带回它的回话（SDP 是字符串、候选是 map，
///   都过得了通道）；
/// * 通话窗那边流一到就报回来 → 这里翻译成 `onLocalStream` / `onRemoteStream`
///   回调（**只报「到了」**，真流留在那边渲染）。
///
/// 子窗报上来的「家底」（屏幕共享支不支持、有没有摄像头、实际用的 ICE 列表）不
/// 用等 —— 诊断面板/界面随时查，所以在这里缓存一份。
///
/// **兜底**：窗口起不来（原生那边建不出引擎、或写这一版时还没跑起来）时，
/// [open] 会退回「就在主窗口里建一份真引擎」那条老路（[CallMediaEngine] 本来就
/// 是可替换接口）—— 通话绝不能因为一扇窗开不出来而打不出去。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show MediaStream, MediaStreamTrack;

import '../../data/media/call_media_engine.dart';
import '../../domain/call/call_diagnostics.dart';
import 'call_window_bridge.dart';
import 'call_window_host.dart';

/// 窗口回话里那个字符串 → [ScreenShareAudioRoute]。认不出来的当「只共享了画面」
/// （宁可少提一嘴，也绝不能因为一条回话没看懂就抛）。
ScreenShareAudioRoute _audioRouteOf(Object? raw) {
  for (final route in ScreenShareAudioRoute.values) {
    if (route.name == raw) return route;
  }
  return ScreenShareAudioRoute.off;
}

class CallWindowMediaEngine implements CallMediaEngine {
  CallWindowMediaEngine({
    required this.transport,
    required this.fallbackFactory,
  });

  final CallWindowTransport transport;

  /// 窗口起不来时用的那份本地引擎（每次兜底新建一份）
  final CallMediaEngine Function() fallbackFactory;

  /// 本地那份引擎（窗口那条路走不通时用的；建过一次就留着复用 ——
  /// 它本来就与过去那个「应用生命周期一份」的引擎同一种生命周期）
  CallMediaEngine? _fallback;

  /// **这一通电话**是不是退回了主窗口（界面据此决定要不要在主窗口里摆那张通话页）
  bool _degraded = false;

  /// 正缩在通话窗里、还是退回了主窗口那张页
  bool get degraded => _degraded;

  /// 子窗报上来的家底（还没报上来时按「都没有」算）
  bool _supportsScreenShare = false;
  bool _hasLocalVideo = false;
  List<String> _iceDescription = const <String>[];

  /// 流到了没。真流在通话窗里渲染，这里只要一个「有」——
  /// 但 `CallMediaEngine` 的接口是 `MediaStream?`，所以拿一个空壳顶着
  /// （它只会被交给界面；主窗口这条路上界面并不画它，通话页在窗口里）。
  MediaStream? _local;
  MediaStream? _remote;

  void Function(MediaStream stream)? _onLocalStream;
  void Function(MediaStream stream)? _onRemoteStream;
  void Function(Map<String, dynamic> candidate)? _onIceCandidate;
  void Function()? _onConnected;
  void Function(Object error)? _onConnectionFailed;

  /// 那颗通话窗**被关掉了**（✕）：这一通的媒体已经收不回来，该收尾了。
  ///
  /// 由 `CallHost` 接上（它才会挂断：状态机在主窗口那一边）。与
  /// [onConnectionFailed] 不是一回事 —— 那个是「网络不通，换个网络也许还行」，
  /// 这个是「拿画面的那颗引擎已经没了」。区别与处理见 [CallWindowLost]。
  void Function()? onWindowLost;

  // ------------------------------------------------------------------ 事件

  /// 通话窗说的话（由 `CallHost` 挂的那条线转过来）。
  void handleEvent(String event, Map<String, dynamic> data) {
    switch (event) {
      case callEventLocalStream:
        _local = _WindowOnlyStream();
        _onLocalStream?.call(_local!);
      case callEventRemoteStream:
        _remote = _WindowOnlyStream();
        _onRemoteStream?.call(_remote!);
      case callEventIceCandidate:
        final raw = data['candidate'];
        if (raw is Map) {
          _onIceCandidate?.call(Map<String, dynamic>.from(raw));
        }
      case callEventConnected:
        _onConnected?.call();
      case callEventFailed:
        _onConnectionFailed?.call(
          CallMediaException('${data['error'] ?? '通话窗报告连接失败'}'),
        );
      case callEventCapabilities:
        _supportsScreenShare = data['supportsScreenShare'] == true;
        _hasLocalVideo = data['hasLocalVideo'] == true;
        final ice = data['iceServersDescription'];
        if (ice is List) {
          _iceDescription = <String>[for (final item in ice) '$item'];
        }
      default:
        debugPrint('[通话窗口] 不认识的事件：$event');
    }
  }

  // ------------------------------------------------------------------ 转发

  /// 媒体指令：窗口那条路走不通就退回本地引擎（只退一次）。
  Future<T> _send<T>(
    String method,
    Future<T> Function(CallMediaEngine engine) local, [
    Map<String, dynamic>? args,
    // 窗口那条回话是能过通道的东西（字符串/map/数字），要变成枚举这类东西时
    // 由调用方给一个解码器（目前只有共享声音那条路用，见 [startScreenShare]）
    T Function(Object? raw)? decode,
  ]) async {
    // 注：`_send` 每次都会先看 `_degraded`（上面那个 getter 就是给它与界面看的）
    if (_degraded) return local(_useFallback());
    try {
      final raw = await transport.invokeMedia(method, args);
      return decode == null ? raw as T : decode(raw);
    } on Object catch (error) {
      // 只有「**窗口叫不应**」才退回主窗口里的引擎（那一层是老规矩：通话绝不
      // 因为一扇窗开不出来而打不出去）。
      //
      // 窗口**答了「这条指令失败」**则是另一回事：说明通话窗那颗引擎就在正常
      // 跑，只是这一条没做成。那种情况把整通电话搬回主窗口毫无好处 —— 同一台
      // 机器、同一个错，反而把通话窗扔成一具空壳、界面再回到主窗口。原样抛
      // 给调用方（控制器本来就有失败处理）。
      //
      // 2026-10-05 真机就是这么坏的：桌面没有「切换扬声器」这条路由，它抛了一下，
      // 整通电话就退回了主窗口 —— 见 `call_media_engine.dart::setSpeakerEnabled`。
      // 窗**起来过、又被关掉**：媒体已经随那颗引擎一道没了，退回主窗口里的引擎
      // 只会画出一张没声音没画面、连「挂断」都点不到的空壳页（见 [CallWindowLost]）。
      // 所以这一种交给宿主收尾（它才拿得到状态机），并把错原样抛出去。
      if (error is CallWindowLost) {
        _reportWindowLost(method);
        rethrow;
      }
      if (!isCallWindowUnreachable(error)) rethrow;
      debugPrint('[通话窗口] 媒体指令 $method 失败，退回主窗口里的引擎：$error');
      _degraded = true;
      // 那扇窗从这一刻起就是具空壳（它那颗引擎再也收不到指令了），而界面马上就
      // 要在主窗口里再摆一页 —— 两扇一起留在屏幕上就是用户 2026-10-05 那张
      // 截图（两份通话界面）。所以退化这一下顺手把窗收掉（`closeWindow()` 只发
      // `bye` 让窗口自己关，主窗口这边的 `_spec` / `_windowOpen` 不归它管，
      // 挂断那条路照旧）。
      unawaited(transport.closeWindow());
      return local(_useFallback());
    }
  }

  /// 探到「那颗窗已经没了」（见 [CallWindowLost]）：交给宿主收尾 + 把那扇
  /// 已经不存在的窗清干净。幂等（宿主那边也有一道闸）。
  void _reportWindowLost(String method) {
    debugPrint('[通话窗口] 那颗窗已经被关掉了（$method）：这一通按结束收尾');
    _degraded = true;
    unawaited(transport.closeWindow());
    onWindowLost?.call();
  }

  CallMediaEngine _useFallback() {
    final existing = _fallback;
    if (existing != null) return existing;
    final engine = fallbackFactory();
    _fallback = engine;
    // 就地接上：退回本地之后，事件由这份引擎自己报——那边的回调要跟这边是同一批
    engine.onLocalStream = (stream) {
      _local = stream;
      _onLocalStream?.call(stream);
    };
    engine.onRemoteStream = (stream) {
      _remote = stream;
      _onRemoteStream?.call(stream);
    };
    engine.onIceCandidate = (candidate) => _onIceCandidate?.call(candidate);
    engine.onConnected = () => _onConnected?.call();
    engine.onConnectionFailed = (error) => _onConnectionFailed?.call(error);
    return engine;
  }

  /// 发一条不需要等结果的（静音/摄像头这类开关；失败只记一笔）
  void _fire(String method, Map<String, dynamic> args) {
    unawaited(
      _send<Object?>(
        method,
        (engine) => _localCall(engine, method, args),
        args,
      ).catchError((Object error) {
        debugPrint('[通话窗口] $method 没送到：$error');
        return null;
      }),
    );
  }

  Future<void> _localCall(
    CallMediaEngine engine,
    String method,
    Map<String, dynamic> args,
  ) async {
    switch (method) {
      case 'setMicrophoneEnabled':
        engine.setMicrophoneEnabled(args['enabled'] == true);
      case 'setCameraEnabled':
        engine.setCameraEnabled(args['enabled'] == true);
      case 'toggleCamera':
        await engine.toggleCamera();
      case 'setSpeakerEnabled':
        await engine.setSpeakerEnabled(args['enabled'] == true);
      default:
        throw UnsupportedError(method);
    }
  }

  // ------------------------------------------------------------------ 接口

  @override
  Future<void> open({required bool video}) async {
    // 每一通电话都**再试一次**独立窗口：上一通窗口没起来，不该让后面几通全部
    // 退回主窗口。
    //
    // 窗口那条路走不通时 [open] 就会退回本地引擎 —— 退回之后窗口那边没人听，
    // 界面也回到主窗口那张页（`CallHost` 看 [degraded]）。
    _degraded = false;
    await _send<void>(
      'open',
      (engine) => engine.open(video: video),
      <String, dynamic>{'video': video},
    );
  }

  @override
  Future<String> createOffer({required bool video}) => _send<String>(
    'createOffer',
    (engine) => engine.createOffer(video: video),
    <String, dynamic>{'video': video},
  );

  @override
  Future<String> acceptOffer(String sdp, {required bool video}) =>
      _send<String>(
        'acceptOffer',
        (engine) => engine.acceptOffer(sdp, video: video),
        <String, dynamic>{'sdp': sdp, 'video': video},
      );

  @override
  Future<void> applyAnswer(String sdp) => _send<void>(
    'applyAnswer',
    (engine) => engine.applyAnswer(sdp),
    <String, dynamic>{'sdp': sdp},
  );

  @override
  Future<void> addIceCandidate(Map<String, dynamic> candidate) => _send<void>(
    'addIceCandidate',
    (engine) => engine.addIceCandidate(candidate),
    <String, dynamic>{'candidate': candidate},
  );

  @override
  void setMicrophoneEnabled(bool enabled) =>
      _fire('setMicrophoneEnabled', <String, dynamic>{'enabled': enabled});

  @override
  void setCameraEnabled(bool enabled) =>
      _fire('setCameraEnabled', <String, dynamic>{'enabled': enabled});

  @override
  Future<void> toggleCamera() =>
      _send<void>('toggleCamera', (engine) => engine.toggleCamera());

  @override
  Future<void> setSpeakerEnabled(bool enabled) => _send<void>(
    'setSpeakerEnabled',
    (engine) => engine.setSpeakerEnabled(enabled),
    <String, dynamic>{'enabled': enabled},
  );

  /// ⚠️ 这里**不能**写成 `_fallback?.supportsScreenShare ?? _supportsScreenShare`：
  /// `??` 只在左边是 null 时才兜底，而 `bool` 永远不是 null —— 那样一写，
  /// **一旦兜底引擎建过一份（哪怕是很早以前那一通），子窗报上来的家底就永远
  /// 作废了**（下一通又走通话窗时，界面/诊断拿到的还是本地那份答案）。
  /// 判据只能是「现在走的是哪条路」（[_degraded]）。
  @override
  bool get supportsScreenShare => _degraded
      ? (_fallback?.supportsScreenShare ?? _supportsScreenShare)
      : _supportsScreenShare;

  @override
  Future<bool> requestScreenSharePermission() => _send<bool>(
    'requestScreenSharePermission',
    (engine) => engine.requestScreenSharePermission(),
  );

  /// 共享哪一块屏幕（桌面「整个屏幕 / 某个窗口」那个选择）要一路带到通话窗那颗
  /// 引擎里 —— 取屏幕流的是它，主窗口这边看不到源列表（见 `screen_share_picker.dart`）。
  @override
  Future<ScreenShareAudioRoute> startScreenShare({
    String? sourceId,
    bool withAudio = false,
  }) => _send<ScreenShareAudioRoute>(
    'startScreenShare',
    (engine) =>
        engine.startScreenShare(sourceId: sourceId, withAudio: withAudio),
    <String, dynamic>{'sourceId': sourceId, 'withAudio': withAudio},
    // 枚举过不了通道：窗口回的是 `ScreenShareAudioRoute.name`
    (raw) => _audioRouteOf(raw),
  );

  @override
  Future<void> stopScreenShare() =>
      _send<void>('stopScreenShare', (engine) => engine.stopScreenShare());

  /// 退回主窗口之后，实际用这份 ICE 列表的是本地引擎（与上一条同一个理由）
  @override
  List<String> get iceServersDescription => _degraded
      ? (_fallback?.iceServersDescription ?? _iceDescription)
      : _iceDescription.isNotEmpty
      ? _iceDescription
      : (_fallback?.iceServersDescription ?? const <String>[]);

  @override
  Future<CallMediaSample> sampleStats() async {
    // 判据是「**现在**走哪条路」，不是「以前建过兜底引擎没有」：上一通退回过
    // 本地引擎、这一通又走通话窗时，统计该问通话窗要（同 [supportsScreenShare]）。
    final fallback = _fallback;
    if (fallback != null && _degraded) return fallback.sampleStats();
    try {
      final raw = await transport.invokeMedia('sampleStats');
      if (raw is Map) {
        return callSampleFrom(Map<String, dynamic>.from(raw));
      }
    } on Object catch (error) {
      // 这一条**一秒就跳一下**（`call_controller.dart::_onTick`：接通后每 3 秒
      // 采一次），所以它天然是「那扇窗还在不在」的免费探针 —— 用户 ✕ 掉窗之后，
      // 第一条探到它的几乎总是这里。
      if (error is CallWindowLost) _reportWindowLost('sampleStats');
      debugPrint('[通话窗口] 取统计失败（当空采样）：$error');
    }
    return const CallMediaSample();
  }

  @override
  MediaStream? get localStream => _fallback?.localStream ?? _local;

  @override
  MediaStream? get remoteStream => _fallback?.remoteStream ?? _remote;

  /// 退回主窗口之后，有没有摄像头也是本地那份引擎说了算（同上）
  @override
  bool get hasLocalVideo =>
      _degraded ? (_fallback?.hasLocalVideo ?? _hasLocalVideo) : _hasLocalVideo;

  @override
  Future<void> close() async {
    if (_degraded) return _useFallback().close();
    try {
      await transport.invokeMedia('close');
    } on Object catch (error) {
      // 挂断时那条线可能已经没了（窗口被用户关了 / 子引擎正在销毁）：这里
      // **不再退回本地引擎** —— 为了一份本来就没建过的媒体而新建一份，往后
      // 每一通电话都得用那份错的引擎。
      debugPrint('[通话窗口] 关媒体没送到（窗口那边可能已经关了）：$error');
    }
  }

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
}

/// 只用来回答「流到了没」的空壳。
///
/// 真流在通话窗那颗引擎里（`MediaStream` 过不了引擎边界）。这个对象不会被
/// 渲染：主窗口这条路上通话页是**窗口里那张**，主窗口自己那张只在兜底
/// （[CallWindowMediaEngine.degraded]）时才摆出来，那时用的已经是本地真流。
///
/// ⚠️ `noSuchMethod` 不是万灵药：接口里**非空**的那几个（`id` / `ownerTag` 是
/// 非空 `String`，`getTracks()` 那一族是非空 `List`）会被编译器补一层
/// `as String` / `as List` 的隐式转换，返回 null 就在运行期炸成
/// `type 'Null' is not a subtype of type 'String'`。
///
/// 2026-10-05 真机就踩在这上面：退回主窗口那张页去画视频时，`CallVideoView`
/// 读了一下 `stream.id`，画面当场只剩一块黑底（异常被它自己吞了，所以
/// 只留下一行日志）。非空的几个必须给真值。
class _WindowOnlyStream implements MediaStream {
  @override
  final String id = 'gracelink-call-window-stream';

  @override
  String get ownerTag => '';

  @override
  List<MediaStreamTrack> getTracks() => const <MediaStreamTrack>[];

  @override
  List<MediaStreamTrack> getAudioTracks() => const <MediaStreamTrack>[];

  @override
  List<MediaStreamTrack> getVideoTracks() => const <MediaStreamTrack>[];

  /// ⚠️ 接口上还有这么一个**非空**返回的东西（`Future<void>`，已废弃）：
  /// `noSuchMethod` 给它回 null 会炸成
  /// `type 'Null' is not a subtype of 'Future<void>'`。现在没人调它，
  /// 但漏在这儿就是个埋雷（与 `id` / `ownerTag` 是同一类，见类头那段说明）。
  @override
  Future<void> getMediaTracks() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
