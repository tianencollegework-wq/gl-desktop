import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../call_colors.dart';

/// 一路通话画面（本地或远端）。
///
/// 老端是两个 `<video>` 元素（`localvideo` / `remotevideo`），把
/// `MediaStream` 直接赋给 `srcObject`。原生这边换成 `RTCVideoRenderer`：
/// 先 `initialize()` 建原生渲染器，再挂流。
///
/// **初始化失败要兜住**：组件测试里没有原生渲染器（平台通道不存在），
/// 这里吞掉异常、画一块深色底，界面结构仍然可测。
class CallVideoView extends StatefulWidget {
  const CallVideoView({
    super.key,
    required this.stream,
    this.fit = RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
    this.onFrameSize,
  });

  final MediaStream stream;

  /// 画面怎么放进这块区域。两者是**不同的产品语义**，不能混用一个：
  ///
  /// * `cover`（默认，摄像头画面）：**填满**这块区域，多出来的裁掉 —— 人脸画面铺满
  ///   更好看，四周不留黑边；
  /// * `contain`（**共享屏幕必须用这个**）：把整幅画面**完整**放进来，四周留黑边 ——
  ///   屏幕共享的全部意义就是"看清对方屏幕上的每个角落"，裁掉一边就是真丢信息。
  ///
  /// 真机上踩过：群通话的共享屏一开始也走 `cover`，对方只看到画面中间那一块、
  /// 上下左右全被裁掉（用户原话：「共享屏幕显示不完整」）。
  final RTCVideoViewObjectFit fit;

  /// 原生报上来的**画面尺寸**（`didTextureChangeVideoSize` 那条事件，第一帧之后
  /// 才有）。宿主拿它去算「这块区域该铺满还是完整放」（见 `call_video_fit.dart`）——
  /// 1:1 通话没有「对方在共享屏幕」这条信令，只能按比例自己判
  /// （用户 2026-10-05：「电脑共享屏幕，手机端看到的好像是不完整的」）。
  final ValueChanged<Size>? onFrameSize;

  @override
  State<CallVideoView> createState() => _CallVideoViewState();
}

class _CallVideoViewState extends State<CallVideoView> {
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  bool _ready = false;

  /// 上一次报给宿主的画面尺寸（同一份不重复报：那条事件来得很勤）
  Size _reported = Size.zero;

  /// 当前真的绑在这块渲染器上的**画面轨**（`id` 拼起来）。
  ///
  /// 插件是按轨逐条报 `onTrack` 的：一份流先建出来时里面可能**还没有画面轨**，
  /// 那一刻绑上去等于「绑了个空的」；等画面轨到齐了如果不重绑，就永远是一片黑。
  String _boundVideo = '';

  @override
  void initState() {
    super.initState();
    // 画面尺寸一变就报一声（`RTCVideoRenderer` 是个 `ValueNotifier`，原生那条
    // `didTextureChangeVideoSize` 会把它刷一下）
    _renderer.addListener(_reportFrameSize);
    unawaited(_start());
  }

  @override
  void didUpdateWidget(CallVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_ready) return;
    // 要重绑的两种情况：
    // ① 换了一条流（本地 ⇄ 对方）；
    // ② **还是同一份流，但画面轨刚刚才上来**（见 [_boundVideo]）。
    final video = _videoTrackIds(widget.stream);
    if (identical(oldWidget.stream, widget.stream) && video == _boundVideo) {
      return;
    }
    _renderer.srcObject = widget.stream;
    _boundVideo = video;
    // 换了流：上一路的尺寸作废，等新的报上来（否则会拿旧比例去挑放法）
    _reported = Size.zero;
    debugPrint('[通话] 画面绑流：${widget.stream.id} 画面轨=[$video]');
  }

  /// 一份流里画面轨的「指纹」（判断要不要重绑）
  static String _videoTrackIds(MediaStream stream) =>
      stream.getVideoTracks().map((track) => track.id).join(',');

  void _reportFrameSize() {
    final size = Size(
      _renderer.videoWidth.toDouble(),
      _renderer.videoHeight.toDouble(),
    );
    if (size.width <= 0 || size.height <= 0 || size == _reported) return;
    _reported = size;
    // 诊断（S12.34）：画面尺寸到没到，是「对方画面看不到」时最先要分清的一件事
    debugPrint('[通话] 画面尺寸：${size.width.toInt()}x${size.height.toInt()}');
    // 宿主想要就给它（没有回调也照旧读尺寸、照旧打日志 —— 之前这里因为
    // 早退把「没接回调的那些画面」一起挡在外面，桌面端整个黑屏过）
    widget.onFrameSize?.call(size);
  }

  @override
  void dispose() {
    _renderer.removeListener(_reportFrameSize);
    unawaited(_release());
    super.dispose();
  }

  /// 绑流（`srcObject` 是同步赋值的，老端也是这么写的）
  Future<void> _start() async {
    try {
      await _renderer.initialize();
      _renderer.srcObject = widget.stream;
      _boundVideo = _videoTrackIds(widget.stream);
      // 诊断（S12.34）：「这一块画的是哪条流、里面有没有画面轨」——
      // 「对方画面看不到」时，这行和 `远端轨到了` 那行对着看就能定位。
      debugPrint('[通话] 画面绑流：${widget.stream.id} 画面轨=[$_boundVideo]');
      if (mounted) setState(() => _ready = true);
      _reportFrameSize();
    } catch (error) {
      debugPrint('[通话] 视频渲染器初始化失败：$error');
    }
  }

  Future<void> _release() async {
    try {
      _renderer.srcObject = null;
      await _renderer.dispose();
    } catch (error) {
      // 没初始化成功过就释放，原生层会报错，忽略即可
      debugPrint('[通话] 释放视频渲染器失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) => _ready
      ? RTCVideoView(_renderer, objectFit: widget.fit)
      : const ColoredBox(color: CallColors.backdrop);
}
