/// 桌面「共享某个窗口」这一路上，跟插件打交道的几件杂活。
///
/// 它们凑在一个文件里，是因为一件真机 bug（2026-10-08 用户报的）：
/// **共享一个应用程序 → 把它最小化 → 再点开，对方看到的画面永远停在最小化前
/// 最后一秒（声音一直是好的）**。
///
/// 根因在采集器本体（插件预编译 `libwebrtc.dll` 里的 `WindowCapturerWin`：
/// GDI / `PrintWindow`，没开 WGC，见 REFACTOR_PLAN S12.36）：窗口被最小化期间
/// DWM 不再为它合成新表面，抓回来的永远是最后一帧；窗口回来之后，**同一个采集器
/// 手里的表面也不会再更新** —— 所以只能**换一条新采集**（[recaptureDesktopScreen]）
/// 把画面救回来，而新轨怎么接回原来的位置由各自那条路负责（1:1 与群通话都是
/// `replaceTrack` 挂回同一个发送端 / 同一个 mid，**不重新协商、服务端一行不改**）。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'shared_window_watch.dart';
import 'window_state_probe.dart';

/// 刷新插件里那份「可共享的源列表」（原生 `sources_`）。
///
/// ⚠️ **重建采集之前必须先刷一次**：原生的 `getDisplayMedia` 只在 `sources_`
/// 里找源（插件 `flutter_screen_capture.cc`），而 Windows / macOS 分支**没有**
/// Linux 那段「找不到就重建列表再试一次」的代码 —— 列表里没有那个 id 就直接报
/// `Bad Arguments / source not found!`。
///
/// 失败不抛：这只是重建前的加固，真的取不到源时 [captureDesktopScreen] 会自己报错。
Future<void> refreshDesktopSources() async {
  try {
    await desktopCapturer.getSources(
      types: <SourceType>[SourceType.Screen, SourceType.Window],
    );
  } catch (error) {
    debugPrint('[桌面共享] 刷新可共享源列表失败（重建采集可能找不到源）：$error');
  }
}

/// 取一次屏幕流（原生 `getDisplayMedia`）。
///
/// [sourceId] 是 `desktopCapturer.getSources()` 给的那个 id（选中的整块屏幕 /
/// 某个窗口）：原生读的是 `video -> deviceId -> exact`，不传就是系统默认源
/// （主屏）。[withAudio] = 连**电脑的声音**一起取（Windows 上是 WASAPI 环路，
/// S12.39；共享某个窗口时按 PID 只抓那个程序的声音）。
Future<MediaStream> captureDesktopScreen({
  String? sourceId,
  bool withAudio = false,
}) => navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
  'video': sourceId == null
      ? true
      : <String, dynamic>{
          'deviceId': <String, dynamic>{'exact': sourceId},
        },
  'audio': withAudio,
});

/// 被共享的那扇窗「最小化 / 藏起来 → 再回来」之后，重建一次采集（返回**新的**
/// 屏幕流）。
///
/// 顺序是硬的 —— **先放掉旧的、再取新的**：插件里那个环路声音采集器
/// （`FlutterScreenCapture::loopback_capturer_`）**整个插件只有一份**，旧的视频
/// 采集器被停掉时（`MediaStreamDispose` → `OnStop`）会连带把当时手里那条环路
/// 一起停掉 —— 反过来「先取新的、再放旧的」就会把**刚建好**的那一路声音掐掉
/// （共享带声音时就成了「画面回来了、声音没了」）。
///
/// [disposeOld] 由调用方提供：它知道旧流挂在哪个字段上，而且要在放掉之前先把
/// 引用摘下来。新的流里没有画面时抛 [StateError]（调用方自己决定怎么记这笔账）。
Future<MediaStream> recaptureDesktopScreen({
  required String? sourceId,
  required bool withAudio,
  required Future<void> Function() disposeOld,
}) async {
  await refreshDesktopSources();
  await disposeOld();
  final stream = await captureDesktopScreen(
    sourceId: sourceId,
    withAudio: withAudio,
  );
  if (stream.getVideoTracks().isEmpty) {
    await disposeStreamQuietly(stream);
    throw StateError('重建屏幕采集失败：新的流里没有画面');
  }
  return stream;
}

/// 放掉一条流（每条 track 都 `stop()`：麦克风 / 投屏那盏「正在使用」标记才会消失）。
///
/// **永不抛**：收尾这一下不该把正经动作带崩（与两条路各自原有的口径一致）。
Future<void> disposeStreamQuietly(MediaStream? stream) async {
  if (stream == null) return;
  try {
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();
  } catch (error) {
    debugPrint('[桌面共享] 释放屏幕流失败：$error');
  }
}

/// 盯住「被共享的那扇窗」（见 [SharedWindowWatch]）。
///
/// 返回 null = 不用盯，三种情形都不需要：
/// * **整块屏幕**（`"0"` / 空 / 非数字的 id）—— 屏幕没有「最小化」这回事；
/// * 不是 Windows；
/// * 装不上 Win32 的探针（`desktopWindowProbe()` 给 null）。
///
/// 调用方在停共享 / 释放时要把拿到的看门狗 [SharedWindowWatch.stop] 掉。
SharedWindowWatch? watchSharedWindow({
  required String? sourceId,
  required VoidCallback onRestored,
}) {
  final hwnd = windowHandleOf(sourceId);
  if (hwnd == null) return null;
  final probe = desktopWindowProbe();
  if (probe == null) return null;
  return SharedWindowWatch(visible: probe, onRestored: onRestored)..start(hwnd);
}
