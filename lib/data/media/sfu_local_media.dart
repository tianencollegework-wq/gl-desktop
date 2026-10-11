import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
// 只取这一个：`flutter/services.dart` 里其它名字与 `flutter_webrtc` 有重名
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../domain/call/call_media_config.dart';
import '../../domain/group_call/sfu_transport.dart';
import 'desktop_screen_capture.dart';
import 'shared_window_watch.dart';

/// 群通话的本机媒体：**只采一次**，发布会话与接收会话共用同一条轨道。
///
/// 这是与 1:1 那套（`WebrtcCallMediaEngine`）最大的结构差别：那边「采媒体」与
/// 「唯一一条连接」是写在一起的，群通话里本地媒体必须与连接解耦（媒体一份、
/// 会话 N 条）。
///
/// 屏幕共享与 1:1 一样走系统投屏（`getDisplayMedia`），但**取流之前**必须先拿到
/// 投屏同意并把前台服务类型升上 `mediaProjection`（Android 14 的硬要求，
/// 见 [requestScreenSharePermission] 的说明）—— 中间那步由控制器做。
class WebrtcSfuLocalMedia implements SfuLocalMedia {
  MediaStream? _mic;
  MediaStream? _screen;

  /// 这一次共享的是哪个源（桌面才有；安卓上是 null）：
  /// 窗口源要重建采集时，得按**同一个源**再取一次。
  String? _screenSourceId;

  /// 这一次共享要不要**电脑的声音**（重建采集时按同一个口径再取一次）
  bool _screenWithAudio = false;

  /// 盯着「被共享的那扇窗」：最小化 / 藏起来之后再回来 → 重建采集
  /// （见 [SharedWindowWatch]；整块屏幕与非 Windows 上是 null）
  SharedWindowWatch? _windowWatch;

  /// 正在重建采集（防止两次重建叠在一起：第二次会把刚取到的流又放掉）
  bool _rebuildingScreen = false;

  /// 「本机屏幕轨换了」的监听方（房间那边把新轨挂回同一个 mid）
  final Set<VoidCallback> _screenTrackListeners = <VoidCallback>{};

  /// 取本机麦克风。
  ///
  /// 失败（没权限 / 没设备 / 被别的应用占着）原样抛给上层：错误文案由界面决定，
  /// 这一层不猜。
  @override
  Future<void> startMicrophone() async {
    if (_mic != null) return;
    final stream = await navigator.mediaDevices.getUserMedia(
      CallMediaConfig.localMediaConstraints(video: false),
    );
    _mic = stream;
  }

  /// 音频路由：免提（扬声器）/ 听筒。
  ///
  /// 与 1:1 那条走的是同一个插件接口（`Helper.setSpeakerphoneOn`）；不调的后果是
  /// 安卓按通话模式默认走听筒 —— 群里的人说话会小得像在很远的地方，
  /// 而微信里群语音默认就是免提。**必须**在拿到媒体之后再调。
  ///
  /// 桌面（Windows/Linux）没有这条路由（插件只在 Apple/Android 接了
  /// `enableSpeakerphone`）：抛出来的 `MissingPluginException` 当成功 —— 桌面
  /// 本来就等于「外放」。1:1 那条路上同一个坑的后果更重，见
  /// `call_media_engine.dart` 里那条注释。
  @override
  Future<void> setSpeakerEnabled(bool enabled) async {
    try {
      await Helper.setSpeakerphoneOn(enabled);
    } on MissingPluginException {
      // 平台没有这条路由：当作已经切到外放
    }
  }

  /// 屏幕共享在这台设备上能不能用：安卓的系统投屏，桌面（Windows / Linux /
  /// macOS）走原生的 `getDisplayMedia` —— 与 1:1 那条
  /// （`CallMediaEngine.supportsScreenShare`）**逐项同一个口径**，
  /// 同一台电脑上一个能共享、另一个不能，是说不通的。
  @override
  bool get supportsScreenShare => sfuScreenShareSupported;

  @override
  Future<bool> requestScreenSharePermission() async {
    if (!supportsScreenShare) return false;
    // 桌面（Windows/Linux）不需要任何授权：原生的桌面捕获直接就能取。
    // `Helper.requestCapturePermission` 只有 Android/macOS 接了（在别的平台上
    // 它会抛「only support for Android/macOS」），所以先把它择出去 ——
    // macOS 确实要系统那一下授权，依旧走插件。
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) return true;
    return Helper.requestCapturePermission(fullScreenOnly: false);
  }

  @override
  Future<void> startScreen({String? sourceId, bool withAudio = false}) async {
    if (_screen != null || _rebuildingScreen) return;
    // 桌面：带上选中的那个源（不传就是主屏）；安卓上那条系统投屏框由
    // `requestScreenSharePermission` 负责。
    //
    // 要不要把**电脑的声音**也发过去（S12.39，默认不要）在这一层是**可选项**
    // 而不是恒开：取系统声音会把「扬声器里正在放的一切」都抓进来 —— 包括群里别人
    // 的说话声，那就等于把别人的话又替他说一遍（对方会听到自己的回声）。所以由用户
    // 自己决定，面板底下那座开关就是这个。
    //
    // ⚠️ 与 1:1 的差别：那边是单条连接 `replaceTrack`，多一条音频轨挂上去就行；
    // 这边是 SFU，**每条轨都要有自己的名字**才能被别人订阅，所以拿到音频轨后
    // 还要多发布一条 `screen-audio`（见 [publishableTracks]）。
    final stream = await captureDesktopScreen(
      sourceId: sourceId,
      withAudio: withAudio,
    );
    if (stream.getVideoTracks().isEmpty) {
      await disposeStreamQuietly(stream);
      throw StateError('屏幕流里没有画面');
    }
    _screen = stream;
    _screenSourceId = sourceId;
    _screenWithAudio = withAudio;
    // 共享的是**某一个窗口**时盯住它（最小化回来要重建采集，见 [SharedWindowWatch]）
    _watchScreenWindow();
  }

  @override
  Future<void> stopScreen() async {
    _windowWatch?.stop();
    final screen = _screen;
    _screen = null;
    await _disposeStream(screen);
  }

  @override
  void addScreenTrackReplacedListener(VoidCallback listener) =>
      _screenTrackListeners.add(listener);

  @override
  void removeScreenTrackReplacedListener(VoidCallback listener) =>
      _screenTrackListeners.remove(listener);

  /// 盯着「被共享的那扇窗」：只对窗口源做（整块屏幕没有最小化这回事，非 Windows
  /// 上装不上探针），拿不到就不盯。
  void _watchScreenWindow() {
    final watch = watchSharedWindow(
      sourceId: _screenSourceId,
      onRestored: () => unawaited(_rebuildScreenCapture()),
    );
    if (watch == null) return;
    _windowWatch = watch;
  }

  /// 被共享的窗口回来了：**重建一次采集**（根因与顺序见 `desktop_screen_capture.dart`）。
  ///
  /// 重建成功就叫一声（监听方把新轨挂回原来那个 mid 上）；失败只是记一行日志 ——
  /// 画面本来就卡着，不会比不修更糟，不去动房间里别的东西。
  Future<void> _rebuildScreenCapture() async {
    final old = _screen;
    if (old == null || _rebuildingScreen) return; // 这期间用户已经停了共享
    _rebuildingScreen = true;
    _windowWatch?.stop(); // 等新的取到了再重新盯
    try {
      final fresh = await recaptureDesktopScreen(
        sourceId: _screenSourceId,
        withAudio: _screenWithAudio,
        disposeOld: () async {
          _screen = null;
          await _disposeStream(old);
        },
      );
      _screen = fresh;
      _watchScreenWindow();
      debugPrint('[群通话] 共享窗口回来了，已重建采集（换到新轨）');
    } catch (error) {
      debugPrint('[群通话] 共享窗口回来重建采集失败（这一趟共享就此结束）：$error');
    } finally {
      _rebuildingScreen = false;
      // 成与不成都要叫一声：成功 = 新轨要挂回原位；失败 = 本机已经没有采集了
      // （旧的在重建前就放掉了，这是那个硬顺序的代价），房间那边靠
      // [screenSharing] 分辨这两种情形，把发布与界面收干净。
      for (final listener in _screenTrackListeners.toList(growable: false)) {
        listener();
      }
    }
  }

  @override
  bool get screenSharing => _screen != null;

  /// 当前该发布的轨道：麦克风一直在；共享屏开着时多一条 `screen`。
  ///
  /// 名字（`mic` / `screen`）会进房间注册表：别人靠它知道「这是他的哪条轨」，
  /// 所以是协议的一部分，不能随手改。
  @override
  List<SfuLocalTrack> get publishableTracks => <SfuLocalTrack>[
    const SfuLocalTrack(name: 'mic', kind: 'audio'),
    if (screenSharing) const SfuLocalTrack(name: 'screen', kind: 'video'),
    // 共享屏的**声音**是单独一条轨（S12.39）：SFU 里每条轨都要有自己的名字，
    // 别人靠名字订阅；`screen` 那条只有画面。用户没开那座开关（或者选的源根本
    // 没有声音，比如一个静音的窗口）时它就不在 —— 所以判据是**真的拿到了音频轨**，
    // 而不是"用户勾了那个选项"。
    if (screenAudioSharing)
      const SfuLocalTrack(name: 'screen-audio', kind: 'audio'),
  ];

  /// 共享屏这一次有没有真的抓到声音（没有时就不发布 `screen-audio`）。
  bool get screenAudioSharing => _screen?.getAudioTracks().isNotEmpty ?? false;

  @override
  Future<void> setMicrophoneEnabled(bool enabled) async {
    for (final track in _mic?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
  }

  @override
  Future<void> dispose() async {
    _windowWatch?.stop();
    final mic = _mic;
    final screen = _screen;
    _mic = null;
    _screen = null;
    _screenTrackListeners.clear();
    await _disposeStream(screen);
    await _disposeStream(mic);
  }

  /// 按 track 名找本机轨道（连接层用它把轨道挂到 transceiver 上）
  MediaStreamTrack? trackOf(String trackName) => switch (trackName) {
    'mic' => _mic?.getAudioTracks().firstOrNull,
    'screen' => _screen?.getVideoTracks().firstOrNull,
    'screen-audio' => _screen?.getAudioTracks().firstOrNull,
    _ => null,
  };

  Future<void> _disposeStream(MediaStream? stream) async {
    if (stream == null) return;
    try {
      // 每条 track 都 stop：麦克风/投屏的"正在使用"标记才会消失
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
    } catch (error) {
      debugPrint('[群通话] 释放本机媒体失败：$error');
    }
  }
}

/// 本机媒体：麦克风 + 屏幕（**只采一次**，两条会话共用同一条轨道）
final sfuLocalMediaProvider = Provider<SfuLocalMedia>(
  (ref) => WebrtcSfuLocalMedia(),
);

/// 当前平台能不能共享屏幕：安卓的系统投屏，以及桌面原生的 `getDisplayMedia`。
///
/// 界面据此决定要不要画那颗「共享屏幕」按钮 —— 画一颗点不动的按钮比不画更糟。
/// 桌面那条是 S12.38 开的：以前这里只认安卓，于是电脑上群里**根本没有共享屏这颗钮**
/// （1:1 通话在 Windows 上早就有了，群通话没有是说不通的）。
bool get sfuScreenShareSupported =>
    !kIsWeb &&
    (Platform.isAndroid ||
        Platform.isWindows ||
        Platform.isMacOS ||
        Platform.isLinux);
