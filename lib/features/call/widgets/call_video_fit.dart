/// 「这一路画面放进这块区域」该用哪一档放法（S12.33）。
///
/// 通话里两路画面的比例经常差得很开：**电脑屏幕**是 16:10（这台机器 3072×1920），
/// 而**手机那块区域**是 9:19.5（竖长条）。`cover`（铺满）在这种差距下会裁掉一大半 ——
/// 用户 2026-10-05 报的就是它：「电脑共享屏幕，手机端看到的好像是不完整的」。
///
/// 算一遍（3072×1920 放进 390×700）：`cover` 的缩放取 `max(390/3072, 700/1920)`
/// = 0.365，画出来是 1121×700 —— 手机那块 390 宽只装得下其中 **35%**，屏幕左右
/// 两边直接没了。同一块屏换成 `contain` 是 390×244，整幅都在，上下留黑边。
///
/// 所以这里按**几何**判，不看信令（1:1 没有「对方在共享屏幕」这条信令，见
/// `call_desktop_page.dart` 里那句注释）：
///
/// * `cover` 会裁掉的比例超过 [severeCrop]（默认 35%）→ 用 `contain`（完整放）；
/// * 否则还是 `cover`（铺满，四周不留黑边）。
///
/// 摄像头那一路（竖屏画面放进竖屏区域）裁掉的比例通常只有 0~10%，仍然铺满；
/// 而横过来拿的手机（16:9 画面）、电脑屏幕这两种情况都会被判成「完整放」——
/// 宁可留黑边，也不能把对方屏幕上的角落丢掉。群通话那条路本来就有信令
/// （`sharedScreen`），这里补的是 1:1 这一条。
library;

import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCVideoViewObjectFit;

/// `cover`（铺满）之下，这块区域里能看到原画面的百分之多少（0~1）。
///
/// 尺寸有任何一项不是正数（还不知道画面多大 / 区域还没量出来）时返回 1 ——
/// 也就是「没裁」，让调用方按原来的口径走。
double coverVisibleFraction(Size frame, Size area) {
  if (frame.width <= 0 ||
      frame.height <= 0 ||
      area.width <= 0 ||
      area.height <= 0) {
    return 1;
  }
  final scale = math.max(area.width / frame.width, area.height / frame.height);
  final visibleWidth = math.min(area.width / scale, frame.width);
  final visibleHeight = math.min(area.height / scale, frame.height);
  return (visibleWidth * visibleHeight) / (frame.width * frame.height);
}

/// 这一路画面放进这块区域，`cover` 会不会裁掉太多（默认超过 35% 就算多）
bool coverCropsTooMuch(Size frame, Size area, {double severeCrop = 0.35}) =>
    1 - coverVisibleFraction(frame, area) > severeCrop;

/// 最终用哪一档放法。
///
/// * [fill] 不是 null = **用户自己挑过**（双击那一下）：照他挑的来，不再自动；
/// * [fill] 为 null = 自动：按 [coverCropsTooMuch] 判；
/// * 还不知道画面多大（[frame] 为 null / 0）时按 `cover` —— 摄像头那一套默认，
///   等原生把第一帧的尺寸报上来（`CallVideoView.onFrameSize`）再算。
///
/// 这里刻意做成**纯函数**：比例这件事最容易看走眼，单测里把真机的几个尺寸
/// （3072×1920 的屏、1080×1920 的竖屏手机、1920×1080 的横屏手机）都钉住。
RTCVideoViewObjectFit fitFor(
  Size? frame,
  Size area, {
  bool? fill,
  double severeCrop = 0.35,
}) {
  if (fill != null) {
    return fill
        ? RTCVideoViewObjectFit.RTCVideoViewObjectFitCover
        : RTCVideoViewObjectFit.RTCVideoViewObjectFitContain;
  }
  if (frame == null || frame.width <= 0 || frame.height <= 0) {
    return RTCVideoViewObjectFit.RTCVideoViewObjectFitCover;
  }
  return coverCropsTooMuch(frame, area, severeCrop: severeCrop)
      ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
      : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover;
}
